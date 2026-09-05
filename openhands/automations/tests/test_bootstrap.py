"""Exercise installer and packaging with real files, processes and synthetic archives."""

import hashlib
import importlib.util
import io
import json
import os
import platform
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "common"))
import apply
import bootstrap

SPEC = ROOT / "orc/h-cloud-upgrader"
module = importlib.util.spec_from_file_location("tool_setup", SPEC / "bootstrap/setup.py")
installer = importlib.util.module_from_spec(module)
module.loader.exec_module(installer)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def archive(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as bundle:
        for name, contents in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(contents)
            member.mode = 0o755
            bundle.addfile(member, io.BytesIO(contents))
    return output.getvalue()


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.binary = b"#!/bin/sh\nprintf 'fixture 1.2.3\\n'\n"
        self.download = self.root / "release.tar.gz"
        self.download.write_bytes(archive({"bin/tool": self.binary}))
        self.tool = {
            "name": "tool", "version": "1.2.3", "version_match": "1.2.3",
            "version_args": ["--version"], "url": self.download.as_uri(),
            "sha256": sha(self.download.read_bytes()), "member": "bin/tool",
            "binary_sha256": sha(self.binary),
        }
        self.destination = self.root / "bin"
        self.destination.mkdir()

    def test_install_cache_and_repair(self):
        installer.install_tool(self.tool, self.destination)
        self.assertEqual((self.destination / "tool").read_bytes(), self.binary)
        original = self.download.read_bytes()
        self.download.unlink()
        installer.install_tool(self.tool, self.destination)
        self.download.write_bytes(original)
        (self.destination / "tool").write_bytes(b"corrupt")
        installer.install_tool(self.tool, self.destination)
        self.assertEqual((self.destination / "tool").read_bytes(), self.binary)

    def test_bad_download_preserves_existing_binary(self):
        previous = self.destination / "tool"
        previous.write_bytes(b"previous version")
        self.download.write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "download checksum"):
            installer.install_tool(self.tool, self.destination)
        self.assertEqual(previous.read_bytes(), b"previous version")

    def test_bad_binary_and_wrong_version_not_published(self):
        for field, value, message in [
            ("binary_sha256", "0" * 64, "executable checksum"),
            ("version_match", "9.9.9", "unexpected version"),
        ]:
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, message):
                installer.install_tool(self.tool | {field: value}, self.destination)
            self.assertFalse((self.destination / "tool").exists())

    def test_raw_binary(self):
        self.download.write_bytes(self.binary)
        installer.install_tool(self.tool | {"member": None, "sha256": sha(self.binary)}, self.destination)

    def test_archive_links_rejected(self):
        with tarfile.open(self.download, "w:gz") as bundle:
            member = tarfile.TarInfo("bin/tool")
            member.type = tarfile.SYMTYPE
            member.linkname = "/bin/sh"
            bundle.addfile(member)
        self.tool["sha256"] = sha(self.download.read_bytes())
        with self.assertRaisesRegex(ValueError, "regular file"):
            installer.install_tool(self.tool, self.destination)

    def test_setup_failure_prevents_sdk_setup(self):
        setup_dir = self.root / "bootstrap"
        setup_dir.mkdir()
        (setup_dir / "setup.py").write_bytes((SPEC / "bootstrap/setup.py").read_bytes())
        lock = {"platform": f"{platform.system().lower()}/{platform.machine()}",
                "tools": [self.tool | {"sha256": "0" * 64}]}
        (setup_dir / "tools.lock.json").write_text(json.dumps(lock))
        (setup_dir / "sdk-setup.sh").write_text("touch sdk-was-started\n")
        result = subprocess.run(
            [sys.executable, str(setup_dir / "setup.py")], cwd=self.root,
            env=os.environ | {"HOME": str(self.root)}, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"checksum mismatch", result.stderr)
        self.assertFalse((self.root / "sdk-was-started").exists())

    def test_unsupported_platform(self):
        lock = self.root / "tools.lock.json"
        lock.write_text(json.dumps({"platform": "unsupported", "tools": []}))
        with self.assertRaisesRegex(ValueError, "Unsupported platform"):
            installer.install(lock, self.root)

    def test_packaging_preserves_preset_and_is_idempotent(self):
        original = {"setup.sh": b"original SDK setup", "main.py": b"original entrypoint",
                    "prompt.txt": b"original prompt"}
        source = archive(original)
        updated = bootstrap.package(source, SPEC / "bootstrap")
        with tarfile.open(fileobj=io.BytesIO(updated)) as bundle:
            for name, data in original.items():
                self.assertEqual(bundle.extractfile("bootstrap/sdk-setup.sh" if name == "setup.sh" else name).read(), data)
            self.assertEqual(bundle.extractfile("bootstrap/setup.py").read(),
                             (SPEC / "bootstrap/setup.py").read_bytes())
        self.assertIsNone(bootstrap.package(updated, SPEC / "bootstrap"))
        with self.assertRaises(ValueError):
            bootstrap.package(archive({"main.py": b""}), SPEC / "bootstrap")

    def test_render_and_smoke_overrides(self):
        body = apply.render(SPEC / "automation.json", SPEC / "prompt.md")
        self.assertEqual(body["setup_script_path"], bootstrap.SETUP)
        self.assertNotIn("BOOTSTRAP_BIN", body["prompt"])
        self.assertNotIn("bootstrap", body)
        smoke = json.loads((SPEC / "smoke.json").read_text())
        dry = apply.render(SPEC / "automation.json", SPEC / "prompt.md", smoke["vars"])
        self.assertIn("dry_run=true", dry["prompt"])
        self.assertIn("max_upgrades=3", dry["prompt"])
        self.assertIn(bootstrap.bin_path(SPEC / "bootstrap"), body["prompt"])

    def test_lock_uses_pinned_https_releases_and_valid_hashes(self):
        lock = json.loads((SPEC / "bootstrap/tools.lock.json").read_text())
        names = []
        for tool in lock["tools"]:
            names.append(tool["name"])
            self.assertTrue(tool["url"].startswith("https://"))
            self.assertNotIn("latest", tool["url"])
            for field in ("sha256", "binary_sha256"):
                self.assertRegex(tool[field], r"^[0-9a-f]{64}$")
        self.assertEqual(len(names), len(set(names)))
        flate = next(t for t in lock["tools"] if t["name"] == "flate")
        self.assertEqual(flate["version"], "v0.6.1")


if __name__ == "__main__":
    unittest.main()
