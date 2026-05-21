#!/bin/bash
# Trigger a benchmark on the bench VM via ssh. Forwards args to the on-VM script.
#
# Usage:
#   bench-run.sh <vm-name> pgbench [--detached|--stream] [--destroy-on-finish] -- <pgbench args>
#   bench-run.sh <vm-name> tpcc    [--detached|--stream] [--destroy-on-finish] -- <tpcc args>
#
# Examples:
#   bench-run.sh bench-foo pgbench -- --init --scale 50 --clients 32 --threads 8 --time 300
#   bench-run.sh bench-foo pgbench --stream -- --init --scale 50 --time 60
#   bench-run.sh bench-foo tpcc -- --build --run --warehouses 100 --vu 16 --rampup 2 --duration 10
#
# Modes:
#   --detached (default)  tmux session 'bench' on the VM; returns immediately.
#                         Use bench-tail.sh to observe.
#   --stream              ssh -t blocking; output streams to local terminal.
#
# --destroy-on-finish only meaningful in --stream mode.

set -euo pipefail

: "${AWS_PROFILE:=pg-dev-postgresqladmindev}"
export AWS_PROFILE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

NAME="${1:-}"
KIND="${2:-}"
[ -n "$NAME" ] && [ -n "$KIND" ] || { echo "Usage: bench-run.sh <vm-name> {pgbench|tpcc} [--detached|--stream] [--destroy-on-finish] -- <args>" >&2; exit 1; }
shift 2

case "$KIND" in
  pgbench) REMOTE_CMD="run-pgbench.sh" ;;
  tpcc)    REMOTE_CMD="run-hammerdb-tpcc.sh" ;;
  *) echo "kind must be pgbench or tpcc, got: $KIND" >&2; exit 1 ;;
esac

MODE="detached"
DESTROY_ON_FINISH=0
PASSTHROUGH=()
while [ $# -gt 0 ]; do
  case "$1" in
    --detached)            MODE="detached"; shift ;;
    --stream)              MODE="stream"; shift ;;
    --destroy-on-finish)   DESTROY_ON_FINISH=1; shift ;;
    --) shift; PASSTHROUGH=("$@"); break ;;
    *) PASSTHROUGH+=("$1"); shift ;;
  esac
done

META_FILE="/tmp/bench_meta_$NAME"
[ -f "$META_FILE" ] || { echo "Missing $META_FILE — provision first." >&2; exit 1; }
# shellcheck disable=SC1090
. "$META_FILE"

SSH_OPTS=(-i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# Build the remote command as a properly %q-quoted argv string. We write it
# into a small launcher script on the VM rather than embedding it as a
# nested-quoted tmux argument — that way arbitrary user args (including those
# with spaces, quotes, or shell metacharacters) survive intact through ssh +
# tmux + the user shell.
REMOTE_ARGV_QUOTED=$(printf '%q ' "/usr/local/bin/${REMOTE_CMD}" "${PASSTHROUGH[@]}")
REMOTE_LAUNCHER="/tmp/bench-launch-$$.sh"

case "$MODE" in
  detached)
    if ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" 'tmux has-session -t bench 2>/dev/null'; then
      echo "A 'bench' tmux session is already running on $NAME."
      echo "  Attach:  $SCRIPT_DIR/ssh-vm.sh $NAME -- 'tmux attach -t bench'"
      echo "  Kill:    $SCRIPT_DIR/ssh-vm.sh $NAME -- 'tmux kill-session -t bench'"
      exit 1
    fi
    ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" \
      "cat > $REMOTE_LAUNCHER && chmod +x $REMOTE_LAUNCHER && tmux new -d -s bench $REMOTE_LAUNCHER" <<EOF
#!/bin/bash
exec $REMOTE_ARGV_QUOTED
EOF
    echo "Launched in tmux session 'bench' on $NAME ($VM_IP)."
    echo "Tail:    $SCRIPT_DIR/bench-tail.sh $NAME"
    echo "Attach:  $SCRIPT_DIR/ssh-vm.sh $NAME -- 'tmux attach -t bench'"
    echo "Fetch:   $SCRIPT_DIR/bench-fetch.sh $NAME"
    if [ "$DESTROY_ON_FINISH" = "1" ]; then
      echo "WARN: --destroy-on-finish is ignored in --detached mode."
    fi
    ;;
  stream)
    set +e
    ssh -t "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "$REMOTE_ARGV_QUOTED"
    rc=$?
    set -e
    echo "Run exited with status $rc."
    if [ "$DESTROY_ON_FINISH" = "1" ]; then
      "$SCRIPT_DIR/bench-fetch.sh" "$NAME" "./results/$NAME" || echo "WARN: fetch failed; destroying anyway"
      "$SCRIPT_DIR/bench-destroy.sh" "$NAME"
    fi
    exit "$rc"
    ;;
esac
