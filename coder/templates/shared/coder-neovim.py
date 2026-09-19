#!/usr/bin/env python3

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile


def install_archive(archive, home, digest):
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != digest:
        raise ValueError("Neovim archive SHA256 mismatch")
    root = home / ".local/share/coder-neovim"
    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".extract-", dir=root) as temporary:
        stage = Path(temporary)
        with tarfile.open(archive) as bundle:
            members = bundle.getmembers()
            names = set()
            for member in members:
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts or not path.parts or path.parts[0] not in {"nvim-linux-x86_64", "nvim-linux-arm64"}:
                    raise ValueError("unsafe Neovim archive path")
                if member.name in names or not (member.isdir() or member.isfile() or member.issym()):
                    raise ValueError("unsupported Neovim archive entry")
                names.add(member.name)
            for member in members:
                target = stage / member.name
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                elif member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.extractfile(member) as source, target.open("xb") as output:
                        shutil.copyfileobj(source, output)
                    target.chmod(member.mode & 0o777)
            for member in members:
                if member.issym():
                    target = stage / member.name
                    link = PurePosixPath(member.linkname)
                    if link.is_absolute():
                        raise ValueError("unsafe Neovim archive symlink")
                    destination = (target.parent / member.linkname).resolve()
                    if stage.resolve() not in destination.parents:
                        raise ValueError("escaping Neovim archive symlink")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.symlink_to(member.linkname)
        bundles = list(stage.iterdir())
        if len(bundles) != 1:
            raise ValueError("expected one Neovim runtime bundle")
        bundle = bundles[0]
        if not os.access(bundle / "bin/nvim", os.X_OK) or not (bundle / "share/nvim/runtime/doc/help.txt").is_file():
            raise ValueError("incomplete Neovim runtime bundle")
        executable = home / ".local/bin/nvim"
        current = root / "current"
        if (executable.exists() or executable.is_symlink()) and (not executable.is_symlink() or os.readlink(executable) != str(current / "bin/nvim")):
            raise ValueError(f"refusing to overwrite existing Neovim: {executable}")
        if current.exists() and not current.is_symlink():
            raise ValueError("refusing non-symlink Neovim current path")
        version = root / digest
        if not version.exists():
            os.replace(bundle, version)
        link = stage / "current"
        link.symlink_to(version)
        os.replace(link, current)
        executable.parent.mkdir(parents=True, exist_ok=True)
        if not executable.is_symlink():
            executable.symlink_to(current / "bin/nvim")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("sha256")
    args = parser.parse_args()
    install_archive(args.archive, Path.home(), args.sha256)


if __name__ == "__main__":
    main()
