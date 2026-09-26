import base64
import gzip
import re
import unittest
from pathlib import Path

TEMPLATES = Path(__file__).resolve().parents[1]
EMBED = re.compile(r'\$\{base64gzip\(file\("\$\{path\.module\}/([^"]+)"\)\)\}')
# The agent passes the startup script as one exec argument; Linux caps a single argument at 128 KiB.
ARG_MAX_STRLEN = 128 * 1024


class StartupScriptSizeTest(unittest.TestCase):
    def test_embedded_files_are_compressed(self):
        self.assertNotIn("base64encode(file(", (TEMPLATES / "common.tf").read_text())

    def test_rendered_common_tf_fits_one_exec_argument(self):
        text = (TEMPLATES / "common.tf").read_text()

        def render(match):
            return base64.b64encode(gzip.compress((TEMPLATES / match.group(1)).read_bytes())).decode()

        rendered = EMBED.sub(render, text)
        self.assertLess(len(rendered.encode()), ARG_MAX_STRLEN * 3 // 4)


if __name__ == "__main__":
    unittest.main()
