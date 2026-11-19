#!/usr/bin/env python3
"""
Runs ONE real traceroute from this machine to the given host and prints the
result as a single JSON line on stdout:

    {"tool": "mtr|traceroute", "host": "...", "hops": [
        {"hop": 1, "ip": "1.2.3.4", "rtt_ms": 12.3, "loss_pct": 0.0}, ...
    ]}

Hops that never answered have ip=null / rtt_ms=null / loss_pct=100 (the "* * *"
lines every real traceroute shows). Prefers mtr (3 report cycles) and falls
back to plain traceroute. Used by the interactive page's live-trace feature via
SSM Run Command; geolocation of the hop IPs happens in the trace_probe Lambda.
"""
import json
import re
import shutil
import subprocess
import sys

MAX_HOPS = 30
TIMEOUT_S = 220
IP_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")


def via_mtr(host):
    proc = subprocess.run(
        ["mtr", "--json", "-r", "-c", "3", "-n", "-m", str(MAX_HOPS), host],
        capture_output=True, text=True, timeout=TIMEOUT_S,
    )
    data = json.loads(proc.stdout)
    hops = []
    for idx, hub in enumerate(data.get("hubs", []), start=1):
        name = (hub.get("name") or "").strip()
        ip = name if IP_RE.match(name) else None
        avg = hub.get("avg") or 0.0
        hops.append({
            "hop": idx,
            "ip": ip,
            "rtt_ms": round(avg, 2) if ip and avg > 0 else None,
            "loss_pct": round(float(hub.get("loss") or 0.0), 1),
        })
    return "mtr", hops


def via_traceroute(host):
    proc = subprocess.run(
        ["traceroute", "-n", "-q", "1", "-w", "2", "-m", str(MAX_HOPS), host],
        capture_output=True, text=True, timeout=TIMEOUT_S,
    )
    hops = []
    for line in proc.stdout.splitlines():
        match = re.match(r"^\s*(\d+)\s+(.*)$", line)
        if not match:
            continue
        idx, rest = int(match.group(1)), match.group(2)
        probe = re.search(r"(\d{1,3}(?:\.\d{1,3}){3})\s+([\d.]+)\s*ms", rest)
        if probe:
            hops.append({"hop": idx, "ip": probe.group(1),
                         "rtt_ms": float(probe.group(2)), "loss_pct": 0.0})
        else:
            hops.append({"hop": idx, "ip": None, "rtt_ms": None, "loss_pct": 100.0})
    return "traceroute", hops


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: trace-hops.py <host>"}))
        return 1
    host = sys.argv[1]
    attempts = []
    if shutil.which("mtr"):
        attempts.append(via_mtr)
    if shutil.which("traceroute"):
        attempts.append(via_traceroute)
    if not attempts:
        print(json.dumps({"error": "neither mtr nor traceroute is installed"}))
        return 1
    last_error = "no output"
    for runner in attempts:
        try:
            tool, hops = runner(host)
            if hops:
                print(json.dumps({"tool": tool, "host": host, "hops": hops}))
                return 0
            last_error = f"{tool} produced no hops"
        except Exception as exc:  # fall through to the next tool
            last_error = f"{type(exc).__name__}: {exc}"
    print(json.dumps({"error": f"traceroute failed: {last_error}"}))
    return 1


if __name__ == "__main__":
    sys.exit(main())
