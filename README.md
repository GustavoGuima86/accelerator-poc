# Global latency POC

Terraform demo comparing access to static assets, an API, and PostgreSQL
across Ohio (`us-east-2`) and Frankfurt (`eu-central-1`). It includes a
browser-based interactive benchmark and an automated Frankfurt report.

## Architecture

- **Static:** private S3 + CloudFront/OAC, alongside a separate public S3
  website bucket used only as the direct-access benchmark baseline.
- **API:** fixed-response ALB vs. AWS Global Accelerator in front of the ALB.
- **Database (optional):** Aurora PostgreSQL Global Database with an Ohio
  writer and Frankfurt replica, plus direct, Global Accelerator, VPC peering,
  replica/write-forwarding, and batched-API tests.
- **Interactive page:** static/API requests run from the visitor's browser;
  database tests run from Frankfurt because browsers cannot speak PostgreSQL.
- **Automated report:** a Frankfurt EC2 client runs repeatable tests and
  publishes a shareable HTML report.

## Quick start

Requirements: Terraform 1.5+, AWS CLI v2, and AWS credentials with permissions
for the resources enabled below.

```sh
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

Open the interactive demo:

```sh
terraform output -raw interactive_page_url
```

Open the automated report:

```sh
terraform output -raw latest_report_url
```

### Run the mock version locally (no AWS required)

The preview server serves `site/index.html` with a generated mock `config.js`
and local mock endpoints, so the presentation and latency tests can be tried
without AWS resources or credentials. From the repository root, run:

```sh
python3 site/preview_server.py
```

Then open <http://127.0.0.1:8751/>. To use another port, pass it as the first
argument, for example `python3 site/preview_server.py 8760`, then open
`http://127.0.0.1:8760/`. Stop the server with `Ctrl+C`.

The interactive page is a scroll-driven presentation: a title slide, the
consulting narrative (situation, the three tools, trade-offs/cost for each,
a "what applies to what" mapping, a cost summary, honest caveats, and next
steps) and the four live-test sections (**Overview**, **Static assets**,
**API**, **Database**) are all stacked as full-height slides in the same
page, in presenting order. Scrolling moves through the deck like a
presentation; the tab bar jumps straight to a section and stays in sync as
you scroll by hand. Each tool's narrative slide carries a "Try it live"
button that jumps into its test and (for the "what it is" slide) starts it
automatically; the matching "trade-offs" slide jumps straight to that
section's cost simulator. The **Static assets**, **API**, and **Database**
sections each also carry their own short "Why this matters" explainer, AWS
doc links, a route map per access path, and their own live test. Database
measurements run from a Frankfurt probe function, while static/API races run
from the visitor's browser. `PRESENTATION.md` holds the same narrative as
plain markdown, for turning into slides or printing as a leave-behind.

The first report run starts during `terraform apply`; it may take several
minutes while endpoints become ready. Rerun it later with:

```sh
./scripts/trigger_benchmark.sh
```

## Interactive demo

The page includes:

- Direct S3 vs. CloudFront asset tests, with selectable payload sizes, repeat
  counts, TTFB/total time, cache status, and edge location.
- Direct ALB vs. Global Accelerator API tests from the viewer's browser.
- Database path tests from Frankfurt, CSV export, and shareable summaries.
- Per-path route maps plus a **live traceroute** that starts together with
  each Run button and lands on the maps when it finishes (below).

### Live traceroute (real hops)

Browsers cannot run traceroute, so each **Run** button also calls a small
Lambda (`modules/trace_probe`) which triggers a real `mtr`/`traceroute` on the
Frankfurt benchmark EC2 via SSM Run Command, geolocates the hop IPs
(best-effort, via ip-api.com), and returns them. When a trace arrives its map
switches from the illustration to the observed hops, with a hop table below.
The direct/public paths are traced end to end. The optimized paths
(CloudFront, Global Accelerator) are traced to the service's anycast address,
which stops at the AWS edge; the map then draws the private-backbone segment
as a clearly-labelled **approximate** continuation.

Two real-world limits apply, and the page says so:

- CloudFront and Global Accelerator are anycast: a traceroute stops at the
  AWS edge, and the AWS global network behind it never answers ICMP. That
  opacity is by design, so the last segment is an approximation.
- Backbone routers often stay silent, so `* * *` gaps in a real trace are
  normal; such hops appear in the table but not on the map.

Requires `enable_benchmark_client = true`. Local preview without AWS:
`python3 site/preview_server.py` (serves the page plus mock endpoints, and a
clearly-labelled simulated trace).

The page uses plain HTTP for the direct S3 website, ALB, and Global Accelerator
baselines. Open the URL over HTTP; HTTPS pages cannot call those endpoints due
to browser mixed-content restrictions. This is a demo, not a production
deployment pattern.

## Aurora and cost

Aurora is enabled by default and incurs charges even when idle. The POC uses
Serverless v2 with a 0.5 ACU minimum, creates VPCs in both regions, a Frankfurt
NAT gateway, a Global Accelerator TCP forwarder, and database probe functions.
Expect several dollars per day; run `terraform destroy` after the demo.

To skip Aurora and its database tests:

```hcl
enable_aurora = false
```

The writer is reachable only from the Frankfurt NAT egress IP and any CIDRs in
`aurora_extra_client_cidrs`. The probe Function URL and static demo buckets
are public, and their embedded token is only an abuse deterrent. Use a
controlled demo account; do not expose real data or credentials. Store
Terraform state securely.

The public S3 baseline is intentionally insecure and exists solely for a fair
direct-vs-CDN comparison. The separate CloudFront origin remains private with
OAC. If account or organization policy blocks public S3 buckets, the website
and report endpoints will not work; do not disable organization guardrails to
run this POC.

## Configuration

Copy `terraform.tfvars.example` to `terraform.tfvars` and change settings as
needed. Useful variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `aws_region` | `us-east-2` | Origin / database writer region |
| `client_region` | `eu-central-1` | Benchmark client and database replica region |
| `enable_benchmark_client` | `true` | Frankfurt EC2 client and automated report |
| `enable_interactive_page` | `true` | Interactive browser demo |
| `enable_aurora` | `true` | Aurora Global Database and database paths |
| `benchmark_runs_per_target` | `30` | HTTP tests per target |
| `db_sessions` | `5` | Database sessions per path/workload |
| `db_queries_per_session` | `20` | Sequential statements per session |
| `aurora_extra_client_cidrs` | `[]` | Additional allowed writer/forwarder CIDRs |

## Repository layout

- `main.tf`, `variables.tf`, `outputs.tf`: root infrastructure and outputs.
- `modules/`: S3/CloudFront, ALB/Global Accelerator, Aurora, networking,
  benchmark client, and interactive site modules.
- `site/index.html`: interactive benchmark UI.
- `lambda_src/`: PostgreSQL probe and batched-query functions with vendored
  Python dependencies.
- `scripts/`: automated benchmarks, HTML report generation, and SSM trigger.
- `files/`: sample web page and test payloads.

Destroy resources when finished:

```sh
terraform destroy
```
