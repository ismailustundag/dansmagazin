import ast
import json
import unittest
from pathlib import Path


EVENTS_SOURCE = Path(__file__).resolve().parents[1] / "app" / "routers" / "events.py"


def load_helpers():
    source = EVENTS_SOURCE.read_text(encoding="utf-8")
    tree = ast.parse(source)
    names = {
        "_normalize_event_language",
        "_parse_event_translations",
        "_resolved_event_content",
    }
    nodes = [
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name in names
    ]

    class HTTPException(Exception):
        def __init__(self, status_code, detail):
            super().__init__(detail)
            self.status_code = status_code
            self.detail = detail

    namespace = {
        "Any": object,
        "Dict": dict,
        "HTTPException": HTTPException,
        "SUPPORTED_EVENT_LANGUAGES": {"tr", "en", "es"},
        "json": json,
    }
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(EVENTS_SOURCE), "exec"), namespace)
    return namespace


class EventTranslationTests(unittest.TestCase):
    def setUp(self):
        self.helpers = load_helpers()

    def test_translations_keep_supported_languages_and_legacy_base(self):
        parsed = self.helpers["_parse_event_translations"](
            {
                "en-US": {"event_name": "Dance Night", "description": "English"},
                "fr": {"event_name": "Ignore me"},
            },
            default_language="tr",
            event_name="Dans Gecesi",
            description="Türkçe",
            program_text="Program",
        )
        self.assertEqual(set(parsed), {"tr", "en"})
        self.assertEqual(parsed["tr"]["event_name"], "Dans Gecesi")
        self.assertEqual(parsed["en"]["event_name"], "Dance Night")

    def test_requested_translation_falls_back_to_default_language(self):
        resolved = self.helpers["_resolved_event_content"](
            {
                "default_language": "en",
                "event_name": "Legacy name",
                "description": "Legacy description",
                "program_text": "Legacy program",
            },
            {
                "en": {
                    "event_name": "English name",
                    "description": "English description",
                    "program_text": "English program",
                }
            },
            "es",
        )
        self.assertEqual(resolved["event_name"], "English name")
        self.assertEqual(resolved["content_language"], "en")

    def test_rollover_copies_translation_rows(self):
        source = EVENTS_SOURCE.read_text(encoding="utf-8")
        self.assertIn("INSERT INTO mobile_event_translations", source)
        self.assertIn("FROM mobile_event_translations", source)


if __name__ == "__main__":
    unittest.main()
