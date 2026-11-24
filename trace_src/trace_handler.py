"""
Live-traceroute bridge for the interactive page.

GET ?t=TOKEN&target=static_direct|api_direct|db_direct

Browsers cannot run traceroute (no raw sockets), so the page asks this
function instead. It triggers ONE real traceroute on the Frankfurt benchmark
EC2 via SSM Run Command, waits for the result, geolocates the hop IPs
(best-effort, via ip-api.com), and returns the hops as JSON for the map.

Limits of the real world this feature lives with:
  * only the public-internet paths can be traced; AWS's own backbone is
    invisible to traceroute by design (anycast edge + private network);
  * silent hops ("* * *") are normal and are returned with ip=null.
"""
import json
import os
import time
import urllib.request

import boto3

TARGETS = json.loads(os.environ.get("TARGETS", "{}"))
INSTANCE_ID = os.environ.get("INSTANCE_ID", "")
DOCUMENT_NAME = os.environ.get("DOCUMENT_NAME", "")
DEADLINE_S = 260
POLL_S = 2.5
GEO_URL = "http://ip-api.com/batch?fields=status,lat,lon,isp,org,city,country,query"

_ssm = boto3.client("ssm")

# Addresses that carry no useful geography (private/link-local ranges).
_SKIP_GEO_PREFIXES = ("10.", "127.", "169.254.", "172.16.", "172.17.", "172.18.",
                      "172.19.", "172.2", "172.30.", "172.31.", "192.168.")


def _respond(status, body):
    # No CORS header here: the Function URL's cors block already adds it, and a
    # duplicate Access-Control-Allow-Origin makes browsers reject the response.
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _run_on_instance(host):
    send = _ssm.send_command(
        InstanceIds=[INSTANCE_ID],
        DocumentName=DOCUMENT_NAME,
        Parameters={"host": [host]},
        TimeoutSeconds=230,
        Comment="Interactive latency page: live traceroute",
    )
    command_id = send["Command"]["CommandId"]
    deadline = time.time() + DEADLINE_S
    while time.time() < deadline:
        try:
            invocation = _ssm.get_command_invocation(CommandId=command_id, InstanceId=INSTANCE_ID)
        except _ssm.exceptions.InvocationDoesNotExist:
            time.sleep(POLL_S)
            continue
        if invocation["Status"] in ("Success", "Failed", "Cancelled", "TimedOut"):
            return invocation
        time.sleep(POLL_S)
    raise TimeoutError("the traceroute did not finish in time")


def _geolocate(hops):
    """Best-effort hop geolocation. Returns a source label, or None."""
    ips = [h["ip"] for h in hops
           if h.get("ip") and not h["ip"].startswith(_SKIP_GEO_PREFIXES)]
    if not ips:
        return None
    payload = json.dumps([{"query": ip} for ip in ips[:100]]).encode()
    request = urllib.request.Request(
        GEO_URL, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=8) as response:
        results = json.load(response)
    geo = {r["query"]: r for r in results
           if isinstance(r, dict) and r.get("status") == "success"}
    if not geo:
        return None
    for hop in hops:
        info = geo.get(hop.get("ip") or "")
        if not info:
            continue
        hop["lat"], hop["lon"] = info.get("lat"), info.get("lon")
        hop["isp"] = info.get("isp") or info.get("org")
        hop["loc"] = ", ".join(x for x in (info.get("city"), info.get("country")) if x)
    return "ip-api.com"


def handler(event, context):
    params = event.get("queryStringParameters") or {}
    if params.get("t") != os.environ.get("TOKEN"):
        return _respond(403, {"error": "invalid token"})
    target = params.get("target") or ""
    host = TARGETS.get(target)
    if not host:
        return _respond(400, {"error": "unknown target; expected one of: " + ", ".join(sorted(TARGETS))})

    started = time.time()
    try:
        invocation = _run_on_instance(host)
    except Exception as exc:
        return _respond(502, {"error": f"SSM trace failed: {type(exc).__name__}: {exc}"})

    if invocation["Status"] != "Success":
        detail = (invocation.get("StandardErrorContent")
                  or invocation.get("StandardOutputContent") or "")[-400:]
        return _respond(502, {"error": f"traceroute exited with status {invocation['Status']}",
                              "detail": detail})

    stdout = invocation.get("StandardOutputContent") or ""
    data = None
    for line in reversed(stdout.splitlines()):  # the script prints one JSON line
        line = line.strip()
        if line.startswith("{"):
            try:
                data = json.loads(line)
                break
            except ValueError:
                continue
    if not data or "hops" not in data:
        return _respond(502, {"error": "could not parse traceroute output",
                              "detail": stdout[-400:]})
    if data.get("error"):
        return _respond(502, {"error": data["error"]})

    geo_source = None
    try:
        geo_source = _geolocate(data["hops"])
    except Exception:
        pass  # geolocation is best-effort; unlocated hops stay list-only

    return _respond(200, {
        "target": target,
        "host": host,
        "tool": data.get("tool"),
        "hops": data["hops"],
        "geo": geo_source,
        "elapsed_ms": round((time.time() - started) * 1000),
    })
