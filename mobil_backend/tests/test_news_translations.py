import ast
import json
import unittest
from pathlib import Path


NEWS_SOURCE = Path(__file__).resolve().parents[1] / "app" / "routers" / "news.py"


def load_helpers():
    source = NEWS_SOURCE.read_text(encoding="utf-8")
    tree = ast.parse(source)
    names = {"_normalize_news_language", "_normalize_news_translations"}
    nodes = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]

    class HTTPException(Exception):
        def __init__(self, status_code, detail):
            super().__init__(detail)
            self.status_code = status_code
            self.detail = detail

    namespace = {
        "Any": object,
        "Dict": dict,
        "HTTPException": HTTPException,
        "NEWS_LANGUAGES": {"tr", "en", "es"},
        "json": json,
    }
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(NEWS_SOURCE), "exec"), namespace)
    return namespace


class NewsTranslationTests(unittest.TestCase):
    def setUp(self):
        self.helpers = load_helpers()

    def test_supported_translations_and_legacy_default_are_preserved(self):
        parsed = self.helpers["_normalize_news_translations"](
            {"en-US": {"title": "English title", "body_text": "English article body"}, "fr": {"title": "Ignore"}},
            default_language="tr",
            legacy_title="Türkçe başlık",
            legacy_body_text="Türkçe haber metni",
        )
        self.assertEqual(set(parsed), {"tr", "en"})
        self.assertEqual(parsed["tr"]["title"], "Türkçe başlık")
        self.assertEqual(parsed["en"]["title"], "English title")

    def test_default_language_requires_complete_content(self):
        with self.assertRaises(Exception):
            self.helpers["_normalize_news_translations"](
                {"en": {"title": "OK", "body_text": "short"}},
                default_language="en",
            )


if __name__ == "__main__":
    unittest.main()
