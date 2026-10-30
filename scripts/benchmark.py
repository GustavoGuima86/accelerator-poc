#!/usr/bin/env python3
"""
Runs a sequential curl-based latency benchmark against a list of target URLs
and writes the raw, per-request results to a JSON file.

This script is uploaded to the Frankfurt benchmark EC2 instance by Terraform
(see modules/benchmark) and executed there via SSM Run Command, so that the
measurements reflect real Frankfurt -> Sydney network conditions regardless
of where the benchmark is triggered from.

Usage:
    python3 benchmark.py <targets.json> <raw_results.json>

targets.json format:
{
  "reports_bucket": "...",
  "reports_region": "eu-central-1",
  "reports_website": "...",
  "runs_per_target": 30,
  "targets": [
    {"name": "...", "label": "...", "category": "static|api", "optimized": true|false, "url": "..."}
  ]
}
"""
import datetime
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

CURL_TIMEOUT_SECONDS = 15
SLEEP_BETWEEN_REQUESTS_SECONDS = 0.2

# Freshly-created CloudFront distributions, Global Accelerator endpoint
# groups and ALB health checks can take several minutes to become fully
# healthy after `terraform apply`. Rather than requiring the operator to
# manually wait, each target is polled until it responds (any HTTP status,
# so we don't wait forever on an intentional 403) or this timeout elapses.
READINESS_TIMEOUT_SECONDS = 600
READINESS_POLL_INTERVAL_SECONDS = 10

# http_code is quoted because curl emits "000" (an invalid JSON number
# literal, due to the leading zeros) when it never got a response at all,
# e.g. connection refused/timeout.
CURL_WRITE_OUT_FORMAT = (
    '{'
    '"http_code":"%{http_code}",'
    '"time_namelookup":%{time_namelookup},'
    '"time_connect":%{time_connect},'
    '"time_appconnect":%{time_appconnect},'
    '"time_starttransfer":%{time_starttransfer},'
    '"time_total":%{time_total},'
    '"size_download":%{size_download}'
    '}'
)


def utcnow_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def curl_once(url):
    """Runs a single curl request and returns a dict with timing, status and
    the X-Cache response header (when present, e.g. for CloudFront)."""
    header_fd, header_path = tempfile.mkstemp(prefix="bench-headers-")
    os.close(header_fd)

    record = {"timestamp": utcnow_iso(), "x_cache": None}

    try:
        proc = subprocess.run(
            [
                "curl",
                "-s",
                "-o", "/dev/null",
                "-D", header_path,
                "--max-time", str(CURL_TIMEOUT_SECONDS),
                "-w", CURL_WRITE_OUT_FORMAT,
                url,
            ],
            capture_output=True,
            text=True,
            timeout=CURL_TIMEOUT_SECONDS + 5,
        )
        stdout = proc.stdout.strip()
        if stdout:
            parsed = json.loads(stdout)
            # "000" means curl never got a response (connection refused,
            # timeout, DNS failure, ...); normalize to None rather than a
            # misleading numeric status code.
            parsed["http_code"] = int(parsed["http_code"]) if parsed.get("http_code") not in (None, "000") else None
            record.update(parsed)
            if record["http_code"] is None:
                record["error"] = (proc.stderr or "no response (connection failed or timed out)").strip()
        else:
            record["error"] = (proc.stderr or "empty curl output").strip()
    except Exception as exc:  # noqa: BLE001 - we want to record *any* failure
        record["error"] = str(exc)

    try:
        with open(header_path, "r", errors="replace") as fh:
            for line in fh:
                if line.lower().startswith("x-cache:"):
                    record["x_cache"] = line.split(":", 1)[1].strip()
    except OSError:
        pass
    finally:
        try:
            os.unlink(header_path)
        except OSError:
            pass

    return record


def wait_until_reachable(name, url):
    """Polls a target until it returns any HTTP response (including 403,
    which is expected for the OAC-protected bucket) or the timeout elapses.
    This absorbs CloudFront/Global Accelerator/ALB propagation delays right
    after `terraform apply` without requiring manual intervention."""
    deadline = time.time() + READINESS_TIMEOUT_SECONDS
    while time.time() < deadline:
        record = curl_once(url)
        if record.get("http_code"):
            return
        print(f"[{name}] not reachable yet ({record.get('error', 'no response')}), retrying...", file=sys.stderr)
        time.sleep(READINESS_POLL_INTERVAL_SECONDS)
    print(f"[{name}] still not reachable after {READINESS_TIMEOUT_SECONDS}s, proceeding anyway", file=sys.stderr)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <targets.json> <raw_results.json>", file=sys.stderr)
        sys.exit(2)

    targets_path, out_path = sys.argv[1], sys.argv[2]

    with open(targets_path) as fh:
        config = json.load(fh)

    targets = config["targets"]
    runs_per_target = int(config.get("runs_per_target", 30))

    # The input targets file contains database credentials/tokens for the
    # optional PostgreSQL benchmark. Never copy those into the raw results,
    # which are uploaded to S3 for later analysis.
    safe_config = dict(config)
    if isinstance(safe_config.get("db"), dict):
        safe_db = dict(safe_config["db"])
        for secret_key in ("password", "batch_api_token", "probe_token"):
            safe_db.pop(secret_key, None)
        safe_config["db"] = safe_db

    results = {
        "generated_at": utcnow_iso(),
        "runs_per_target": runs_per_target,
        "client": {"hostname": socket.gethostname()},
        "config": safe_config,
        "targets": {},
    }

    print("Waiting for all targets to become reachable...", file=sys.stderr)
    for target in targets:
        wait_until_reachable(target["name"], target["url"])

    for target in targets:
        name = target["name"]
        url = target["url"]
        print(f"[{name}] {runs_per_target}x GET {url}", file=sys.stderr)

        runs = []
        for i in range(runs_per_target):
            runs.append(curl_once(url))
            time.sleep(SLEEP_BETWEEN_REQUESTS_SECONDS)

        ok = sum(1 for r in runs if r.get("http_code") == 200)
        print(f"[{name}] {ok}/{runs_per_target} succeeded", file=sys.stderr)

        results["targets"][name] = {"meta": target, "runs": runs}

    with open(out_path, "w") as fh:
        json.dump(results, fh, indent=2)

    print(f"Wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
