import asyncio
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest


class StaticNewsTests(unittest.TestCase):
    def test_list_detail_and_failure(self):
        path = Path(os.environ.get("DISCOVER_TEST_SOURCE", "app/routers/discover.py"))
        spec = importlib.util.spec_from_file_location("news_under_test", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "news.json"
            module.STATIC_NEWS_FILE = str(feed)
            rows = [
                {"id": i, "date": date, "title": {"rendered": "A &amp; B"},
                 "content": {"rendered": "<p>Full article</p>"},
                 "_dm_default_language": "tr",
                 "_dm_translations": {
                     "tr": {"title": "Türkçe haber", "body_text": "Türkçe haber metni"},
                     "en": {"title": "English news", "body_text": "English news body"},
                 }}
                for i, date in [(7, "2026-01-01"), (9, "2026-02-01")]
            ]
            feed.write_text(json.dumps(rows))
            items = asyncio.run(module._fetch_wp_news(1, language="en"))
            self.assertEqual([row["id"] for row in items], [9])
            self.assertEqual(items[0]["title"], "English news")
            detail = asyncio.run(module._fetch_wp_post_detail(7, language="en"))
            self.assertEqual(detail["content_html"], "<p>English news body</p>")
            fallback = asyncio.run(module._fetch_wp_post_detail(7, language="es"))
            self.assertEqual(fallback["title"], "Türkçe haber")
            with self.assertRaises(module.HTTPException) as error:
                asyncio.run(module._fetch_wp_post_detail(99))
            self.assertEqual(error.exception.status_code, 404)
            feed.write_text("broken")
            with self.assertRaises(module.HTTPException) as error:
                asyncio.run(module._fetch_wp_news())
            self.assertEqual(error.exception.status_code, 503)


if __name__ == "__main__":
    unittest.main()
