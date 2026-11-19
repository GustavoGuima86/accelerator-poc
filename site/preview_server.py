#!/usr/bin/env python3
"""Local preview server for the interactive latency page (site/index.html).

Serves the page together with a generated config.js and *working* mock
endpoints, so the Run buttons can be exercised locally without any AWS
resources. Simulated latencies are loosely modelled on Frankfurt -> Ohio:

  /direct/<key>   slow "public S3 website" download
  /cdn/<key>      fast "CloudFront edge" download (adds x-cache / x-amz-cf-pop)
  /api-direct     slow API round trip
  /api-ga         faster API round trip (Global Accelerator stand-in)
  /probe          simulated Aurora database probe sessions (all 5 paths)

Usage:  python3 site/preview_server.py  [port]     (default port 8751)
"""
import json
import random
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SITE_DIR = Path(__file__).resolve().parent
DEFAULT_PORT = 8751

# The page's DB timings are measured inside the probe, so the mock only waits
# a fraction of the simulated time to keep a full demo run reasonably quick.
TIME_SCALE = 0.35
MAX_WAIT_S = 1.6

PAYLOAD_SIZES = {"10kb.bin": 10240, "1mb.bin": 1048576}
PAGE_HTML = b"""<!doctype html><html><head><title>Sample page</title></head>
<body><h1>Sample page</h1><p>Tiny static asset used by the latency preview.</p></body></html>
"""

DB_PATHS = [
    {"id": "public_direct", "label": "Direct, public internet", "optimized": False, "writes": True},
    {"id": "global_accelerator", "label": "Global Accelerator", "optimized": True, "writes": True},
    {"id": "vpc_peering", "label": "VPC peering (private)", "optimized": True, "writes": True},
    {"id": "replica_local", "label": "Frankfurt replica", "optimized": True, "writes": True},
    {"id": "batched_api", "label": "One call to API next to DB", "optimized": True, "writes": False},
]

# Simulated traceroute used ONLY by the local preview. Real deployments run an
# actual mtr/traceroute on the Frankfurt EC2 client via the trace_probe Lambda.
# IPs are from the TEST-NET documentation ranges on purpose. The route follows
# a plausible Frankfurt -> Ohio path: European transit, a transatlantic hop,
# then US East Coast transit down to Ohio.
TRACE_CHAIN = [
    {"hop": 1, "ip": "172.31.0.1", "rtt_ms": 0.4, "loss_pct": 0.0},
    {"hop": 2, "ip": "192.0.2.10", "rtt_ms": 1.1, "loss_pct": 0.0, "lat": 50.11, "lon": 8.68,
     "isp": "Example Internet Exchange", "loc": "Frankfurt, Germany"},
    {"hop": 3, "ip": "192.0.2.11", "rtt_ms": 5.8, "loss_pct": 0.0, "lat": 52.31, "lon": 4.76,
     "isp": "Example Transit AS64500", "loc": "Amsterdam, Netherlands"},
    {"hop": 4, "ip": "192.0.2.20", "rtt_ms": 11.4, "loss_pct": 0.0, "lat": 51.47, "lon": -0.45,
     "isp": "Example Transit AS64500", "loc": "London, United Kingdom"},
    {"hop": 5, "ip": None, "rtt_ms": None, "loss_pct": 100.0},
    {"hop": 6, "ip": "192.0.2.40", "rtt_ms": 87.3, "loss_pct": 0.0, "lat": 40.64, "lon": -73.78,
     "isp": "Example Subsea Cable", "loc": "New York, United States"},
    {"hop": 7, "ip": "192.0.2.55", "rtt_ms": 91.6, "loss_pct": 0.0, "lat": 38.95, "lon": -77.46,
     "isp": "Example Transit AS64510", "loc": "Ashburn, United States"},
    {"hop": 8, "ip": None, "rtt_ms": None, "loss_pct": 100.0},
    {"hop": 9, "ip": "192.0.2.70", "rtt_ms": 106.8, "loss_pct": 0.0, "lat": 39.96, "lon": -82.99,
     "isp": "Example Transit AS64520", "loc": "Columbus, United States"},
    {"hop": 10, "ip": "203.0.113.7", "rtt_ms": 109.2, "loss_pct": 0.0, "lat": 39.96, "lon": -82.99,
     "isp": "Destination network", "loc": "Columbus, United States"},
]
TRACE_HOSTS = {
    "static_direct": "s3-website-simulated.ohio.example",
    "static_optimized": "d1example2.cloudfront.net",
    "api_direct": "alb-simulated.ohio.example",
    "api_optimized": "75.2.60.5",
    "db_direct": "aurora-writer-simulated.ohio.example",
    "db_optimized": "75.2.60.5",
}
# Optimized targets are anycast: a real traceroute stops at the AWS edge.
# The preview simulates that by returning only the hops up to the edge; the
# page then draws the approximate continuation through the private backbone.
TRACE_EDGE_CHAIN = TRACE_CHAIN[:3] + [
    {"hop": 4, "ip": "192.0.2.99", "rtt_ms": 9.2, "loss_pct": 0.0, "lat": 50.04, "lon": 8.56,
     "isp": "Amazon.com (AWS edge)", "loc": "Frankfurt, Germany"},
]

