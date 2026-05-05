#!/usr/bin/env bash
set -euo pipefail

# Pushes the current (or given) sync branch and opens a PR against `clickhouse`,
# listing every upstream commit pulled in this merge with links back to
# ubicloud/ubicloud.
#
# Assumes:
#   - HEAD of the branch is a merge commit (parent 1 = clickhouse, parent 2 = upstream tip)
#   - `origin` points at the fork that hosts the PR base branch `clickhouse`
#   - `gh` is authenticated and can create PRs against `origin`

UPSTREAM_REPO="ubicloud/ubicloud"
BRANCH=${1:-$(git symbolic-ref --short HEAD)}

# Resolve origin's GitHub repo (owner/name) — `gh repo set-default` may point
# at upstream, so we always target the remote we actually pushed to.
ORIGIN_URL=$(git remote get-url origin)
ORIGIN_REPO=$(echo "$ORIGIN_URL" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')
echo "Origin repo: $ORIGIN_REPO"

MERGE_COMMIT=$(git rev-parse "$BRANCH")
PARENT_COUNT=$(git rev-list --parents -n 1 "$MERGE_COMMIT" | awk '{print NF - 1}')
if [ "$PARENT_COUNT" -lt 2 ]; then
  echo "HEAD of $BRANCH ($MERGE_COMMIT) is not a merge commit." >&2
  exit 1
fi

TARGET=$(git rev-parse "${MERGE_COMMIT}^2")
LAST_SYNC=$(git merge-base "${MERGE_COMMIT}^1" "${MERGE_COMMIT}^2")

COMMIT_COUNT=$(git rev-list --count "${LAST_SYNC}..${TARGET}")
echo "Branch: $BRANCH"
echo "Upstream range: ${LAST_SYNC:0:12}..${TARGET:0:12} ($COMMIT_COUNT commits)"

echo "Pushing $BRANCH to origin..."
git push -u origin "$BRANCH"

BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT

MERGE_BODY=$(git log -1 --format=%b "$MERGE_COMMIT")

{
  echo "Merging \`upstream/main\` (\`${TARGET:0:12}\`) into \`clickhouse\`."
  if [ -n "$MERGE_BODY" ]; then
    echo
    echo "## Merge notes"
    echo
    echo "$MERGE_BODY"
  fi
  echo
  echo "## Upstream commits ($COMMIT_COUNT)"
  echo
  git log --reverse --no-merges \
    --format="- [\`%h\`](https://github.com/${UPSTREAM_REPO}/commit/%H) %s" \
    "${LAST_SYNC}..${TARGET}"
} > "$BODY_FILE"

PR_URL=$(gh pr create \
  --repo "$ORIGIN_REPO" \
  --base clickhouse \
  --head "$BRANCH" \
  --title "Sync upstream up to ${TARGET:0:12}" \
  --body-file "$BODY_FILE")
echo "PR: $PR_URL"

# Triggers a workflow_dispatch run for $1 against $BRANCH and prints the run URL.
# Polls briefly because dispatch returns before the run is queued.
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
