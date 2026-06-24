#!/usr/bin/env python3
import argparse
import csv
import json
import os
import re
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

try:
    import psycopg2
    import psycopg2.extras
except Exception as e:
    raise SystemExit(
        "psycopg2 import edilemedi. Gerekirse: PYTHONPATH=/usr/lib/python3/dist-packages python3 scripts/unify_users.py ..."
    ) from e

DEFAULT_DB_URL = "postgresql://dansmagazin_user:dansmagazin@localhost:5432/dansmagazin_db"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def norm_email(v: str) -> str:
    return (v or "").strip().lower()


def norm_name(v: str) -> str:
    s = (v or "").strip().lower()
    s = re.sub(r"\s+", " ", s)
    s = re.sub(r"[^a-z0-9çğıöşü\s]", "", s)
    return s


def db_url_from_env() -> str:
    return (
        os.getenv("USER_UNIFY_DATABASE_URL", "").strip()
        or os.getenv("DATABASE_URL", "").strip()
        or DEFAULT_DB_URL
    )


def conn_db(url: str):
    return psycopg2.connect(url, cursor_factory=psycopg2.extras.RealDictCursor)


def ensure_tables(conn):
    cur = conn.cursor()
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS identity_wp_users_staging (
            id BIGSERIAL PRIMARY KEY,
            source_tag TEXT NOT NULL,
            wp_user_id BIGINT,
            email TEXT,
            username TEXT,
            display_name TEXT,
            role TEXT,
            created_at TEXT,
            raw_json TEXT,
            imported_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );

        CREATE TABLE IF NOT EXISTS identity_app_accounts_staging (
            id BIGSERIAL PRIMARY KEY,
            source_tag TEXT NOT NULL,
            app_account_id BIGINT,
            email TEXT,
            name TEXT,
            phone TEXT,
            role TEXT,
            created_at TEXT,
            imported_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );

        CREATE TABLE IF NOT EXISTS identity_merge_runs (
            id BIGSERIAL PRIMARY KEY,
            run_note TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );

        CREATE TABLE IF NOT EXISTS identity_match_candidates (
            id BIGSERIAL PRIMARY KEY,
            run_id BIGINT NOT NULL,
            strategy TEXT NOT NULL,
            confidence INTEGER NOT NULL,
            wp_user_id BIGINT,
            app_account_id BIGINT,
            email TEXT,
            wp_display_name TEXT,
            app_name TEXT,
            reason TEXT,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );

        CREATE INDEX IF NOT EXISTS idx_identity_candidates_run ON identity_match_candidates(run_id);
        CREATE INDEX IF NOT EXISTS idx_identity_candidates_wp ON identity_match_candidates(wp_user_id);
        CREATE INDEX IF NOT EXISTS idx_identity_candidates_app ON identity_match_candidates(app_account_id);

        CREATE TABLE IF NOT EXISTS identity_map (
            wp_user_id BIGINT PRIMARY KEY,
            app_account_id BIGINT UNIQUE,
            match_strategy TEXT,
            confidence INTEGER,
            note TEXT,
            linked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            is_active BOOLEAN NOT NULL DEFAULT TRUE
        );

        CREATE TABLE IF NOT EXISTS identity_merge_audit (
            id BIGSERIAL PRIMARY KEY,
            run_id BIGINT,
            wp_user_id BIGINT,
            app_account_id BIGINT,
            action TEXT NOT NULL,
            details TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        );
        """
    )
    conn.commit()


def import_wp_csv(conn, csv_path: str, source_tag: str):
    inserted = 0
    cur = conn.cursor()
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        required = {"wp_user_id", "email", "username", "display_name"}
        miss = required - set(reader.fieldnames or [])
        if miss:
            raise SystemExit(f"CSV kolonları eksik: {sorted(miss)}")

        for row in reader:
            wp_user_id = row.get("wp_user_id") or None
            email = norm_email(row.get("email", ""))
            username = (row.get("username") or "").strip()
            display_name = (row.get("display_name") or "").strip()
            role = (row.get("role") or "").strip()
            created_at = (row.get("created_at") or "").strip()

            cur.execute(
                """
                INSERT INTO identity_wp_users_staging
                (source_tag, wp_user_id, email, username, display_name, role, created_at, raw_json)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
                """,
                (
                    source_tag,
                    int(wp_user_id) if wp_user_id and str(wp_user_id).isdigit() else None,
                    email,
                    username,
                    display_name,
                    role,
                    created_at,
                    json.dumps(row, ensure_ascii=False),
                ),
            )
            inserted += 1

    conn.commit()
    print(f"WP staging import tamamlandı: {inserted} kayıt")


def snapshot_app_accounts(conn, source_tag: str):
    cur = conn.cursor()
    cur.execute(
        """
        INSERT INTO identity_app_accounts_staging
        (source_tag, app_account_id, email, name, phone, role, created_at)
        SELECT %s, id, LOWER(TRIM(COALESCE(email,''))), COALESCE(name,''), COALESCE(phone,''), COALESCE(role,''), COALESCE(created_at,'')
        FROM accounts
        """,
        (source_tag,),
    )
    inserted = cur.rowcount
    conn.commit()
    print(f"APP staging snapshot tamamlandı: {inserted} kayıt")


def _insert_run(conn, note: str) -> int:
    cur = conn.cursor()
    cur.execute(
        "INSERT INTO identity_merge_runs (run_note) VALUES (%s) RETURNING id",
        (note,),
    )
    rid = int(cur.fetchone()["id"])
    conn.commit()
    return rid


def build_candidates(conn, wp_source: str, app_source: str, note: str) -> int:
    run_id = _insert_run(conn, note)
    cur = conn.cursor()

    cur.execute(
        """
        SELECT wp_user_id, email, display_name
        FROM identity_wp_users_staging
        WHERE source_tag=%s
        """,
        (wp_source,),
    )
    wp_rows = cur.fetchall()

    cur.execute(
        """
        SELECT app_account_id, email, name, phone
        FROM identity_app_accounts_staging
        WHERE source_tag=%s
        """,
        (app_source,),
    )
    app_rows = cur.fetchall()

    wp_by_email: Dict[str, List[dict]] = {}
    for r in wp_rows:
        em = norm_email(r.get("email") or "")
        if not em:
            continue
        wp_by_email.setdefault(em, []).append(r)

    app_by_email: Dict[str, List[dict]] = {}
    for r in app_rows:
        em = norm_email(r.get("email") or "")
        if not em:
            continue
        app_by_email.setdefault(em, []).append(r)

    inserted = 0

    # Strategy 1: exact email
    for em, wps in wp_by_email.items():
        apps = app_by_email.get(em, [])
        if not apps:
            continue
        ambiguous = len(wps) != 1 or len(apps) != 1
        conf = 100 if not ambiguous else 70
        reason = "email_exact_unique" if not ambiguous else f"email_exact_ambiguous wp={len(wps)} app={len(apps)}"
        for w in wps:
            for a in apps:
                cur.execute(
                    """
                    INSERT INTO identity_match_candidates
                    (run_id, strategy, confidence, wp_user_id, app_account_id, email, wp_display_name, app_name, reason)
                    VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)
                    """,
                    (
                        run_id,
                        "email_exact",
                        conf,
                        w.get("wp_user_id"),
                        a.get("app_account_id"),
                        em,
                        w.get("display_name") or "",
                        a.get("name") or "",
                        reason,
                    ),
                )
                inserted += 1

    # Strategy 2: name+phone (manual)
    app_name_phone: Dict[Tuple[str, str], List[dict]] = {}
    for a in app_rows:
        nn = norm_name(a.get("name") or "")
        ph = re.sub(r"\D", "", a.get("phone") or "")
        if not nn or not ph:
            continue
        app_name_phone.setdefault((nn, ph), []).append(a)

    for w in wp_rows:
        nn = norm_name(w.get("display_name") or "")
        if not nn:
            continue
        # wp tarafında phone yoksa bu strateji pas geç
        # (ileride wp csv'de phone kolonu verilirse genişletilebilir)

    conn.commit()
    print(f"Candidate üretimi tamamlandı. run_id={run_id}, inserted={inserted}")
    return run_id


def report(conn, run_id: int):
    cur = conn.cursor()
    cur.execute("SELECT run_note, created_at FROM identity_merge_runs WHERE id=%s", (run_id,))
    run = cur.fetchone()
    if not run:
        raise SystemExit(f"run_id bulunamadı: {run_id}")

    cur.execute("SELECT COUNT(*) c FROM identity_match_candidates WHERE run_id=%s", (run_id,))
    total = int(cur.fetchone()["c"])

    cur.execute(
        """
        SELECT strategy, confidence, COUNT(*) c
        FROM identity_match_candidates
        WHERE run_id=%s
        GROUP BY strategy, confidence
        ORDER BY strategy, confidence DESC
        """,
        (run_id,),
    )
    by_grp = cur.fetchall()

    cur.execute(
        """
        SELECT COUNT(*) c
        FROM identity_match_candidates
        WHERE run_id=%s AND strategy='email_exact' AND confidence>=95
        """,
        (run_id,),
    )
    auto_ready = int(cur.fetchone()["c"])

    cur.execute(
        """
        SELECT email, COUNT(*) c
        FROM identity_match_candidates
        WHERE run_id=%s AND strategy='email_exact'
        GROUP BY email
        HAVING COUNT(*) > 1
        ORDER BY c DESC
        LIMIT 20
        """,
        (run_id,),
    )
    top_amb = cur.fetchall()

    print(f"\nRun: {run_id} | note={run['run_note']} | at={run['created_at']}")
    print(f"Toplam candidate: {total}")
    print(f"Auto-ready (email unique): {auto_ready}")
    print("\nDağılım:")
    for r in by_grp:
        print(f"- {r['strategy']} conf={r['confidence']} -> {r['c']}")

    if top_amb:
        print("\nAmbiguous email örnekleri:")
        for r in top_amb:
            print(f"- {r['email']}: {r['c']} candidate")


def apply_auto_exact(conn, run_id: int, note: str):
    cur = conn.cursor()

    cur.execute(
        """
        WITH c AS (
          SELECT id, wp_user_id, app_account_id, email
          FROM identity_match_candidates
          WHERE run_id=%s AND strategy='email_exact' AND confidence>=95
        ),
        one_wp AS (
          SELECT wp_user_id
          FROM c
          GROUP BY wp_user_id
          HAVING COUNT(*)=1
        ),
        one_app AS (
          SELECT app_account_id
          FROM c
          GROUP BY app_account_id
          HAVING COUNT(*)=1
        )
        SELECT c.id, c.wp_user_id, c.app_account_id, c.email
        FROM c
        JOIN one_wp w ON w.wp_user_id=c.wp_user_id
        JOIN one_app a ON a.app_account_id=c.app_account_id
        """,
        (run_id,),
    )
    rows = cur.fetchall()

    linked = 0
    for r in rows:
        cur.execute(
            """
            INSERT INTO identity_map (wp_user_id, app_account_id, match_strategy, confidence, note)
            VALUES (%s,%s,%s,%s,%s)
            ON CONFLICT (wp_user_id) DO UPDATE
            SET app_account_id=EXCLUDED.app_account_id,
                match_strategy=EXCLUDED.match_strategy,
                confidence=EXCLUDED.confidence,
                note=EXCLUDED.note,
                linked_at=NOW(),
                is_active=TRUE
            """,
            (
                r["wp_user_id"],
                r["app_account_id"],
                "email_exact",
                100,
                note,
            ),
        )
        cur.execute(
            """
            INSERT INTO identity_merge_audit (run_id, wp_user_id, app_account_id, action, details)
            VALUES (%s,%s,%s,%s,%s)
            """,
            (
                run_id,
                r["wp_user_id"],
                r["app_account_id"],
                "link_upsert",
                json.dumps({"email": r["email"], "note": note}, ensure_ascii=False),
            ),
        )
        cur.execute(
            "UPDATE identity_match_candidates SET status='applied' WHERE id=%s",
            (r["id"],),
        )
        linked += 1

    conn.commit()
    print(f"Auto-apply tamamlandı. run_id={run_id}, linked={linked}")


def parse_args():
    ap = argparse.ArgumentParser(description="WP/Woo + App kullanıcı birleştirme yardımcı aracı (güvenli/dry-run odaklı)")
    ap.add_argument("--db-url", default=db_url_from_env(), help="PostgreSQL bağlantı URL")

    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ensure", help="Gerekli staging/map tablolarını oluştur")

    p_import = sub.add_parser("import-wp-csv", help="WP kullanıcı CSV'sini staging'e al")
    p_import.add_argument("--csv", required=True, help="CSV path (wp_user_id,email,username,display_name,role,created_at)")
    p_import.add_argument("--source", required=True, help="Kaynak etiketi (örn: wp_2026_02_20)")

    p_snap = sub.add_parser("snapshot-app", help="accounts tablosunu staging'e snapshot al")
    p_snap.add_argument("--source", required=True, help="Kaynak etiketi (örn: app_2026_02_20)")

    p_build = sub.add_parser("build-candidates", help="Dry-run candidate üret")
    p_build.add_argument("--wp-source", required=True)
    p_build.add_argument("--app-source", required=True)
    p_build.add_argument("--note", default=f"dry_run_{now_iso()}")

    p_report = sub.add_parser("report", help="Run raporu")
    p_report.add_argument("--run-id", type=int, required=True)

    p_apply = sub.add_parser("apply-auto", help="Sadece unique exact-email match'leri uygula")
    p_apply.add_argument("--run-id", type=int, required=True)
    p_apply.add_argument("--note", default="auto_apply_exact_email")

    return ap.parse_args()


def main():
    args = parse_args()
    conn = conn_db(args.db_url)
    try:
        if args.cmd == "ensure":
            ensure_tables(conn)
            print("OK: tablolar hazır")
        elif args.cmd == "import-wp-csv":
            ensure_tables(conn)
            import_wp_csv(conn, args.csv, args.source)
        elif args.cmd == "snapshot-app":
            ensure_tables(conn)
            snapshot_app_accounts(conn, args.source)
        elif args.cmd == "build-candidates":
            ensure_tables(conn)
            run_id = build_candidates(conn, args.wp_source, args.app_source, args.note)
            report(conn, run_id)
        elif args.cmd == "report":
            report(conn, args.run_id)
        elif args.cmd == "apply-auto":
            apply_auto_exact(conn, args.run_id, args.note)
            report(conn, args.run_id)
        else:
            raise SystemExit("Desteklenmeyen komut")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
