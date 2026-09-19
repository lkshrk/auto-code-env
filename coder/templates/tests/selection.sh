#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
python3 - "$script_dir/../../scripts/select-templates.sh" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(sys.argv.pop()).resolve()


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="coder selection ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.git("init", "--quiet", "--initial-branch=main")
        for name in ("alpha", "beta", "backends", "shared", "tests"):
            self.write(f"coder/templates/{name}/main.tf", f"{name}\n")
        self.write("coder/templates/common.tf", "common\n")
        self.catalog()
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.root), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", *args],
            env=self.env, text=True, stderr=subprocess.PIPE,
        ).strip()

    def write(self, relative, content="changed\n"):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        return path

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "--quiet", "--allow-empty", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def select(self, *args, success=True, root=None):
        result = subprocess.run(["bash", str(SCRIPT), str(root or self.root), *args], env=self.env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
        return result.stdout.splitlines()

    def test_empty_diff_and_unrelated_changes(self):
        self.assertEqual(self.select("targets-changed", self.base, self.base), [])
        self.write("coder/worker/README.md")
        self.assertEqual(self.select("targets-changed", self.base, self.commit()), [])

    def test_invalid_arguments_fail_closed(self):
        for args in ((), ("invalid",), ("targets-changed",), ("targets", "HEAD"),
                     ("all",), ("changed", "HEAD", "HEAD"), ("legacy", "alpha")):
            with self.subTest(args=args):
                self.select(*args, success=False)

    def test_invalid_refs_fail_closed(self):
        for ref in ("missing", "0" * 40, "--all"):
            with self.subTest(ref=ref):
                self.select("targets-changed", ref, "HEAD", success=False)
                self.select("targets-changed", "HEAD", ref, success=False)

    def test_shallow_history_fails_closed(self):
        self.write("coder/templates/dev/extra.tf")
        self.commit()
        shallow = Path(self.temp.name) / "shallow"
        self.git("clone", "--quiet", "--depth=1", self.root.as_uri(), str(shallow))
        self.select("targets-changed", self.base, "HEAD", success=False, root=shallow)

    def test_merge_base_excludes_base_branch_only_changes(self):
        self.git("checkout", "--quiet", "-b", "topic")
        self.write("unrelated.txt")
        head = self.commit()
        self.git("checkout", "--quiet", "main")
        self.write("coder/templates/dev/extra.tf")
        base = self.commit()
        self.git("checkout", "--quiet", "topic")
        self.assertEqual(self.select("targets-changed", base, head), [])

    def test_nested_dev_changes_select_all_targets(self):
        for path in ("backend", "variables.tf", "nested/config.json", "file with spaces", "\ncoder/modules/file"):
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD")
                self.write(f"coder/templates/dev/{path}")
                self.assertEqual(self.select("targets-changed", base, self.commit()), self.select("targets"))

    def test_deleted_shared_file_selects_all_targets(self):
        (self.root / "coder/templates/common.tf").unlink()
        self.assertEqual(self.select("targets-changed", self.base, self.commit()), self.select("targets"))

    def test_non_repository_fails_closed(self):
        shutil.rmtree(self.root / ".git")
        self.select("targets-changed", self.base, "HEAD", success=False)

    def catalog(self):
        self.write("coder/templates/dev/main.tf")
        catalog = {"version": 1, "targets": {
            "dev": {"source": "dev", "backend": "kubernetes"},
        }}
        self.write("coder/targets.json", json.dumps(catalog))
        return catalog

    def test_targets_are_one_package_from_one_source(self):
        self.catalog()
        self.assertEqual(self.select("targets"), ["dev\tcoder/templates/dev\tkubernetes"])

    def test_target_changes_exclude_legacy_catalog_by_default(self):
        self.catalog()
        base = self.commit()
        self.write("coder/templates/alpha/extra.tf")
        self.assertEqual(self.select("targets-changed", base, self.commit()), [])
        for path in ("coder/templates/dev/main.tf", "coder/templates/common.tf", "coder/templates/backends/kubernetes.tf", "coder/templates/shared/nested/setup.sh", "coder/modules/runtime/main.tf", "coder/scripts/example.sh", "coder/templates/tests/example.sh", ".github/workflows/coder-templates.yaml"):
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD")
                self.write(path, f"edited {path}\n")
                self.assertEqual(self.select("targets-changed", base, self.commit()), self.select("targets"))

    def test_target_catalog_change_selects_targets(self):
        catalog = self.catalog()
        base = self.commit()
        catalog["targets"]["dev-desktop"] = {"source": "dev", "backend": "kubernetes"}
        self.write("coder/targets.json", json.dumps(catalog))
        self.assertEqual(self.select("targets-changed", base, self.commit()), self.select("targets"))

    def test_invalid_target_catalogs_fail_closed(self):
        for catalog in ({"version": 2, "targets": {}}, {"version": 1, "targets": {}},
                        {"version": 1, "targets": {"bad name": {"source": "dev", "backend": "kubernetes"}}},
                        {"version": 1, "targets": {"target": {"source": "alpha", "backend": "kubernetes"}}},
                        {"version": 1, "targets": {"target": {"source": "dev", "backend": "unknown"}}},
                        {"version": 1, "targets": {"target": {"source": "dev", "backend": "docker"}}},
                        {"version": 1, "targets": {"target": {"source": "dev", "backend": "kubernetes", "extra": True}}}):
            with self.subTest(catalog=catalog):
                self.catalog()
                self.write("coder/targets.json", json.dumps(catalog))
                self.select("targets", success=False)
        self.write("coder/targets.json", '{"version":1,"targets":{},"targets":{}}')
        self.select("targets", success=False)

    def test_missing_target_sources_fail_closed(self):
        self.catalog()
        (self.root / "coder/templates/dev/main.tf").unlink()
        self.select("targets", success=False)

    def test_target_selection_ref_errors_are_not_silenced(self):
        self.catalog()
        self.select("targets-changed", "missing", "HEAD", success=False)
        self.git("checkout", "--quiet", "--orphan", "unrelated-targets")
        self.write("unrelated.txt")
        self.select("targets-changed", self.base, self.commit(), success=False)


    def workflow_selection(self, event, base=None, success=True):
        workflow = SCRIPT.parents[2] / ".github/workflows/coder-templates.yaml"
        lines = workflow.read_text().splitlines()
        start = lines.index("      - name: Select templates")
        start = lines.index("        run: |", start) + 1
        body = []
        for line in lines[start:]:
            if line and not line.startswith("          "):
                break
            body.append(line[10:] if line else "")
        scripts = self.root / "coder/scripts"
        scripts.mkdir(exist_ok=True)
        shutil.copy2(SCRIPT, scripts / SCRIPT.name)
        runner = Path(self.temp.name) / "runner"
        runner.mkdir(exist_ok=True)
        output = runner / "outputs"
        output.write_text("")
        env = dict(self.env, GITHUB_WORKSPACE=str(self.root), RUNNER_TEMP=str(runner),
                   GITHUB_OUTPUT=str(output), GITHUB_EVENT_NAME=event,
                   BASE_SHA=base or self.base, HEAD_SHA=self.git("rev-parse", "HEAD"))
        result = subprocess.run(["bash", "-c", "\n".join(body)], cwd=self.root, env=env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("has_templates=true", output.read_text())
        records = runner / "coder-template-targets"
        return records.read_text().splitlines() if records.exists() else []

    def test_workflow_obsolete_source_pr_selects_nothing(self):
        self.catalog()
        base = self.commit()
        self.write("coder/templates/alpha/extra.tf")
        self.commit()
        self.assertEqual(self.workflow_selection("pull_request", base), [])

    def test_workflow_shared_pr_validates_targets(self):
        self.catalog()
        base = self.commit()
        self.write("coder/templates/common.tf", "shared edit\n")
        self.commit()
        expected = self.select("targets")
        self.assertEqual(self.workflow_selection("pull_request", base), expected)

    def test_workflow_main_and_dispatch_select_only_targets(self):
        self.catalog()
        base = self.commit()
        self.write("coder/templates/common.tf", "shared edit\n")
        self.commit()
        expected = self.select("targets")
        self.assertEqual(self.workflow_selection("push", base), expected)
        self.assertEqual(self.workflow_selection("workflow_dispatch", base), expected)

    def test_workflow_invalid_git_fails_without_success_output(self):
        self.catalog()
        self.commit()
        self.workflow_selection("pull_request", "missing-base", success=False)

    def test_workflow_pr_excludes_deleted_legacy(self):
        self.catalog()
        base = self.commit()
        shutil.rmtree(self.root / "coder/templates/alpha")
        self.commit()
        self.assertEqual(self.workflow_selection("pull_request", base), [])


unittest.main()
PY
