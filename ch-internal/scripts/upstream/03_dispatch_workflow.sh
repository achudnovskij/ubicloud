#!/usr/bin/env bash
set -euo pipefail

# Stage 3 of the upstream-sync flow: fire workflow_dispatch for the heavy CI
# pipelines on the sync branch and print the resulting run URLs.
#
# The caller (manual operator or daily orchestrator) decides whether to invoke
# this — typically skipped on the conflict-marker path because the code is
# malformed and CI would just fail. A human's resolution push will trigger
# both pipelines naturally via the pull_request synchronize event.
#
# Args:
#   $1 (optional) — sync branch name (defaults to current branch)

BRANCH=${1:-$(git symbolic-ref --short HEAD)}

# Resolve origin's GitHub repo (owner/name). `gh repo set-default` may point
# at upstream, so we always target the remote we actually pushed to.
ORIGIN_URL=$(git remote get-url origin)
ORIGIN_REPO=$(echo "$ORIGIN_URL" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')

# Triggers a workflow_dispatch run for $1 against $BRANCH and prints the run
# URL. Polls briefly because dispatch returns before the run is queued.
trigger_run() {
  local workflow="$1"
  echo "Triggering ${workflow} on ${BRANCH}..."
  gh workflow run "$workflow" --repo "$ORIGIN_REPO" --ref "$BRANCH"

  local url=""
  for _ in $(seq 1 20); do
    sleep 1
    url=$(gh run list \
            --repo "$ORIGIN_REPO" \
            --workflow "$workflow" \
            --branch "$BRANCH" \
            --event workflow_dispatch \
            --limit 1 \
            --json url \
            --jq '.[0].url' 2>/dev/null || true)
    [ -n "$url" ] && break
  done

  if [ -n "$url" ]; then
    echo "  ${url}"
  else
    echo "  run did not appear; check https://github.com/${ORIGIN_REPO}/actions/workflows/${workflow}?query=branch%3A${BRANCH}"
  fi
}

trigger_run ch-internal-ubimirror-ci.yml
trigger_run ch-internal-pg-ubicloud-ci-e2e.yml
