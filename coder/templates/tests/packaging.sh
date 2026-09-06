#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$script_dir/../../scripts/package-template.sh" <<'PY'
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(sys.argv.pop()).resolve()


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="coder packaging ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.templates = self.root / "coder/templates"
        self.source = self.templates / "dev"
        self.output = self.root / "package"
        self.write("common.tf", 'module "openhands" { source = "./modules/openhands" }\n')
        self.write("backends/kubernetes.tf", 'locals { backend_kind = "kubernetes" }\n')
        self.write("backends/docker.tf", 'locals { backend_kind = "docker" }\n')
        self.write("dev/main.tf", "locals { repos = [] }\n")
        self.write("dev/variables.tf", 'variable "example" { default = "ok" }\n')
        self.write("dev/README.md", "not packaged\n")
        self.write("shared/nested/bootstrap.sh", "exit 0\n").chmod(0o755)
        self.modules = self.root / "coder/modules"
        (self.modules / "openhands/nested").mkdir(parents=True)
        (self.modules / "openhands/main.tf").write_text('variable "config" {}\n')
        (self.modules / "openhands/nested/config.json").write_text('{"enabled": true}\n')

    def write(self, relative, content):
        path = self.templates / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def package(self, success=True):
        result = subprocess.run(["bash", str(SCRIPT), str(self.source), str(self.output)], capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_complete_package_and_immutable_source_snapshot(self):
        self.package()
        self.assertEqual(
            {str(path.relative_to(self.output)) for path in self.output.rglob("*") if path.is_file()},
            {"main.tf", "variables.tf", "common.tf", "kubernetes.tf", "backend", "shared/nested/bootstrap.sh",
             "modules/openhands/main.tf", "modules/openhands/nested/config.json"},
        )
        for name in ("main.tf", "variables.tf"):
            self.assertEqual((self.output / name).read_bytes(), (self.source / name).read_bytes())
        self.assertEqual((self.output / "common.tf").read_bytes(), (self.templates / "common.tf").read_bytes())
        self.assertEqual((self.output / "backend").read_text(), "kubernetes\n")
        self.assertEqual((self.output / "modules/openhands/nested/config.json").read_bytes(), (self.modules / "openhands/nested/config.json").read_bytes())
        self.assertEqual((self.output / "shared/nested/bootstrap.sh").stat().st_mode & 0o777, 0o755)
        (self.source / "main.tf").write_text("changed after packaging\n")
        self.assertEqual((self.output / "main.tf").read_text(), "locals { repos = [] }\n")
        self.assertFalse((self.source / "backend").exists())

    def test_explicit_docker_backend(self):
        self.write("dev/backend", " docker\n")
        self.package()
        self.assertTrue((self.output / "docker.tf").is_file())
        self.assertFalse((self.output / "kubernetes.tf").exists())
        self.assertEqual((self.output / "backend").read_text(), " docker\n")
        self.assertEqual((self.output / "docker.tf").read_bytes(), (self.templates / "backends/docker.tf").read_bytes())

    def test_interpreter_caches_are_not_packaged(self):
        self.write("shared/__pycache__/components.cpython-313.pyc", "cache")
        cache = self.modules / "openhands/__pycache__"
        cache.mkdir()
        (cache / "runtime.cpython-313.pyc").write_text("cache")
        self.package()
        self.assertFalse(list(self.output.rglob("__pycache__")))
        self.assertFalse(list(self.output.rglob("*.pyc")))

    def test_optional_modules(self):
        shutil.rmtree(self.modules)
        self.package()
        self.assertFalse((self.output / "modules").exists())

    def test_invalid_backend_markers(self):
        for marker in ("", "../common", "docker\nkubernetes", "dock er", "/tmp/backend", "missing"):
            with self.subTest(marker=marker):
                self.write("dev/backend", marker)
                self.package(success=False)
                self.assertFalse(self.output.exists())

    def test_reserved_file_collisions(self):
        for name in ("common.tf", "kubernetes.tf"):
            with self.subTest(name=name):
                collision = self.write(f"dev/{name}", "collision\n")
                self.package(success=False)
                self.assertFalse(self.output.exists())
                collision.unlink()

    def test_missing_sources(self):
        for path in (self.source / "main.tf", self.templates / "common.tf", self.templates / "backends/kubernetes.tf", self.templates / "shared"):
            with self.subTest(path=path):
                moved = path.with_name(path.name + ".hidden")
                path.rename(moved)
                self.package(success=False)
                self.assertFalse(self.output.exists())
                moved.rename(path)

    def test_existing_output_is_not_modified(self):
        self.output.mkdir()
        (self.output / "keep").write_text("preserved\n")
        self.package(success=False)
        self.assertEqual((self.output / "keep").read_text(), "preserved\n")

    def test_output_inside_sources_is_rejected(self):
        self.output = self.source / "package"
        self.package(success=False)
        self.assertFalse(self.output.exists())

    def test_symlinks_are_not_packaged(self):
        for path in (self.source / "linked.tf", self.templates / "shared/linked", self.modules / "linked", self.source / "backend"):
            with self.subTest(path=path):
                path.symlink_to(self.templates / "common.tf")
                self.package(success=False)
                self.assertFalse(self.output.exists())
                path.unlink()

    def test_missing_output_parent(self):
        self.output = self.root / "missing/package"
        self.package(success=False)
        self.assertFalse(self.output.exists())

    def test_usage(self):
        result = subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stderr)


unittest.main()
PY
