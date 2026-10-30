#!/bin/bash
# Executed on the Frankfurt benchmark EC2 instance via SSM Run Command.
# Downloads the benchmark + report scripts and the resolved target list from
# the artifacts bucket, runs the HTTP and database latency benchmarks,
# generates the HTML report, and publishes both the raw results and the
# report back to S3.
set -euo pipefail

REGION="${client_region}"
ARTIFACTS_BUCKET="${artifacts_bucket}"
REPORTS_BUCKET="${reports_bucket}"

WORKDIR="$(mktemp -d)"
cd "$WORKDIR"

# dig (bind-utils) is used to resolve the Aurora endpoint via a public DNS
# resolver; pg8000 is a pure-Python PostgreSQL driver.
if ! command -v dig >/dev/null 2>&1; then dnf install -y bind-utils; fi
if ! python3 -c "import pg8000" >/dev/null 2>&1; then
  dnf install -y python3-pip
  python3 -m pip install --quiet pg8000
fi

aws s3 cp "s3://$ARTIFACTS_BUCKET/scripts/benchmark.py" ./benchmark.py --region "$REGION"
aws s3 cp "s3://$ARTIFACTS_BUCKET/scripts/db_benchmark.py" ./db_benchmark.py --region "$REGION"
aws s3 cp "s3://$ARTIFACTS_BUCKET/scripts/generate_report.py" ./generate_report.py --region "$REGION"
aws s3 cp "s3://$ARTIFACTS_BUCKET/targets/targets.json" ./targets.json --region "$REGION"

python3 benchmark.py targets.json raw_results.json

# The DB benchmark is optional; a failure there must not lose the HTTP results.
DB_ARGS=""
if python3 db_benchmark.py targets.json raw_db_results.json && [ -f raw_db_results.json ]; then
  DB_ARGS="raw_db_results.json"
else
  echo "Database benchmark did not produce results; the report will omit the database section." >&2
fi

python3 generate_report.py raw_results.json report.html $DB_ARGS

TS="$(date -u +%Y%m%dT%H%M%SZ)"

aws s3 cp raw_results.json "s3://$ARTIFACTS_BUCKET/results/$TS/raw_results.json" --region "$REGION"
if [ -f raw_db_results.json ]; then
  aws s3 cp raw_db_results.json "s3://$ARTIFACTS_BUCKET/results/$TS/raw_db_results.json" --region "$REGION"
fi
aws s3 cp report.html "s3://$REPORTS_BUCKET/reports/$TS.html" --region "$REGION" --content-type text/html
aws s3 cp report.html "s3://$REPORTS_BUCKET/latest.html" --region "$REGION" --content-type text/html

echo "Benchmark complete. Report: http://$REPORTS_BUCKET.s3-website.$REGION.amazonaws.com/latest.html"
echo "Timestamped copy: http://$REPORTS_BUCKET.s3-website.$REGION.amazonaws.com/reports/$TS.html"
