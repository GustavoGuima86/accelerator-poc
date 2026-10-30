#!/usr/bin/env python3
"""
Benchmarks the different ways a Frankfurt client can reach the Aurora
PostgreSQL global database whose writer lives in Sydney:

  public_direct       straight to the writer over the public internet
  global_accelerator  via Global Accelerator -> TCP forwarder -> writer
  vpc_peering         private path over inter-region VPC peering
  replica_local       the Frankfurt secondary cluster (reads are local;
                      writes are forwarded to Sydney by write forwarding)
  batch_api           ONE HTTPS call to a Lambda next to the writer that
                      runs the same N queries locally

Each database path is measured with two workloads, each repeated over several
fresh sessions:
  read   connect + N x SELECT by primary key
  write  connect + N x single-row INSERT (autocommit)

Usage:
    python3 db_benchmark.py <targets.json> <raw_db_results.json>

Does nothing (exit 0, no output file) when targets.json has no "db" section.
"""
import datetime
import ipaddress
import json
import socket
import ssl
import subprocess
import sys
import time
import uuid

import pg8000.native

READINESS_TIMEOUT_SECONDS = 900
READINESS_POLL_INTERVAL_SECONDS = 15
REPLICA_SYNC_TIMEOUT_SECONDS = 600
SEED_ROWS = 100


def utcnow_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# --------------------------------------------------------------------------
# Name resolution. The same Aurora hostname resolves to a public IP from the
# internet and to a private IP from inside the VPC (or a peered VPC with
# DNS resolution enabled). To measure each path honestly we pin the IP.
# --------------------------------------------------------------------------
def resolve_public(hostname):
    """Resolve through a public resolver, bypassing the VPC resolver, so we get the internet-facing IP."""
    out = subprocess.run(
        ["dig", "+short", "+time=3", "+tries=2", "@1.1.1.1", hostname, "A"],
        capture_output=True, text=True, timeout=30,
    ).stdout.split()
    ips = []
    for token in out:
        try:
            ips.append(str(ipaddress.ip_address(token)))
        except ValueError:
            continue
    if not ips:
        raise RuntimeError(f"public DNS returned no A record for {hostname}")
    return ips[-1]


def resolve_vpc(hostname):
    """Resolve through the VPC resolver (what any in-VPC application would get)."""
    return socket.gethostbyname(hostname)


def is_private(ip):
    return ipaddress.ip_address(ip).is_private


# --------------------------------------------------------------------------
# Connections
# --------------------------------------------------------------------------
def _ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def connect(cfg, host, port):
    return pg8000.native.Connection(
        user=cfg["user"],
        password=cfg["password"],
        host=host,
        port=port,
        database=cfg["database"],
        ssl_context=_ssl_context() if cfg.get("ssl", True) else None,
        timeout=30,
    )


def wait_until_connectable(name, cfg, host, port):
    deadline = time.time() + READINESS_TIMEOUT_SECONDS
    last = None
    while time.time() < deadline:
        try:
            conn = connect(cfg, host, port)
            conn.run("SELECT 1")
            conn.close()
            return True
        except Exception as exc:  # noqa: BLE001
            last = exc
            log(f"[{name}] not connectable yet ({type(exc).__name__}: {exc}), retrying...")
            time.sleep(READINESS_POLL_INTERVAL_SECONDS)
    log(f"[{name}] still not connectable after {READINESS_TIMEOUT_SECONDS}s: {last}")
    return False


def setup_schema(cfg, host, port):
    """Create and seed the benchmark tables through the writer (idempotent)."""
    conn = connect(cfg, host, port)
    try:
        conn.run(
            "CREATE TABLE IF NOT EXISTS bench_items "
            "(id integer PRIMARY KEY, payload text NOT NULL)"
        )
        conn.run(
            "CREATE TABLE IF NOT EXISTS bench_writes "
            "(id text PRIMARY KEY, source text NOT NULL, created_at timestamptz NOT NULL DEFAULT now())"
        )
        have = conn.run("SELECT count(*) FROM bench_items")[0][0]
        if have < SEED_ROWS:
            for row_id in range(1, SEED_ROWS + 1):
                conn.run(
                    "INSERT INTO bench_items (id, payload) VALUES (:id, :payload) "
                    "ON CONFLICT (id) DO NOTHING",
                    id=row_id,
                    payload="x" * 200,
                )
    finally:
        conn.close()


