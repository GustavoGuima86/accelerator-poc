#!/usr/bin/env python3
"""
Turns raw_results.json (produced by benchmark.py) into a single, self-contained
HTML report with inline SVG bar charts comparing direct vs. optimized access,
for both static assets (S3 vs CloudFront) and API traffic (ALB vs Global
Accelerator). No external JS/CSS/CDN dependencies, so the report renders the
same whether opened locally or served from S3.

CloudFront's cache behavior (Miss vs Hit) is derived from the actual
X-Cache response header on each individual request, rather than assuming
request #1 is always cold — this is more honest since the edge cache may
already be warm from a previous benchmark run.

Usage:
    python3 generate_report.py <raw_results.json> <report.html>
"""
import html
import json
import statistics
import sys

MS = 1000.0

COLOR_DIRECT = "#d64545"
COLOR_MISS = "#f08c00"
COLOR_HIT = "#2f9e44"
COLOR_NEUTRAL = "#4263eb"
COLOR_BG = "#f1f3f5"
COLOR_TEXT = "#1b1f23"
COLOR_MUTED = "#6c757d"


def percentile(values, pct):
    if not values:
        return None
    values = sorted(values)
    k = (len(values) - 1) * (pct / 100.0)
    f = int(k)
    c = min(f + 1, len(values) - 1)
    if f == c:
        return values[f]
    return values[f] + (values[c] - values[f]) * (k - f)


def stats(values):
    if not values:
        return None
    return {
        "min": min(values),
        "avg": statistics.mean(values),
        "p95": percentile(values, 95),
        "max": max(values),
        "n": len(values),
    }


def is_hit(x_cache):
    return bool(x_cache) and "hit" in x_cache.lower() and "miss" not in x_cache.lower()


def is_miss(x_cache):
    return bool(x_cache) and "miss" in x_cache.lower()


def summarize(runs):
    ok_runs = [r for r in runs if r.get("http_code") == 200]
    errors = [r for r in runs if r.get("http_code") != 200]

    ttfb_ms = [r["time_starttransfer"] * MS for r in ok_runs if "time_starttransfer" in r]
    total_ms = [r["time_total"] * MS for r in ok_runs if "time_total" in r]

    hit_total_ms = [r["time_total"] * MS for r in ok_runs if is_hit(r.get("x_cache")) and "time_total" in r]
    miss_total_ms = [r["time_total"] * MS for r in ok_runs if is_miss(r.get("x_cache")) and "time_total" in r]

    cache_counts = {}
    for r in ok_runs:
        v = r.get("x_cache")
        if v:
            cache_counts[v] = cache_counts.get(v, 0) + 1

    return {
        "attempted": len(runs),
        "succeeded": len(ok_runs),
        "failed": len(errors),
        "ttfb_ms": stats(ttfb_ms),
        "total_ms": stats(total_ms),
        "hit_total_ms": stats(hit_total_ms),
        "miss_total_ms": stats(miss_total_ms),
        "cache_counts": cache_counts,
    }


def fmt_ms(value):
    if value is None:
        return "n/a"
    return f"{value:,.0f} ms"


def bar_chart_svg(rows, max_value, width=640, bar_height=28, gap=14, label_width=190):
    """rows: list of (label, value_ms, color, sample_size). Returns inline SVG."""
    height = len(rows) * (bar_height + gap) + gap
    chart_width = width - label_width - 90
    parts = [
        f'<svg viewBox="0 0 {width} {height}" width="100%" height="{height}" '
        f'xmlns="http://www.w3.org/2000/svg" role="img">'
    ]
    y = gap
    for label, value, color, n in rows:
        bar_w = 0 if not value or not max_value else max(2, (value / max_value) * chart_width)
        parts.append(
            f'<text x="{label_width - 10}" y="{y + bar_height * 0.65}" '
            f'text-anchor="end" font-size="13" fill="{COLOR_TEXT}" '
            f'font-family="-apple-system,Segoe UI,Helvetica,Arial,sans-serif">{html.escape(label)}</text>'
        )
        parts.append(
            f'<rect x="{label_width}" y="{y}" width="{chart_width}" height="{bar_height}" '
            f'fill="{COLOR_BG}" rx="4"></rect>'
        )
        parts.append(
            f'<rect x="{label_width}" y="{y}" width="{bar_w:.1f}" height="{bar_height}" '
            f'fill="{color}" rx="4"></rect>'
        )
        value_text = fmt_ms(value) if value else "n/a"
        if n:
            value_text += f" (n={n})"
        parts.append(
            f'<text x="{label_width + bar_w + 8}" y="{y + bar_height * 0.65}" '
            f'font-size="13" fill="{COLOR_TEXT}" '
            f'font-family="-apple-system,Segoe UI,Helvetica,Arial,sans-serif">{html.escape(value_text)}</text>'
        )
        y += bar_height + gap
    parts.append("</svg>")
    return "".join(parts)


