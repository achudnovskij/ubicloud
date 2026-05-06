#!/usr/bin/env bash
set -euo pipefail

# Stage 2 of the upstream-sync flow: push the sync branch and open the PR
# against `clickhouse`. The PR body lists every upstream commit pulled in this
# merge with links back to ubicloud/ubicloud, annotated with `[m]` when the
# commit touches `migrate/` and `[fork]` when it touches a file the fork has
# modified relative to the upstream merge-base. The merge commit body (written
# by 01_initiate.sh) is pasted verbatim, so any "## Conflicted files" section
# it added surfaces as a top-level PR section automatically.
#
# Conflict-aware behaviour (draft, `upstream-sync-conflict` label, title prefix) and
# CI/E2E workflow_dispatch triggers are intentionally NOT here — the caller
# (manual operator or daily orchestrator) layers those on top.
#
# Assumes:
#   - HEAD of the branch is a merge commit (parent 1 = clickhouse, parent 2 = upstream tip)
#   - `origin` points at the fork that hosts the PR base branch `clickhouse`
#   - `gh` is authenticated and can create PRs against `origin`

UPSTREAM_REPO="ubicloud/ubicloud"
BRANCH=${1:-$(git symbolic-ref --short HEAD)}

# Open the PR as draft when SYNC_PR_DRAFT=1. The orchestrator sets this when
# it knows the merge has unresolved conflicts; manual one-off runs leave it
# unset and get a normal ready-for-review PR.
PR_DRAFT="${SYNC_PR_DRAFT:-}"

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

CLICKHOUSE_TIP=$(git rev-parse "${MERGE_COMMIT}^1")
TARGET=$(git rev-parse "${MERGE_COMMIT}^2")
LAST_SYNC=$(git merge-base "$CLICKHOUSE_TIP" "$TARGET")

COMMIT_COUNT=$(git rev-list --count "${LAST_SYNC}..${TARGET}")
echo "Branch: $BRANCH"
echo "Upstream range: ${LAST_SYNC:0:12}..${TARGET:0:12} ($COMMIT_COUNT commits)"

# Files that diverge between clickhouse and the upstream merge-base — used to
# badge upstream commits with [fork]. One newline-separated string; per-commit
# checks use `grep -Fxq` against this set.
FORK_FILES=$(git diff --name-only "$LAST_SYNC" "$CLICKHOUSE_TIP" | sort -u)

echo "Pushing $BRANCH to origin..."
git push -u origin "$BRANCH"

BODY_FILE=$(mktemp)
trap 'rm -f "$BODY_FILE"' EXIT

# Build the italicised marker tail (e.g. " *[m] [fork]*") for a given upstream
# commit, or empty string if no markers apply.
build_marker() {
  local sha="$1"
  local files has_m=0 has_fork=0 out=""
  files=$(git show --name-only --format= "$sha")
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
      migrate/*) has_m=1 ;;
    esac
    if [ "$has_fork" -eq 0 ] && [ -n "$FORK_FILES" ] \
        && printf '%s\n' "$FORK_FILES" | grep -Fxq "$f"; then
      has_fork=1
    fi
  done <<< "$files"
  [ "$has_m" -eq 1 ] && out="[m]"
  [ "$has_fork" -eq 1 ] && out="${out:+$out }[fork]"
  if [ -n "$out" ]; then
    printf ' *%s*' "$out"
  fi
}

# Compose body. The merge commit body is pasted verbatim — when 01_initiate.sh
# committed conflicts, it already wrote a "## Conflicted files — resolve before
# merge" section into that body. When a developer manually resolved, their
# notes appear here. Either way, no special parsing or wrapping in 02.
{
  echo "Merging \`upstream/main\` (\`${TARGET:0:12}\`) into \`clickhouse\`."

  MERGE_BODY=$(git log -1 --format=%b "$MERGE_COMMIT")
  if [ -n "$MERGE_BODY" ]; then
    echo
    echo "$MERGE_BODY"
  fi

  echo
  echo "## Upstream commits ($COMMIT_COUNT)"
  echo
  echo "*[m] migration · [fork] touches fork-modified file*"
  echo
  while IFS= read -r line; do
    sha=${line%% *}
    subj=${line#* }
    marker=$(build_marker "$sha")
    echo "- [\`${sha:0:9}\`](https://github.com/${UPSTREAM_REPO}/commit/${sha}) ${subj}${marker}"
  done < <(git log --reverse --no-merges --format="%H %s" "${LAST_SYNC}..${TARGET}")
} > "$BODY_FILE"

PR_FLAGS=(--label upstream-sync-auto)
[ -n "$PR_DRAFT" ] && PR_FLAGS+=(--draft)

PR_URL=$(gh pr create \
  --repo "$ORIGIN_REPO" \
  --base clickhouse \
  --head "$BRANCH" \
  --title "Sync upstream up to ${TARGET:0:12}" \
  --body-file "$BODY_FILE" \
  "${PR_FLAGS[@]}")
echo "PR: $PR_URL"
