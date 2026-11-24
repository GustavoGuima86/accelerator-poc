#!/usr/bin/env python3
"""
Finds out why database queries through Global Accelerator are slower than the
other paths. Run it ON the Frankfurt benchmark instance (see
scripts/run_db_diagnostic.sh), because the forwarder only accepts that client.

It runs read-only sessions (fresh connection + N SELECTs) against:

  aurora_public      Ohio writer, public IP (the "direct" baseline)
  forwarder_direct   the socat forwarder's own public IP, SKIPPING the accelerator
  accelerator        the accelerator's anycast IP (port 5432)

each once as-is and once with TCP_NODELAY set on the client socket, and prints
per-query timings so recurring stalls are visible.

How to read it:
  * stalls on accelerator only            -> the accelerator edge
  * stalls on forwarder_direct as well    -> the socat forwarder (e.g. Nagle)
  * stalls vanish with client nodelay     -> client/proxy small-write interaction
  * no stalls anywhere                    -> not reproducible now; run again

Usage:
    python3 db_diagnostic.py <targets.json> <forwarder_public_ip> [sessions] [queries]
"""
import json
import socket
import ssl
import statistics as st
import sys
import time

import pg8000.native

STALL_MS = 40  # a query this far above the path's fastest query counts as a stall


def _ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def resolve_public(hostname):
    import subprocess
    out = subprocess.run(["dig", "+short", "+time=3", "+tries=2", "@1.1.1.1", hostname, "A"],
                         capture_output=True, text=True, timeout=30).stdout.split()
    ips = [t for t in out if t.replace(".", "").isdigit()]
    if not ips:
        raise RuntimeError(f"no public A record for {hostname}")
    return ips[-1]


def session(cfg, host, port, queries, nodelay):
    original = socket.create_connection

    def patched(*args, **kwargs):
        sock = original(*args, **kwargs)
        if nodelay:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return sock

    socket.create_connection = patched
    try:
        t0 = time.perf_counter()
        conn = pg8000.native.Connection(
            user=cfg["user"], password=cfg["password"], host=host, port=port,
            database=cfg["database"], ssl_context=_ssl_context(), timeout=30)
        connect_ms = (time.perf_counter() - t0) * 1000
    finally:
        socket.create_connection = original

    times = []
    try:
        for i in range(queries):
            q0 = time.perf_counter()
            conn.run("SELECT id, payload FROM bench_items WHERE id = :id", id=(i % 100) + 1)
            times.append((time.perf_counter() - q0) * 1000)
    finally:
        conn.close()
    return connect_ms, times


def summarize(label, runs):
    allq = [q for _, qs in runs for q in qs]
    floor = min(allq)
    stalls = [q for q in allq if q - floor > STALL_MS]
    extra = sorted(round(q - floor) for q in stalls)
    print(f"{label:34} connect {st.mean(c for c, _ in runs):6.0f} ms | "
          f"query avg {st.mean(allq):5.0f}  min {floor:5.0f}  p95 {sorted(allq)[int(len(allq) * .95) - 1]:5.0f} | "
          f"stalled {len(stalls):3d}/{len(allq)}"
          + (f" (extra ms: min {extra[0]}, median {extra[len(extra) // 2]}, max {extra[-1]})" if extra else ""))
    return {"label": label, "connect_avg_ms": st.mean(c for c, _ in runs), "query_avg_ms": st.mean(allq),
            "query_min_ms": floor, "stalled": len(stalls), "queries": len(allq), "extra_ms": extra,
            "sample_session_ms": [round(q) for q in runs[0][1]]}


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    cfg_all = json.load(open(sys.argv[1]))
    cfg = cfg_all["db"]
    forwarder_ip = sys.argv[2]
    sessions = int(sys.argv[3]) if len(sys.argv) > 3 else 5
    queries = int(sys.argv[4]) if len(sys.argv) > 4 else 20

    paths = [
        ("aurora_public", resolve_public(cfg["primary_endpoint"]), cfg["port"]),
        ("forwarder_direct", forwarder_ip, 5432),
        ("accelerator", cfg["global_accelerator_ip"], cfg["db_accelerator_port"]),
    ]
    print(f"{sessions} sessions x {queries} SELECTs per row; stall = query > fastest + {STALL_MS} ms\n")
    for name, host, port in paths:
        print(f"  {name:18} -> {host}:{port}")
    print()

    results = []
    for nodelay in (False, True):
        for name, host, port in paths:
            runs = []
            for _ in range(sessions):
                try:
                    runs.append(session(cfg, host, port, queries, nodelay))
                except Exception as exc:  # noqa: BLE001
                    print(f"{name} nodelay={nodelay}: {type(exc).__name__}: {exc}")
                    break
            if runs:
                results.append(summarize(f"{name}{' + client nodelay' if nodelay else ''}", runs))
        print()

    print("Sample session (ms per query) for each row:")
    for r in results:
        print(f"  {r['label']:34} {r['sample_session_ms']}")
    print("\nJSON:" + json.dumps(results))


if __name__ == "__main__":
    main()
