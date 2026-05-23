#!/bin/bash
# Prepares the Ubicloud environment for PostgreSQL development.
# Authenticates with GitHub, fetches latest AMIs, and updates the database.
#
# Usage: .devcontainer/prepare-pg-ubicloud.sh [--region us-west-2] [--region us-east-1]
#   --region: AWS region(s) to update (default: us-west-2). Can be specified multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REGIONS=()

: "${AWS_ASSUME_ROLE:?AWS_ASSUME_ROLE is not set. Ensure it is defined in docker-compose.yml or exported in your shell.}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)
      REGIONS+=("$2")
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--region us-west-2] [--region us-east-1]" >&2
      exit 1
      ;;
  esac
done

# Default to us-west-2 if no regions specified
if [ ${#REGIONS[@]} -eq 0 ]; then
  REGIONS=("us-west-2")
fi

# 0. Sync mise-managed tools (ruby/nodejs/golang/victoria-metrics) from
#    .tool-versions and re-bundle if Ruby was bumped by an upstream merge.
echo ""
echo "=== Syncing mise tools from .tool-versions ==="
"$SCRIPT_DIR/sync-tool-versions.sh"
# After a tool-version bump, the parent shell's PATH still points at the
# previously-active versions. Refresh this script's env so the remaining
# steps (rake, bundle exec, foreman) run under the new active tools.
MISE_BIN="${MISE:-/home/vscode/.local/bin/mise}"
if [ -x "$MISE_BIN" ]; then
  eval "$("$MISE_BIN" env -s bash)"
fi

# 1. Run database migrations to latest version
echo ""
echo "=== Running database migrations (rake dev_up) ==="
(cd "$SCRIPT_DIR/../.." && bundle exec rake dev_up)

# 2. Create default project with private_locations enabled
"$SCRIPT_DIR/register-pg-project.sh"

# 3. GitHub authentication
echo ""
echo "=== GitHub CLI authentication ==="
if [ -n "${GH_TOKEN:-}" ]; then
  echo "Using GH_TOKEN — skipping interactive login"
else
  gh auth status 2>/dev/null || gh auth login
fi

# 4. Download AWS config (skip when credentials are already in environment)
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  echo ""
  echo "=== AWS credentials available in environment — skipping ~/.aws/config download ==="
else
  echo ""
  echo "=== Downloading AWS config ==="
  mkdir -p ~/.aws
  sudo chown -R "$(id -u):$(id -g)" ~/.aws
  gh api /repos/ClickHouse/data-plane-configuration/contents/aws-config \
    -H "Accept: application/vnd.github.raw" > ~/.aws/config
  echo "AWS config written to ~/.aws/config"
fi

# 5. Register regions (create locations + fetch and update AMIs)
for REGION in "${REGIONS[@]}"; do
  "$SCRIPT_DIR/register-pg-region.sh" "$REGION" "$AWS_ASSUME_ROLE"
done

"$SCRIPT_DIR/aws-sso-login.sh"

# Start foreman last so respirate boots with the fully prepared AWS profile,
# downloaded ~/.aws/config, registered locations, and a valid SSO session.
"$SCRIPT_DIR/start-foreman.sh" --restart

echo ""
echo "=== Done ==="
