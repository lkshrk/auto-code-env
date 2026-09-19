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
    """auto-code-env owns the "which tools does each stack need" catalog.
    stack-install.py/install-stacks.py never call dotfiles' own
    coder-components.py at all (see StackInstallEquivalenceTests below),
    so there's no CODER_CATALOG_PATH wiring into it to guard here -- that
    approach was tried and superseded, see auto-code-env's memory notes.
    What still needs guarding until dotfiles' embedded catalog constants
    are deleted (a follow-up, once this is verified live): the two
    copies must stay identical, so a stack added here doesn't silently
    diverge from what dotfiles' own script would still install if ever
    invoked directly (e.g. from a non-Coder machine).
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
        result = subprocess.run(["python3", str(DOTFILES / RESOLVER), "--contract"], capture_output=True, text=True)
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
class StackInstallEquivalenceTests(unittest.TestCase):
    """stack-install.py (auto-code-env) renders an Omni config that
    relies on Omni's own $include + host provider-priority resolution
    for tool provider definitions (see stack-install.py's module
    docstring for why), instead of copying dotfiles' coder-components.py
    resolver's approach of manually merging tool definitions into a
    single generated file. What must still match exactly is the
    *effective installed tool set* for every selection: expanding the
    new design's active groups against its own static catalog-derived
    group definitions must equal the old resolver's flat tool set.
    """

    STACKS = ["", "go", "infra,omni",
              "go,python,ts,lua,rust,k8s,gitops,argo,talos,cilium,cnpg,iac,containers,quality,terminal-recording,media"]
    CLIENTS = ["", "claude", "codex", "claude,codex"]

    def test_effective_installed_tool_set_matches_dotfiles_for_every_combination(self):
        stack_install = load(SHARED / "stack-install.py", "stack_install")
        dotfiles_resolver = load(DOTFILES / RESOLVER, "dotfiles_coder_components")
        catalog = stack_install.load_catalog(CATALOG)
        for stacks, clients, plugins in itertools.product(self.STACKS, self.CLIENTS, ("0", "1")):
            if plugins == "1" and not clients:
                continue
            with self.subTest(stacks=stacks, clients=clients, plugins=plugins):
                env = {"CODER_OMNI_STACKS": stacks, "CODER_AGENT_CLIENTS": clients, "CODER_AGENT_PLUGINS": plugins}
                old = dotfiles_resolver.resolve(DOTFILES, env)
                old_tools = {t for g in old["groups"] for t in g.get("tools", [])}

                config, names = stack_install.render_config(DOTFILES, env, catalog, SHARED)
                self.assertEqual(names, config["hosts"][stack_install.HOST])
                active = set(names)
                new_tools = {t for g in config["groups"] for t in g.get("tools", []) if g["name"] in active}
                self.assertEqual(old_tools, new_tools)

                # No duplicate/unknown group names, and every active
                # name actually resolves to a declared group.
                declared = {g["name"] for g in config["groups"]}
                self.assertTrue(active <= declared, active - declared)
                self.assertEqual(len(names), len(set(names)))

    def test_static_groups_cover_every_catalog_stack_and_runtime(self):
        stack_install = load(SHARED / "stack-install.py", "stack_install")
        catalog = stack_install.load_catalog(CATALOG)
        groups = {g["name"]: g["tools"] for g in stack_install.build_static_groups(catalog)}
        for stack in catalog["STACK_TOOLS"]:
            self.assertIn("stack-" + stack, groups)
        for runtime in catalog["RUNTIMES"]:
            self.assertIn("runtime-" + runtime, groups)
            self.assertEqual(groups["runtime-" + runtime], [runtime])

    def test_linux_tools_json_overrides_take_precedence_by_include_order(self):
        stack_install = load(SHARED / "stack-install.py", "stack_install")
        catalog = stack_install.load_catalog(CATALOG)
        config, _ = stack_install.render_config(DOTFILES, {"CODER_OMNI_STACKS": ""}, catalog, SHARED)
        includes = config["$include"]
        self.assertTrue(includes[-1].endswith("linux-tools.json"), includes)
        self.assertTrue(includes[0].endswith("settings.d/tools.json"), includes)


if __name__ == "__main__":
    unittest.main()