def wait_for_replica_data(cfg, host, port):
    """Reads on the replica are only meaningful once the seed data has replicated."""
    deadline = time.time() + REPLICA_SYNC_TIMEOUT_SECONDS
    while time.time() < deadline:
        try:
            conn = connect(cfg, host, port)
            try:
                if conn.run("SELECT count(*) FROM bench_items")[0][0] >= SEED_ROWS:
                    return True
            finally:
                conn.close()
        except Exception as exc:  # noqa: BLE001
            log(f"[replica_local] waiting for seed data to replicate ({type(exc).__name__}: {exc})")
        time.sleep(READINESS_POLL_INTERVAL_SECONDS)
    return False


# --------------------------------------------------------------------------
# Workloads
# --------------------------------------------------------------------------
def run_session(cfg, host, port, workload, queries, source):
    """One fresh connection followed by `queries` sequential statements."""
    record = {"workload": workload}
    t0 = time.perf_counter()
    try:
        conn = connect(cfg, host, port)
    except Exception as exc:  # noqa: BLE001
        record["error"] = f"connect: {type(exc).__name__}: {exc}"
        return record
    record["connect_ms"] = (time.perf_counter() - t0) * 1000

    query_ms = []
    try:
        for i in range(queries):
            q0 = time.perf_counter()
            if workload == "read":
                conn.run("SELECT id, payload FROM bench_items WHERE id = :id", id=(i % SEED_ROWS) + 1)
            else:
                # Use a deterministic id rather than a sequence/identity; the
                # latter is not supported by Aurora global write forwarding.
                # Each session uses fresh ids to avoid conflicts.
                conn.run(
                    "INSERT INTO bench_writes (id, source) VALUES (:id, :s)",
                    id=str(uuid.uuid4()),
                    s=source,
                )
            query_ms.append((time.perf_counter() - q0) * 1000)
    except Exception as exc:  # noqa: BLE001
        record["error"] = f"{workload}: {type(exc).__name__}: {exc}"
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass

    record["query_ms"] = query_ms
    record["total_ms"] = record["connect_ms"] + sum(query_ms)
    return record


def curl_batch_api(url, token):
    """One HTTPS request that makes the Lambda run all N queries next to the DB."""
    fmt = '\n%{http_code} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}'
    proc = subprocess.run(
        ["curl", "-s", "--max-time", "60", "-H", f"x-bench-token: {token}", "-w", fmt, url],
        capture_output=True, text=True, timeout=70,
    )
    body, _, timing = proc.stdout.rpartition("\n")
    record = {"workload": "batched"}
    try:
        code, t_conn, t_app, t_first, t_total = timing.split()
        record["http_code"] = int(code) if code != "000" else None
        record["time_starttransfer_ms"] = float(t_first) * 1000
        record["total_ms"] = float(t_total) * 1000
        if record["http_code"] == 200:
            inner = json.loads(body)
            record["lambda_connect_ms"] = inner.get("connect_ms")
            record["lambda_queries_ms"] = inner.get("queries_ms")
            record["queries"] = inner.get("queries")
        else:
            record["error"] = f"HTTP {record['http_code']}: {body[:200]}"
    except Exception as exc:  # noqa: BLE001
        record["error"] = f"{type(exc).__name__}: {exc} ({proc.stderr.strip()})"
    return record


