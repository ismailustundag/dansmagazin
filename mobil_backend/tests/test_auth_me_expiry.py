import unittest
from unittest.mock import patch

from fastapi import HTTPException

from app.routers import auth


class Cursor:
    def __init__(self, valid):
        self.valid = valid
        self.query = ""

    def execute(self, query, params):
        self.query = query

    def fetchone(self):
        return {"valid": True} if self.valid else None


class Connection:
    def __init__(self, valid):
        self.cur = Cursor(valid)

    def cursor(self):
        return self.cur

    def close(self):
        pass


class AuthMeExpiryTests(unittest.TestCase):
    def test_expired_session_is_rejected_before_profile_lookup(self):
        conn = Connection(valid=False)
        with patch.object(auth, "db_conn", return_value=conn), \
             patch.object(auth, "_get_session", return_value={"account_id": 1}), \
             patch.object(auth, "_find_wp_by_account") as lookup:
            with self.assertRaises(HTTPException) as error:
                auth.me(authorization="Bearer expired-token")
        self.assertEqual(error.exception.status_code, 401)
        self.assertIn("expires_at::timestamptz > NOW()", conn.cur.query)
        lookup.assert_not_called()

