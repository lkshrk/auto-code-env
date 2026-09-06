from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import tempfile
import threading
import unittest
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
CA_SCRIPT = ROOT / "shared/workspace-ca.sh"


class BootstrapIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("tofu"), "OpenTofu unavailable")
    def test_single_repository_path_with_runtime_enabled_and_disabled(self):
        source = (ROOT / "common.tf").read_text()
        expression = re.search(r"working_directory\s*=\s*(.*)", source).group(1)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "main.tf").write_text(
                'variable "enabled" { type = bool }\n'
                'locals {\nrepos_set = toset(["https://github.com/example/project.git"])\n'
                'repo_clone_dirs = "project"\n}\n'
                'module "openhands" {\n'
                f'source = "{ROOT.parent / "modules/openhands"}"\n'
                'enabled = var.enabled\n'
                f'working_directory = {expression}\n}}\n'
                'output "directory" {\n'
                f'value = {expression}\n}}\n'
            )
            initialized = subprocess.run(["tofu", f"-chdir={root}", "init", "-backend=false", "-input=false"], capture_output=True, text=True)
            self.assertEqual(initialized.returncode, 0, initialized.stderr)
            for enabled in (False, True):
                result = subprocess.run([
                    "tofu", f"-chdir={root}", "plan", "-input=false", "-lock=false", "-no-color",
                    f"-var=enabled={str(enabled).lower()}",
                ], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('"/home/coder/project"', result.stdout)

    def test_ca_bundle_survives_setup_subprocess_and_retains_public_roots(self):
        self.assertTrue(CA_SCRIPT.is_file())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cert = root / "lan.pem"
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(root / "key.pem"), "-out", str(cert),
                "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost", "-days", "1",
            ], check=True, capture_output=True)
            env = {"HOME": str(root), "PATH": os.environ["PATH"], "CODER_WORKSPACE_CA_PATH": str(cert)}
            command = '. "$1"; bash -c \'true\'; python3 -c \'import json,os; print(json.dumps(dict(os.environ)))\''
            result = subprocess.run(["bash", "-c", command, "bash", str(CA_SCRIPT)], env=env, check=True, capture_output=True, text=True)
            values = json.loads(result.stdout)
            bundle = Path(values["SSL_CERT_FILE"])
            for name in ("NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO"):
                self.assertEqual(values[name], str(bundle))
            self.assertEqual(bundle.stat().st_mode & 0o777, 0o600)
            self.assertIn(cert.read_bytes(), bundle.read_bytes())
            self.assertIn(Path("/etc/ssl/certs/ca-certificates.crt").read_bytes(), bundle.read_bytes())
            context = ssl.create_default_context(cafile=str(bundle))
            self.assertGreater(context.cert_store_stats()["x509_ca"], 1)
            subprocess.run(["openssl", "verify", "-CAfile", str(bundle), str(cert)], check=True, capture_output=True)
            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"trusted")

                def log_message(self, *args):
                    pass

            server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            server_context.load_cert_chain(cert, root / "key.pem")
            with HTTPServer(("127.0.0.1", 0), Handler) as server:
                server.socket = server_context.wrap_socket(server.socket, server_side=True)
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    url = f"https://localhost:{server.server_port}"
                    with self.assertRaises(urllib.error.URLError):
                        urllib.request.urlopen(url, context=ssl.create_default_context(), timeout=5)
                    with urllib.request.urlopen(url, context=context, timeout=5) as response:
                        self.assertEqual(response.read(), b"trusted")
                    module_path = ROOT.parent / "modules/openhands/runtime.py"
                    code = (
                        "import importlib.util,json,os,subprocess,sys;from pathlib import Path;"
                        "s=importlib.util.spec_from_file_location('runtime',sys.argv[1]);"
                        "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);"
                        "env=m.clean_environment(Path.home());"
                        "assert 'CODER_SESSION_TOKEN' not in env;"
                        "subprocess.run([sys.executable,'-c',"
                        "'import urllib.request,sys; assert urllib.request.urlopen(sys.argv[1]).read()==b\"trusted\"',"
                        "sys.argv[2]],env=env,check=True)"
                    )
                    subprocess.run(["python3", "-c", code, str(module_path), url], env={**values, "CODER_SESSION_TOKEN": "synthetic-excluded"}, check=True, capture_output=True, timeout=10)
                finally:
                    server.shutdown()
                    thread.join(timeout=5)
            before = bundle.read_bytes()
            subprocess.run(["bash", "-c", '. "$1"', "bash", str(CA_SCRIPT)], env=env, check=True, capture_output=True)
            self.assertEqual(bundle.read_bytes(), before)

    def test_repeated_export_preserves_custom_ca_and_cleans_failed_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "lan.pem"
            extra = root / "extra.pem"
            source.write_text("local CA fixture\n")
            extra.write_text("custom CA fixture\n")
            env = {"HOME": directory, "PATH": os.environ["PATH"], "CODER_WORKSPACE_CA_PATH": str(source), "NODE_EXTRA_CA_CERTS": str(extra)}
            result = subprocess.run(["sh", "-c", '. "$1"; . "$1"; cat "$SSL_CERT_FILE"', "sh", str(CA_SCRIPT)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(extra.read_text() in result.stdout, "custom CA must survive repeated export")
            env["NODE_EXTRA_CA_CERTS"] = str(root / "missing.pem")
            result = subprocess.run(["sh", "-c", '. "$1"', "sh", str(CA_SCRIPT)], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list((root / ".local/state/coder-environment").glob(".ca-bundle.*")), [])

    def test_absent_ca_does_not_override_existing_trust_configuration(self):
        self.assertTrue(CA_SCRIPT.is_file())
        with tempfile.TemporaryDirectory() as directory:
            env = {"HOME": directory, "PATH": os.environ["PATH"], "CODER_WORKSPACE_CA_PATH": directory + "/absent", "SSL_CERT_FILE": "/custom/roots.pem"}
            result = subprocess.run(["bash", "-c", '. "$1"; printf "%s" "$SSL_CERT_FILE"', "bash", str(CA_SCRIPT)], env=env, check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout, "/custom/roots.pem")
            self.assertFalse((Path(directory) / ".local").exists())


if __name__ == "__main__":
    unittest.main()
