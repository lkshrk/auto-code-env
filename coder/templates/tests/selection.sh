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

    def test_all_discovers_only_templates_in_sorted_order(self):
        self.write("coder/templates/dev/main.tf")
        self.write("coder/templates/incomplete/variables.tf")
        expected = [f"coder/templates/{name}" for name in ("alpha", "beta", "dev")]
        self.assertEqual(self.select("all"), expected)
        self.assertEqual(self.select("all"), expected)

    def test_empty_diff_and_unrelated_changes(self):
        self.assertEqual(self.select("changed", self.base, self.base), [])
        self.write("coder/worker/README.md")
        self.assertEqual(self.select("changed", self.base, self.commit()), [])

    def test_template_files_and_nested_paths(self):
        for path in ("main.tf", "backend", "variables.tf", "nested/config.json", "file with spaces", "\ncoder/modules/file"):
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD")
                self.write(f"coder/templates/alpha/{path}")
                self.assertEqual(self.select("changed", base, self.commit()), ["coder/templates/alpha"])

    def test_shared_inputs_select_all(self):
        paths = ("coder/templates/common.tf", "coder/templates/new.tf", "coder/templates/shared/nested/script.sh",
                 "coder/templates/backends/docker.tf", "coder/templates/tests/test_new.py", "coder/modules/openhands/main.tf",
                 "coder/modules/openhands/nested/data.json", "coder/scripts/package-template.sh",
                 ".github/workflows/coder-templates.yaml")
        for path in paths:
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD")
                self.write(path)
                self.assertEqual(self.select("changed", base, self.commit()), ["coder/templates/alpha", "coder/templates/beta"])

    def test_deleted_shared_file_selects_all(self):
        (self.root / "coder/templates/common.tf").unlink()
        self.assertEqual(self.select("changed", self.base, self.commit()), ["coder/templates/alpha", "coder/templates/beta"])

    def test_deleted_template_is_never_selected(self):
        shutil.rmtree(self.root / "coder/templates/alpha")
        self.assertEqual(self.select("changed", self.base, self.commit()), [])
        self.assertEqual(self.select("all"), ["coder/templates/beta"])

    def test_deleted_main_with_remaining_files_is_not_template(self):
        (self.root / "coder/templates/alpha/main.tf").unlink()
        self.write("coder/templates/alpha/variables.tf")
        self.assertEqual(self.select("changed", self.base, self.commit()), [])

    def test_new_template_selected(self):
        self.write("coder/templates/dev/main.tf")
        self.assertEqual(self.select("changed", self.base, self.commit()), ["coder/templates/dev"])

    def test_template_rename_selects_only_new_name(self):
        self.git("mv", "coder/templates/alpha", "coder/templates/renamed")
        self.assertEqual(self.select("changed", self.base, self.commit()), ["coder/templates/renamed"])

    def test_move_between_templates_selects_both(self):
        self.write("coder/templates/alpha/extra.tf")
        base = self.commit()
        self.git("mv", "coder/templates/alpha/extra.tf", "coder/templates/beta/extra.tf")
        self.assertEqual(self.select("changed", base, self.commit()), ["coder/templates/alpha", "coder/templates/beta"])

    def test_merge_base_excludes_base_branch_only_changes(self):
        self.git("checkout", "--quiet", "-b", "topic")
        self.write("coder/templates/alpha/extra.tf")
        head = self.commit()
        self.git("checkout", "--quiet", "main")
        self.write("coder/templates/beta/extra.tf")
        base = self.commit()
        self.git("checkout", "--quiet", "topic")
        self.assertEqual(self.select("changed", base, head), ["coder/templates/alpha"])

    def test_invalid_refs_fail_closed(self):
        for ref in ("missing", "0" * 40, "--all"):
            with self.subTest(ref=ref):
                self.select("changed", ref, "HEAD", success=False)
                self.select("changed", "HEAD", ref, success=False)

    def test_missing_merge_base_fails_closed(self):
        self.git("checkout", "--quiet", "--orphan", "unrelated")
        self.write("unrelated.txt")
        head = self.commit()
        self.select("changed", self.base, head, success=False)

    def test_shallow_history_fails_closed(self):
        self.write("coder/templates/alpha/extra.tf")
        self.commit()
        shallow = Path(self.temp.name) / "shallow"
        self.git("clone", "--quiet", "--depth=1", self.root.as_uri(), str(shallow))
        self.select("changed", self.base, "HEAD", success=False, root=shallow)

    def test_non_repository_fails_closed(self):
        shutil.rmtree(self.root / ".git")
        self.select("changed", self.base, "HEAD", success=False)

    def test_invalid_names_fail_closed(self):
        self.write("coder/templates/bad name/main.tf")
        self.select("all", success=False)

    def test_invalid_arguments_fail_closed(self):
        for args in ((), ("invalid",), ("changed",), ("all", "HEAD", "HEAD")):
            with self.subTest(args=args):
                self.select(*args, success=False)


    def catalog(self):
        self.write("coder/templates/dev/main.tf")
        catalog = {"version": 1, "targets": {
            "dev": {"source": "dev", "backend": "docker"},
            "dev-kubernetes": {"source": "dev", "backend": "kubernetes"},
        }}
        self.write("coder/targets.json", json.dumps(catalog))
        return catalog

    def test_targets_are_two_packages_from_one_source(self):
        self.catalog()
        self.assertEqual(self.select("targets"), ["dev\tcoder/templates/dev\tdocker", "dev-kubernetes\tcoder/templates/dev\tkubernetes"])
        self.assertEqual(self.select("all"), ["coder/templates/alpha", "coder/templates/beta", "coder/templates/dev"])

    def test_target_changes_exclude_legacy_catalog_by_default(self):
        self.catalog()
        base = self.commit()
        self.write("coder/templates/alpha/extra.tf")
        self.assertEqual(self.select("targets-changed", base, self.commit()), [])
        for path in ("coder/templates/dev/main.tf", "coder/templates/common.tf", "coder/modules/runtime/main.tf", "coder/scripts/example.sh", "coder/templates/tests/example.sh", ".github/workflows/coder-templates.yaml"):
            with self.subTest(path=path):
                base = self.git("rev-parse", "HEAD")
                self.write(path, f"edited {path}\n")
                self.assertEqual(self.select("targets-changed", base, self.commit()), self.select("targets"))

    def test_target_catalog_change_selects_targets(self):
        catalog = self.catalog()
        base = self.commit()
        catalog["targets"]["dev"]["backend"] = "kubernetes"
        self.write("coder/targets.json", json.dumps(catalog))
        self.assertEqual(self.select("targets-changed", base, self.commit()), self.select("targets"))

    def test_explicit_legacy_selection_retains_names_and_backend_markers(self):
        self.catalog()
        self.assertEqual(self.select("legacy", "beta, alpha,beta"), ["alpha\tcoder/templates/alpha\t-", "beta\tcoder/templates/beta\t-"])
        for value in ("dev", "dev-kubernetes", "missing", "alpha,", "../alpha", "*", "", "alpha\nbeta"):
            with self.subTest(value=value):
                self.select("legacy", value, success=False)

    def test_invalid_target_catalogs_fail_closed(self):
        for catalog in ({"version": 2, "targets": {}}, {"version": 1, "targets": {}},
                        {"version": 1, "targets": {"bad name": {"source": "dev", "backend": "docker"}}},
                        {"version": 1, "targets": {"target": {"source": "alpha", "backend": "docker"}}},
                        {"version": 1, "targets": {"target": {"source": "dev", "backend": "unknown"}}},
                        {"version": 1, "targets": {"alpha": {"source": "dev", "backend": "docker"}}}):
            with self.subTest(catalog=catalog):
                self.catalog()
                self.write("coder/targets.json", json.dumps(catalog))
                self.select("targets", success=False)
        self.write("coder/targets.json", '{"version":1,"targets":{},"targets":{}}')
        self.select("targets", success=False)

    def test_missing_target_sources_and_deleted_legacy_fail_closed(self):
        self.catalog()
        (self.root / "coder/templates/dev/main.tf").unlink()
        self.select("targets", success=False)
        self.catalog()
        shutil.rmtree(self.root / "coder/templates/alpha")
        self.select("legacy", "alpha", success=False)

    def test_target_selection_ref_errors_are_not_silenced(self):
        self.catalog()
        self.select("targets-changed", "missing", "HEAD", success=False)
        self.git("checkout", "--quiet", "--orphan", "unrelated-targets")
        self.write("unrelated.txt")
        self.select("targets-changed", self.base, self.commit(), success=False)


    def workflow_selection(self, event, base=None, legacy="", success=True):
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
                   BASE_SHA=base or self.base, HEAD_SHA=self.git("rev-parse", "HEAD"),
                   LEGACY_TEMPLATES=legacy)
        result = subprocess.run(["bash", "-c", "\n".join(body)], cwd=self.root, env=env, capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("has_templates=true", output.read_text())
        records = runner / "coder-template-targets"
        return records.read_text().splitlines() if records.exists() else []

    def test_workflow_legacy_only_pr_validates_affected_legacy(self):
        self.catalog()
        base = self.commit()
        self.write("coder/templates/alpha/extra.tf")
        self.commit()
        self.assertEqual(self.workflow_selection("pull_request", base), ["alpha\tcoder/templates/alpha\t-"])

    def test_workflow_shared_pr_validates_targets_and_legacy(self):
        self.catalog()
        base = self.commit()
        self.write("coder/templates/common.tf", "shared edit\n")
        self.commit()
        expected = self.select("targets") + self.select("legacy", "alpha,beta")
        self.assertEqual(self.workflow_selection("pull_request", base), expected)

    def test_workflow_main_defaults_and_dispatch_legacy_remain_explicit(self):
        self.catalog()
        base = self.commit()
        self.write("coder/templates/common.tf", "shared edit\n")
        self.commit()
        expected = self.select("targets")
        self.assertEqual(self.workflow_selection("push", base, legacy="alpha"), expected)
        self.assertEqual(self.workflow_selection("workflow_dispatch", base), expected)
        self.assertEqual(self.workflow_selection("workflow_dispatch", base, legacy="beta"), expected + self.select("legacy", "beta"))

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
