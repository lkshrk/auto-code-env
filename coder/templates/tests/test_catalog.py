import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
DOTFILES = Path(os.environ.get("CODER_TEST_DOTFILES", ROOT / ".agent_tmp/dotfiles"))
CATALOG = ROOT / "coder/templates/shared/catalog.json"
SHARED = ROOT / "coder/templates/shared"


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CatalogOwnershipTests(unittest.TestCase):
    """auto-code-env owns the "which tools does each stack need" catalog.
    dotfiles no longer has a stack/tool catalog of its own to drift
    against (see its feat/trim-coder-components-to-dots-only change):
    it only keeps its Omni tool *provider* definitions
    (settings.d/tools.json), merged in natively via Omni's own
    $include, see stack-install.py's module docstring.
    """

    def test_catalog_is_valid_json_with_expected_keys(self):
        catalog = json.loads(CATALOG.read_text())
        self.assertEqual(set(catalog), {"STACK_TOOLS", "ALIASES", "BASE", "CORE_DOTS", "RUNTIMES"})
        self.assertIn("go", catalog["STACK_TOOLS"])
        self.assertIn("git", catalog["BASE"])

    def test_stacks_with_node_language_servers_pull_the_nvm_runtime(self):
        stack_install = load(SHARED / "stack-install.py", "stack_install")
        catalog = stack_install.load_catalog(CATALOG)
        for stack in ("python", "k8s", "gitops", "quality"):
            selection = {"stacks": [stack], "clients": [], "CODER_AGENT_PLUGINS": "0"}
            names = stack_install.select_group_names(selection, catalog)
            self.assertIn("runtime-nvm", names, stack)
            self.assertLess(names.index("runtime-nvm"), names.index("stack-" + stack), names)
        selection = {"stacks": ["rust", "iac"], "clients": [], "CODER_AGENT_PLUGINS": "0"}
        self.assertNotIn("runtime-nvm", stack_install.select_group_names(selection, catalog))

    def test_every_stack_language_has_a_claude_language_server(self):
        catalog = json.loads(CATALOG.read_text())
        script = (SHARED / "claude-lsp.sh").read_text()
        for stack, server in {"go": "gopls", "python": "pyright", "ts": "typescript-language-server",
                              "lua": "lua-language-server", "rust": "rust-analyzer", "iac": "terraform-ls",
                              "k8s": "yaml-language-server", "gitops": "yaml-language-server",
                              "quality": "bash-language-server"}.items():
            self.assertIn(server, catalog["STACK_TOOLS"][stack], stack)
            self.assertIn(f'"{server}": {{', script, server)


@unittest.skipUnless(DOTFILES.is_dir(), "set CODER_TEST_DOTFILES to exact companion checkout")
class StackInstallStructureTests(unittest.TestCase):
    """stack-install.py (auto-code-env) renders an Omni config that
    relies on Omni's own $include + host provider-priority resolution
    for tool provider definitions (see stack-install.py's module
    docstring for why). What's exercised here against a real dotfiles
    checkout is that the static group/catalog structure it builds is
    internally consistent (no duplicate/unknown group names, every
    catalog stack and runtime has a group) and that its own $include
    ordering (dotfiles' tools.json first, this repo's linux-tools.json
    last, so the latter's overrides win) holds.
    """

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

    def test_include_never_points_at_dotfiles_tracked_tools_json(self):
        # Regression test: `omni tools sync` writes resolved provider
        # state back into the *first* file that $include's a synced
        # tool's provider block, not just reads it. Verified live
        # against a real Coder workspace: pointing $include at
        # dotfiles' tracked settings.d/tools.json (its live path inside
        # the preserved git checkout) got that file silently truncated
        # to `{}` -- destroying the user's checkout, which prepare-
        # dotfiles.sh explicitly promises never to alter. The rendered
        # config must always $include a disposable copy under
        # shared_dir instead (stage_tool_providers()), never the path
        # inside dotfiles_dir itself.
        stack_install = load(SHARED / "stack-install.py", "stack_install")
        catalog = stack_install.load_catalog(CATALOG)
        with tempfile.TemporaryDirectory() as shared_dir:
            config, _ = stack_install.render_config(DOTFILES, {"CODER_OMNI_STACKS": ""}, catalog, shared_dir)
            tools_include = config["$include"][0]
            self.assertFalse(tools_include.startswith(str(Path(DOTFILES).resolve())), tools_include)
            self.assertTrue(tools_include.startswith(str(Path(shared_dir).resolve())), tools_include)

    def test_stage_tool_providers_copies_without_touching_dotfiles_checkout(self):
        stack_install = load(SHARED / "stack-install.py", "stack_install")
        with tempfile.TemporaryDirectory() as shared_dir:
            source = DOTFILES / stack_install.DOTS_ROOT / "settings.d/tools.json"
            before = source.read_text()
            before_mtime = source.stat().st_mtime_ns
            stack_install.stage_tool_providers(DOTFILES, shared_dir)
            staged = stack_install.staged_tools_path(shared_dir)
            self.assertEqual(staged.read_text(), before)
            self.assertEqual(source.read_text(), before)
            self.assertEqual(source.stat().st_mtime_ns, before_mtime)


if __name__ == "__main__":
    unittest.main()
