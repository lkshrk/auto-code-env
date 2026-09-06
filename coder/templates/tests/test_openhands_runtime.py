import base64
import copy
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest


MODULE = Path(__file__).resolve().parents[2] / "modules" / "openhands"
RUNTIME = MODULE / "runtime.py"
DEFAULT_ENVIRONMENT_NAMES = re.findall(
    r'"([A-Z][A-Z0-9_]*)"',
    (MODULE / "main.tf").read_text().split("default_environment_names = [", 1)[1].split("]", 1)[0],
)
spec = importlib.util.spec_from_file_location("openhands_runtime", RUNTIME)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
RAW = {
    "version": "1.44.0",
    "python_version": "3.12",
    "port": 18001,
    "working_directory": "",
    "runtime_revision": "a" * 64,
    "environment_names": DEFAULT_ENVIRONMENT_NAMES,
}
IMPORT_RUNTIME = (
    "import importlib.util;"
    f"s=importlib.util.spec_from_file_location('runtime',{str(RUNTIME)!r});"
    "r=importlib.util.module_from_spec(s);s.loader.exec_module(r);"
)


def rendered_script(config):
    return (MODULE / "startup.sh.tftpl").read_text().replace(
        "${runtime_base64}", base64.b64encode(RUNTIME.read_bytes()).decode()
    ).replace("${config_base64}", base64.b64encode(json.dumps(config).encode()).decode())


class OpenHandsRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.root = runtime.private_directory(self.home / ".coder-openhands")

    def test_key_persistence_independence_and_permissions(self):
        with runtime.startup_lock(self.root / "startup.lock"):
            first = runtime.load_keys(self.root)
        self.assertNotEqual(first[0], first[1])
        for name in ("session-api-key", "encryption-key"):
            (self.root / name).chmod(0o644)
        with runtime.startup_lock(self.root / "startup.lock"):
            self.assertEqual(first, runtime.load_keys(self.root))
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        for path in self.root.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_partial_or_lost_keys_are_not_regenerated(self):
        runtime.load_keys(self.root)
        (self.root / "encryption-key").unlink()
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            runtime.load_keys(self.root)
        (self.root / "session-api-key").unlink()
        runtime.write_private(self.root / "configured.json", "{}")
        with self.assertRaisesRegex(RuntimeError, "missing"):
            runtime.load_keys(self.root)
        (self.root / "configured.json").unlink()
        (self.home / ".coder-openhands-data").mkdir()
        with self.assertRaisesRegex(RuntimeError, "missing"):
            runtime.load_keys(self.root)

    def test_invalid_and_identical_keys_fail_closed(self):
        runtime.load_keys(self.root)
        runtime.write_private(self.root / "encryption-key", "invalid")
        with self.assertRaisesRegex(RuntimeError, "invalid"):
            runtime.load_keys(self.root)
        runtime.write_private(self.root / "encryption-key", runtime.read_private(self.root / "session-api-key"))
        with self.assertRaisesRegex(RuntimeError, "independent"):
            runtime.load_keys(self.root)

    def test_symlink_and_hardlink_rejection(self):
        target = self.home / "unmanaged"
        target.write_text("untouched")
        link = self.root / "link"
        link.symlink_to(target)
        with self.assertRaises(OSError):
            runtime.write_private(link, "replacement")
        link.unlink()
        os.link(target, link)
        with self.assertRaises(RuntimeError):
            runtime.write_private(link, "replacement")
        self.assertEqual(target.read_text(), "untouched")
        directory = self.root / "linked-directory"
        directory.symlink_to(self.home, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            runtime.private_directory(directory)

    def test_fifo_state_is_rejected_without_blocking(self):
        path = self.root / "fifo"
        os.mkfifo(path)
        with self.assertRaises(RuntimeError):
            runtime.read_private(path)

    def test_startup_missing_uv_fails_and_preserves_generated_keys(self):
        with socket.socket() as bound:
            bound.bind(("127.0.0.1", 0))
            port = bound.getsockname()[1]
        payload = base64.b64encode(json.dumps({**RAW, "port": port}).encode()).decode()
        env = runtime.clean_environment(self.home)
        env["PATH"] = ""
        previous = None
        for _ in range(2):
            result = subprocess.run([sys.executable, "-I", str(RUNTIME), payload], env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("requires uv", result.stderr)
            self.assertNotIn("OpenHands ready", result.stdout)
            keys = runtime.load_keys(self.root)
            if previous is not None:
                self.assertEqual(previous, keys)
            previous = keys
            for key in keys:
                self.assertNotIn(key, result.stdout + result.stderr)
        self.assertFalse((self.root / "server.json").exists())
        self.assertFalse((self.home / ".coder-openhands-data").exists())

    def test_missing_process_record_fails_before_install_or_launch(self):
        runtime.load_keys(self.root)
        runtime.write_private(self.root / "configured.json", "{}")
        payload = base64.b64encode(json.dumps(RAW).encode()).decode()
        env = runtime.clean_environment(self.home)
        env["PATH"] = ""
        result = subprocess.run([sys.executable, "-I", str(RUNTIME), payload], env=env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("process record is missing", result.stderr)
        self.assertNotIn("OpenHands ready", result.stdout)
        self.assertFalse((self.root / "server.json").exists())

    def test_private_write_truncates_existing_content(self):
        path = self.root / "state.json"
        runtime.write_private(path, '{"long": "value"}')
        runtime.write_private(path, "{}")
        self.assertEqual(json.loads(runtime.read_private(path)), {})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_lock_excludes_another_process_and_releases(self):
        path = self.root / "startup.lock"
        code = IMPORT_RUNTIME + f"\nwith r.startup_lock(r.Path({str(path)!r}), timeout=0.1): pass"
        with runtime.startup_lock(path):
            result = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("startup lock timed out", result.stderr)
        result = subprocess.run([sys.executable, "-I", "-c", code], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_concurrent_key_initialization_is_stable(self):
        code = IMPORT_RUNTIME + (
            f"\nroot=r.Path({str(self.root)!r})"
            "\nwith r.startup_lock(root/'startup.lock'):"
            "\n keys=r.load_keys(root)"
            "\n print(r.hashlib.sha256(''.join(keys).encode()).hexdigest())"
        )
        children = [subprocess.Popen([sys.executable, "-I", "-c", code], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(4)]
        outputs = []
        for child in children:
            stdout, stderr = child.communicate(timeout=10)
            self.assertEqual(child.returncode, 0, stderr)
            outputs.append(stdout)
        self.assertEqual(len(set(outputs)), 1)
        self.assertEqual(len(outputs[0].strip()), 64)

    def test_configuration_defaults_and_arbitrary_literal_path(self):
        config = runtime.configuration(RAW, self.home)
        self.assertEqual(config["host"], "127.0.0.1")
        self.assertEqual(config["working_directory"], str(self.home / "workspace"))
        path = str(self.home / "work ' $(false) ${HOME}\nspace")
        self.assertEqual(runtime.configuration({**RAW, "working_directory": path}, self.home)["working_directory"], path)

    def test_invalid_configuration_and_storage_overlap(self):
        cases = [
            ("version", "latest"), ("version", "1.44.0;false"),
            ("python_version", "3.11"), ("python_version", "python3"),
            ("port", 0), ("port", 65536), ("port", 18001.5), ("port", True),
            ("working_directory", "relative"), ("working_directory", "/"),
            ("working_directory", str(self.home)),
            ("working_directory", str(self.root / "workspace")),
            ("working_directory", str(self.home / ".coder-openhands-data")),
            ("runtime_revision", "invalid"),
        ]
        for name, value in cases:
            with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                runtime.configuration({**RAW, name: value}, self.home)
        link = self.home / "workspace-link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            runtime.configuration({**RAW, "working_directory": str(link)}, self.home)

    def test_owned_process_identity_config_and_pid_reuse_checks(self):
        identity = runtime.process_identity(os.getpid())
        record = {"identity": identity, "config": RAW}
        self.assertTrue(runtime.validate_record(record, RAW, identity["command"]))
        with self.assertRaisesRegex(RuntimeError, "configuration/version changed"):
            runtime.validate_record(record, {**RAW, "port": 19001}, identity["command"])
        with self.assertRaisesRegex(RuntimeError, "ownership mismatch"):
            runtime.validate_record(record, RAW, ["unowned"])
        reused = copy.deepcopy(record)
        reused["identity"]["start"] = "-1"
        with self.assertRaisesRegex(RuntimeError, "ownership mismatch"):
            runtime.validate_record(reused, RAW, identity["command"])
        dead = {"identity": {"pid": 2**30}, "config": RAW}
        self.assertFalse(runtime.validate_record(dead, RAW, []))

    def test_port_conflict_without_starting_a_server(self):
        with socket.socket() as bound:
            bound.bind(("127.0.0.1", 0))
            port = bound.getsockname()[1]
            with self.assertRaisesRegex(RuntimeError, "already in use"):
                runtime.require_free_port(port)
            self.assertFalse(runtime.owns_listener(os.getpid(), port))
        runtime.require_free_port(port)

    def test_readiness_timeout_preserves_process(self):
        identity = runtime.process_identity(os.getpid())
        with socket.socket() as bound:
            bound.bind(("127.0.0.1", 0))
            record = {"identity": identity, "config": {**RAW, "port": bound.getsockname()[1]}}
            before = time.monotonic()
            with self.assertRaisesRegex(RuntimeError, "readiness timed out"):
                runtime.wait_ready(record, identity["command"], "test-only-key", timeout=0.03)
            self.assertLess(time.monotonic() - before, 1)
        self.assertEqual(runtime.process_identity(os.getpid()), identity)

    def test_health_requires_authenticated_count_and_all_versions(self):
        info = {name: "1.44.0" for name in ("version", "sdk_version", "tools_version")}
        runtime.validate_health({"status": "ok"}, {"status": "ready"}, 0, info, "1.44.0")
        for count in (None, True, "0", -1, {}):
            with self.subTest(count=count), self.assertRaises(ValueError):
                runtime.validate_health({"status": "ok"}, {"status": "ready"}, count, info, "1.44.0")
        for name in info:
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                runtime.validate_health({"status": "ok"}, {"status": "ready"}, 0, {**info, name: "other"}, "1.44.0")
        with self.assertRaises(ValueError):
            runtime.validate_health({"status": "ok"}, {"status": "initializing"}, 0, info, "1.44.0")
        with self.assertRaisesRegex(RuntimeError, "redirected"):
            runtime.NoRedirect().redirect_request(None, None, 302, None, None, "https://example.org")

    def test_environment_uses_only_managed_keys_and_disables_auxiliary_servers(self):
        env = runtime.clean_environment(self.home)
        self.assertEqual(set(env), {"HOME", "PATH", "LANG", "PYTHONUNBUFFERED"})
        config = runtime.configuration(RAW, self.home)
        keys = runtime.load_keys(self.root)
        server_env = runtime.server_environment(env, self.root, self.home / ".coder-openhands-data", config, keys)
        self.assertEqual(server_env["OH_SESSION_API_KEYS_0"], keys[0])
        self.assertEqual(server_env["OH_SECRET_KEY"], keys[1])
        self.assertEqual(server_env["OH_ENABLE_VSCODE"], "false")
        self.assertEqual(server_env["OH_ENABLE_VNC"], "false")
        self.assertEqual(server_env["OH_WORKSPACE_PATH"], str(self.home / "workspace"))
        self.assertNotIn("SESSION_API_KEY", server_env)

    def test_workspace_environment_reaches_real_child_without_default_secrets(self):
        expected_names = {
            "GIT_SSH_COMMAND", "SSH_AUTH_SOCK", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
            "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "DOCKER_HOST", "DOCKER_TLS_VERIFY",
            "DOCKER_CERT_PATH", "KUBECONFIG", "XDG_CACHE_HOME", "TMPDIR", "NODE_EXTRA_CA_CERTS",
            "SSL_CERT_FILE", "CODER_URL", "NVM_DIR", "PNPM_HOME", "CARGO_HOME", "GOPATH",
        }
        self.assertTrue(expected_names <= set(DEFAULT_ENVIRONMENT_NAMES))
        source = {name: f"test-only-{name}" for name in DEFAULT_ENVIRONMENT_NAMES}
        excluded = {
            "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY",
            "CODER_AGENT_TOKEN", "CODER_SESSION_TOKEN", "OH_SESSION_API_KEYS_1",
            "OH_SECRET_KEY", "OPENHANDS_AGENT_SERVER_CONFIG_PATH", "PYTHONPATH",
            "PYTHONHOME", "PYTHONSTARTUP", "LD_PRELOAD", "BASH_ENV", "ENV", "NODE_OPTIONS",
        }
        source.update({name: "test-only-excluded-value" for name in excluded})
        config = runtime.configuration(RAW, self.home)
        inherited = runtime.inherited_environment(config, source)
        self.assertEqual(inherited, {name: source[name] for name in DEFAULT_ENVIRONMENT_NAMES})
        base = runtime.clean_environment(self.home)
        self.assertFalse(set(base) & set(source))
        keys = runtime.load_keys(self.root)
        env = runtime.server_environment(base, self.root, self.home / ".coder-openhands-data", config, keys, inherited)
        code = (
            "import os,json;"
            "assert len(os.environ['OH_SECRET_KEY'])==64;"
            "assert len(os.environ['OH_SESSION_API_KEYS_0'])==64;"
            "print(json.dumps({k:v for k,v in os.environ.items() if k not in "
            "{'OH_SECRET_KEY','OH_SESSION_API_KEYS_0'}}))"
        )
        result = subprocess.run([sys.executable, "-I", "-c", code], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        received = json.loads(result.stdout)
        for name in DEFAULT_ENVIRONMENT_NAMES:
            self.assertEqual(received[name], source[name])
        for name in excluded - {"OH_SECRET_KEY", "OPENHANDS_AGENT_SERVER_CONFIG_PATH"}:
            self.assertNotIn(name, received)
        self.assertEqual(env["OH_SECRET_KEY"], keys[1])
        self.assertEqual(received["OPENHANDS_AGENT_SERVER_CONFIG_PATH"], str(self.root / "agent-server.json"))

    def test_deliberate_environment_additions_and_reserved_names(self):
        config = runtime.configuration({**RAW, "environment_names": DEFAULT_ENVIRONMENT_NAMES + ["WORKSPACE_API_TOKEN"]}, self.home)
        source = {"WORKSPACE_API_TOKEN": "test-only-explicit-value", "UNAPPROVED_TOKEN": "test-only-omitted"}
        self.assertEqual(runtime.inherited_environment(config, source), {"WORKSPACE_API_TOKEN": source["WORKSPACE_API_TOKEN"]})
        for name in (
            "OH_SECRET_KEY", "OH_ENABLE_VSCODE", "OPENHANDS_AGENT_SERVER_CONFIG_PATH",
            "CODER_AGENT_TOKEN", "CODER_SESSION_TOKEN", "PYTHONPATH", "PYTHONHOME",
            "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "BASH_ENV", "ENV", "SESSION_API_KEY",
            "HOME", "PATH", "GIT_CONFIG_COUNT", "lowercase", "NAME=value", "NAME;false",
        ):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "reserved inherited"):
                runtime.configuration({**RAW, "environment_names": [name]}, self.home)

    def test_installed_144_environment_contract(self):
        try:
            versions = [importlib.metadata.version(package) for package in runtime.PACKAGES]
        except importlib.metadata.PackageNotFoundError:
            self.skipTest("OpenHands packages are not installed; no dependencies installed by tests")
        if versions != ["1.44.0"] * 3:
            self.skipTest("Installed OpenHands packages are not all 1.44.0")
        env = runtime.clean_environment(self.home)
        config = runtime.configuration({**RAW, "python_version": f"{sys.version_info.major}.{sys.version_info.minor}"}, self.home)
        runtime.check_environment(sys.executable, config, env)
        with self.assertRaisesRegex(RuntimeError, "version mismatch"):
            runtime.check_environment(sys.executable, {**config, "version": "0.0.0"}, env)
        with self.assertRaisesRegex(RuntimeError, "version mismatch"):
            runtime.check_environment(sys.executable, {**config, "python_version": "3.99"}, env)

    def test_installed_144_config_contract(self):
        try:
            version = importlib.metadata.version("openhands-agent-server")
        except importlib.metadata.PackageNotFoundError:
            self.skipTest("OpenHands Agent Server not installed")
        if version != "1.44.0":
            self.skipTest("Installed Agent Server is not 1.44.0")
        config = runtime.configuration(RAW, self.home)
        keys = runtime.load_keys(self.root)
        env = runtime.server_environment(runtime.clean_environment(self.home), self.root, self.home / ".coder-openhands-data", config, keys)
        code = (
            "import os;from openhands.agent_server.config import load_config;"
            "c=load_config();"
            "assert c.session_api_keys==[os.environ['OH_SESSION_API_KEYS_0']];"
            "assert c.secret_key.get_secret_value()==os.environ['OH_SECRET_KEY'];"
            "assert not c.enable_vscode and not c.enable_vnc;"
            "assert str(c.conversations_path)==os.environ['OH_CONVERSATIONS_PATH'];"
            "assert str(c.workspace_path)==os.environ['OH_WORKSPACE_PATH'];"
            "assert str(c.conversation_worktree_root)==os.environ['OH_CONVERSATION_WORKTREE_ROOT'];"
            "assert str(c.bash_events_dir)==os.environ['OH_BASH_EVENTS_DIR'];"
            "print('config contract passed')"
        )
        result = subprocess.run([sys.executable, "-I", "-c", code], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("config contract passed", result.stdout)
        for key in keys:
            self.assertNotIn(key, result.stdout + result.stderr)

    def test_shell_syntax_encoding_and_failure_propagation(self):
        sentinel = self.home / "should-not-exist"
        config = {**RAW, "version": "invalid", "working_directory": f"/tmp/'$(touch {sentinel})'\n${{HOME}}"}
        script = rendered_script(config)
        result = subprocess.run(["bash", "--noprofile", "--norc", "-n"], input=script, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = subprocess.run(["bash", "--noprofile", "--norc"], input=script + f"touch '{sentinel}'\n", env=runtime.clean_environment(self.home), text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid OpenHands version", result.stderr)
        self.assertFalse(sentinel.exists())
        self.assertEqual(list(self.root.iterdir()), [])

    def test_opentofu_disabled_contract_is_explicit_and_resource_free(self):
        source = (MODULE / "main.tf").read_text()
        self.assertIn('startup_script = var.enabled ? templatefile(', source)
        self.assertIn('}) : ""', source)
        self.assertIn('default  = false', (MODULE / "variables.tf").read_text())
        self.assertIn('value = local.startup_script', (MODULE / "outputs.tf").read_text())
        for path in MODULE.glob("*.tf"):
            self.assertNotRegex(path.read_text(), r'\b(resource|provider|data)\s+"')

    @unittest.skipUnless(shutil.which("tofu"), "OpenTofu unavailable")
    def test_opentofu_evaluates_disabled_and_enabled_script(self):
        executable = shutil.which("tofu")
        for enabled in (False, True):
            result = subprocess.run(
                [executable, f"-chdir={MODULE}", "console", f"-var=enabled={str(enabled).lower()}"],
                input="base64encode(local.startup_script)\n", capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            script = base64.b64decode(json.loads(result.stdout)).decode()
            if enabled:
                self.assertIn("python3 -I", script)
                result = subprocess.run(["bash", "-n"], input=script, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            else:
                self.assertEqual(script, "")


if __name__ == "__main__":
    unittest.main()
