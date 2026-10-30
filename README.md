# Global latency POC

Terraform demo comparing access to static assets, an API, and PostgreSQL
across Sydney (`ap-southeast-2`) and Frankfurt (`eu-central-1`). It includes a
browser-based interactive benchmark and an automated Frankfurt report.

## Architecture

- **Static:** private S3 + CloudFront/OAC, alongside a separate public S3
  website bucket used only as the direct-access benchmark baseline.
- **API:** fixed-response ALB vs. AWS Global Accelerator in front of the ALB.
- **Database (optional):** Aurora PostgreSQL Global Database with a Sydney
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
- Database path tests from Frankfurt, plus a what-if model, browser-local
  history, CSV export, and shareable summaries.

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
| `aws_region` | `ap-southeast-2` | Origin / database writer region |
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
