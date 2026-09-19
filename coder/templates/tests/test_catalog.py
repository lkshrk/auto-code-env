import importlib.util
import itertools
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[3]
DOTFILES = Path(os.environ.get("CODER_TEST_DOTFILES", ROOT / ".agent_tmp/dotfiles"))
CATALOG = ROOT / "coder/templates/shared/catalog.json"
RESOLVER = "scripts/coder-components.py"
SHARED = ROOT / "coder/templates/shared"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CatalogOwnershipTests(unittest.TestCase):
    """auto-code-env owns the "which tools does each stack need" catalog;
    dotfiles only executes installs against a catalog it's handed. These
    tests guard the transition: until dotfiles' own embedded catalog is
    deleted (a follow-up, once this is verified live), both copies must
    stay identical, and wiring CODER_CATALOG_PATH must be a true no-op on
    the resolved configuration.
    """

    def test_catalog_is_valid_json_with_expected_keys(self):
        catalog = json.loads(CATALOG.read_text())
        self.assertEqual(set(catalog), {"STACK_TOOLS", "ALIASES", "BASE", "CORE_DOTS", "RUNTIMES"})
        self.assertIn("go", catalog["STACK_TOOLS"])
        self.assertIn("git", catalog["BASE"])

    @unittest.skipUnless(DOTFILES.is_dir(), "set CODER_TEST_DOTFILES to exact companion checkout")
    def test_catalog_matches_dotfiles_embedded_defaults(self):
        # Drift guard for the transition period: once dotfiles' embedded
        # catalog is removed in a follow-up, this test (and the embedded
        # fallback it's checking against) goes away with it.
        result = subprocess.run(["python3", str(DOTFILES / RESOLVER), "--contract"],
                                capture_output=True, text=True, env=dict(os.environ, CODER_CATALOG_PATH=""))
        self.assertEqual(result.returncode, 0, result.stderr)
        catalog = json.loads(CATALOG.read_text())
        # coder-components.py doesn't expose its embedded constants over
        # --contract directly; import it to compare the real module globals.
        import importlib.util
        spec = importlib.util.spec_from_file_location("dotfiles_coder_components", DOTFILES / RESOLVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(catalog["STACK_TOOLS"], module.STACK_TOOLS)
        self.assertEqual(catalog["ALIASES"], module.ALIASES)
        self.assertEqual(catalog["BASE"], module.BASE)
        self.assertEqual(catalog["CORE_DOTS"], module.CORE_DOTS)
        self.assertEqual(catalog["RUNTIMES"], module.RUNTIMES)

    @unittest.skipUnless(DOTFILES.is_dir(), "set CODER_TEST_DOTFILES to exact companion checkout")
    def test_wiring_catalog_path_is_a_no_op_on_resolved_config(self):
        # Proves the exact env var common.tf now exports doesn't change
        # what gets installed, since catalog.json == the embedded defaults.
        baseline = subprocess.run(["python3", str(DOTFILES / RESOLVER)],
                                  capture_output=True, text=True, check=True,
                                  env=dict(os.environ, CODER_OMNI_STACKS="go,python", CODER_CATALOG_PATH=""))
        wired = subprocess.run(["python3", str(DOTFILES / RESOLVER)],
                               capture_output=True, text=True, check=True,
                               env=dict(os.environ, CODER_OMNI_STACKS="go,python", CODER_CATALOG_PATH=str(CATALOG)))
        self.assertEqual(json.loads(baseline.stdout), json.loads(wired.stdout))


@unittest.skipUnless(DOTFILES.is_dir(), "set CODER_TEST_DOTFILES to exact companion checkout")
class StackInstallEquivalenceTests(unittest.TestCase):
    """stack-install.py (auto-code-env) must resolve the exact same tool
    selection, group composition, and provider definitions as dotfiles'
    coder-components.py did/does for the tools-only subset of its config
    -- the only intended difference is the coder-neovim.py helper path
    baked into the neovim provider's install script, since that helper
    moved to auto-code-env alongside the rest of the native Linux
    install recipes (pure machine mechanics, not personal content).
    """

    STACKS = ["", "go", "infra,omni",
              "go,python,ts,lua,rust,k8s,gitops,argo,talos,cilium,cnpg,iac,containers,quality,terminal-recording,media"]
    CLIENTS = ["", "claude", "codex", "claude,codex"]

    def test_tool_selection_and_providers_match_dotfiles_for_every_combination(self):
        stack_install = load(SHARED / "stack-install.py", "stack_install")
        dotfiles_resolver = load(DOTFILES / RESOLVER, "dotfiles_coder_components")
        catalog = stack_install.load_catalog(CATALOG)
        for stacks, clients, plugins in itertools.product(self.STACKS, self.CLIENTS, ("0", "1")):
            if plugins == "1" and not clients:
                continue
            with self.subTest(stacks=stacks, clients=clients, plugins=plugins):
                env = {"CODER_OMNI_STACKS": stacks, "CODER_AGENT_CLIENTS": clients, "CODER_AGENT_PLUGINS": plugins}
                old = dotfiles_resolver.resolve(DOTFILES, env)
                new = stack_install.resolve_tools(DOTFILES, env, catalog)
                old_groups = [{"name": g["name"], "tools": sorted(g["tools"])} for g in old["groups"] if g.get("tools") is not None]
                new_groups = [{"name": g["name"], "tools": sorted(g["tools"])} for g in new["groups"] if g.get("tools") is not None]
                self.assertEqual(old_groups, new_groups)
                names = {t for g in old["groups"] for t in g.get("tools", [])}
                for name in names:
                    if name == "neovim":
                        # Only the baked-in helper path may legitimately differ.
                        old_install = old["tools"][name]["providers"][0]["options"]["install"]
                        new_install = new["tools"][name]["providers"][0]["options"]["install"]
                        self.assertNotEqual(old_install, new_install)
                        self.assertIn("scripts/coder-neovim.py", old_install)
                        self.assertIn(str(SHARED / "coder-neovim.py"), new_install)
                        continue
                    self.assertEqual(old["tools"][name], new["tools"][name], name)


if __name__ == "__main__":
    unittest.main()
