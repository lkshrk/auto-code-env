import importlib.util
import json
import os
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
