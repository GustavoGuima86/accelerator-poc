import json
import os
import ssl
import threading
import time
import uuid

import pg8000.native

QUERY_SQL = "SELECT id, payload FROM bench_items WHERE id = :id"
MAX_QUERIES = 100
_schema_checked = False
_schema_lock = threading.Lock()


def _ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _ensure_schema():
    """Initialize the small demo tables directly through the Sydney writer."""
    global _schema_checked
    if _schema_checked:
        return
    conn = pg8000.native.Connection(
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        database=os.environ["DB_NAME"],
        ssl_context=_ssl_context() if os.environ.get("DB_SSL", "true") == "true" else None,
        timeout=10,
    )
    try:
        conn.run("CREATE TABLE IF NOT EXISTS bench_items (id integer PRIMARY KEY, payload text NOT NULL)")
        conn.run("CREATE TABLE IF NOT EXISTS bench_writes (id text PRIMARY KEY, source text NOT NULL, created_at timestamptz NOT NULL DEFAULT now())")
        if conn.run("SELECT count(*) FROM bench_items")[0][0] < 100:
            for row_id in range(1, 101):
                conn.run(
                    "INSERT INTO bench_items (id, payload) VALUES (:id, :payload) ON CONFLICT (id) DO NOTHING",
                    id=row_id,
                    payload="x" * 200,
                )
    finally:
        conn.close()
    _schema_checked = True


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    qs = event.get("queryStringParameters") or {}
    supplied = headers.get("x-bench-token") or qs.get("t")
    if supplied != os.environ["BENCH_TOKEN"]:
        return {"statusCode": 403, "body": "forbidden"}

    try:
        query_count = int(qs.get("queries") or os.environ.get("QUERY_COUNT", "20"))
    except ValueError:
        return {"statusCode": 400, "body": "queries must be an integer"}
    query_count = max(1, min(query_count, MAX_QUERIES))

    _ensure_schema()

    t0 = time.perf_counter()
    conn = pg8000.native.Connection(
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        database=os.environ["DB_NAME"],
        ssl_context=_ssl_context() if os.environ.get("DB_SSL", "true") == "true" else None,
        timeout=10,
    )
    t_connected = time.perf_counter()

    rows = 0
    for i in range(query_count):
        rows += len(conn.run(QUERY_SQL, id=(i % 100) + 1))
    t_done = time.perf_counter()
    conn.close()

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(
            {
                "queries": query_count,
                "rows": rows,
                "connect_ms": round((t_connected - t0) * 1000, 2),
                "queries_ms": round((t_done - t_connected) * 1000, 2),
            }
        ),
    }