# (mean, spread) in milliseconds. Frankfurt<->Ohio round trips are roughly
# ~90-110 ms, noticeably shorter than the Frankfurt<->Sydney distance this
# demo used to simulate, so every cross-region figure below is scaled down
# accordingly (same-region figures, e.g. the replica's local reads, are
# unchanged since they never depended on the far-region distance).
DB_PROFILES = {
    "public_direct": {"connect": (112, 8), "query": (91, 6)},
    "global_accelerator": {"connect": (66, 5), "query": (89, 4)},
    "vpc_peering": {"connect": (103, 5), "query": (90, 5)},
    "replica_local": {
        "connect": (9, 2),
        "read_query": (1.4, 0.4),
        "write_query": (48, 4),
        "write_warning": "Writes are forwarded to the Ohio writer; only reads stay local.",
    },
    "batched_api": {"https": (115, 8), "query": (2.3, 0.5)},
}


def jitter(mean, spread):
    return max(0.1, random.gauss(mean, spread))


def payload_bytes(key):
    if key == "page.html":
        return PAGE_HTML
    size = PAYLOAD_SIZES.get(key)
    if size is None:
        return None
    return random.Random(key).randbytes(size)


def db_probe_result(params):
    path = (params.get("path") or [""])[0]
    workload = (params.get("workload") or ["read"])[0]
    try:
        queries = min(50, max(1, int((params.get("queries") or ["20"])[0])))
    except ValueError:
        queries = 20
    prof = DB_PROFILES.get(path)
    if prof is None:
        return 400, {"error": f"unknown path '{path}'"}

    result = {"path": path, "workload": workload, "queries": queries}
    if path == "batched_api":
        inner = sum(jitter(*prof["query"]) for _ in range(queries))
        https = jitter(*prof["https"])
        result["inner_queries_ms"] = round(inner, 1)
        result["total_ms"] = round(https + inner, 1)
        wait = result["total_ms"]
    else:
        connect = jitter(*prof["connect"])
        if path == "replica_local":
            qmean, qspread = prof["read_query"] if workload == "read" else prof["write_query"]
            if workload != "read":
                result["warning"] = prof["write_warning"]
        else:
            qmean, qspread = prof["query"]
        query_ms = [round(jitter(qmean, qspread), 2) for _ in range(queries)]
        result["connect_ms"] = round(connect, 1)
        result["query_ms"] = query_ms
        result["total_ms"] = round(connect + sum(query_ms), 1)
        wait = result["total_ms"]
    delay = min(wait * TIME_SCALE / 1000.0, MAX_WAIT_S)
    time.sleep(delay)
    return 200, result


