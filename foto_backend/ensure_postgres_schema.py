#!/usr/bin/env python3
import os
import sys

try:
    import psycopg2
except Exception as e:
    print(f"psycopg2 import hatasi: {e}", file=sys.stderr)
    sys.exit(1)


def main():
    dsn = os.getenv("DATABASE_URL", "").strip()
    if not dsn:
        print("DATABASE_URL bos", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    cur = conn.cursor()

    cur.close()
    conn.close()
    print("schema ok (face matching tables disabled)")


if __name__ == "__main__":
    main()
