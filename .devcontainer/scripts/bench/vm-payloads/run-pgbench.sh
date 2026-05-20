#!/bin/bash
# Runs pgbench against the target Postgres reading connection params from /etc/bench.env.
#
# Usage:
#   run-pgbench.sh [--init] [--scale N] [--clients N] [--threads N] [--time SEC]
#                  [--protocol simple|extended|prepared] [--no-vacuum] [-- <extra pgbench args>]
#
#   --init      Run pgbench -i first to (re)initialize tables at the given --scale.
#               WITHOUT this flag, the run uses whatever scale already exists.

set -euo pipefail

# shellcheck disable=SC1091
. /etc/bench.env

INIT=0
SCALE=10
CLIENTS=16
THREADS=4
TIME=60
PROTOCOL=prepared
NO_VACUUM=0
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --init)       INIT=1; shift ;;
    --scale)      SCALE="$2"; shift 2 ;;
    --clients)    CLIENTS="$2"; shift 2 ;;
    --threads)    THREADS="$2"; shift 2 ;;
    --time)       TIME="$2"; shift 2 ;;
    --protocol)   PROTOCOL="$2"; shift 2 ;;
    --no-vacuum)  NO_VACUUM=1; shift ;;
    --)           shift; EXTRA=("$@"); break ;;
    *)            echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

TS=$(date +%Y%m%d-%H%M%S)
LOG_DIR=/var/log/bench
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/pgbench-${TS}.log"
ln -sfn "$LOG" "$LOG_DIR/latest.log"

export PGPASSWORD="$PG_PASS"
PG_ARGS=(-h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DBASE")

{
  echo "=== pgbench run $TS ==="
  echo "host=$PG_HOST db=$PG_DBASE user=$PG_USER scale=$SCALE clients=$CLIENTS threads=$THREADS time=${TIME}s protocol=$PROTOCOL init=$INIT"
  echo "pgbench version: $(pgbench --version)"
  echo

  if [ "$INIT" = "1" ]; then
    echo "--- pgbench -i (scale=$SCALE) ---"
    INIT_FLAGS=(-i -s "$SCALE")
    [ "$NO_VACUUM" = "1" ] && INIT_FLAGS+=(--no-vacuum)
    pgbench "${PG_ARGS[@]}" "${INIT_FLAGS[@]}"
    echo
  fi

  echo "--- pgbench run ---"
  RUN_FLAGS=(-c "$CLIENTS" -j "$THREADS" -T "$TIME" -P 5 -M "$PROTOCOL")
  [ "$NO_VACUUM" = "1" ] && RUN_FLAGS+=(--no-vacuum)
  pgbench "${PG_ARGS[@]}" "${RUN_FLAGS[@]}" "${EXTRA[@]}"
  echo
  echo "=== done $TS log=$LOG ==="
} 2>&1 | tee "$LOG"
