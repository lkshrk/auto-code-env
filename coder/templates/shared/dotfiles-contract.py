import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def verify(repo):
    for name in ("setup-coder-components.sh", "setup-coder.sh", "setup-hermes.sh",
                 "setup-workspace.sh", "scripts/install-omni-latest.sh", "scripts/volatile-dots.sh"):
        subprocess.run(["bash", "-n", str(repo / name)], check=True, capture_output=True)
    for name in ("coder-components", "coder-core", "coder-client-config", "coder-neovim"):
        source = repo / "scripts" / (name + ".py")
        compile(source.read_text(), str(source), "exec")
    result = subprocess.run(["python3", str(repo / "scripts/coder-components.py"), "--contract"],
                            check=True, capture_output=True, text=True)
    contract = json.loads(result.stdout)
    if contract["version"] != 1 or not contract["required_commands"]:
        raise ValueError("unsupported dotfiles component contract")
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        config = root / "config.json"
        config.write_text(json.dumps(contract["configuration"]))
        subprocess.run(["python3", str(repo / "scripts/coder-core.py"), "check-dots", str(config)],
                       env={"HOME": directory, "PATH": os.environ["PATH"]},
                       check=True, capture_output=True)
    contract.pop("configuration")
    contract["dotfiles_revision"] = subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    return contract


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repo", type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(verify(args.repo.resolve())))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Incompatible preserved dotfiles checkout; update explicitly: {error}\n")


if __name__ == "__main__":
    main()
