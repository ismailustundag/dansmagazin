import ast
import unittest
from pathlib import Path


EVENTS_SOURCE = Path(__file__).resolve().parents[1] / "app" / "routers" / "events.py"


class EventRolloverContractTests(unittest.TestCase):
    def test_rollover_is_serialized_before_rows_are_loaded(self):
        source = EVENTS_SOURCE.read_text(encoding="utf-8")
        tree = ast.parse(source)
        rollover = next(
            node
            for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "_rollover_and_expire_events"
        )
        function_source = ast.get_source_segment(source, rollover) or ""

        lock_position = function_source.find("pg_advisory_xact_lock")
        load_position = function_source.find("FROM mobile_event_submissions")

        self.assertGreaterEqual(lock_position, 0)
        self.assertGreater(load_position, lock_position)


if __name__ == "__main__":
    unittest.main()
