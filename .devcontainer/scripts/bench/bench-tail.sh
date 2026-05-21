#!/bin/bash
# Tail /var/log/bench/latest.log on the bench VM.
#
# Usage: bench-tail.sh <vm-name>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAME="${1:?Usage: bench-tail.sh <vm-name>}"

exec "$SCRIPT_DIR/ssh-vm.sh" "$NAME" -- 'tail -F /var/log/bench/latest.log'
