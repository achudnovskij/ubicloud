#!/bin/bash
# Fetch /var/log/bench/ from the bench VM via scp.
#
# Usage: bench-fetch.sh <vm-name> [dest-dir]
#   dest-dir defaults to ./results/<vm-name>

set -euo pipefail

: "${AWS_PROFILE:=pg-dev-postgresqladmindev}"
export AWS_PROFILE

NAME="${1:?Usage: bench-fetch.sh <vm-name> [dest-dir]}"
DEST="${2:-./results/$NAME}"

META_FILE="/tmp/bench_meta_$NAME"
[ -f "$META_FILE" ] || { echo "Missing $META_FILE — provision first." >&2; exit 1; }
# shellcheck disable=SC1090
. "$META_FILE"

mkdir -p "$DEST"
scp -i "$KEY_FILE" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -r "${VM_USER}@${VM_IP}:/var/log/bench/" "$DEST"

echo "Fetched logs to: $DEST"
ls -l "$DEST/bench" 2>/dev/null || ls -l "$DEST"
