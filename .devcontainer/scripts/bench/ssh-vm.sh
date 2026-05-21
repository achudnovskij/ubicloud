#!/bin/bash
# SSH into a benchmark VM by name. Reads /tmp/bench_meta_<vm-name> for IP and
# /tmp/bench_ssh_key_<vm-name> for the private key.
#
# Usage:
#   ssh-vm.sh <vm-name>                            # interactive shell
#   ssh-vm.sh <vm-name> -- <remote command>        # one-shot command
#   ssh-vm.sh bench-foo -- 'tail -F /var/log/bench/latest.log'

set -euo pipefail

: "${AWS_PROFILE:=pg-dev-postgresqladmindev}"
export AWS_PROFILE

NAME="${1:?Usage: ssh-vm.sh <vm-name> [-- <args>]}"
shift || true
if [ "${1:-}" = "--" ]; then shift; fi

META_FILE="/tmp/bench_meta_$NAME"
[ -f "$META_FILE" ] || { echo "Missing $META_FILE — provision first." >&2; exit 1; }
# shellcheck disable=SC1090
. "$META_FILE"

exec ssh -i "$KEY_FILE" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  "${VM_USER}@${VM_IP}" "$@"
