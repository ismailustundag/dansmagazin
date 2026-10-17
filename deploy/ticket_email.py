"""Ticket email delivery kept separate from the event router for safe rollout."""

import html
import logging
import os
import smtplib
import ssl
from email.message import EmailMessage
from io import BytesIO

import qrcode

logger = logging.getLogger("mobil_backend.ticket_email")


def _school_qr_payload(**kwargs):
    from app.routers.profile import _school_qr_payload as build_payload
    return build_payload(**kwargs)


def _send_one(row):
    server = os.getenv("SMTP_SERVER", "").strip()
    username = os.getenv("SMTP_USERNAME", "").strip()
    password = os.getenv("SMTP_PASSWORD", "")
    sender = os.getenv("SMTP_FROM", "").strip() or username
    try:
        port = int(os.getenv("SMTP_PORT", "587"))
    except ValueError:
        port = 587
    recipient = str(row.get("email") or "").strip()
    if not server or not username or not password or not recipient or "@" not in recipient:
        return False, "missing_smtp_or_recipient"
    qr_payload = _school_qr_payload(
        ticket_id=int(row["ticket_id"]), submission_id=int(row["submission_id"]),
        raw_token=str(row["qr_token"] or ""), account_id=int(row["account_id"]),
        event_name=str(row["event_name"] or ""), event_slug=str(row["event_slug"] or ""),
        school_name=str(row.get("school_name") or ""), school_id=int(row.get("school_id") or 0),
    )
    if not qr_payload:
        return False, "empty_qr_payload"
    qr_buffer = BytesIO()
    qrcode.make(qr_payload).save(qr_buffer, format="PNG")
    event_name = str(row.get("event_name") or "DansMagazin etkinliği")
    ticket_id = int(row["ticket_id"])
    app_url = os.getenv("APP_DOWNLOAD_URL", "https://api2.dansmagazin.net/app-download").strip()
    event_date = str(row.get("event_date") or "Belirtilmedi")
    venue = str(row.get("venue") or "Belirtilmedi")
    name = str(row.get("name") or "DansMagazin kullanıcısı")
    message = EmailMessage()
    message["Subject"] = f"Biletiniz hazır: {event_name}"
    message["From"] = sender
    message["To"] = recipient
    message.set_content(
        f"Merhaba {name},\n\n{event_name} etkinliği için biletiniz hazır.\n"
        f"Bilet no: {ticket_id}\nTarih: {event_date}\nMekan: {venue}\n\n"
        f"QR kodunuz ektedir. Biletinizi DansMagazin uygulamasında görmek için: {app_url}\n"
    )
    safe = {k: html.escape(str(v or "")) for k, v in {
        "name": name, "event": event_name, "date": event_date, "venue": venue,
        "ticket": ticket_id, "app": app_url,
    }.items()}
    message.add_alternative(
        f"<p>Merhaba {safe['name']},</p><p><strong>{safe['event']}</strong> etkinliği için "
        f"biletiniz hazır.</p><p>Bilet no: <strong>{safe['ticket']}</strong><br>"
        f"Tarih: {safe['date']}<br>Mekan: {safe['venue']}</p>"
        f"<p>QR kodunuz ektedir. <a href=\"{safe['app']}\">DansMagazin uygulamasını indirin</a>.</p>",
        subtype="html",
    )
    message.add_attachment(qr_buffer.getvalue(), maintype="image", subtype="png", filename=f"bilet-{ticket_id}.png")
    with smtplib.SMTP(server, port, timeout=20) as smtp:
        smtp.starttls(context=ssl.create_default_context())
        smtp.login(username, password)
        smtp.send_message(message)
    return True, "sent"


def send_ticket_emails_for_notifications(conn, notifications):
    """Best-effort delivery; ticket creation and push notifications must not fail."""
    summary = {"attempted": 0, "sent": 0, "failed": 0, "errors": []}
    cur = conn.cursor()
    for item in notifications or []:
        ticket_id = int(item.get("ticket_id") or 0)
        account_id = int(item.get("account_id") or 0)
        if ticket_id <= 0 or account_id <= 0:
            continue
        summary["attempted"] += 1
        cur.execute(
            """SELECT t.id AS ticket_id, t.account_id, t.submission_id, t.qr_token,
              t.event_slug, t.event_name, a.email, a.name, s.event_date, s.venue,
              COALESCE(ps.school_id, 0) AS school_id, COALESCE(ds.name, '') AS school_name
              FROM mobile_tickets t JOIN accounts a ON a.id=t.account_id
              LEFT JOIN mobile_event_submissions s ON s.id=t.submission_id
              LEFT JOIN mobile_profile_settings ps ON ps.account_id=t.account_id
              LEFT JOIN mobile_dance_schools ds ON ds.id=ps.school_id
              WHERE t.id=%s AND t.account_id=%s LIMIT 1""",
            (ticket_id, account_id),
        )
        row = cur.fetchone()
        if not row:
            summary["failed"] += 1
            summary["errors"].append(f"ticket_not_found:{ticket_id}")
            continue
        try:
            sent, reason = _send_one(row)
            if sent:
                summary["sent"] += 1
            else:
                summary["failed"] += 1
                summary["errors"].append(f"{ticket_id}:{reason}")
        except Exception as exc:
            summary["failed"] += 1
            summary["errors"].append(f"{ticket_id}:{exc}")
            logger.exception("ticket_email_failed ticket_id=%s", ticket_id)
    summary["errors"] = summary["errors"][:10]
    logger.info("ticket_email_summary %s", summary)
    return summary
