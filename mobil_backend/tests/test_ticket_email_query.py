import unittest
from unittest.mock import patch

from app.ticket_email import _send_one, send_ticket_emails_for_notifications


class Cursor:
    def __init__(self):
        self.query = ""

    def execute(self, query, values):
        self.query = query

    def fetchone(self):
        return None


class Connection:
    def __init__(self):
        self.cur = Cursor()

    def cursor(self):
        return self.cur


class RowCursor(Cursor):
    def __init__(self, rows):
        super().__init__()
        self.rows = list(rows)

    def fetchone(self):
        return self.rows.pop(0) if self.rows else None


class RowConnection(Connection):
    def __init__(self, rows):
        self.cur = RowCursor(rows)


class TicketEmailQueryTests(unittest.TestCase):
    def test_ticket_lookup_uses_current_school_column(self):
        conn = Connection()
        result = send_ticket_emails_for_notifications(
            conn, [{"ticket_id": 1362, "account_id": 674}]
        )
        self.assertEqual(result["attempted"], 1)
        self.assertIn("ps.dance_school_id", conn.cur.query)
        self.assertNotIn("ps.school_id", conn.cur.query)

    def test_port_465_uses_verified_implicit_tls(self):
        row = {"ticket_id": 1362, "account_id": 674, "submission_id": 205,
               "qr_token": "token", "event_slug": "adf", "event_name": "Festival",
               "email": "buyer@example.com", "name": "Buyer"}
        env = {"SMTP_SERVER": "mail.kurumsaleposta.com", "SMTP_USERNAME": "sender@example.com",
               "SMTP_PASSWORD": "test", "TICKET_SMTP_PORT": "465"}
        with patch.dict("os.environ", env), \
             patch("app.ticket_email._school_qr_payload", return_value="qr"), \
             patch("app.ticket_email.smtplib.SMTP_SSL") as ssl_client, \
             patch("app.ticket_email.smtplib.SMTP") as starttls_client:
            sent, reason = _send_one(row, send_sales_notification=False)
        self.assertTrue(sent)
        self.assertEqual(reason, "sent")
        ssl_client.assert_called_once()
        starttls_client.assert_not_called()
        ssl_client.return_value.__enter__.return_value.send_message.assert_called_once()

    def test_paid_ticket_sends_customer_and_sales_messages(self):
        row = {"ticket_id": 1362, "account_id": 674, "submission_id": 205,
               "qr_token": "token", "event_slug": "adf", "event_name": "Festival",
               "email": "buyer@example.com", "name": "Buyer", "woo_order_id": "DM-1",
               "ticket_type": "paid", "order_total": "5500"}
        env = {"SMTP_SERVER": "mail.kurumsaleposta.com", "SMTP_USERNAME": "sender@example.com",
               "SMTP_PASSWORD": "test", "TICKET_SMTP_PORT": "465",
               "SALES_NOTIFICATION_EMAIL": "info@dansmagazin.net"}
        with patch.dict("os.environ", env), \
             patch("app.ticket_email._school_qr_payload", return_value="qr"), \
             patch("app.ticket_email.smtplib.SMTP_SSL") as ssl_client:
            sent, reason = _send_one(row)
        self.assertTrue(sent)
        self.assertEqual(reason, "sent_with_sales_notification")
        messages = [call.args[0] for call in ssl_client.return_value.__enter__.return_value.send_message.call_args_list]
        self.assertEqual(len(messages), 2)
        self.assertEqual(messages[0]["To"], "buyer@example.com")
        self.assertEqual(messages[1]["To"], "info@dansmagazin.net")
        self.assertIn("Yeni bilet siparişi", messages[1]["Subject"])

    def test_sales_notification_is_once_per_order_and_skips_guest_ticket(self):
        base = {"submission_id": 205, "qr_token": "token", "event_slug": "adf",
                "event_name": "Festival", "email": "buyer@example.com", "name": "Buyer"}
        rows = [
            {**base, "ticket_id": 1, "account_id": 10, "woo_order_id": "DM-1", "ticket_type": "paid"},
            {**base, "ticket_id": 2, "account_id": 10, "woo_order_id": "DM-1", "ticket_type": "paid"},
            {**base, "ticket_id": 3, "account_id": 10, "woo_order_id": "guest-list", "ticket_type": "guest"},
        ]
        with patch("app.ticket_email._send_one", return_value=(True, "sent_with_sales_notification")) as send:
            result = send_ticket_emails_for_notifications(
                RowConnection(rows),
                [{"ticket_id": 1, "account_id": 10}, {"ticket_id": 2, "account_id": 10},
                 {"ticket_id": 3, "account_id": 10}],
            )
        self.assertEqual(result["sent"], 3)
        self.assertEqual(result["sales_sent"], 1)
        self.assertEqual([call.kwargs["send_sales_notification"] for call in send.call_args_list], [True, False, False])


if __name__ == "__main__":
    unittest.main()
