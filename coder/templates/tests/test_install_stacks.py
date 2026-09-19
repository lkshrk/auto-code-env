import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SHARED = ROOT / "coder/templates/shared"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HomeSandboxTests(unittest.TestCase):
    """install-stacks.py's binary-linking logic touches real paths under
    $HOME with security-sensitive refuse-to-overwrite checks -- exercise
    it against a real filesystem in a throwaway HOME, no mocks."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="install-stacks-home-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.previous_home = os.environ.get("HOME")
        os.environ["HOME"] = str(self.home)
        self.addCleanup(self._restore_home)
        self.mod = load(SHARED / "install-stacks.py", "install_stacks")

    def _restore_home(self):
        if self.previous_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = self.previous_home

    def write_executable(self, path, content="#!/bin/sh\nexit 0\n"):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(path.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        return path

    def test_link_creates_symlink_and_receipt(self):
        source = self.write_executable(self.home / "src/tool")
        self.mod.link_local_bin(source, "tool")
        target = self.home / ".local/bin/tool"
        self.assertTrue(target.is_symlink())
        self.assertEqual(os.readlink(target), str(source))
        receipt = self.mod.link_state_dir() / "tool"
        self.assertEqual(receipt.read_text().strip(), str(source))

    def test_relink_to_same_source_is_a_no_op(self):
        source = self.write_executable(self.home / "src/tool")
        self.mod.link_local_bin(source, "tool")
        self.mod.link_local_bin(source, "tool")
        target = self.home / ".local/bin/tool"
        self.assertEqual(os.readlink(target), str(source))

    def test_relink_to_new_source_updates_when_previous_matches_receipt(self):
        first = self.write_executable(self.home / "src/tool-a")
        second = self.write_executable(self.home / "src/tool-b")
        self.mod.link_local_bin(first, "tool")
        self.mod.link_local_bin(second, "tool")
        target = self.home / ".local/bin/tool"
        self.assertEqual(os.readlink(target), str(second))

    def test_refuses_to_replace_a_real_file_not_owned_by_a_previous_link(self):
        (self.home / ".local/bin").mkdir(parents=True)
        real_file = self.home / ".local/bin/tool"
        real_file.write_text("not a symlink we made")
        source = self.write_executable(self.home / "src/tool")
        with self.assertRaises(SystemExit):
            self.mod.link_local_bin(source, "tool")

    def test_refuses_to_replace_a_manually_modified_symlink(self):
        first = self.write_executable(self.home / "src/tool-a")
        self.mod.link_local_bin(first, "tool")
        # Something outside our tracking repointed the symlink.
        target = self.home / ".local/bin/tool"
        rogue = self.write_executable(self.home / "rogue/tool")
        target.unlink()
        target.symlink_to(rogue)
        second = self.write_executable(self.home / "src/tool-b")
        with self.assertRaises(SystemExit):
            self.mod.link_local_bin(second, "tool")

    def test_rejects_unsafe_executable_names(self):
        source = self.write_executable(self.home / "src/tool")
        for name in ("../escape", "/abs", "-flag", ""):
            with self.assertRaises(SystemExit):
                self.mod.link_local_bin(source, name)

    def test_refuses_symlinked_receipt_directory(self):
        state_parent = self.home / ".local/state"
        state_parent.mkdir(parents=True)
        real_dir = self.home / "elsewhere"
        real_dir.mkdir()
        (state_parent / "coder-components").symlink_to(real_dir)
        source = self.write_executable(self.home / "src/tool")
        with self.assertRaises(SystemExit):
            self.mod.link_local_bin(source, "tool")

    def test_link_node_commands_requires_absolute_existing_node(self):
        with self.assertRaises(SystemExit):
            self.mod.link_node_commands("relative/bin")
        with self.assertRaises(SystemExit):
            self.mod.link_node_commands(self.home / "no-such-bin")

    def test_link_node_commands_links_present_executables_only(self):
        node_bin = self.home / "node-bin"
        self.write_executable(node_bin / "node")
        self.write_executable(node_bin / "npm")
        self.mod.link_node_commands(node_bin)
        self.assertTrue((self.home / ".local/bin/node").is_symlink())
        self.assertTrue((self.home / ".local/bin/npm").is_symlink())
        self.assertFalse((self.home / ".local/bin/npx").exists())


class OmniCompatibleTests(unittest.TestCase):
    """omni_compatible() shells out to a real `omni` binary on PATH --
    exercised here against a small fake standing in for the real thing,
    same pattern auto-code-env's existing components.py tests use."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="omni-fake-bin-")
        self.addCleanup(self.temp.cleanup)
        self.bin_dir = Path(self.temp.name)
        self.previous_path = os.environ.get("PATH", "")
        os.environ["PATH"] = f"{self.bin_dir}:{self.previous_path}"
        self.addCleanup(lambda: os.environ.__setitem__("PATH", self.previous_path))
        self.previous_omni_version = os.environ.get("OMNI_VERSION")
        self.addCleanup(self._restore_omni_version)
        self.mod = load(SHARED / "install-stacks.py", "install_stacks_omni_compat")
        self.config = Path(self.temp.name) / "config.json"
        self.config.write_text("{}")

    def _restore_omni_version(self):
        if self.previous_omni_version is None:
            os.environ.pop("OMNI_VERSION", None)
        else:
            os.environ["OMNI_VERSION"] = self.previous_omni_version

    def write_fake_omni(self, version="0.10.14", settings_ok=True):
        script = self.bin_dir / "omni"
        script.write_text(
            "#!/bin/sh\n"
            f'if [ "$1" = "--version" ]; then echo "omni version v{version}"; exit 0; fi\n'
            f'exit {0 if settings_ok else 1}\n'
        )
        script.chmod(script.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    def test_missing_binary_is_incompatible(self):
        os.environ.pop("OMNI_VERSION", None)
        self.assertFalse(self.mod.omni_compatible(str(self.config)))

    def test_matching_pinned_version_is_compatible(self):
        self.write_fake_omni(version="0.10.14")
        os.environ["OMNI_VERSION"] = "0.10.14"
        self.assertTrue(self.mod.omni_compatible(str(self.config)))

    def test_mismatched_pinned_version_is_incompatible(self):
        self.write_fake_omni(version="0.9.0")
        os.environ["OMNI_VERSION"] = "0.10.14"
        self.assertFalse(self.mod.omni_compatible(str(self.config)))

    def test_unpinned_version_only_requires_settings_to_load(self):
        self.write_fake_omni(settings_ok=True)
        os.environ.pop("OMNI_VERSION", None)
        self.assertTrue(self.mod.omni_compatible(str(self.config)))

    def test_broken_config_is_incompatible(self):
        self.write_fake_omni(settings_ok=False)
        os.environ.pop("OMNI_VERSION", None)
        self.assertFalse(self.mod.omni_compatible(str(self.config)))


class OmniReleaseBaseTests(unittest.TestCase):
    def setUp(self):
        self.mod = load(SHARED / "install-stacks.py", "install_stacks_release_base")
        self.previous = os.environ.get("OMNI_VERSION")
        self.addCleanup(self._restore)

    def _restore(self):
        if self.previous is None:
            os.environ.pop("OMNI_VERSION", None)
        else:
            os.environ["OMNI_VERSION"] = self.previous

    def test_default_targets_latest_release(self):
        os.environ.pop("OMNI_VERSION", None)
        self.assertEqual(self.mod.omni_release_base(), "https://github.com/lkshrk/omni/releases/latest/download")

    def test_pinned_version_targets_exact_release(self):
        os.environ["OMNI_VERSION"] = "0.10.14"
        self.assertEqual(self.mod.omni_release_base(), "https://github.com/lkshrk/omni/releases/download/v0.10.14")

    def test_rejects_non_exact_version(self):
        os.environ["OMNI_VERSION"] = "latest"
        with self.assertRaises(SystemExit):
            self.mod.omni_release_base()


if __name__ == "__main__":
    unittest.main()
