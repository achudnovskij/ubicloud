#!/bin/bash
# Tear down a benchmark-client VM and all the AWS resources bench-provision.sh
# created for it: EC2 instance, security group, route table, subnet, internet
# gateway, VPC, EC2 keypair, plus the Postgres firewall rules opened for this
# client. Reads /tmp/bench_meta_<vm-name>.
#
# Usage: bench-destroy.sh <vm-name>

set -euo pipefail

: "${AWS_PROFILE:=pg-dev-postgresqladmindev}"
export AWS_PROFILE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOKE="$SCRIPT_DIR/../invoke_ubicloud_api_curl.sh"

NAME="${1:?Usage: bench-destroy.sh <vm-name>}"
META_FILE="/tmp/bench_meta_$NAME"
[ -f "$META_FILE" ] || { echo "Missing $META_FILE — was this VM provisioned via bench-provision.sh?" >&2; exit 1; }
# shellcheck disable=SC1090
. "$META_FILE"

PG_LOCATION="${PG_LOCATION:-us-west-2-cell-0}"

echo "=== bench-destroy ==="
echo "vm_name:     $VM_NAME"
echo "instance:    $INSTANCE_ID"
echo "vpc:         $VPC_ID"
echo "region:      $REGION"
echo "pg_resource: $PG_RESOURCE"

# --- 1. Close the Postgres firewall rules we opened ---
if [ -n "${PG_FIREWALL_RULE_DESC:-}" ]; then
  echo "Removing PG firewall rules tagged description=$PG_FIREWALL_RULE_DESC..."
  RULES_JSON=$("$INVOKE" GET "/project/default/location/$PG_LOCATION/postgres/$PG_RESOURCE/firewall-rule" 2>/dev/null || echo '{"items":[]}')
  echo "$RULES_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('items', []):
    if r.get('description') == '$PG_FIREWALL_RULE_DESC':
        print(r['id'])
" | while read -r rule_id; do
    [ -n "$rule_id" ] || continue
    echo "  delete $rule_id"
    "$INVOKE" DELETE "/project/default/location/$PG_LOCATION/postgres/$PG_RESOURCE/firewall-rule/$rule_id" -o /dev/null -w "%{http_code}\n" || true
  done
fi

# --- 2. Terminate EC2 instance and wait ---
echo "Terminating $INSTANCE_ID..."
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null || true
"$SCRIPT_DIR/wait_for_vm_state.sh" "$INSTANCE_ID" terminated 300 "$REGION" || true

# --- 3. Delete keypair ---
aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME" 2>/dev/null || true

# --- 4. Network teardown (dependency order: SG, RT, subnet, IGW, VPC) ---
echo "Deleting SG $SG_ID..."
aws ec2 delete-security-group --region "$REGION" --group-id "$SG_ID" 2>/dev/null || true

echo "Disassociating + deleting route table $RTB_ID..."
ASSOC=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$RTB_ID" \
  --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text 2>/dev/null || true)
for a in $ASSOC; do
  [ "$a" != "None" ] && aws ec2 disassociate-route-table --region "$REGION" --association-id "$a" 2>/dev/null || true
done
aws ec2 delete-route-table --region "$REGION" --route-table-id "$RTB_ID" 2>/dev/null || true

echo "Deleting subnet $SUBNET_ID..."
aws ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET_ID" 2>/dev/null || true

echo "Detaching + deleting IGW $IGW_ID..."
aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW_ID" 2>/dev/null || true

echo "Deleting VPC $VPC_ID..."
aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC_ID" 2>/dev/null || true

# --- 5. Local cleanup ---
rm -f "$KEY_FILE" "${KEY_FILE}.pub" "$META_FILE"
echo "Removed $KEY_FILE, ${KEY_FILE}.pub, $META_FILE"
echo "Done."
