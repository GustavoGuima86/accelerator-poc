#!/bin/bash
# Triggers the global latency benchmark on the Frankfurt EC2 instance via SSM
# Run Command, waits for it to finish, and prints the resulting report URL.
#
# Used automatically once by Terraform right after `terraform apply`, and can
# also be run manually any time afterwards to refresh the report.
#
# Usage:
#   ./scripts/trigger_benchmark.sh <instance-id> <ssm-document-name> <region>
#
# With no arguments, reads instance_id/document/region from `terraform output`
# in the current directory (convenient for manual re-runs).
set -euo pipefail

# Upper bound for how long we keep polling (the benchmark itself can spend up
# to ~10 min waiting for CloudFront/Global Accelerator/Aurora to become
# reachable, then several more minutes measuring).
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-3000}"
POLL_SECONDS=10

if [[ $# -ge 3 ]]; then
  INSTANCE_ID="$1"
  DOCUMENT_NAME="$2"
  REGION="$3"
else
  echo "No arguments given, reading from terraform output..." >&2
  INSTANCE_ID="$(terraform output -raw benchmark_instance_id)"
  DOCUMENT_NAME="$(terraform output -raw benchmark_ssm_document_name)"
  REGION="$(terraform output -raw client_region)"
fi

# A freshly created instance can take a minute or two to register with SSM.
echo "Waiting for $INSTANCE_ID to register with SSM..." >&2
for _ in $(seq 1 60); do
  PING="$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
  [[ "$PING" == "Online" ]] && break
  sleep 5
done
if [[ "${PING:-}" != "Online" ]]; then
  echo "Instance $INSTANCE_ID is not online in SSM; try again in a minute." >&2
  exit 1
fi

echo "Triggering benchmark on instance $INSTANCE_ID (region $REGION)..." >&2
COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "$DOCUMENT_NAME" \
  --query 'Command.CommandId' \
  --output text)"
echo "Command ID: $COMMAND_ID" >&2

# `aws ssm wait command-executed` gives up after ~100s, far too short here,
# so poll the invocation status ourselves.
elapsed=0
STATUS="Pending"
while [[ "$STATUS" == "Pending" || "$STATUS" == "InProgress" || "$STATUS" == "Delayed" ]]; do
  if (( elapsed >= MAX_WAIT_SECONDS )); then
    echo "Still running after ${MAX_WAIT_SECONDS}s; giving up waiting (it keeps running on the instance)." >&2
    echo "Check later with: aws ssm get-command-invocation --region $REGION --command-id $COMMAND_ID --instance-id $INSTANCE_ID" >&2
    exit 1
  fi
  sleep "$POLL_SECONDS"
  elapsed=$((elapsed + POLL_SECONDS))
  STATUS="$(aws ssm get-command-invocation \
    --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query 'Status' --output text 2>/dev/null || echo Pending)"
  echo "  [${elapsed}s] status: $STATUS" >&2
done

aws ssm get-command-invocation \
  --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text

if [[ "$STATUS" != "Success" ]]; then
  echo "--- stderr ---" >&2
  aws ssm get-command-invocation \
    --region "$REGION" --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query 'StandardErrorContent' --output text >&2
  exit 1
fi
