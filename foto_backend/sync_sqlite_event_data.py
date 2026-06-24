#!/usr/bin/env python3
import os
import sqlite3
from typing import List

import psycopg2
import psycopg2.extras

DB_PATH = os.path.join(os.path.dirname(__file__), "database.db")
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://dansmagazin_user:dansmagazin@localhost:5432/dansmagazin_db")

EVENT_TABLES = {
    "saas_events": {"col": "slug", "fk": None},
    "events": {"col": "slug", "fk": None},
    "users": {"col": "event_id", "fk": "event_id"},
    "event_photos": {"col": "event_id", "fk": "event_id"},
    "photo_matches": {"col": "event_id", "fk": "event_id"},
    "jobs": {"col": "event_slug", "fk": "event_slug"},
    "mail_logs": {"col": "event_slug", "fk": "event_slug"},
    "qr_scans": {"col": "event_slug", "fk": "event_slug"},
    "photo_downloads": {"col": "event_slug", "fk": "event_slug"},
    "photo_attempts": {"col": "event_slug", "fk": "event_slug"},
}


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


def table_exists_sqlite(conn: sqlite3.Connection, table: str) -> bool:
    cur = conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name=?", (table,))
    return cur.fetchone() is not None


def table_exists_pg(conn, table: str) -> bool:
    cur = conn.cursor()
    cur.execute(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name=%s)",
        (table,),
    )
    return bool(cur.fetchone()[0])


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

    s_conn = sqlite3.connect(DB_PATH)
    s_conn.row_factory = sqlite3.Row
    pg_conn = psycopg2.connect(DATABASE_URL)

    try:
        # slugs from sqlite
        if not table_exists_sqlite(s_conn, "saas_events"):
            raise SystemExit("SQLite saas_events tablosu yok")
        s_cur = s_conn.cursor()
        s_cur.execute("SELECT slug FROM saas_events")
        slugs = [r[0] for r in s_cur.fetchall()]
        if not slugs:
            print("[INFO] SQLite'da aktarılacak etkinlik yok")
            return

        print("[INFO] Slugs:", slugs)

        with pg_conn:
            for table, meta in EVENT_TABLES.items():
                if not table_exists_sqlite(s_conn, table) or not table_exists_pg(pg_conn, table):
                    print(f"[SKIP] {table}: table missing")
                    continue

                col = meta["col"]
                # delete existing rows for these slugs
                placeholders = ",".join(["%s"] * len(slugs))
                with pg_conn.cursor() as cur:
                    cur.execute(f"DELETE FROM {table} WHERE {col} IN ({placeholders})", slugs)

                s_cols = sqlite_columns(s_conn, table)
                p_cols = pg_columns(pg_conn, table)
                cols = [c for c in s_cols if c in p_cols]
                if not cols:
                    print(f"[SKIP] {table}: no common columns")
                    continue

                s_cur = s_conn.cursor()
                qmarks = ",".join(["?"] * len(slugs))
                s_cur.execute(
                    f"SELECT {', '.join(cols)} FROM {table} WHERE {col} IN ({qmarks})",
                    slugs,
                )
                rows = s_cur.fetchall()
                if not rows:
                    print(f"[OK] {table}: 0 rows")
                    continue

                insert_sql = f"INSERT INTO {table} ({', '.join(cols)}) VALUES %s"
                with pg_conn.cursor() as cur:
                    psycopg2.extras.execute_values(cur, insert_sql, rows, page_size=1000)
                print(f"[OK] {table}: {len(rows)} rows")

                if "id" in cols:
                    reset_sequence(pg_conn, table)

        print("[DONE] Sync completed")

    finally:
        s_conn.close()
        pg_conn.close()


if __name__ == "__main__":
    main()
