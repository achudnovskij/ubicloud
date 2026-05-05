#!/usr/bin/env bash
set -euo pipefail

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

git fetch upstream
git fetch origin

TARGET=${1:-$(git rev-parse upstream/main)}
SYNC_DATE=$(date +%Y-%m-%d)
SYNC_BRANCH="sync/upstream-${SYNC_DATE}"
i=2
while git show-ref --verify --quiet "refs/heads/$SYNC_BRANCH"; do
  SYNC_BRANCH="sync/upstream-${SYNC_DATE}-${i}"
  i=$((i+1))
done

LAST_SYNC=$(git merge-base origin/clickhouse upstream/main)
echo "Syncing $LAST_SYNC -> $TARGET"
echo "Commits: $(git log --oneline $LAST_SYNC..$TARGET | wc -l)"

git checkout clickhouse
git pull --ff-only origin clickhouse
git checkout -b "$SYNC_BRANCH"

merge_ok=1
git merge $TARGET --no-ff -m "Merge upstream up to $TARGET" || merge_ok=0

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
    echo ""
    echo "Merge has conflicts. Files to resolve:"
    printf '%s\n' "$remaining" | awk '{print "  " $0}'
    echo ""
    echo "After resolving:"
    echo "  git add -- <files>"
    echo "  git commit --no-edit"
    echo "  ch-internal/scripts/create_sync_pr.sh"
    exit 1
  fi

  echo "All remaining conflicts were cache/* — auto-resolved. Finalizing merge commit..."
  git commit --no-edit
fi

echo "Merge clean. Opening PR..."
exec "$(dirname "$0")/create_sync_pr.sh" "$SYNC_BRANCH"
