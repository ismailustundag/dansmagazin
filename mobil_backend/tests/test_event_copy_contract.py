import ast
import unittest
from datetime import date
from pathlib import Path
from typing import Any, Dict, Optional


EVENTS_SOURCE = Path(__file__).resolve().parents[1] / "app" / "routers" / "events.py"


class EventCopyContractTests(unittest.TestCase):
    def _reactivation_rule(self):
        tree = ast.parse(EVENTS_SOURCE.read_text(encoding="utf-8"))
        helper = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "_should_reactivate_future_copy"
        )
        namespace = {
            "Any": Any,
            "Dict": Dict,
            "Optional": Optional,
            "date": date,
            "_submission_event_day": lambda row: date.fromisoformat(row["event_date"][:10]),
            "_now_local": lambda: None,
        }
        exec(compile(ast.Module(body=[helper], type_ignores=[]), str(EVENTS_SOURCE), "exec"), namespace)
        return namespace["_should_reactivate_future_copy"]

    def test_copy_uses_defined_submission_insert_helper(self):
        tree = ast.parse(EVENTS_SOURCE.read_text(encoding="utf-8"))
        functions = {
            node.name: node
            for node in tree.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }
        copy_function = functions["copy_manage_item"]
        called_names = {
            node.func.id
            for node in ast.walk(copy_function)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
        }

        self.assertIn("_insert_mobile_event_submission", called_names)
        self.assertIn("_insert_mobile_event_submission", functions)
        self.assertNotIn("_insert_submission_row", called_names)

    def test_update_reactivates_a_future_copy_after_it_was_expired(self):
        tree = ast.parse(EVENTS_SOURCE.read_text(encoding="utf-8"))
        functions = {
            node.name: node
            for node in tree.body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }
        update_function = functions["update_manage_item"]
        called_names = {
            node.func.id
            for node in ast.walk(update_function)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
        }

        self.assertIn("_should_reactivate_future_copy", functions)
        self.assertIn("_should_reactivate_future_copy", called_names)
        self.assertIn("_ensure_live_event_state", called_names)

    def test_reactivation_rule_only_accepts_expired_future_copies(self):
        rule = self._reactivation_rule()
        today = date(2026, 8, 13)

        self.assertTrue(rule({"source_type": "copy", "status": "expired", "event_date": "2026-08-14"}, today=today))
        self.assertFalse(rule({"source_type": "copy", "status": "expired", "event_date": "2026-08-12"}, today=today))
        self.assertFalse(rule({"source_type": "manual", "status": "expired", "event_date": "2026-08-14"}, today=today))
        self.assertFalse(rule({"source_type": "copy", "status": "approved", "event_date": "2026-08-14"}, today=today))


if __name__ == "__main__":
    unittest.main()
