import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "shared" / "wow-tools.py"


def load(env):
    os.environ.update(env)
    spec = importlib.util.spec_from_file_location("wow_tools", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


BUGGRABBER = r'''
BugGrabberDB = {
["lastSanitation"] = 3,
["session"] = 12,
["errors"] = {
{
["message"] = "Interface/AddOns/Old/Old.lua:3: attempt to index a nil value",
["time"] = 1786749083,
["stack"] = "[string \"@Interface/AddOns/Old/Old.lua\"]:3: in function <...>",
["session"] = 11,
["counter"] = 2,
},
{
["message"] = "Interface/AddOns/Foo-Dev/Foo.lua:10: bad argument #1 to 'SetText' (string expected, got nil)\n",
["time"] = 1786792494,
["locals"] = "self = Frame {\n}\n",
["stack"] = "[string \"@Interface/AddOns/Foo-Dev/Foo.lua\"]:10: in function 'Update'\n[C]: ?",
["session"] = 12,
["counter"] = 1,
},
},
}
'''

API_DOC = '''local AddOns =
{
	Name = "AddOns",
	Type = "System",
	Namespace = "C_AddOns",

	Functions =
	{
		{
			Name = "IsAddOnLoaded",
			Type = "Function",
			SecretArguments = "AllowedWhenUntainted",
			Arguments =
			{
				{ Name = "name", Type = "uiAddon", Nilable = false },
			},
			Returns =
			{
				{ Name = "loadedOrLoading", Type = "bool", Nilable = false },
				{ Name = "loaded", Type = "bool", Nilable = false },
			},
		},
	},

	Events =
	{
		{
			Name = "AddonLoaded",
			Type = "Event",
			LiteralName = "ADDON_LOADED",
			Payload =
			{
				{ Name = "addOnName", Type = "cstring", Nilable = false },
			},
		},
	},

	Tables =
	{
	},
};

APIDocumentation:AddDocumentationTable(AddOns);
'''


class WowToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.home = self.tmp / "wow"
        docs = self.home / "wow-ui-source/Interface/AddOns/Blizzard_APIDocumentationGenerated"
        docs.mkdir(parents=True)
        (docs / "AddOnsDocumentation.lua").write_text(API_DOC)
        frame = self.home / "wow-ui-source/Interface/AddOns/Blizzard_Test"
        frame.mkdir(parents=True)
        (frame / "Test.xml").write_text(
            '<Ui><Frame name="CharacterFrame" parent="UIParent"><Frames>'
            '<Frame name="$parentInset" inherits="InsetFrameTemplate"/>'
            '<Button name="$parentTab1"><Scripts/></Button></Frames></Frame></Ui>'
        )
        (frame / "Test.lua").write_text('RAID_CLASS_COLORS = {}\nfunction ChatFrame_Open() end\nlocal hidden = 1\n'
                                        'local function f()\n    GENERAL_CHAT_DOCK = 1\n    lowerCase = 2\nend\n')
        self.sv = self.tmp / "sv"
        self.sv.mkdir()
        (self.sv / "!BugGrabber.lua").write_text(BUGGRABBER)
        (self.sv / "Foo-Dev.lua").write_text('FooDBDev = {\n["profiles"] = {\n["Default"] = {\n["scale"] = 1.5,\n},\n},\n}\n')
        self.mod = load({
            "WOW_HOME": str(self.home),
            "XDG_CACHE_HOME": str(self.tmp / "cache"),
            "XDG_CONFIG_HOME": str(self.tmp / "config"),
            "WOW_SV_REMOTE": "wowsv",
            "WOW_SV_PATH": str(self.sv),
            "RCLONE_CONFIG_WOWSV_TYPE": "local",
        })

    def run_cmd(self, *argv):
        out = io.StringIO()
        old = sys.argv
        sys.argv = ["wow-tools", *argv]
        try:
            with redirect_stdout(out):
                code = self.mod.main()
        finally:
            sys.argv = old
        return code, out.getvalue()

    def test_lua_parser_reads_savedvariables(self):
        data = self.mod.LuaParser(BUGGRABBER).assignments()["BugGrabberDB"]
        self.assertEqual(data["session"], 12)
        self.assertEqual(len(data["errors"]), 2)
        self.assertEqual(data["errors"][1]["locals"], "self = Frame {\n}\n")
        self.assertIn("'SetText'", data["errors"][1]["message"])

    @unittest.skipUnless(shutil.which("rclone"), "rclone not installed")
    def test_errors_default_to_current_session(self):
        code, out = self.run_cmd("errors")
        self.assertEqual(code, 0)
        self.assertIn("1 error(s), session 12", out)
        self.assertIn("Foo-Dev/Foo.lua:10", out)
        self.assertNotIn("Old.lua", out)
        code, out = self.run_cmd("errors", "--all", "--match", "old.lua")
        self.assertIn("Old.lua:3", out)
        self.assertNotIn("Foo-Dev", out)

    @unittest.skipUnless(shutil.which("rclone"), "rclone not installed")
    def test_sv_show_with_key(self):
        code, out = self.run_cmd("sv", "show", "Foo-Dev", "--key", "FooDBDev.profiles.Default")
        self.assertEqual(json.loads(out), {"scale": 1.5})
        code, out = self.run_cmd("sv", "list")
        self.assertIn("Foo-Dev.lua", out)

    def test_api_lookup(self):
        code, out = self.run_cmd("api", "IsAddOnLoaded")
        self.assertEqual(code, 0)
        self.assertIn("C_AddOns.IsAddOnLoaded(name: uiAddon) -> loadedOrLoading: bool, loaded: bool", out)
        self.assertIn("SecretArguments=AllowedWhenUntainted", out)
        code, out = self.run_cmd("api", "ADDON_LOADED", "--kind", "event")
        self.assertIn("event ADDON_LOADED(addOnName: cstring)", out)
        code, out = self.run_cmd("api", "GetAddOnInfoThatDoesNotExist")
        self.assertEqual(code, 1)

    def test_framexml_globals(self):
        names = set(self.mod.framexml_globals())
        for name in ("CharacterFrame", "CharacterFrameInset", "CharacterFrameTab1", "RAID_CLASS_COLORS",
                     "ChatFrame_Open", "GENERAL_CHAT_DOCK", "STANDARD_TEXT_FONT"):
            self.assertIn(name, names)
        for name in ("hidden", "lowerCase", "$parentInset", "local"):
            self.assertNotIn(name, names)

    def test_check_lints_toc_and_xml(self):
        repo = self.tmp / "repo"
        addon = repo / "Foo"
        addon.mkdir(parents=True)
        (addon / "Foo.toc").write_text(
            "## Interface: 110200\n## SavedVariables: FooDB\nfoo.lua\nMissing.lua\nLibs\\LibStub\\LibStub.lua\nFrames.xml\n"
            "Classic.lua [AllowLoadGameType classic]\n"
        )
        (addon / "Foo.lua").write_text("FooDB = FooDB or {}\n")
        (addon / "Classic.lua").write_text("\n")
        (addon / "Frames.xml").write_text('<Ui><Script file="Gone.lua"/><Include file="sub\\Sub.xml"/></Ui>')
        (addon / "sub").mkdir()
        (addon / "sub" / "Sub.xml").write_text('<Ui><Script file="..\\Foo.lua"/></Ui>')
        code, out = self.run_cmd("check", "--no-lua", str(repo))
        self.assertEqual(code, 1)
        self.assertIn("listed file missing: Missing.lua", out)
        self.assertIn("Script file missing: Gone.lua", out)
        self.assertIn("older than the game", out)
        self.assertIn("1 Libs file(s)", out)
        self.assertNotIn("foo.lua", out.lower().replace("foo.lua:", ""))
        self.assertNotIn("Classic.lua", out)

    def test_repo_globals_include_savedvariables_g_assignments_and_frames(self):
        repo = self.tmp / "repo2"
        (repo / "A").mkdir(parents=True)
        (repo / "A" / "A.toc").write_text("## SavedVariables: ADB, AOther\n## SavedVariablesPerCharacter: ACharDB\nA.lua\n")
        (repo / "A" / "A.lua").write_text('local x = 1\n_G.CategoryManager = {}\n_G["Quoted"] = 1\nfunction A_Global() end\n')
        (repo / "A" / "A.xml").write_text('<Ui><Frame name="AFrame"><Frames><Frame name="$parentChild"/></Frames></Frame></Ui>')
        names = set(self.mod.repo_globals([repo]))
        for name in ("ADB", "AOther", "ACharDB", "CategoryManager", "Quoted", "A_Global", "AFrame", "AFrameChild"):
            self.assertIn(name, names)
        self.assertNotIn("x", names)


if __name__ == "__main__":
    unittest.main()
