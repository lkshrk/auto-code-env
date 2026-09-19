import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "shared" / "coder-neovim.py"
spec = importlib.util.spec_from_file_location("coder_neovim", SCRIPT)
neovim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(neovim)


class CoderNeovimTests(unittest.TestCase):
    def archive(self, path, extra=None, content=b"fixture-binary"):
        with tarfile.open(path, "w:gz") as archive:
            entries = [("nvim-linux-x86_64/bin/nvim", content, 0o755),
                       ("nvim-linux-x86_64/share/nvim/runtime/doc/help.txt", b"runtime docs", 0o644)]
            if extra:
                entries.append(extra)
            for name, data, mode in entries:
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = mode
                archive.addfile(member, io.BytesIO(data))
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_full_runtime_archive_atomic_update_and_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "home"
            archive = root / "nvim.tar.gz"
            digest = self.archive(archive)
            with self.assertRaisesRegex(ValueError, "SHA256"):
                neovim.install_archive(archive, home, "0" * 64)
            neovim.install_archive(archive, home, digest)
            neovim.install_archive(archive, home, digest)
            self.assertEqual((home / ".local/bin/nvim").read_bytes(), b"fixture-binary")
            self.assertEqual((home / ".local/share/coder-neovim/current/share/nvim/runtime/doc/help.txt").read_text(), "runtime docs")
            digest = self.archive(archive, content=b"updated")
            neovim.install_archive(archive, home, digest)
            self.assertEqual((home / ".local/bin/nvim").read_bytes(), b"updated")
            digest = self.archive(archive, ("../escaped", b"bad", 0o644))
            with self.assertRaisesRegex(ValueError, "unsafe"):
                neovim.install_archive(archive, home, digest)
            self.assertFalse((root / "escaped").exists())
            self.assertEqual((home / ".local/bin/nvim").read_bytes(), b"updated")

    def test_neovim_preserves_unmanaged_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            target = home / ".local/bin/nvim"
            target.parent.mkdir(parents=True)
            target.write_text("user executable")
            archive = home / "nvim.tar.gz"
            digest = self.archive(archive)
            with self.assertRaisesRegex(ValueError, "overwrite"):
                neovim.install_archive(archive, home, digest)
            self.assertEqual(target.read_text(), "user executable")


if __name__ == "__main__":
    unittest.main()