def speedup_text(direct_value, optimized_value, metric_label):
    if not direct_value or not optimized_value or optimized_value <= 0:
        return ""
    factor = direct_value / optimized_value
    return f'<p class="speedup">Optimized path is <strong>{factor:.1f}&times; faster</strong> than direct access ({metric_label}, avg).</p>'


def render_section(title, intro, rows, metric_label):
    values = [v for _, v, _, _ in rows if v]
    max_value = max(values) if values else 1
    chart = bar_chart_svg(rows, max_value)

    direct_value = next((v for _, v, c, _ in rows if c == COLOR_DIRECT), None)
    best_optimized = next((v for _, v, c, _ in reversed(rows) if c == COLOR_HIT), None)
    speedup_html = speedup_text(direct_value, best_optimized, metric_label)

    return f"""
    <section class="card">
      <h2>{html.escape(title)}</h2>
      <p class="intro">{intro}</p>
      {chart}
      {speedup_html}
    </section>
    """


def render_table(data):
    rows = []
    for name, entry in data.items():
        meta = entry["meta"]
        s = entry["summary"]
        rows.append(
            "<tr>"
            f"<td>{html.escape(meta['label'])}</td>"
            f"<td>{html.escape(meta['category'])}</td>"
            f"<td>{'optimized' if meta['optimized'] else 'direct'}</td>"
            f"<td>{s['succeeded']}/{s['attempted']}</td>"
            f"<td>{fmt_ms(s['ttfb_ms']['avg']) if s['ttfb_ms'] else 'n/a'}</td>"
            f"<td>{fmt_ms(s['ttfb_ms']['p95']) if s['ttfb_ms'] else 'n/a'}</td>"
            f"<td>{fmt_ms(s['total_ms']['avg']) if s['total_ms'] else 'n/a'}</td>"
            f"<td>{fmt_ms(s['total_ms']['p95']) if s['total_ms'] else 'n/a'}</td>"
            "</tr>"
        )
    return "".join(rows)


def build_static_section(title, intro, data, direct_name, cdn_name):
    direct = data.get(direct_name, {}).get("summary")
    cdn = data.get(cdn_name, {}).get("summary")
    if not direct or not cdn:
        return ""

    rows = [("Direct S3 (insecure)", direct["total_ms"]["avg"] if direct["total_ms"] else None, COLOR_DIRECT, direct["total_ms"]["n"] if direct["total_ms"] else 0)]
    if cdn["miss_total_ms"]:
        rows.append(("CloudFront — cache Miss", cdn["miss_total_ms"]["avg"], COLOR_MISS, cdn["miss_total_ms"]["n"]))
    if cdn["hit_total_ms"]:
        rows.append(("CloudFront — cache Hit", cdn["hit_total_ms"]["avg"], COLOR_HIT, cdn["hit_total_ms"]["n"]))
    if not cdn["miss_total_ms"] and not cdn["hit_total_ms"] and cdn["total_ms"]:
        rows.append(("CloudFront (cache status unknown)", cdn["total_ms"]["avg"], COLOR_HIT, cdn["total_ms"]["n"]))

    return render_section(title, intro, rows, "total time")


