import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "common"))
import apply


class FakeApi:
    def __init__(self, existing=None):
        self.calls = []
        self.existing = existing

    def __call__(self, method, url, key, body=None):
        self.calls.append((method, url.split("/api/", 1)[1], body))
        if method == "GET" and url.endswith("/api/agent-profiles/default"):
            return {"name": "default", "profile": {"id": "profile-id", "agent_kind": "openhands"}}
        if method == "GET" and "/api/automation/v1?" in url:
            items = [self.existing] if self.existing else []
            return {"automations": items, "total": len(items)}
        if method == "POST" and url.endswith("/preset/prompt"):
            return {"id": "new-id", **body}
        if method == "PATCH":
            return {"id": url.rsplit("/", 1)[1], **body}
        raise AssertionError(f"unexpected call {method} {url}")


class DeployTests(unittest.TestCase):
    def deploy(self, body, existing=None):
        fake = FakeApi(existing)
        original = apply.request
        apply.request = fake
        try:
            result, action = apply.deploy("http://x", "key", dict(body), ROOT / "orc/pr-review")
        finally:
            apply.request = original
        return result, action, fake.calls

    def test_profile_name_resolves_to_id(self):
        spec = {"name": "pr-review", "agent_profile": "default", "prompt": "p", "trigger": {"type": "event"},
                "timeout": 900, "keep_alive": False, "enabled": True}
        result, action, calls = self.deploy(spec)
        self.assertEqual(action, "created")
        creation = next(b for m, p, b in calls if p == "automation/v1/preset/prompt")
        self.assertEqual(creation["agent_profile_id"], "profile-id")
        self.assertNotIn("agent_profile", creation)

    def test_existing_automation_is_patched_with_profile_id(self):
        spec = {"name": "pr-review", "agent_profile": "default", "prompt": "p", "trigger": {"type": "event"},
                "timeout": 900, "keep_alive": False, "enabled": True}
        result, action, calls = self.deploy(spec, existing={"id": "old-id", "name": "pr-review"})
        self.assertEqual(action, "updated")
        patch = next(b for m, p, b in calls if p == "automation/v1/old-id")
        self.assertEqual(patch["agent_profile_id"], "profile-id")
        self.assertEqual(set(patch) - {"agent_profile_id"}, {"name", "prompt", "trigger", "timeout", "keep_alive", "enabled"})

    def test_model_without_profile_is_untouched(self):
        spec = {"name": "x", "model": "standard-auto", "prompt": "p", "trigger": {"type": "cron"},
                "timeout": 60, "keep_alive": False, "enabled": True}
        result, action, calls = self.deploy(spec)
        creation = next(b for m, p, b in calls if p == "automation/v1/preset/prompt")
        self.assertEqual(creation["model"], "standard-auto")
        self.assertNotIn("agent_profile_id", creation)


if __name__ == "__main__":
    unittest.main()
