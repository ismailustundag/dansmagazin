import ast
import unittest
from pathlib import Path


EVENTS_SOURCE = Path(__file__).resolve().parents[1] / "app" / "routers" / "events.py"


class EventSubmissionAccessContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = EVENTS_SOURCE.read_text(encoding="utf-8")
        cls.tree = ast.parse(cls.source)

    def _function_source(self, name: str) -> str:
        node = next(
            item
            for item in self.tree.body
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)) and item.name == name
        )
        return ast.get_source_segment(self.source, node) or ""

    def test_submission_requires_active_account_not_editor_permission(self):
        source = self._function_source("create_submission")
        self.assertIn("_require_event_submitter_account", source)
        self.assertNotIn("_require_editor_account", source)

    def test_new_submission_is_always_pending(self):
        source = self._function_source("create_submission")
        self.assertIn('status="pending"', source)
        self.assertIn('"status": "pending"', source)

    def test_super_admin_notification_is_created_after_submission(self):
        source = self._function_source("create_submission")
        self.assertIn("_notify_super_admins_for_event_submission", source)
        notifier = self._function_source("_notify_super_admins_for_event_submission")
        self.assertIn("event_submission_pending", notifier)
        self.assertIn("LOWER(COALESCE(role,''))='super_admin'", notifier)
        self.assertIn("_dispatch_push_for_accounts", notifier)

    def test_submission_rate_limit_is_kept(self):
        source = self._function_source("create_submission")
        self.assertIn("recent_pending_count + requested_count > 30", source)
        self.assertIn("status_code=429", source)


if __name__ == "__main__":
    unittest.main()
