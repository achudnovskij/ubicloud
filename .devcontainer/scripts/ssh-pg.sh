#!/bin/bash
# SSH into a PostgreSQL server VM by resource name. Supports interactive shell,
# inline remote commands, or running a local script file remotely.
#
# Usage:
#   ssh-pg.sh <resource-name> [N | --idx N]                    # interactive shell
#                                                              # (positional N is for back-compat with the prior
#                                                              #  `ssh-pg.sh <name> [server-index]` form)
#   ssh-pg.sh <resource-name> [N | --idx N] -- <remote cmd>    # one-shot command
#   ssh-pg.sh <resource-name> [N | --idx N] --script <file>    # run local script remotely
#
#   --idx N    0-based server index when the resource has multiple servers (default: 0)
#   --script   pipe the named local file via stdin to `bash -s` on the remote

set -euo pipefail

RESOURCE_NAME="${1:?Usage: ssh-pg.sh <resource-name> [N | --idx N] [-- <cmd> | --script <file>]}"
shift

SERVER_INDEX=0
SCRIPT_FILE=""
REMOTE_CMD=()

# Back-compat: a bare numeric first positional is the server index.
if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
  SERVER_INDEX="$1"
  shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --idx)
      [ $# -ge 2 ] || { echo "Missing value for --idx" >&2; exit 1; }
      SERVER_INDEX="$2"; shift 2 ;;
    --script)
      [ $# -ge 2 ] || { echo "Missing value for --script" >&2; exit 1; }
      SCRIPT_FILE="$2"; shift 2 ;;
    --)
      shift; REMOTE_CMD=("$@"); break ;;
    *)
      echo "Unknown arg: $1" >&2
      echo "Usage: ssh-pg.sh <resource-name> [N | --idx N] [-- <cmd> | --script <file>]" >&2
      exit 1 ;;
  esac
done

KEY_FILE="/tmp/pg_ssh_key_$$"
cleanup() { rm -f "$KEY_FILE"; }
trap cleanup EXIT

SSH_INFO=$(RACK_ENV=development bundle exec ruby -r ./loader -e '
  r = PostgresResource.first(name: ARGV[0]) or abort "Resource not found: #{ARGV[0]}"
  s = r.servers[ARGV[1].to_i]&.vm&.sshable or abort "Server or sshable not found at index #{ARGV[1]}"
  File.write(ARGV[2], s.keys.first.private_key)
  File.chmod(0600, ARGV[2])
  puts "#{s.unix_user}@#{s.host}"
' -- "$RESOURCE_NAME" "$SERVER_INDEX" "$KEY_FILE")

SSH_OPTS=(-i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

if [ -n "$SCRIPT_FILE" ]; then
  [ -f "$SCRIPT_FILE" ] || { echo "Script file not found: $SCRIPT_FILE" >&2; exit 1; }
  exec ssh "${SSH_OPTS[@]}" "$SSH_INFO" 'bash -s' <"$SCRIPT_FILE"
elif [ ${#REMOTE_CMD[@]} -gt 0 ]; then
  exec ssh "${SSH_OPTS[@]}" "$SSH_INFO" "${REMOTE_CMD[@]}"
else
  echo "Connecting to ${SSH_INFO}..." >&2
  exec ssh "${SSH_OPTS[@]}" "$SSH_INFO"
fi
