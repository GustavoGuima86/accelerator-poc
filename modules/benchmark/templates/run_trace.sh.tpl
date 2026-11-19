#!/bin/bash
# Executed on the Frankfurt benchmark EC2 instance via SSM Run Command.
# Installs traceroute tooling if missing, fetches the trace script from the
# artifacts bucket, and runs ONE real traceroute to {{host}}. The JSON result
# is printed to stdout, where the trace_probe Lambda picks it up.
set -euo pipefail

REGION="${client_region}"
ARTIFACTS_BUCKET="${artifacts_bucket}"

if ! command -v mtr >/dev/null 2>&1 || ! command -v traceroute >/dev/null 2>&1; then
  dnf install -y mtr traceroute
fi

aws s3 cp "s3://$ARTIFACTS_BUCKET/scripts/trace-hops.py" /tmp/trace-hops.py --region "$REGION"

exec python3 /tmp/trace-hops.py "{{host}}"
