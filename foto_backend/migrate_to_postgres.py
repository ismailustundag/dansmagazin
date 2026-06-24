#!/usr/bin/env python3
import os
import sqlite3
from typing import List, Tuple

import psycopg2
import psycopg2.extras

DB_PATH = os.path.join(os.path.dirname(__file__), "database.db")
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://dansmagazin_user:dansmagazin@localhost:5432/dansmagazin_db")


PG_SCHEMA_SQL = [
    """
    CREATE TABLE IF NOT EXISTS users (
        id SERIAL PRIMARY KEY,
        event_id TEXT,
        name TEXT,
        email TEXT,
        selfie_path TEXT,
        kvkk_consent INTEGER,
        created_at TEXT,
        gallery_token TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS event_photos (
        id SERIAL PRIMARY KEY,
        event_id TEXT,
        file_path TEXT,
        created_at TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS photo_matches (
        id SERIAL PRIMARY KEY,
        event_id TEXT,
        user_id INTEGER,
        photo_id INTEGER,
        score REAL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS events (
        id SERIAL PRIMARY KEY,
        slug TEXT UNIQUE,
        name TEXT,
        created_at TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS accounts (
        id SERIAL PRIMARY KEY,
        email TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        photo_credit INTEGER NOT NULL DEFAULT 0,
        name TEXT,
        phone TEXT,
        avatar_path TEXT,
        created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS sessions (
        id SERIAL PRIMARY KEY,
        account_id INTEGER NOT NULL,
        session_token TEXT UNIQUE NOT NULL,
        expires_at TEXT NOT NULL,
        created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS saas_events (
        id SERIAL PRIMARY KEY,
        account_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        slug TEXT UNIQUE NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        frame_landscape TEXT,
        frame_portrait TEXT,
        frame_square TEXT,
        created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS jobs (
        id SERIAL PRIMARY KEY,
        account_id INTEGER NOT NULL,
        event_slug TEXT NOT NULL,
        action TEXT NOT NULL,
        uploaded_count INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL,
        message TEXT,
        created_at TEXT NOT NULL,
        finished_at TEXT,
        target_user_id INTEGER,
        processed_count INTEGER,
        match_count INTEGER,
        match_cursor INTEGER,
        match_start INTEGER,
        match_end INTEGER,
        pid TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS mail_logs (
        id SERIAL PRIMARY KEY,
        event_slug TEXT NOT NULL,
        user_id INTEGER,
        email TEXT NOT NULL,
        status TEXT NOT NULL,
        error TEXT,
        sent_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS qr_scans (
        id SERIAL PRIMARY KEY,
        event_slug TEXT NOT NULL,
        ip TEXT,
        user_agent TEXT,
        created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS photo_downloads (
        id SERIAL PRIMARY KEY,
        event_slug TEXT NOT NULL,
        user_id INTEGER,
        photo_id INTEGER,
        created_at TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS photo_attempts (
        id SERIAL PRIMARY KEY,
        event_slug TEXT NOT NULL,
        user_id INTEGER NOT NULL,
        photo_id INTEGER NOT NULL,
        attempted_at TEXT NOT NULL
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS idx_photo_attempts_unique ON photo_attempts(event_slug, user_id, photo_id)",
]


def sqlite_columns(conn: sqlite3.Connection, table: str) -> List[str]:
    cur = conn.execute(f"PRAGMA table_info({table})")
    return [r[1] for r in cur.fetchall()]


def pg_columns(conn, table: str) -> List[str]:
    cur = conn.cursor()
    cur.execute(
        "SELECT column_name FROM information_schema.columns WHERE table_name=%s",
        (table,),
    )
    return [r[0] for r in cur.fetchall()]


def copy_table(sqlite_conn, pg_conn, table: str):
    s_cols = sqlite_columns(sqlite_conn, table)
    p_cols = pg_columns(pg_conn, table)
    cols = [c for c in s_cols if c in p_cols]
    if not cols:
        print(f"[SKIP] {table}: no common columns")
        return

    s_cur = sqlite_conn.cursor()
    s_cur.execute(f"SELECT {', '.join(cols)} FROM {table}")
    rows = s_cur.fetchall()
    if not rows:
        print(f"[OK] {table}: 0 rows")
        return

    insert_sql = f"INSERT INTO {table} ({', '.join(cols)}) VALUES %s"
    with pg_conn.cursor() as pcur:
        psycopg2.extras.execute_values(pcur, insert_sql, rows, page_size=1000)
    print(f"[OK] {table}: {len(rows)} rows")


def reset_sequence(pg_conn, table: str):
    with pg_conn.cursor() as cur:
        cur.execute(f"SELECT MAX(id) FROM {table}")
        row = cur.fetchone()
        max_id = row[0] if row and row[0] is not None else 0
        cur.execute(
            "SELECT pg_get_serial_sequence(%s, %s)",
            (table, "id"),
        )
        seq = cur.fetchone()[0]
        if seq:
            cur.execute("SELECT setval(%s, %s, true)", (seq, max_id))


def main():
    if not os.path.exists(DB_PATH):
        raise SystemExit(f"SQLite DB bulunamadı: {DB_PATH}")

    sqlite_conn = sqlite3.connect(DB_PATH)
    sqlite_conn.row_factory = sqlite3.Row

    pg_conn = psycopg2.connect(DATABASE_URL)
    pg_conn.autocommit = False

    with pg_conn.cursor() as cur:
        for sql in PG_SCHEMA_SQL:
            cur.execute(sql)
    pg_conn.commit()

    tables = [
        "accounts",
        "sessions",
        "saas_events",
        "users",
        "events",
        "event_photos",
        "photo_matches",
        "jobs",
        "mail_logs",
        "qr_scans",
        "photo_downloads",
        "photo_attempts",
    ]

    for t in tables:
        copy_table(sqlite_conn, pg_conn, t)
        pg_conn.commit()
        try:
            reset_sequence(pg_conn, t)
            pg_conn.commit()
        except Exception:
            pg_conn.rollback()

    sqlite_conn.close()
    pg_conn.close()
    print("Migration completed.")


if __name__ == "__main__":
    main()
