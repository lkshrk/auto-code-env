import json
import itertools
import re
import shutil
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
DOTFILES = Path(os.environ.get("CODER_TEST_DOTFILES", ROOT / ".agent_tmp/dotfiles"))
CHECK = ROOT / "coder/templates/shared/dotfiles-contract.py"


class DotfilesContractTests(unittest.TestCase):
    def test_stub_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "setup-coder-components.sh").write_text("#!/bin/bash\ntrue\n")
            result = subprocess.run(["python3", str(CHECK), directory], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    @unittest.skipUnless(DOTFILES.is_dir(), "set CODER_TEST_DOTFILES to exact companion checkout")
    def test_pair_and_negative_selection(self):
        resolver = subprocess.run(["python3", str(DOTFILES / "scripts/coder-components.py"), "--contract"],
                                  capture_output=True, text=True)
        self.assertEqual(resolver.returncode, 0, resolver.stderr)
        selections = ("", "go,python,ts,lua,rust,k8s,gitops,argo,talos,cilium,cnpg,iac,containers,quality,terminal-recording,media", "infra,omni", "unknown-stack")
        for selection in selections:
            result = subprocess.run(["python3", str(CHECK), str(DOTFILES)],
                                    env=dict(os.environ, CODER_OMNI_STACKS=selection), capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, selection != "unknown-stack", result.stderr)
            if result.returncode == 0:
                self.assertEqual(json.loads(result.stdout)["version"], 1)


class PrerequisiteTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("tofu"), "OpenTofu unavailable")
    def test_evaluated_closure_matches_previous_dev_and_legacy(self):
        common = (ROOT / "coder/templates/common.tf").read_text()
        expression = re.search(r"selected_stacks = (distinct\(concat\(.*?\n  \)\))", common, re.S).group(1)
        expression = expression.replace("tobool(data.coder_parameter.enable_openhands.value)", "var.openhands")
        self.assertIn("stacks            = jsondecode(data.coder_parameter.stacks.value)",
                      (ROOT / "coder/templates/dev/main.tf").read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "main.tf").write_text(
                'variable "stacks" { type = list(string) }\n'
                'variable "dind" { type = bool }\n'
                'variable "playwright" { type = bool }\n'
                'variable "openhands" { type = bool }\n'
                'locals {\nstacks = var.stacks\nenable_dind = var.dind\nenable_playwright = var.playwright\n'
                f'selected_stacks = {expression}\n}}\n')
            for stacks, dind, playwright, openhands in itertools.product(
                    ([], ["go", "ts", "go"], ["containers", "python"]), (False, True), (False, True), (False, True)):
                result = subprocess.run(["tofu", f"-chdir={root}", "console",
                    "-var=stacks=" + json.dumps(stacks), f"-var=dind={str(dind).lower()}",
                    f"-var=playwright={str(playwright).lower()}", f"-var=openhands={str(openhands).lower()}"],
                    input="jsonencode(local.selected_stacks)\n", capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = list(dict.fromkeys(stacks + (["containers"] if dind else []) +
                    (["ts"] if playwright else []) + (["python"] if openhands else [])))
                self.assertEqual(json.loads(json.loads(result.stdout)), expected)

    def test_dev_default_matches_published_catalog(self):
        targets = json.loads((ROOT / "coder/targets.json").read_text())
        self.assertEqual((ROOT / "coder/templates/dev/backend").read_text().strip(),
                         targets["targets"]["dev"]["backend"])