class Handler(BaseHTTPRequestHandler):
    server_version = "LatencyPreview/1.0"

    def log_message(self, fmt, *args):  # keep the console quiet
        pass

    def _send(self, status, body, content_type, extra_headers=None, delay=0.0):
        if delay > 0:
            time.sleep(delay)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Expose-Headers", "x-cache, x-amz-cf-pop")
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, status, obj, extra_headers=None, delay=0.0):
        self._send(status, json.dumps(obj).encode(), "application/json", extra_headers, delay)

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        params = parse_qs(url.query)
        origin = f"http://{self.headers.get('Host', f'127.0.0.1:{DEFAULT_PORT}')}"

        if path in ("/", "/index.html"):
            body = (SITE_DIR / "index.html").read_bytes()
            self._send(200, body, "text/html; charset=utf-8")
            return

        if path == "/config.js":
            config = {
                "title": "Latency route preview (local mock)",
                "originRegion": "us-east-2",
                "clientRegion": "eu-central-1",
                "static": {
                    "directBase": f"{origin}/direct",
                    "cloudfrontBase": f"{origin}/cdn",
                    "page": "page.html",
                    "assets": [
                        {"label": "10 KB", "key": "10kb.bin", "bytes": PAYLOAD_SIZES["10kb.bin"]},
                        {"label": "1 MB", "key": "1mb.bin", "bytes": PAYLOAD_SIZES["1mb.bin"]},
                    ],
                },
                "api": {"directUrl": f"{origin}/api-direct", "acceleratorUrl": f"{origin}/api-ga"},
                "db": {"probeUrl": f"{origin}/probe", "probeToken": "preview", "paths": DB_PATHS},
                "trace": {"url": f"{origin}/trace", "token": "preview",
                          "targets": ["static_direct", "static_optimized", "api_direct",
                                      "api_optimized", "db_direct", "db_optimized"]},
            }
            body = f"window.BENCH_CONFIG = {json.dumps(config)};".encode()
            self._send(200, body, "application/javascript")
            return

        if path.startswith("/direct/") or path.startswith("/cdn/"):
            key = path.split("/", 2)[2]
            body = payload_bytes(key)
            if body is None:
                self._send_json(404, {"error": f"no such payload: {key}"})
                return
            if path.startswith("/cdn/"):
                headers = {
                    "x-cache": "Hit from cloudfront",
                    "x-amz-cf-pop": "FRA50-P2",
                    "x-amz-cf-id": f"preview-{random.randint(10**9, 10**10 - 1)}",
                }
                self._send(200, body, "application/octet-stream", headers, delay=random.uniform(0.012, 0.03))
            else:
                self._send(200, body, "application/octet-stream", {"Server": "AmazonS3"}, delay=random.uniform(0.085, 0.115))
            return

        if path in ("/api-direct", "/api-ga"):
            delay = random.uniform(0.09, 0.115) if path == "/api-direct" else random.uniform(0.05, 0.075)
            self._send_json(200, {"ok": True, "region": "us-east-2", "ts": time.time()}, delay=delay)
            return

        if path == "/probe":
            if params.get("ping"):
                self._send_json(200, {"ok": True, "schema": True})
                return
            status, obj = db_probe_result(params)
            self._send_json(status, obj)
            return

        if path == "/trace":
            token = (params.get("t") or [""])[0]
            if token != "preview":
                self._send_json(403, {"error": "invalid token"})
                return
            target = (params.get("target") or [""])[0]
            host = TRACE_HOSTS.get(target)
            if not host:
                self._send_json(400, {"error": "unknown target; expected one of: " + ", ".join(sorted(TRACE_HOSTS))})
                return
            time.sleep(2.5)  # a real trace takes 30-90 s; the preview only simulates
            hops = TRACE_EDGE_CHAIN if target.endswith("_optimized") else TRACE_CHAIN
            self._send_json(200, {
                "target": target, "host": host, "tool": "mtr (simulated)",
                "hops": hops, "geo": "preview fixture",
                "elapsed_ms": 42100, "simulated": True,
            })
            return

        self._send_json(404, {"error": f"no preview endpoint at {path}"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Latency preview ready: http://127.0.0.1:{port}")
    print("Endpoints are local mocks with simulated Frankfurt<->Ohio latencies.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
