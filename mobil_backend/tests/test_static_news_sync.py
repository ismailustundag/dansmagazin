import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("sync", Path(__file__).parents[1] / "ops/sync_static_news.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class SyncTests(unittest.TestCase):
    def test_publish_update_retire_and_preserve_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "site"
            root.mkdir()
            feed = Path(directory) / "feed.json"
            feed.with_name("static-news-catalog.json").write_text(json.dumps({"news_paths": ["/old"], "page_paths": ["/albumler"]}))
            feed.write_text(json.dumps([{"id": 17, "date": "2026-01-01", "link": "https://dansmagazin.net/old/",
                                        "content": {"rendered": "original full text"}}]))
            template = '<meta property="og:type" content="article"><h1>Title &amp; news</h1><div class="dm-article-body"><div><p>{}</p></div></div>'
            for slug in ("old", "new", "albumler", "unclassified"):
                (root / slug).mkdir()
                marker = '<meta name="dm:content-type" content="news">' if slug in ("new", "albumler") else ''
                (root / slug / "index.html").write_text(marker + template.format("first"))
            sync.synchronize(root, feed)
            rows = json.loads(feed.read_text())
            self.assertEqual(len(rows), 2)
            old = next(row for row in rows if row["id"] == 17)
            self.assertEqual(old["content"]["rendered"], "original full text")
            new_id = next(row["id"] for row in rows if row["id"] != 17)
            (root / "new/index.html").write_text('<meta name="dm:content-type" content="news">' + template.format("updated"))
            sync.synchronize(root, feed)
            rows = json.loads(feed.read_text())
            self.assertIn("updated", next(row for row in rows if row["id"] == new_id)["content"]["rendered"])
            (root / "new/index.html").unlink()
            sync.synchronize(root, feed)
            self.assertEqual([row["id"] for row in json.loads(feed.read_text())], [17])
            before = feed.read_text()
            (root / "old/index.html").unlink()
            with self.assertRaises(ValueError):
                sync.synchronize(root, feed)
            self.assertEqual(feed.read_text(), before)


if __name__ == "__main__":
    unittest.main()
