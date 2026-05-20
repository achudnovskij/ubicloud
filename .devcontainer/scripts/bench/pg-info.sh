#!/bin/bash
# Output eval-able env vars for a Postgres resource: PG_IP, PG_PWD, SRV_INST, SRV_AZ
# Usage:  eval "$(.devcontainer/scripts/bench/pg-info.sh <resource-name>)"
set -euo pipefail

NAME="${1:?usage: $0 <pg-resource-name>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
INVOKE="$SCRIPT_DIR/../invoke_ubicloud_api_curl.sh"

# Public IP + password from the API
PG_LOCATION="${PG_LOCATION:-us-west-2-cell-0}"
INFO=$("$INVOKE" GET "/project/default/location/$PG_LOCATION/postgres/$NAME" 2>/dev/null)
PG_IP=$(jq -r '.hostname // empty' <<<"$INFO")
PG_PWD=$(jq -r '.password // empty' <<<"$INFO")

# AWS instance id + AZ via the Ubicloud DB (not in API)
INSTANCE_INFO=$(cd "$PROJECT_ROOT" && bundle exec ruby -r ./loader -e "
r = PostgresResource.first(name: '$NAME') or abort 'NO_RESOURCE'
ai = r.representative_server.vm.aws_instance
puts \"#{ai.instance_id} #{ai.az_id}\"
" 2>/dev/null)

SRV_INST=$(echo "$INSTANCE_INFO" | awk '{print $1}')
SRV_AZ=$(echo "$INSTANCE_INFO" | awk '{print $2}')

# Emit shell-quoted assignments so callers can safely `eval` even when values
# contain shell metacharacters (the password is API-provided and could
# legitimately include $, `, etc.).
printf 'export PG_NAME=%q\n'     "$NAME"
printf 'export PG_LOCATION=%q\n' "$PG_LOCATION"
printf 'export PG_IP=%q\n'       "$PG_IP"
printf 'export PG_PWD=%q\n'      "$PG_PWD"
printf 'export SRV_INST=%q\n'    "$SRV_INST"
printf 'export SRV_AZ=%q\n'      "$SRV_AZ"
