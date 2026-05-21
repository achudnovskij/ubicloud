#!/bin/bash
# Bench VM setup — runs on the VM via SSH from bench-provision.sh as root (sudo).
# Reads payloads (bench.env, run-* scripts, TCL templates) from $PAYLOAD_DIR
# (default /tmp/bench-payloads) and installs them to canonical paths.

set -euo pipefail

PAYLOAD_DIR="${PAYLOAD_DIR:-/tmp/bench-payloads}"
TARGET_USER="${TARGET_USER:-ubi}"
HAMMERDB_IMAGE="${HAMMERDB_IMAGE:-tpcorg/hammerdb:latest}"

echo "=== bench setup start $(date -Is) ==="

export DEBIAN_FRONTEND=noninteractive

# Wait for any cloud-init / unattended-upgrades to release apt locks.
for _ in $(seq 1 60); do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     && ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

# PG-flavor AMIs ship an S3-backed apt source (pg-packaging-s3.sources) the bench
# VM's instance role can't read; remove it so apt-get update exits 0.
rm -f /etc/apt/sources.list.d/pg-packaging-s3.sources

apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq tmux psmisc \
  postgresql-client postgresql-contrib \
  docker.io

systemctl enable --now docker
usermod -aG docker "$TARGET_USER" || true

install -d -m 755 /opt/bench/hammerdb /var/log/bench
chown -R "$TARGET_USER:$TARGET_USER" /var/log/bench
# HammerDB's logtotemp writes /tmp/hammerdb_*.log inside the container; bind
# /var/log/bench/hammerdb to /tmp so those logs (and the hammer.DB jobs file)
# survive the container's --rm. Mode 0777 because the container user (uid 1001
# in tpcorg/hammerdb) is different from the host TARGET_USER.
install -d -m 0777 /var/log/bench/hammerdb

install -m 600 -o "$TARGET_USER" -g "$TARGET_USER" "$PAYLOAD_DIR/bench.env" /etc/bench.env
install -m 755 "$PAYLOAD_DIR/run-pgbench.sh"        /usr/local/bin/run-pgbench.sh
install -m 755 "$PAYLOAD_DIR/run-hammerdb-tpcc.sh"  /usr/local/bin/run-hammerdb-tpcc.sh
install -m 644 "$PAYLOAD_DIR/hammerdb/build.tcl"    /opt/bench/hammerdb/build.tcl
install -m 644 "$PAYLOAD_DIR/hammerdb/run.tcl"      /opt/bench/hammerdb/run.tcl

docker pull "$HAMMERDB_IMAGE" || echo "WARN: failed to pre-pull $HAMMERDB_IMAGE — will pull on first run"

# Quick connectivity smoke test (non-fatal).
. /etc/bench.env
PGPASSWORD="$PG_PASS" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DEFAULT_DBASE" \
  -tAc "SELECT version();" || echo "WARN: PG connectivity check failed"

date -Is >/var/run/bench-ready
echo "=== bench setup done $(date -Is) ==="
