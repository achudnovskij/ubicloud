#!/bin/bash
# Runs HammerDB TPC-C against the target Postgres reading connection params from /etc/bench.env.
# Uses the tpcorg/hammerdb container with TCL templates in /opt/bench/hammerdb/.
#
# Usage:
#   run-hammerdb-tpcc.sh --build    --warehouses 100 [--build-vu 8] [--tpcc-dbase tpcc] [--tpcc-user tpcc] [--tpcc-pass tpcc]
#   run-hammerdb-tpcc.sh --run      --vu 16 --rampup 2 --duration 10 [--tpcc-dbase tpcc] [--tpcc-user tpcc] [--tpcc-pass tpcc]
#   run-hammerdb-tpcc.sh --build --run ...    (build then run)
#
# Build phase creates the schema and loads warehouses; run phase executes a timed TPC-C workload.

set -euo pipefail

# shellcheck disable=SC1091
. /etc/bench.env

DO_BUILD=0
DO_RUN=0
WAREHOUSES=10
BUILD_VU=4
NUM_VU=8
RAMPUP=2
DURATION=5
TPCC_DBASE="tpcc"
TPCC_USER="tpcc"
TPCC_PASS="tpcc"
HAMMERDB_IMAGE="${HAMMERDB_IMAGE:-tpcorg/hammerdb:latest}"

while [ $# -gt 0 ]; do
  case "$1" in
    --build)        DO_BUILD=1; shift ;;
    --run)          DO_RUN=1; shift ;;
    --warehouses)   WAREHOUSES="$2"; shift 2 ;;
    --build-vu)     BUILD_VU="$2"; shift 2 ;;
    --vu)           NUM_VU="$2"; shift 2 ;;
    --rampup)       RAMPUP="$2"; shift 2 ;;
    --duration)     DURATION="$2"; shift 2 ;;
    --tpcc-dbase)   TPCC_DBASE="$2"; shift 2 ;;
    --tpcc-user)    TPCC_USER="$2"; shift 2 ;;
    --tpcc-pass)    TPCC_PASS="$2"; shift 2 ;;
    *)              echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ "$DO_BUILD" = "0" ] && [ "$DO_RUN" = "0" ]; then
  echo "Specify at least one of --build or --run" >&2
  exit 1
fi

TS=$(date +%Y%m%d-%H%M%S)
LOG_DIR=/var/log/bench
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/tpcc-${TS}.log"
ln -sfn "$LOG" "$LOG_DIR/latest.log"

# Pre-create the tpcc database + login role using the superuser credentials from /etc/bench.env.
# HammerDB's build phase normally does this via pg_superuser, but Ubicloud's superuser may not have
# rolcreaterole on managed roles, so we do it explicitly here for clarity and idempotency.
ensure_tpcc_db() {
  export PGPASSWORD="$PG_PASS"
  local PSQL=(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DEFAULT_DBASE" -v ON_ERROR_STOP=1 -tAc)

  if ! "${PSQL[@]}" "SELECT 1 FROM pg_roles WHERE rolname = '$TPCC_USER'" | grep -q 1; then
    "${PSQL[@]}" "CREATE ROLE \"$TPCC_USER\" LOGIN PASSWORD '$TPCC_PASS'"
  fi
  if ! "${PSQL[@]}" "SELECT 1 FROM pg_database WHERE datname = '$TPCC_DBASE'" | grep -q 1; then
    "${PSQL[@]}" "CREATE DATABASE \"$TPCC_DBASE\" OWNER \"$TPCC_USER\""
  fi
}

# Common docker invocation for HammerDB.
hammerdb_run() {
  local tcl="$1"
  docker run --rm --network host \
    -e PG_HOST="$PG_HOST" \
    -e PG_PORT="$PG_PORT" \
    -e PG_SSLMODE="${PG_SSLMODE:-require}" \
    -e PG_DEFAULT_DBASE="$PG_DEFAULT_DBASE" \
    -e PG_SUPERUSER="$PG_USER" \
    -e PG_SUPERUSERPASS="$PG_PASS" \
    -e PG_DBASE="$TPCC_DBASE" \
    -e PG_USER="$TPCC_USER" \
    -e PG_PASS="$TPCC_PASS" \
    -e PG_COUNT_WARE="$WAREHOUSES" \
    -e PG_BUILD_VU="$BUILD_VU" \
    -e PG_NUM_VU="$NUM_VU" \
    -e PG_RAMPUP="$RAMPUP" \
    -e PG_DURATION="$DURATION" \
    -v /opt/bench/hammerdb:/scripts:ro \
    -v /var/log/bench/hammerdb:/tmp \
    -w /home/hammerdb \
    "$HAMMERDB_IMAGE" \
    ./hammerdbcli auto "/scripts/$tcl"
}

{
  echo "=== HammerDB TPC-C $TS ==="
  echo "host=$PG_HOST default_db=$PG_DEFAULT_DBASE tpcc_db=$TPCC_DBASE tpcc_user=$TPCC_USER"
  echo "build=$DO_BUILD run=$DO_RUN warehouses=$WAREHOUSES build_vu=$BUILD_VU vu=$NUM_VU rampup=${RAMPUP}m duration=${DURATION}m"
  echo

  if [ "$DO_BUILD" = "1" ]; then
    echo "--- ensuring tpcc role + db ---"
    ensure_tpcc_db
    echo "--- HammerDB build phase ---"
    hammerdb_run build.tcl
    echo
  fi

  if [ "$DO_RUN" = "1" ]; then
    echo "--- HammerDB run phase ---"
    hammerdb_run run.tcl
    echo
  fi

  echo "=== done $TS log=$LOG ==="
} 2>&1 | tee "$LOG"
