import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).parents[1] / "app/static_news.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublisherTests(unittest.TestCase):
    def test_publish_update_retry_delete(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            feed = root / "feed.json"
            feed.write_text('[]')
            (root / "haberler").mkdir()
            for page in (root / "index.html", root / "haberler/index.html"):
                page.write_text('<section class="dm-card-grid"></section>')
            with patch.dict(os.environ, STATIC_NEWS_FILE=str(feed), STATIC_NEWS_ROOT=str(root)):
                args = dict(title='News <script>', body_text='Body <script>alert(1)</script>',
                            source_link='javascript:alert(1)', submitter_name='Editor', cover_path='',
                            default_language='tr', translations={
                                'tr': {'title': 'Türkçe', 'body_text': 'Türkçe metin'},
                                'en': {'title': 'English', 'body_text': 'English body'},
                            })
                result = publisher.publish(1, **args)
                publisher.publish(1, **args)
                stored = json.loads(feed.read_text())
                self.assertEqual(len(stored), 1)
                self.assertEqual(stored[0]['_dm_translations']['en']['title'], 'English')
                page = root / "haber-1/index.html"
                self.assertNotIn('<script>', page.read_text())
                self.assertNotIn('javascript:', page.read_text())
                self.assertIn('dm:content-type', page.read_text())
                args['title'] = 'Edited news'
                publisher.publish(1, post_id=result['post_id'], **args)
                self.assertIn('Edited news', (root / 'index.html').read_text())
                publisher.delete(result['post_id'])
                self.assertFalse(page.exists())
                self.assertEqual(json.loads(feed.read_text()), [])
                self.assertNotIn('Edited news', (root / 'index.html').read_text())


if __name__ == '__main__':
    unittest.main()