def build_api_section(data):
    direct = data.get("api_direct_alb", {}).get("summary")
    ga = data.get("api_global_accelerator", {}).get("summary")
    if not direct or not ga:
        return ""

    ttfb_rows = [
        ("Direct ALB", direct["ttfb_ms"]["avg"] if direct["ttfb_ms"] else None, COLOR_DIRECT, direct["ttfb_ms"]["n"] if direct["ttfb_ms"] else 0),
        ("Global Accelerator", ga["ttfb_ms"]["avg"] if ga["ttfb_ms"] else None, COLOR_HIT, ga["ttfb_ms"]["n"] if ga["ttfb_ms"] else 0),
    ]
    total_rows = [
        ("Direct ALB", direct["total_ms"]["avg"] if direct["total_ms"] else None, COLOR_DIRECT, direct["total_ms"]["n"] if direct["total_ms"] else 0),
        ("Global Accelerator", ga["total_ms"]["avg"] if ga["total_ms"] else None, COLOR_HIT, ga["total_ms"]["n"] if ga["total_ms"] else 0),
    ]

    intro = (
        "Mock API endpoint (fixed 200 OK response) behind an ALB in Sydney, reached directly over "
        "the public internet vs. via AWS Global Accelerator's global network backbone, measured from Frankfurt."
    )
    return (
        render_section("API traffic: time to first byte (TTFB)", intro, ttfb_rows, "TTFB")
        + render_section("API traffic: total response time", intro, total_rows, "total time")
    )


DB_PATH_ORDER = ["public_direct", "global_accelerator", "vpc_peering", "replica_local"]


def db_session_stats(sessions, key):
    ok = [s for s in sessions if "error" not in s and key in s]
    failed = len(sessions) - len(ok)
    return stats([s[key] for s in ok]), failed


