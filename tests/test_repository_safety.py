import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_env_example() -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in (ROOT / ".env.example").read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


class RepositorySafetyTest(unittest.TestCase):
    def test_public_defaults_disable_external_publication(self) -> None:
        env = read_env_example()
        self.assertEqual(env["DEMO_MODE"], "true")
        self.assertEqual(env["LIVE_MODE"], "false")
        self.assertEqual(env["SOCIAL_PUBLISH_PROVIDER"], "mock")
        self.assertEqual(env["BUFFER_PUBLISH_ENABLED"], "false")
        self.assertEqual(env["BUFFER_DRY_RUN"], "true")
        self.assertEqual(env["PUBLICATION_WORKER_ENABLED"], "false")

    def test_all_workflows_are_valid_json(self) -> None:
        workflows = sorted((ROOT / "n8n" / "workflows").glob("*.json"))
        self.assertTrue(workflows)
        for workflow in workflows:
            with self.subTest(workflow=workflow.name):
                document = json.loads(workflow.read_text(encoding="utf-8"))
                self.assertIsInstance(document.get("nodes"), list)
                self.assertTrue(document.get("name"))


if __name__ == "__main__":
    unittest.main()
