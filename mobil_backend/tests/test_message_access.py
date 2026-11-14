import unittest
from unittest.mock import patch

from app.routers import messages


class _Cursor:
    def __init__(self, rows):
        self._rows = list(rows)
        self.queries = []

    def execute(self, query, params=None):
        self.queries.append((query, params))

    def fetchone(self):
        return self._rows.pop(0) if self._rows else None


class _Connection:
    def __init__(self, rows):
        self.cur = _Cursor(rows)

    def cursor(self):
        return self.cur


class MessageAccessTests(unittest.TestCase):
    def test_external_contact_detection(self):
        self.assertTrue(messages._contains_external_contact("Bana test@example.com adresinden ulaş"))
        self.assertTrue(messages._contains_external_contact("Detaylar https://example.com"))
        self.assertFalse(messages._contains_external_contact("Yarın görüşürüz"))

    @patch("app.routers.messages.get_blocked_peer_ids")
    def test_unrelated_block_does_not_break_friendship(self, blocked):
        blocked.side_effect = [{99}, set()]
        conn = _Connection([{"exists": 1}])

        self.assertTrue(messages._is_friend(conn, 10, 20))

    @patch("app.routers.messages.get_blocked_peer_ids")
    def test_direct_block_prevents_friendship(self, blocked):
        blocked.side_effect = [{20}, set()]
        conn = _Connection([{"exists": 1}])

        self.assertFalse(messages._is_friend(conn, 10, 20))
        self.assertEqual(conn.cur.queries, [])

    def test_existing_conversation_is_detected_for_history_access(self):
        conn = _Connection([{"exists": 1}])

        self.assertTrue(messages._has_existing_conversation(conn, 10, 20))
        self.assertEqual(conn.cur.queries[0][1], (10, 20, 20, 10))


if __name__ == "__main__":
    unittest.main()
