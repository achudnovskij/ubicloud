#!/bin/bash
# Run psql against an Ubicloud-managed Postgres resource by name. Reads the
# resource's hostname + password from the Ubicloud API and connects directly
# over the public endpoint (no SSH, no SSM).
#
# Usage:
#   psql-pg.sh <pg-name> [<psql args>...]
#
# Examples:
#   psql-pg.sh bench-pg                              # interactive shell
#   psql-pg.sh bench-pg -c 'SELECT version()'        # one-shot query
#   psql-pg.sh bench-pg -tAc 'SELECT pg_current_wal_lsn()'
#   psql-pg.sh bench-pg -d tpcc -c "..."             # other database
#
# Requires:
#   - The PG resource must be in state=running (hostname populated).
#   - The dev container's egress IP must satisfy the PG firewall rules
#     (Ubicloud's default for new PG resources is 0.0.0.0/0:5432, so this
#     normally just works).
#   - psql client (Dockerfile installs postgresql-client).

set -euo pipefail

NAME="${1:?Usage: psql-pg.sh <pg-name> [psql args...]}"
shift

PG_LOCATION="${PG_LOCATION:-us-west-2-cell-0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOKE="$SCRIPT_DIR/invoke_ubicloud_api_curl.sh"

INFO=$("$INVOKE" GET "/project/default/location/$PG_LOCATION/postgres/$NAME") || {
  echo "psql-pg: API call failed for $NAME" >&2
  exit 1
}
PG_IP=$(jq -r '.hostname // empty' <<<"$INFO")
PG_PWD=$(jq -r '.password // empty' <<<"$INFO")

if [ -z "$PG_IP" ]; then
  echo "psql-pg: $NAME has no hostname (state=running?). API response:" >&2
  echo "$INFO" | jq . >&2 2>/dev/null || echo "$INFO" >&2
  exit 1
fi
[ -n "$PG_PWD" ] || { echo "psql-pg: $NAME has no password in API response" >&2; exit 1; }

exec env PGPASSWORD="$PG_PWD" psql \
  -h "$PG_IP" -p 5432 -U postgres -d postgres \
  "$@"
