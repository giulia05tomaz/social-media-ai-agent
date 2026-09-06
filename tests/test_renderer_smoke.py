import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "renderer"))

from render_content import load_json, render_local  # noqa: E402


class RendererSmokeTest(unittest.TestCase):
    def test_webtech_template_renders_valid_png_without_external_calls(self) -> None:
        temporary_dir = Path(tempfile.mkdtemp(prefix="renderer-test-", dir=ROOT / "tests"))
        try:
            relative_dir = temporary_dir.relative_to(ROOT)
            template = load_json(ROOT / "templates" / "webtech-ai-agent-v1.json")
            payload = {
                "mode": "initial",
                "renderer": "local",
                "template_id": "webtech-ai-agent-v1",
                "content_id": "public-smoke-test",
                "version_id": "00000000-0000-4000-8000-000000000001",
                "version_label": "PUBLIC-v1",
                "client_id": "webtech-demo",
                "title": "Agente de IA para Social Media",
                "subtitle": "Do briefing à publicação, automaticamente",
                "cta": "Peça uma demo",
                "source_image_path": "tests/fixtures/webtech-background.png",
                "output_path": str(relative_dir / "render.png").replace("\\", "/"),
                "layout_spec_path": str(relative_dir / "layout.json").replace("\\", "/"),
            }

            result = render_local(payload, template, ROOT)

            self.assertEqual(result["width"], 1080)
            self.assertEqual(result["height"], 1080)
            self.assertEqual(result["format"], "PNG")
            self.assertEqual(len(result["checksum_sha256"]), 64)
            self.assertTrue((temporary_dir / "render.png").is_file())
            layout = json.loads((temporary_dir / "layout.json").read_text(encoding="utf-8"))
            self.assertEqual(layout["headline"]["text"], payload["title"])
        finally:
            shutil.rmtree(temporary_dir, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
