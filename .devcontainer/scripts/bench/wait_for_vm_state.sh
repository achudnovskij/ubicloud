#!/bin/bash
# Poll an EC2 instance until it reaches a target state.
#
# Usage:
#   wait_for_vm_state.sh <instance-id> <state> [timeout_seconds] [region]
#   wait_for_vm_state.sh i-0abcdef1234567890 running
#   wait_for_vm_state.sh i-0abcdef1234567890 terminated 600
#
# Exits 0 on success, 1 on timeout. AWS CLI must be authenticated; region
# defaults to AWS_REGION or us-west-2.
set -euo pipefail

: "${AWS_PROFILE:=pg-dev-postgresqladmindev}"
export AWS_PROFILE

INSTANCE_ID="${1:?Usage: wait_for_vm_state.sh <instance-id> <state> [timeout] [region]}"
TARGET_STATE="${2:?Usage: wait_for_vm_state.sh <instance-id> <state> [timeout] [region]}"
TIMEOUT="${3:-600}"
REGION="${4:-${AWS_REGION:-us-west-2}}"

INTERVAL=10
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "missing")
  echo "$(date +%H:%M:%S) $INSTANCE_ID state=$STATE"
  if [ "$STATE" = "$TARGET_STATE" ]; then
    echo "Reached state: $TARGET_STATE"
    exit 0
  fi
  if [ "$TARGET_STATE" = "terminated" ] && [ "$STATE" = "missing" ]; then
    echo "Instance no longer exists; treating as terminated."
    exit 0
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "Timeout waiting for $INSTANCE_ID to reach state: $TARGET_STATE" >&2
exit 1