def render_db_section(db_raw):
    """Database access paths: Frankfurt client -> Aurora writer in Sydney.

    Two charts (read / write session time) plus a per-query table. A session is
    one fresh connection followed by N sequential statements, which is what a
    chatty application does, so the round-trip time is paid N+handshake times."""
    n_queries = db_raw.get("queries_per_session", "?")
    paths = db_raw.get("paths", {})
    batch = db_raw.get("batch_api", {})

    def path_rows(workload, color_for):
        rows, table = [], []
        for name in DB_PATH_ORDER:
            entry = paths.get(name)
            if not entry:
                continue
            meta = entry["meta"]
            st, failed = db_session_stats(entry.get(workload, []), "total_ms")
            q_all = [q for s in entry.get(workload, []) if "error" not in s for q in s.get("query_ms", [])]
            qs = stats(q_all)
            conn_st, _ = db_session_stats(entry.get(workload, []), "connect_ms")
            rows.append((meta["label"], st["avg"] if st else None, color_for(name, meta), st["n"] if st else 0))
            table.append((meta, workload, st, qs, conn_st, failed))
        return rows, table

    def color_read(name, meta):
        return COLOR_DIRECT if name == "public_direct" else COLOR_HIT

    read_rows, read_table = path_rows("read", color_read)
    write_rows, write_table = path_rows("write", color_read)

    # The batched API only exists for the read workload.
    batch_ok = [r for r in batch.get("runs", []) if r.get("http_code") == 200]
    batch_total = stats([r["total_ms"] for r in batch_ok])
    if batch_total:
        read_rows.append(("One call to API next to DB", batch_total["avg"], COLOR_NEUTRAL, batch_total["n"]))

    def chart_block(title, intro, rows):
        values = [v for _, v, _, _ in rows if v]
        if not values:
            return f'<section class="card"><h2>{html.escape(title)}</h2><p class="intro">No successful measurements.</p></section>'
        direct = next((v for _, v, c, _ in rows if c == COLOR_DIRECT), None)
        best = min(values)
        callout = ""
        if direct and best and best < direct:
            callout = (f'<p class="speedup">Fastest path is <strong>{direct / best:.1f}&times; faster</strong> '
                       f"than direct public access (session time, avg).</p>")
        return (f'<section class="card"><h2>{html.escape(title)}</h2><p class="intro">{intro}</p>'
                f'{bar_chart_svg(rows, max(values))}{callout}</section>')

    def fmt(st, key="avg"):
        return fmt_ms(st[key]) if st else "n/a"

    table_rows = []
    for meta, workload, st, qs, conn_st, failed in read_table + write_table:
        table_rows.append(
            "<tr>"
            f"<td>{html.escape(meta['label'])}</td><td>{workload}</td>"
            f"<td>{fmt(conn_st)}</td><td>{fmt(qs)}</td><td>{fmt(qs, 'p95')}</td>"
            f"<td>{fmt(st)}</td><td>{failed}</td>"
            "</tr>"
        )
    if batch_total:
        lq = stats([r["lambda_queries_ms"] for r in batch_ok if r.get("lambda_queries_ms") is not None])
        table_rows.append(
            "<tr>"
            "<td>One call to API next to DB</td><td>read (batched)</td>"
            f"<td>n/a</td><td>{fmt(lq)} for all {n_queries}</td><td>n/a</td>"
            f"<td>{fmt(batch_total)}</td><td>{len(batch.get('runs', [])) - len(batch_ok)}</td>"
            "</tr>"
        )

    warnings = []
    for name, entry in paths.items():
        meta = entry["meta"]
        for key in ("warning", "resolve_error"):
            if meta.get(key):
                warnings.append(f"<li><strong>{html.escape(meta['label'])}</strong>: {html.escape(meta[key])}</li>")
    warn_html = ""
    if warnings:
        warn_html = (f'<section class="card"><h2>Measurement caveats</h2><ul>{"".join(warnings)}</ul></section>')

    return "".join([
        '<h2 style="margin-top:36px">Database access (Aurora PostgreSQL, writer in Sydney)</h2>',
        warn_html,
        chart_block(
            f"Database reads: one session = connect + {n_queries} queries",
            "Fresh connection, then sequential primary-key lookups, from Frankfurt. Every statement pays "
            "the Frankfurt-Sydney round trip unless the data is served locally by the replica, or the "
            "whole batch runs next to the database.",
            read_rows,
        ),
        chart_block(
            f"Database writes: one session = connect + {n_queries} single-row INSERTs",
            "Writes always have to reach the Sydney writer. The Frankfurt replica forwards them there "
            "(write forwarding), so it cannot beat the network, only match or add to it.",
            write_rows,
        ),
        f"""<section class="card"><h2>Database detail</h2>
        <table><thead><tr><th>Path</th><th>Workload</th><th>Connect avg</th><th>Per-query avg</th>
        <th>Per-query p95</th><th>Session avg</th><th>Failed sessions</th></tr></thead>
        <tbody>{"".join(table_rows)}</tbody></table></section>""",
    ])


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <raw_results.json> <report.html> [raw_db_results.json]", file=sys.stderr)
        sys.exit(2)

    in_path, out_path = sys.argv[1], sys.argv[2]
    db_path = sys.argv[3] if len(sys.argv) > 3 else None

    with open(in_path) as fh:
        raw = json.load(fh)

    db_raw = None
    if db_path:
        with open(db_path) as fh:
            db_raw = json.load(fh)

    data = {}
    for name, entry in raw["targets"].items():
        data[name] = {"meta": entry["meta"], "summary": summarize(entry["runs"])}

    sections = []
    sections.append(
        build_static_section(
            "Static web page: total download time",
            "Same index.html page, served from Sydney (ap-southeast-2), measured from Frankfurt (eu-central-1).",
            data,
            "static_direct_s3_page",
            "static_cloudfront_page",
        )
    )
    sections.append(
        build_static_section(
            "Static asset (1MB file): total download time",
            "Same 1MB sample file, served from Sydney, measured from Frankfurt. Larger payloads make the "
            "egress/distance penalty of direct S3 access more visible.",
            data,
            "static_direct_s3_asset",
            "static_cloudfront_asset",
        )
    )
    sections.append(build_api_section(data))

    cache_counts = {}
    for name in ("static_cloudfront_page", "static_cloudfront_asset"):
        for k, v in data.get(name, {}).get("summary", {}).get("cache_counts", {}).items():
            cache_counts[k] = cache_counts.get(k, 0) + v
    if cache_counts:
        items = "".join(f"<li><code>{html.escape(k)}</code>: {v} request(s)</li>" for k, v in cache_counts.items())
        sections.append(
            f"""
            <section class="card">
              <h2>CloudFront cache behavior (X-Cache header)</h2>
              <p class="intro">Breakdown of the <code>X-Cache</code> response header across all CloudFront requests
              in this run. <code>Miss from cloudfront</code> means the edge had to fetch from the S3 origin;
              <code>Hit from cloudfront</code> means it was served directly from the edge cache.</p>
              <ul>{items}</ul>
            </section>
            """
        )

    if db_raw:
        sections.append(render_db_section(db_raw))

    table_rows = render_table(data)

    html_doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<title>Global Network Latency POC — Report</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<style>
  body {{
    font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
    background: #ffffff;
    color: {COLOR_TEXT};
    max-width: 880px;
    margin: 0 auto;
    padding: 32px 20px 64px;
    line-height: 1.5;
  }}
  h1 {{ font-size: 1.6rem; margin-bottom: 4px; }}
  .subtitle {{ color: {COLOR_MUTED}; margin-top: 0; margin-bottom: 28px; }}
  .card {{
    background: #fff;
    border: 1px solid #e9ecef;
    border-radius: 10px;
    padding: 20px 24px;
    margin-bottom: 20px;
  }}
  .card h2 {{ margin-top: 0; font-size: 1.1rem; }}
  .intro {{ color: {COLOR_MUTED}; font-size: 0.92rem; }}
  .speedup {{ font-size: 1.05rem; margin-top: 14px; }}
  .speedup strong {{ color: {COLOR_HIT}; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 0.88rem; }}
  th, td {{ text-align: left; padding: 8px 10px; border-bottom: 1px solid #e9ecef; }}
  th {{ color: {COLOR_MUTED}; font-weight: 600; }}
  code {{ background: {COLOR_BG}; padding: 1px 5px; border-radius: 4px; }}
  .legend {{ font-size: 0.85rem; color: {COLOR_MUTED}; margin-top: -8px; margin-bottom: 24px; }}
  .legend span {{ display: inline-flex; align-items: center; margin-right: 18px; }}
  .legend .dot {{ width: 10px; height: 10px; border-radius: 50%; display: inline-block; margin-right: 6px; }}
  .meta {{ color: {COLOR_MUTED}; font-size: 0.8rem; margin-top: 40px; }}
</style>
</head>
<body>
  <h1>Global Network Latency POC — Results</h1>
  <p class="subtitle">
    Origin: Sydney (ap-southeast-2) &nbsp;&middot;&nbsp;
    Client: Frankfurt (eu-central-1) &nbsp;&middot;&nbsp;
    Generated: {html.escape(raw.get("generated_at", "n/a"))} &nbsp;&middot;&nbsp;
    Runs per target: {raw.get("runs_per_target", "n/a")}
  </p>

  <div class="legend">
    <span><span class="dot" style="background:{COLOR_DIRECT}"></span>Direct / unoptimized access</span>
    <span><span class="dot" style="background:{COLOR_MISS}"></span>CloudFront, cache miss</span>
    <span><span class="dot" style="background:{COLOR_HIT}"></span>Optimized (cache hit / Global Accelerator)</span>
  </div>

  {''.join(sections)}

  <section class="card">
    <h2>Raw summary, all targets</h2>
    <table>
      <thead>
        <tr>
          <th>Target</th><th>Category</th><th>Path</th><th>Success</th>
          <th>TTFB avg</th><th>TTFB p95</th><th>Total avg</th><th>Total p95</th>
        </tr>
      </thead>
      <tbody>
        {table_rows}
      </tbody>
    </table>
  </section>

  <p class="meta">
    Generated by scripts/generate_report.py from scripts/benchmark.py raw results.
    Values are averages/95th percentiles over sequential HTTP(S) GET requests per target,
    executed from an EC2 instance in eu-central-1 via SSM Run Command.
  </p>
</body>
</html>
"""

    with open(out_path, "w") as fh:
        fh.write(html_doc)

    print(f"Wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
