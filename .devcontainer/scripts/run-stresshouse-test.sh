#!/usr/bin/env bash
# Run one stresshouse test with retries. All output is written to a log file
# under $LOG_DIR (named after a sanitized $TEST_NAME); nothing is printed to
# stdout or stderr. Caller is expected to read the log file(s) afterwards.
# Exits 0 on pass, 1 on fail.
#
# Required env: TEST_NAME, ENTRYPOINT, PLUGIN_CONFIG, IMAGE, NETWORK, API_HOST
# Optional env: LOG_DIR (default /tmp/ci-logs), TIMEOUT_MIN (default 20),
#               MAX_ATTEMPTS (default 2)

set -uo pipefail

: "${TEST_NAME:?TEST_NAME required}"
: "${ENTRYPOINT:?ENTRYPOINT required}"
: "${PLUGIN_CONFIG:?PLUGIN_CONFIG required}"
: "${IMAGE:?IMAGE required}"
: "${NETWORK:?NETWORK required}"
: "${API_HOST:?API_HOST required}"
LOG_DIR="${LOG_DIR:-/tmp/ci-logs}"
TIMEOUT_MIN="${TIMEOUT_MIN:-20}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"

LOG_NAME=$(echo "$TEST_NAME" | tr ' A-Z' '-a-z' | tr -cs 'a-z0-9-' '-')
mkdir -p "$LOG_DIR"

for ATTEMPT in $(seq 1 "$MAX_ATTEMPTS"); do
  if [ "$ATTEMPT" -eq 1 ]; then
    LOG_FILE="$LOG_DIR/${LOG_NAME}.log"
  else
    LOG_FILE="$LOG_DIR/${LOG_NAME}-retry${ATTEMPT}.log"
  fi

  echo "=== ${TEST_NAME} attempt ${ATTEMPT}/${MAX_ATTEMPTS} started $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" > "$LOG_FILE"

  EXIT_CODE=0
  timeout "${TIMEOUT_MIN}m" docker run --rm \
    --network "$NETWORK" \
    --add-host "api.localhost:${API_HOST}" \
    --entrypoint "$ENTRYPOINT" \
    "$IMAGE" \
    --plugin-config "$PLUGIN_CONFIG" \
    >> "$LOG_FILE" 2>&1 || EXIT_CODE=$?

  echo "=== ${TEST_NAME} attempt ${ATTEMPT} exit=${EXIT_CODE} finished $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$LOG_FILE"

  if [ $EXIT_CODE -eq 0 ]; then
    exit 0
  fi
done

exit 1
