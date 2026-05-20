---
name: ubicloud-bench
description: Run pgbench (TPC-B) and HammerDB TPC-C benchmarks against an Ubicloud-managed Postgres server, using a dedicated EC2 bench client provisioned via AWS CLI. Use when the user wants to measure PG throughput/latency or stress-test a particular instance size.
user-invocable: true
---

# Ubicloud benchmark framework

This skill drives a complete benchmark workflow:

1. **Provision** an EC2 bench client (in its own VPC, same physical AZ as the target PG) — `.devcontainer/scripts/bench/bench-provision.sh`.
2. **Run** pgbench or HammerDB TPC-C against an Ubicloud-managed PG over the public network — `bench-run.sh`.
3. **Fetch** result logs back to the dev container via scp — `bench-fetch.sh`.
4. **Tear down** everything when done — `bench-destroy.sh`.

Connectivity is plain SSH/SCP. The bench client's security group opens port 22 only to the dev container's current egress IP (auto-detected via `checkip.amazonaws.com`, or pass `--ssh-cidr` to override). The bench client is always **amd64** because HammerDB upstream ships only x86_64 binaries — see [Architecture pinning](#architecture-pinning) below.

## Quick reference

| Script | Purpose |
|---|---|
| `.devcontainer/scripts/bench/bench-provision.sh <pg-name> --cores N \| --instance-type T [--name V]` | Bootstrap VPC + SG + IAM + EC2 + install payloads |
| `.devcontainer/scripts/bench/bench-run.sh <vm> {pgbench\|tpcc} [--detached\|--stream] -- <workload args>` | Launch a benchmark on the client |
| `.devcontainer/scripts/bench/bench-tail.sh <vm>` | Stream `tail -F` of the live run log over SSH |
| `.devcontainer/scripts/bench/bench-fetch.sh <vm> [dest-dir]` | scp `/var/log/bench/` to local |
| `.devcontainer/scripts/bench/bench-destroy.sh <vm>` | Tear down EC2 + VPC + SG + keypair + close PG firewall rule |
| `.devcontainer/scripts/bench/ssh-vm.sh <vm> [-- <cmd>]` | SSH into the VM (interactive shell or one-shot command) |
| `.devcontainer/scripts/bench/pg-info.sh <pg-name>` | eval-able env vars: `PG_IP`, `PG_PWD`, `SRV_INST`, `SRV_AZ` |
| `.devcontainer/scripts/psql-pg.sh <pg-name> [psql args]` | psql directly against the PG resource over its public endpoint (reads hostname+password from API) — use for ad-hoc queries, wait-event sampling, etc. |

`AWS_PROFILE` defaults to `pg-dev-postgresqladmindev` in every bench script — caller doesn't need to `export` anything. To override, set `AWS_PROFILE=...` before invoking.

## Typical full workflow

```bash
# 1. Provision a PG (use the ubicloud-onebox skill or the API directly)
.devcontainer/scripts/invoke_ubicloud_api_curl.sh POST \
  /project/default/location/us-west-2-cell-0/postgres/bench-pg \
  -d '{"size":"m8gd.2xlarge","storage_size":474}'
.devcontainer/scripts/wait_for_postgres_state.sh bench-pg running 900

# 2. Provision a bench client in the same physical AZ as the PG primary
.devcontainer/scripts/bench/bench-provision.sh bench-pg --cores 8 --name bench-cli

# 3. Run a benchmark (detached; tmux on the VM; returns immediately)
.devcontainer/scripts/bench/bench-run.sh bench-cli tpcc -- \
  --build --run --warehouses 100 --build-vu 8 --vu 32 --rampup 2 --duration 5

# 4. Observe progress (optional)
.devcontainer/scripts/bench/bench-tail.sh bench-cli
#   or:
.devcontainer/scripts/bench/ssh-vm.sh bench-cli           # interactive

# 5. Fetch results
.devcontainer/scripts/bench/bench-fetch.sh bench-cli results/bench-cli

# 6. Tear down
.devcontainer/scripts/bench/bench-destroy.sh bench-cli
.devcontainer/scripts/invoke_ubicloud_api_curl.sh DELETE \
  /project/default/location/us-west-2-cell-0/postgres/bench-pg
```

## Parameter recommendations by PG size

For OLTP saturation runs, both warehouse count and vuser count are tuned to the **PG** vCPU count (the bench client is rarely the bottleneck for OLTP).

### pgbench (TPC-B)

`bench-run.sh <vm> pgbench [--detached|--stream] -- --init --scale S --clients C --threads T --time SEC [--no-vacuum] [--protocol prepared]`

| PG size | vCPU | scale | clients | threads | time |
|---|---:|---:|---:|---:|---:|
| m8gd.large    | 2  | 5   | 8   | 2 | 60 |
| m8gd.xlarge   | 4  | 10  | 16  | 4 | 120 |
| m8gd.2xlarge  | 8  | 50  | 64  | 8 | 300 |
| m8gd.4xlarge  | 16 | 100 | 128 | 16 | 300 |

Use `-M prepared` and `-N` flag (skip branches/tellers updates) for peak TPS — they remove client-side parsing overhead and a small-table lock-contention hot spot respectively. Pass them via `-- ... -- -N -M prepared`.

### Diagnosing the bottleneck mid-run

While a bench is active, sample `pg_stat_activity.wait_event` directly from the dev container — `psql-pg.sh` is a thin wrapper that reads the PG resource's hostname/password from the Ubicloud API and runs `psql` over the public endpoint:

```bash
.devcontainer/scripts/psql-pg.sh <pg-name> -c "
  SELECT wait_event_type, wait_event, count(*)
  FROM pg_stat_activity
  WHERE state='active' AND pid <> pg_backend_pid()
  GROUP BY 1,2 ORDER BY 3 DESC LIMIT 20"
```

| Dominant wait | Bottleneck | Fix |
|---|---|---|
| `LWLock:WALWrite` | WAL flush serialization (bgwriter starving) | bump `bgwriter_lru_maxpages` |
| `IO:DataFileRead` | Buffer cache too small / cold | bump PG size or scale down workload |
| `Lock:transactionid` | Row-level lock contention | use `-N` for pgbench; back off `--vu` for TPC-C |
| `Client:ClientRead` | Bench client-side bound, PG idle | bench client too small |
| _(empty)_ + `state=active` | PG is CPU-bound — what you want for saturation | — |

### HammerDB TPC-C

`bench-run.sh <vm> tpcc [--detached|--stream] -- --build [--run] --warehouses W --build-vu B --vu V --rampup R --duration D [--tpcc-dbase tpcc] [--tpcc-user tpcc] [--tpcc-pass tpcc]`

| PG size | vCPU | warehouses | build-vu | vu | rampup | duration | expected NOPM |
|---|---:|---:|---:|---:|---:|---:|---:|
| m8gd.large    | 2  | 50  | 2  | 12 | 1 | 10 | ~100k |
| m8gd.xlarge   | 4  | 75  | 4  | 16 | 1 | 5  | ~200k |
| m8gd.2xlarge  | 8  | 100 | 8  | 32 | 2 | 5  | ~300–600k |
| m8gd.4xlarge  | 16 | 200 | 16 | 64 | 2 | 10 | ~600k–1.2M |

Rules of thumb behind these numbers:
- **warehouses ≈ 10–20 × PG vCPU** — small enough that the working set spills past `shared_buffers` (forcing buffer-manager exercise) but stays in OS page cache (keeps the test CPU-bound, not I/O-bound).
- **vu ≈ 4 × PG vCPU** — TPC-C is bursty OLTP, ~25% CPU-busy per vuser. 4× saturates 2 cores per vuser comfortably without dropping into lock-wait territory. Going beyond ~8× usually *decreases* NOPM due to contention.
- **build-vu = PG vCPU** — one bulk-loader per server core; more than that doesn't help.
- **duration ≥ 5 min** rides past one full checkpoint cycle (PG default 5 min) for stable steady-state numbers. Shorter runs give artificially-low or artificially-high results depending on where the checkpoint storm lands.

## Reading the results

After `bench-fetch.sh`, results land in `<dest-dir>/bench/`:

```
bench/
├── latest.log → pgbench-YYYYMMDD-HHMMSS.log   # or tpcc-…
├── pgbench-…log
├── tpcc-…log                                  # bench-side stdout from the run
└── hammerdb/
    ├── hammerdb_<runid>.log                   # ← look for "TEST RESULT" here
    ├── hdbxtprofile.log                       # per-vuser, per-proc latency profile
    └── hammer.DB                              # HammerDB's internal job state
```

The TPC-C money line:

```bash
grep "TEST RESULT" results/<vm>/bench/hammerdb/hammerdb_*.log
# Vuser 1:TEST RESULT : System achieved 311062 NOPM from 715345 PostgreSQL TPM
```

`hdbxtprofile.log` gives per-procedure (NEWORD, PAYMENT, DELIVERY, SLEV, OSTAT) call counts and P50/P95/P99 latencies — useful for diagnosing which transaction type is the bottleneck.

pgbench has its summary inline in the bench-side log: search for `tps = ` and `latency average = `.

## Architecture pinning

`bench-provision.sh` **rejects arm64 instance types** with a clear error:

```
ERROR: requested i8ge.2xlarge is arm64; bench framework requires amd64
       (HammerDB upstream is x86_64-only). Pick an amd64 instance type
       (e.g., m6id.* m7i.* m8i.*).
```

Reason: `tpcorg/hammerdb` Docker image has no arm64 variant, and the upstream HammerDB GitHub release ships no aarch64 binary tarball. The bench client's architecture has **no bearing on PG throughput** — they're network peers — so pinning amd64 lets us run TPC-C natively against an arm64 (Graviton) PG without QEMU emulation.

For pgbench, arm64 bench clients would technically work (pgbench is in `postgresql-contrib`, available for arm64), but for consistency the framework rejects them across the board.

## Cross-AZ vs same-AZ — load-bearing detail

`bench-provision.sh` automatically pins the bench client to the **physical** AZ of the PG primary, using AWS's account-independent **AZ-ID** (e.g., `usw2-az1`), not the per-account-logical AZ name. This is non-negotiable for meaningful benchmarks — cross-AZ vs same-AZ shows ~**2× difference in TPS** (per prior measurements: 11.5k cross-AZ vs 21k+ same-AZ on m8gd.2xlarge).

`pg-info.sh` queries Ubicloud's DB for `aws_instance.az_id` and bench-provision uses it directly. To override, pass `--az usw2-az3` explicitly.

To verify after provisioning:

```bash
.devcontainer/scripts/bench/ssh-vm.sh <vm> -- 'curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone-id'
```

Should match the PG's AZ-ID.

## --detached vs --stream

| Mode | Behavior |
|---|---|
| `--detached` (default) | Run launches in `tmux new -d -s bench` on the VM; script returns immediately. Use `bench-tail.sh` to observe. |
| `--stream` | `ssh -t` blocking; output streams to local terminal. |

Use `--detached` for long runs (hours). Use `--stream` for short interactive smokes when you want real-time feedback. Plus `--destroy-on-finish` (only in `--stream` mode) for one-shot tests that auto-clean.

## SSH-ingress CIDR — the one knob to understand

`bench-provision.sh` auto-detects the dev container's current public egress IP via `curl -s https://checkip.amazonaws.com` and opens the SG **only** to that `/32`. If your egress IP changes mid-session (corporate VPN reconnect, Codespaces NAT rotation, ISP DHCP renewal), SSH stops working.

Three ways to handle that:

1. **Re-provision** — bench VMs are short-lived, and the new run picks up the new IP. Simplest.
2. **Pass `--ssh-cidr` explicitly** at provision time — e.g., a corp NAT range, or a tighter prefix.
3. **Update the SG by hand**: `aws ec2 authorize-security-group-ingress --group-id <SG_ID> --protocol tcp --port 22 --cidr <NEW>/32` (and `revoke-security-group-ingress` to drop the stale rule).

## What gets created in AWS

For each `bench-provision.sh` run (tags: `Project=ubicloud-bench`, `BenchName=<vm-name>`):

- VPC `10.99.0.0/16`
- Subnet `10.99.1.0/24` in the target AZ
- Internet gateway + route table (default → IGW)
- Security group with one ingress rule (port 22 from `$SSH_CIDR`)
- EC2 keypair `<vm-name>` (private key written to `/tmp/bench_ssh_key_<vm-name>`, 0600)
- EC2 instance (no IAM role attached; no AWS API access from the VM)
- One firewall-rule pair on the PG resource (5432 + 6432) opening the bench client's public IP

No shared resources across runs — everything is per-VM and `bench-destroy.sh` cleans it all.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ssh: connect to host … port 22: Operation timed out` after a working session | Dev container's egress IP rotated; the auto-detected `/32` is now stale | Re-provision, or refresh the SG rule (see "SSH-ingress CIDR" above) |
| `Permission denied (publickey)` | `/tmp/bench_ssh_key_<vm-name>` got recreated/deleted, or keypair mismatch | Re-provision |
| `exec format error` running HammerDB | Bench client is arm64 (shouldn't happen — `bench-provision.sh` rejects arm64) | Use an amd64 instance type |
| TPC-C exits in <30 s with no `TEST RESULT` | TCL build failed before the run phase; check `tpcc-…log` for the specific error (db already exists, network unreachable, etc.) | Inspect; if PG `tpcc` db left over from a prior run, drop it on PG first |
| pgbench reports `pgbench was not found in /usr/lib/postgresql/18/bin` | Older `setup.sh` (didn't install `postgresql-contrib`) | Re-provision with current `setup.sh`; the current version installs `postgresql-contrib` for `pgbench` |

## Permission allowlist

The single pattern that needs to be in `.claude/settings.json` for the user to run any of the above without prompting:

```json
"Bash(.devcontainer/scripts/bench/*.sh*)"
```

That's already present in the repo's settings. Two pitfalls to be aware of:

1. **Pipes break pattern matching** (per `CLAUDE.md`): `.../bench-fetch.sh foo | tail -5` won't match. Let scripts handle their own output trimming, or redirect via `>file`.
2. **Absolute paths don't match the relative glob**: use `.devcontainer/scripts/bench/<script>.sh`, not `/workspaces/ubicloud-3/.devcontainer/...`.
