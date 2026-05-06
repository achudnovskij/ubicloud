#!/usr/bin/env bash
# Adhoc local entry point for the upstream-sync flow. Runs 01 → 02 → 03 and
# stops with next-steps guidance if any stage fails.
#
# For unattended automation, use daily.sh (which adds takeover detection,
# draft handling, tagging, and 14-day cleanup).
#
# Conflicts are not auto-committed here — 01 stops with `exit 1` and prints
# resolution instructions, leaving the merge in-progress for interactive fixup.

# NOTE: no `set -e` — we want to inspect each stage's exit code and emit
# tailored guidance instead of dropping out silently.
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)

if ! "$DIR/01_initiate.sh"; then
  echo
  echo "==> 01_initiate.sh stopped with unresolved conflicts."
  echo "    Follow the 'After resolving:' instructions above, then continue:"
  echo "      $DIR/02_create_pr.sh"
  echo "      $DIR/03_dispatch_workflow.sh"
  exit 1
fi

SYNC_BRANCH=$(git symbolic-ref --short HEAD)
echo "==> 01 done. On branch $SYNC_BRANCH."

if ! "$DIR/02_create_pr.sh" "$SYNC_BRANCH"; then
  echo
  echo "==> 02_create_pr.sh failed. Once fixed, retry:"
  echo "      $DIR/02_create_pr.sh $SYNC_BRANCH"
  echo "      $DIR/03_dispatch_workflow.sh $SYNC_BRANCH"
  exit 1
fi

echo "==> 02 done. PR opened."

if ! "$DIR/03_dispatch_workflow.sh" "$SYNC_BRANCH"; then
  echo
  echo "==> 03_dispatch_workflow.sh failed. PR is open; retry dispatch with:"
  echo "      $DIR/03_dispatch_workflow.sh $SYNC_BRANCH"
  exit 1
fi

echo
echo "==> Sync complete on $SYNC_BRANCH."
