"""
Database probe used by the interactive page.

Runs ONE benchmark session (fresh connection + N sequential statements) against
ONE access path and returns the timings measured inside the function, so the
visitor-to-Lambda hop is not part of the numbers. It lives in the near region
(next to the benchmark client), so the figures describe "an application in
Frankfurt talking to the database in Sydney".

  GET ?path=public_direct|global_accelerator|vpc_peering|replica_local
      &workload=read|write&queries=N
  GET ?ping=1      warms the function and makes sure the schema exists
"""
import ipaddress
import json
import os
import socket
import ssl
import time
import threading
import urllib.request
import uuid

import pg8000.native

PATHS = ("public_direct", "global_accelerator", "vpc_peering", "replica_local", "batched_api")
MAX_QUERIES = 50
SEED_ROWS = 100

_dns_cache = {}
_schema_checked = False
_schema_lock = threading.Lock()


def _env(name, default=None):
    return os.environ.get(name, default)


def _ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _connect(host, port):
    return pg8000.native.Connection(
        user=_env("DB_USER"),
        password=_env("DB_PASSWORD"),
        host=host,
        port=port,
        database=_env("DB_NAME"),
        ssl_context=_ssl_context() if _env("DB_SSL", "true") == "true" else None,
        timeout=25,
    )


def _resolve_public(hostname):
    """Resolve through public DNS-over-HTTPS, bypassing the VPC resolver, so we get the internet-facing IP."""
    cached = _dns_cache.get(hostname)
    if cached and time.time() - cached[1] < 120:
        return cached[0]
    last = None
    for base in ("https://cloudflare-dns.com/dns-query", "https://dns.google/resolve"):
        try:
            req = urllib.request.Request(
                f"{base}?name={hostname}&type=A", headers={"accept": "application/dns-json"}
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                answers = json.load(resp).get("Answer", [])
            ips = [a["data"] for a in answers if a.get("type") == 1]
            if ips:
                _dns_cache[hostname] = (ips[-1], time.time())
                return ips[-1]
        except Exception as exc:  # noqa: BLE001
            last = exc
    raise RuntimeError(f"public DNS lookup failed for {hostname}: {last}")


def _resolve_vpc(hostname):
    return socket.gethostbyname(hostname)


def _is_private(ip):
    return ipaddress.ip_address(ip).is_private


def _target(path):
    """Returns (host, port, warning-or-None) for an access path."""
    port = int(_env("DB_PORT", "5432"))
    if path == "public_direct":
        host = _resolve_public(_env("PRIMARY_ENDPOINT"))
        warn = "resolved to a private address, so this is not the public-internet path" if _is_private(host) else None
        return host, port, warn
    if path == "global_accelerator":
        return _env("GA_IP"), int(_env("GA_PORT", "5432")), None
    if path == "vpc_peering":
        host = _resolve_vpc(_env("PRIMARY_ENDPOINT"))
        warn = None if _is_private(host) else "resolved to a public address, so this is not the private peering path"
        return host, port, warn
    if path == "replica_local":
        return _resolve_vpc(_env("REPLICA_ENDPOINT")), port, None
    raise ValueError(f"unknown path {path}")


def _ensure_schema():
    """Check the table exists; schema/seed creation is done by the Sydney Lambda during apply."""
    global _schema_checked
    if _schema_checked:
        return
    with _schema_lock:
        if _schema_checked:
            return
        try:
            host, port, _ = _target("vpc_peering")
            conn = _connect(host, port)
            try:
                conn.run("SELECT 1 FROM bench_items LIMIT 1")
            finally:
                conn.close()
            _schema_checked = True
        except Exception as exc:  # noqa: BLE001
            print(f"schema readiness check skipped: {type(exc).__name__}: {exc}")


def _json(status, body):
    return {"statusCode": status, "headers": {"content-type": "application/json"}, "body": json.dumps(body)}


def _run_batched(queries):
    """Frankfurt -> ONE HTTPS call to the Sydney function that runs all N queries next to the database."""
    url = _env("BATCH_API_URL")
    result = {"path": "batched_api", "workload": "read", "queries": queries}
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(f"{url}?t={_env('BATCH_TOKEN')}&queries={queries}", timeout=50) as resp:
            inner = json.load(resp)
    except Exception as exc:  # noqa: BLE001
        result["error"] = f"{type(exc).__name__}: {exc}"
        return result
    result["total_ms"] = round((time.perf_counter() - t0) * 1000, 2)
    result["inner_connect_ms"] = inner.get("connect_ms")
    result["inner_queries_ms"] = inner.get("queries_ms")
    return result


def handler(event, context):
    qs = event.get("queryStringParameters") or {}

    # Query-parameter token (not a header): keeps the browser request "simple",
    # so there is no CORS preflight round trip.
    if qs.get("t") != _env("BENCH_TOKEN"):
        return _json(403, {"error": "forbidden"})

    if qs.get("ping"):
        _ensure_schema()
        return _json(200, {"ok": True, "schema_ready": _schema_checked})

    path = qs.get("path")
    workload = qs.get("workload", "read")
    if path not in PATHS or workload not in ("read", "write"):
        return _json(400, {"error": "bad path or workload", "paths": list(PATHS)})
    try:
        queries = max(1, min(int(qs.get("queries", "10")), MAX_QUERIES))
    except ValueError:
        return _json(400, {"error": "queries must be an integer"})

    _ensure_schema()

    if path == "batched_api":
        if workload != "read":
            return _json(200, {"path": path, "workload": workload, "error": "the batched API only runs the read workload"})
        return _json(200, _run_batched(queries))

    result = {"path": path, "workload": workload, "queries": queries}
    try:
        host, port, warning = _target(path)
    except Exception as exc:  # noqa: BLE001
        result["error"] = f"{type(exc).__name__}: {exc}"
        return _json(200, result)
    result["host"] = host
    if warning:
        result["warning"] = warning

    t0 = time.perf_counter()
    try:
        conn = _connect(host, port)
    except Exception as exc:  # noqa: BLE001
        result["error"] = f"connect: {type(exc).__name__}: {exc}"
        return _json(200, result)
    result["connect_ms"] = round((time.perf_counter() - t0) * 1000, 2)

    query_ms = []
    try:
        for i in range(queries):
            q0 = time.perf_counter()
            if workload == "read":
                conn.run("SELECT id, payload FROM bench_items WHERE id = :id", id=(i % SEED_ROWS) + 1)
            else:
                # Avoid a sequence/identity operation: Aurora global write
                # forwarding doesn't forward nextval/sequence operations.
                conn.run(
                    "INSERT INTO bench_writes (id, source) VALUES (:id, :s)",
                    id=str(uuid.uuid4()),
                    s=f"interactive-{path}",
                )
            query_ms.append(round((time.perf_counter() - q0) * 1000, 2))
    except Exception as exc:  # noqa: BLE001
        result["error"] = f"{workload}: {type(exc).__name__}: {exc}"
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass

    result["query_ms"] = query_ms
    result["total_ms"] = round(result["connect_ms"] + sum(query_ms), 2)
    return _json(200, result)
