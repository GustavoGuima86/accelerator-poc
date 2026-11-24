#!/bin/bash
# Runs scripts/db_diagnostic.py on the Frankfurt benchmark instance via SSM and
# prints the result. Read-only: it only issues SELECTs. Needs AWS credentials.
#
# Usage (from the repo root, after `terraform apply`):
#   ./scripts/run_db_diagnostic.sh
# Optional: PROJECT_NAME (default global-latency-poc), SESSIONS, QUERIES.
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-global-latency-poc}"
SESSIONS="${SESSIONS:-5}"
QUERIES="${QUERIES:-20}"

INSTANCE_ID="$(terraform output -raw benchmark_instance_id)"
CLIENT_REGION="$(terraform output -raw client_region)"
ARTIFACTS_BUCKET="$(terraform output -raw benchmark_reports_bucket | sed 's/-bench-reports-/-bench-artifacts-/')"
FORWARDER_REGION="$(terraform output -raw aurora_primary_endpoint | sed -E 's/.*\.([a-z]+-[a-z]+-[0-9])\.rds\.amazonaws\.com$/\1/')"

FORWARDER_IP="$(aws ec2 describe-instances --region "$FORWARDER_REGION" \
  --filters "Name=tag:Name,Values=${PROJECT_NAME}-db-forwarder" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
if [[ -z "$FORWARDER_IP" || "$FORWARDER_IP" == "None" ]]; then
  echo "Could not find the running forwarder instance (tag Name=${PROJECT_NAME}-db-forwarder in $FORWARDER_REGION)." >&2
  exit 1
fi
echo "Instance: $INSTANCE_ID ($CLIENT_REGION)  forwarder: $FORWARDER_IP  artifacts: $ARTIFACTS_BUCKET" >&2

SCRIPT_B64="$(base64 < "$(dirname "$0")/db_diagnostic.py" | tr -d '\n')"

# The on-instance steps use a throwaway venv so the system python (which the aws
# CLI depends on) is never modified.
REMOTE="set -euo pipefail
W=\$(mktemp -d); cd \$W
python3 -m venv v && ./v/bin/pip install --quiet pg8000
echo '$SCRIPT_B64' | base64 -d > diag.py
aws s3 cp s3://$ARTIFACTS_BUCKET/targets/targets.json targets.json --region $CLIENT_REGION --only-show-errors
./v/bin/python diag.py targets.json $FORWARDER_IP $SESSIONS $QUERIES"

COMMAND_ID="$(aws ssm send-command --region "$CLIENT_REGION" --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript --timeout-seconds 900 \
  --parameters "$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]]}))' "$REMOTE")" \
  --query 'Command.CommandId' --output text)"
echo "SSM command: $COMMAND_ID (waiting...)" >&2

STATUS=Pending
for _ in $(seq 1 180); do
  sleep 5
  STATUS="$(aws ssm get-command-invocation --region "$CLIENT_REGION" --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null || echo Pending)"
  [[ "$STATUS" != "Pending" && "$STATUS" != "InProgress" && "$STATUS" != "Delayed" ]] && break
done

aws ssm get-command-invocation --region "$CLIENT_REGION" --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text | grep -v '^JSON:'
if [[ "$STATUS" != "Success" ]]; then
  echo "--- status: $STATUS; stderr ---" >&2
  aws ssm get-command-invocation --region "$CLIENT_REGION" --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" --query StandardErrorContent --output text >&2
  exit 1
fi
