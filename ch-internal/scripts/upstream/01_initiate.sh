#!/usr/bin/env bash
set -euo pipefail

# Stage 1 of the upstream-sync flow: fetch upstream, branch off clickhouse,
# merge upstream/main, commit the merge with a structured message. Higher-level
# orchestration (PR creation, CI dispatch, daily-loop dedup) lives in caller
# scripts that invoke this and 02_create_pr.sh in sequence.
#
# Exit codes:
#   0  merge committed successfully (clean OR cache-only OR conflict-markers-committed)
#   1  unresolved conflicts and SYNC_COMMIT_CONFLICTS unset — merge left in-progress
#      for a developer to resolve interactively
#
# When SYNC_COMMIT_CONFLICTS=1, unresolved conflicts after the cache/*
# auto-resolve loop are committed verbatim (with conflict markers).
COMMIT_CONFLICTS="${SYNC_COMMIT_CONFLICTS:-}"

# Merge commit message file: subject line plus optional "## Conflicted files"
# section. 02_create_pr.sh reads the committed body via `git log -1 --format=%b`
# and pastes it into the PR body verbatim, so the conflict file list surfaces
# as a real PR section without any inter-script parsing.
MERGE_MSG_FILE=/tmp/sync_commit_message.txt

# Retry git commands that race with concurrent index.lock holders
# (VS Code's git extension polls in the background and can grab the lock
# between our operations).
git_retry() {
  local attempt=1
  local max=10
  while true; do
    if git "$@" 2>/tmp/git_retry.err; then
      return 0
    fi
    if grep -q "index.lock" /tmp/git_retry.err && [ "$attempt" -lt "$max" ]; then
      sleep 0.5
      attempt=$((attempt+1))
      continue
    fi
    cat /tmp/git_retry.err >&2
    return 1
  done
}

# Apply pending DB migrations and regenerate schema/static caches + model
# annotations, then stage any updates so they fold into the merge commit.
# Migration filenames are unique across upstream and the fork, so this is safe
# to run on every path including the conflict-markers-committed one.
refresh_schema_caches() {
  echo "Applying test DB migrations and refreshing schema caches..."
  # Re-resolve gems: the upstream merge may have bumped Gemfile.lock to
  # reference versions that the pre-merge `bundle install` didn't fetch.
  bundle install
  bundle exec rake test_up
  git add -u cache/ model/ 2>/dev/null || true
}

git fetch upstream
git fetch origin

TARGET=${1:-$(git rev-parse upstream/main)}
SYNC_DATE=$(date +%Y-%m-%d)
SYNC_BRANCH="sync/upstream-${SYNC_DATE}"
i=2
# Bump if either local or remote already has the branch.
while git show-ref --verify --quiet "refs/heads/$SYNC_BRANCH" \
   || git ls-remote --exit-code --heads origin "$SYNC_BRANCH" >/dev/null 2>&1; do
  SYNC_BRANCH="sync/upstream-${SYNC_DATE}-${i}"
  i=$((i+1))
done

LAST_SYNC=$(git merge-base origin/clickhouse upstream/main)
echo "Syncing $LAST_SYNC -> $TARGET"
echo "Commits: $(git log --oneline $LAST_SYNC..$TARGET | wc -l)"

git checkout clickhouse
git pull --ff-only origin clickhouse
git checkout -b "$SYNC_BRANCH"

# Seed the merge commit message file with the subject. Conflict sections (if
# any) are appended below before the commit.
echo "Merge upstream up to $TARGET" > "$MERGE_MSG_FILE"

# --no-commit so we control the message via -F, regardless of merge outcome.
merge_ok=1
git merge "$TARGET" --no-ff --no-commit || merge_ok=0

if [ "$merge_ok" -eq 0 ]; then
  # Auto-resolve cache/* conflicts in favor of upstream (theirs).
  while IFS= read -r f; do
    case "$f" in
      cache/*.cache)
        echo "Auto-resolving (theirs): $f"
        git_retry checkout --theirs -- "$f"
        git_retry add -- "$f"
        ;;
    esac
  done < <(git diff --name-only --diff-filter=U)

  remaining=$(git diff --name-only --diff-filter=U)
  if [ -n "$remaining" ]; then
    if [ -n "$COMMIT_CONFLICTS" ]; then
      echo ""
      echo "Committing conflict markers in place (SYNC_COMMIT_CONFLICTS=1):"
      printf '%s\n' "$remaining" | awk '{print "  " $0}'

      # Record the conflict file list in the merge commit body. 02_create_pr.sh
      # reads this verbatim into the PR body so reviewers see exactly which
      # files still have markers in them.
      {
        echo ""
        echo "## Conflicted files — resolve before merge"
        echo ""
        printf '%s\n' "$remaining" | awk '{print "- " $0}'
      } >> "$MERGE_MSG_FILE"

      printf '%s\n' "$remaining" | while IFS= read -r f; do
        git_retry add -- "$f"
      done

      refresh_schema_caches

      # core.hooksPath=/dev/null bypasses linters/formatters that would reject
      # malformed code (conflict markers don't parse). The PR will be opened as
      # draft so this commit is visibly broken to reviewers.
      git -c core.hooksPath=/dev/null commit -F "$MERGE_MSG_FILE"
    else
      echo ""
      echo "Merge has conflicts. Files to resolve:"
      printf '%s\n' "$remaining" | awk '{print "  " $0}'
      echo ""
      echo "After resolving:"
      echo "  git add -- <files>"
      echo "  git commit -F $MERGE_MSG_FILE   # or amend with your own notes"
      echo "  ch-internal/scripts/upstream/02_create_pr.sh"
      exit 1
    fi
  else
    echo "All remaining conflicts were cache/* — auto-resolved. Finalizing merge commit..."
    refresh_schema_caches
    git commit -F "$MERGE_MSG_FILE"
  fi
else
  # Clean merge — finalize the commit ourselves since we used --no-commit.
  refresh_schema_caches
  git commit -F "$MERGE_MSG_FILE"
fi

echo "Merge complete on branch $SYNC_BRANCH."
