#!/usr/bin/env bash
set -euo pipefail

# Daily orchestrator for the upstream-sync flow.
# Wraps 01 → 02 → 03 with takeover detection, draft handling, conflict-PR
# decoration, tagging for next-day dedup, and 14-day branch cleanup.
#
# Intended for a GitHub Actions cron job (gh authed via the workflow's
# GITHUB_TOKEN), but runs locally too if you have gh auth.
#
# Required gh permissions: contents:write, pull-requests:write, actions:write.
# Required tools: gh, jq, git, GNU date (for `date -d '14 days ago'`).

DIR=$(cd "$(dirname "$0")" && pwd)

ORIGIN_URL=$(git remote get-url origin)
ORIGIN_REPO=$(echo "$ORIGIN_URL" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')
echo "Origin repo: $ORIGIN_REPO"

# ----- 1. Look for existing open sync PR and decide skip / supersede ---------
EXISTING=$(gh pr list --repo "$ORIGIN_REPO" --state open --label upstream-sync-auto \
  --json number,headRefOid,headRefName,isDraft,assignees,labels \
  --jq '.[0] // empty')

if [ -n "$EXISTING" ]; then
  PR_NUM=$(jq -r .number <<<"$EXISTING")
  HEAD_SHA=$(jq -r .headRefOid <<<"$EXISTING")
  HEAD_REF=$(jq -r .headRefName <<<"$EXISTING")
  IS_DRAFT=$(jq -r .isDraft <<<"$EXISTING")
  ASSIGNEES=$(jq -r '.assignees | length' <<<"$EXISTING")
  HAS_CONFLICT_LABEL=$(jq -r '[.labels[].name] | contains(["upstream-sync-conflict"])' <<<"$EXISTING")

  TAG_SHA=$(gh api "repos/${ORIGIN_REPO}/git/ref/tags/sync-bot/${HEAD_REF}" \
            --jq .object.sha 2>/dev/null || echo "")

  # Takeover signals (any one → skip): assignee set; conflict PR marked
  # ready; head SHA changed vs sync-bot tag.
  TOUCHED=false
  [ "$ASSIGNEES" -gt 0 ] && TOUCHED=true
  [ "$IS_DRAFT" = "false" ] && [ "$HAS_CONFLICT_LABEL" = "true" ] && TOUCHED=true
  [ -n "$TAG_SHA" ] && [ "$HEAD_SHA" != "$TAG_SHA" ] && TOUCHED=true

  if [ "$TOUCHED" = "true" ]; then
    echo "PR #$PR_NUM appears to be in human hands — skipping today's run."
    exit 0
  fi

  echo "Superseding stale PR #$PR_NUM (branch retained for 14 days)..."
  gh pr comment "$PR_NUM" --repo "$ORIGIN_REPO" \
    --body "Superseded by upcoming daily sync. Branch retained for 14 days; reopen this PR or push to its branch to recover."
  gh pr close "$PR_NUM" --repo "$ORIGIN_REPO"
fi

# ----- 2. Run the merge initiator -------------------------------------------
SYNC_COMMIT_CONFLICTS=1 "$DIR/01_initiate.sh"
SYNC_BRANCH=$(git symbolic-ref --short HEAD)
MERGE_COMMIT=$(git rev-parse HEAD)
echo "Sync branch: $SYNC_BRANCH at $MERGE_COMMIT"

# ----- 3. Detect conflict markers in the merge tree --------------------------
HAS_CONFLICTS=""
if git grep -l '^<<<<<<< ' "$MERGE_COMMIT" >/dev/null 2>&1; then
  HAS_CONFLICTS=1
  echo "Conflict markers detected in merge commit."
fi

# ----- 4. Open the PR (draft if conflicts) -----------------------------------
if [ -n "$HAS_CONFLICTS" ]; then
  SYNC_PR_DRAFT=1 "$DIR/02_create_pr.sh" "$SYNC_BRANCH"
else
  "$DIR/02_create_pr.sh" "$SYNC_BRANCH"
fi

PR_NUM=$(gh pr list --repo "$ORIGIN_REPO" --head "$SYNC_BRANCH" --state open \
         --json number --jq '.[0].number')

# ----- 5. Decorate conflict PRs with title prefix + label --------------------
# Use REST API directly instead of `gh pr edit`: the latter fails on the
# Projects (classic) GraphQL deprecation that triggers on any PullRequest
# GraphQL write in this environment.
if [ -n "$HAS_CONFLICTS" ]; then
  CURR_TITLE=$(gh pr view "$PR_NUM" --repo "$ORIGIN_REPO" --json title --jq .title)
  gh api --method PATCH "repos/${ORIGIN_REPO}/pulls/${PR_NUM}" \
    -f "title=[CONFLICT] ${CURR_TITLE}" >/dev/null
  gh api --method POST "repos/${ORIGIN_REPO}/issues/${PR_NUM}/labels" \
    -f "labels[]=upstream-sync-conflict" >/dev/null
fi

# ----- 6. Tag the merge commit for tomorrow's takeover detection -------------
# -f overwrites a stale tag from a prior aborted run on the same branch.
git tag -f "sync-bot/$SYNC_BRANCH" "$MERGE_COMMIT"
git push --force origin "sync-bot/$SYNC_BRANCH"

# ----- 7. Dispatch CI/E2E only on the clean path -----------------------------
if [ -z "$HAS_CONFLICTS" ]; then
  "$DIR/03_dispatch_workflow.sh" "$SYNC_BRANCH"
else
  echo "Skipping CI/E2E dispatch (conflict path; pull_request synchronize will trigger them on resolution push)."
fi

# ----- 8. Cleanup: drop branches >14 days with no open PR --------------------
echo "Cleaning up stale sync branches..."
git fetch --prune origin
CUTOFF_TS=$(date -d '14 days ago' +%s)

git for-each-ref --format='%(refname:short)|%(committerdate:unix)' \
    'refs/remotes/origin/sync/upstream-*' \
  | while IFS='|' read -r ref ts; do
      branch_name=${ref#origin/}
      [ "$ts" -ge "$CUTOFF_TS" ] && continue

      if gh pr list --repo "$ORIGIN_REPO" --head "$branch_name" --state open \
           --json number --jq 'length' | grep -q '^[1-9]'; then
        continue
      fi

      echo "  Deleting stale branch + tag: $branch_name"
      git push origin --delete "$branch_name" || true
      git push origin --delete "refs/tags/sync-bot/$branch_name" || true
    done

echo "Daily sync complete."
