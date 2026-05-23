#!/bin/bash
# Sync mise-managed tools to whatever .tool-versions specifies, then reconcile
# the bundle so native gems / git-sourced gems / new Gemfile.lock entries are
# picked up.
#
# Used by both:
#   - .devcontainer/Dockerfile                       (at image build time)
#   - .devcontainer/scripts/prepare-pg-ubicloud.sh   (after upstream merges)
#
# Idempotent and cheap when nothing changed (`bundle check` is ~100ms).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MISE="${MISE:-/home/vscode/.local/bin/mise}"
TOOL_VERSIONS="$REPO_ROOT/.tool-versions"

if [ ! -x "$MISE" ]; then
  echo "mise not found at $MISE (set MISE=... to override)" >&2
  exit 1
fi
if [ ! -f "$TOOL_VERSIONS" ]; then
  echo ".tool-versions not found at $TOOL_VERSIONS" >&2
  exit 1
fi

cd "$REPO_ROOT"

# Snapshot the inherited PATH so we can tell at the end whether the caller's
# shell still resolves tools to stale install dirs.
CALLER_PATH="$PATH"

echo "=== mise: installing tools listed in .tool-versions ==="
"$MISE" install

while IFS= read -r line; do
  line="${line%%#*}"
  [ -z "${line// /}" ] && continue
  tool="$(echo "$line" | awk '{print $1}')"
  version="$(echo "$line" | awk '{print $2}')"
  [ -z "$tool" ] && continue
  [ -z "$version" ] && continue
  "$MISE" use --global "${tool}@${version}"
done < "$TOOL_VERSIONS"

# After `mise use --global`, the parent shell's PATH may still point at the
# previously-active tool bin dirs (mise activate baked them in at shell start).
# Refresh our env so the rest of this script and its children (gem, bundle)
# pick up the new active versions instead of the stale shell PATH.
if "$MISE" env -s bash >/tmp/.mise_env.$$ 2>/dev/null && [ -s /tmp/.mise_env.$$ ]; then
  # shellcheck disable=SC1090
  . /tmp/.mise_env.$$
fi
rm -f /tmp/.mise_env.$$

# bundler and foreman live in the active Ruby's gem dir, so they must be
# present after any Ruby reinstall. Install only when missing.
if command -v gem >/dev/null 2>&1; then
  for g in bundler foreman; do
    if ! gem list -i "$g" >/dev/null 2>&1; then
      echo "=== gem install $g ==="
      gem install "$g"
    fi
  done
fi

# Reconcile the bundle. Cheap when satisfied; otherwise fetches git-sourced
# gems and rebuilds native ones for the active Ruby ABI. Skipped at the first
# Docker build layer because Gemfile.lock hasn't been COPY'd in yet — the
# Dockerfile's later `bundle install` step handles that case.
if [ -f "$REPO_ROOT/Gemfile.lock" ] && command -v bundle >/dev/null 2>&1; then
  if bundle check >/dev/null 2>&1; then
    echo "Bundle already satisfied — skipping bundle install"
  else
    echo "=== bundle install ==="
    bundle install
  fi
fi

echo "=== sync-tool-versions done ==="

# A shell script cannot mutate its parent's PATH. If our inherited PATH was
# different from the post-refresh one, the caller's shell is still pointing at
# the previous tool versions and needs its own refresh.
if [ "$CALLER_PATH" != "$PATH" ]; then
  echo ""
  echo "NOTE: your shell still has the previous tool versions on PATH."
  echo "      Refresh with:  eval \"\$($MISE env -s bash)\""
  echo "      Or open a new terminal."
fi
