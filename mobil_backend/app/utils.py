import os
from typing import Any, Dict, List, Optional, Tuple

import psycopg2
import psycopg2.extras
from fastapi import HTTPException, Request

DATABASE_URL = os.getenv("DATABASE_URL", "").strip()

def get_db_connection():
    if not DATABASE_URL:
        raise HTTPException(status_code=500, detail="Veritabanı yapılandırması eksik (DATABASE_URL)")
    return psycopg2.connect(DATABASE_URL, cursor_factory=psycopg2.extras.RealDictCursor)

def parse_csv_set(raw_value: str) -> set[str]:
    return {item.strip() for item in (raw_value or "").split(",") if item and item.strip()}

def client_ip_from_request(request: Request) -> str:
    forwarded = (request.headers.get("x-forwarded-for") or "").split(",")[0].strip()
    return forwarded or (request.client.host if request.client else "unknown")

def display_name(name: str, email: str, preferred: Optional[str] = None) -> str:
    p = " ".join((preferred or "").split())
    if p:
        return p
    n = (name or "").strip()
    if n:
        return n
    e = (email or "").strip()
    if "@" in e:
        return e.split("@", 1)[0]
    return "user"

def get_blocked_peer_ids(conn, account_id: int) -> set[int]:
    cur = conn.cursor()
    cur.execute(
        """
        SELECT blocked_account_id AS other_id FROM mobile_user_blocks WHERE blocker_account_id=%s
        UNION
        SELECT blocker_account_id AS other_id FROM mobile_user_blocks WHERE blocked_account_id=%s
        """,
        (int(account_id), int(account_id)),
    )
    return {int(row["other_id"]) for row in (cur.fetchall() or []) if row and row.get("other_id") is not None}