# --------------------------------------------------------------------------
def build_paths(cfg):
    paths = {}

    def add(name, label, host_fn, port, optimized, note):
        try:
            host = host_fn()
            paths[name] = {"label": label, "host": host, "port": port, "optimized": optimized, "note": note}
        except Exception as exc:  # noqa: BLE001
            paths[name] = {"label": label, "host": None, "port": port, "optimized": optimized,
                           "note": note, "resolve_error": f"{type(exc).__name__}: {exc}"}

    add("public_direct", "Direct, public internet", lambda: resolve_public(cfg["primary_endpoint"]),
        cfg["port"], False, "Sydney writer, public IP")
    add("global_accelerator", "Global Accelerator", lambda: cfg["global_accelerator_ip"],
        cfg["db_accelerator_port"], True, "Anycast IP -> AWS backbone -> TCP forwarder -> Sydney writer")
    add("vpc_peering", "VPC peering (private)", lambda: resolve_vpc(cfg["primary_endpoint"]),
        cfg["port"], True, "Inter-region peering to the Sydney writer's private IP")
    add("replica_local", "Frankfurt replica", lambda: resolve_vpc(cfg["replica_endpoint"]),
        cfg["port"], True, "Local reads; writes forwarded to Sydney by write forwarding")

    if paths["vpc_peering"].get("host") and not is_private(paths["vpc_peering"]["host"]):
        paths["vpc_peering"]["warning"] = (
            f"{paths['vpc_peering']['host']} is not a private address: peering DNS resolution is not "
            "effective, so this measurement is NOT the private path."
        )
    if paths["public_direct"].get("host") and is_private(paths["public_direct"]["host"]):
        paths["public_direct"]["warning"] = (
            f"{paths['public_direct']['host']} is a private address: the writer is not reachable on a "
            "public IP, so this measurement is NOT the public-internet path."
        )
    return paths


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <targets.json> <raw_db_results.json>", file=sys.stderr)
        sys.exit(2)

    with open(sys.argv[1]) as fh:
        config = json.load(fh)

    cfg = config.get("db")
    if not cfg:
        log("No 'db' section in targets.json, skipping database benchmark.")
        return

    sessions = int(cfg.get("sessions", 5))
    queries = int(cfg.get("queries_per_session", 20))

    paths = build_paths(cfg)
    for name, p in paths.items():
        log(f"[{name}] host={p.get('host')} port={p['port']}"
            + (f" WARNING: {p['warning']}" if p.get("warning") else "")
            + (f" RESOLVE ERROR: {p['resolve_error']}" if p.get("resolve_error") else ""))

    # Schema/seed go through the private peering path: it is the first thing
    # that works after apply and does not depend on the public SG rule.
    setup_path = paths["vpc_peering"] if paths["vpc_peering"].get("host") else paths["public_direct"]
    if not setup_path.get("host"):
        log("No usable path to the writer for schema setup; aborting DB benchmark.")
        sys.exit(1)

    log("Preparing schema and seed data on the Sydney writer...")
    if not wait_until_connectable("setup", cfg, setup_path["host"], setup_path["port"]):
        sys.exit(1)
    setup_schema(cfg, setup_path["host"], setup_path["port"])

    results = {
        "generated_at": utcnow_iso(),
        "sessions": sessions,
        "queries_per_session": queries,
        "paths": {},
    }

    if paths["replica_local"].get("host"):
        log("Waiting for seed data to replicate to the Frankfurt replica...")
        if not wait_for_replica_data(cfg, paths["replica_local"]["host"], paths["replica_local"]["port"]):
            paths["replica_local"]["warning"] = "seed data did not replicate in time; read results may be errors"

    for name, p in paths.items():
        entry = {"meta": p, "read": [], "write": []}
        results["paths"][name] = entry
        if not p.get("host"):
            continue
        if not wait_until_connectable(name, cfg, p["host"], p["port"]):
            entry["meta"]["warning"] = (entry["meta"].get("warning", "") + " unreachable").strip()
            continue
        for workload in ("read", "write"):
            log(f"[{name}] {workload}: {sessions} sessions x {queries} queries")
            for _ in range(sessions):
                entry[workload].append(
                    run_session(cfg, p["host"], p["port"], workload, queries, source=f"bench-{name}")
                )

    batch = {"meta": {"label": "One call to an API next to the DB", "optimized": True,
                      "note": f"HTTPS to a Lambda in Sydney that runs the same {queries} reads locally"},
             "runs": []}
    if cfg.get("batch_api_url"):
        log(f"[batch_api] {sessions * 3} calls")
        for _ in range(sessions * 3):
            batch["runs"].append(curl_batch_api(cfg["batch_api_url"], cfg["batch_api_token"]))
    results["batch_api"] = batch

    with open(sys.argv[2], "w") as fh:
        json.dump(results, fh, indent=2)
    log(f"Wrote {sys.argv[2]}")


if __name__ == "__main__":
    main()
