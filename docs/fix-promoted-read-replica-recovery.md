# Fix: Promoted Read Replica Stays in Read-Only Recovery Mode

## Problem

When a PostgreSQL read replica is promoted via `POST .../promote-read-replica`,
the PostgreSQL instance remains in recovery mode (read-only) indefinitely. Any
attempt to write to the promoted server fails with:

```
ERROR: cannot execute CREATE TABLE in a read-only transaction
```

## Root Cause

Commit `a20c50117` ("Simplify read replica promotion", by Burak Yucesoy,
2026-02-19) removed the `when_promote_set?` handler that routed promotion
through the `taking_over` label. That label ran `postgres/bin/promote` via
daemonizer, which called `pg_ctlcluster promote` to bring PostgreSQL out of
recovery. The replacement path only calls `switch_to_new_timeline` and
increments `configure`, which never removes `standby.signal` or calls
`pg_promote()`.

Read replicas are initialized with a `standby.signal` file
(`rhizome/postgres/bin/initialize-database-from-backup:33`), which tells
PostgreSQL to stay in standby/recovery mode indefinitely, continuously fetching
WAL from the parent.

When the promote route is called (`routes/project/location/postgres.rb:344`), it:

1. Sets `restore_target = Time.now` on the resource
2. Calls `switch_to_new_timeline` on the server (creates a new timeline, sets
   `timeline_access: "push"`)
3. Increments the `configure` semaphore to trigger reconfiguration

The `configure` label (`prog/postgres/postgres_server_nexus.rb:396`) then:

1. Writes a clean config (no recovery settings, since `doing_pitr?` returns
   `false` for a server with `timeline_access: "push"`)
2. Reloads/restarts PostgreSQL

However, PostgreSQL remains in recovery because `standby.signal` still exists in
the data directory. PostgreSQL will not exit recovery mode just because the
config changed -- it requires either:

- Removal of `standby.signal`, or
- An explicit call to `pg_promote()`

The `wait_recovery_completion` label handles exactly this (checking recovery
state and calling `pg_wal_replay_resume()`), but it is only reached during
initial provisioning via the `when_initial_provisioning_set?` guard. For an
already-running server being promoted, `configure` skips straight to `hop_wait`.

## Fix

Added a recovery check in the `configure` label for primary servers. After
configure succeeds (outside initial provisioning), if the server's model says it
is primary (`timeline_access == "push"`) but PostgreSQL reports
`pg_is_in_recovery() = true`, we call `pg_promote()` to exit recovery mode.

### Changed files

- **`prog/postgres/postgres_server_nexus.rb`** -- Added `pg_is_in_recovery()`
  check and `pg_promote()` call in the `configure` label for primary servers.
  Includes `rescue FlowControl; raise` to avoid catching strand control flow
  exceptions (since `Nap < FlowControl < RuntimeError < StandardError`).

- **`spec/prog/postgres/postgres_server_nexus_spec.rb`** -- Added test cases:
  - Primary still in recovery after configure triggers `pg_promote()` and naps 1s
  - Connection error during recovery check triggers nap 5s (graceful retry)
  - Updated existing primary configure tests to mock the `run_query` call

## Why this is safe

- `pg_promote()` is a no-op if PostgreSQL is already primary
- The check only runs when the server model says primary but PG disagrees
- On failure (e.g., PG not yet accepting connections), it naps 5s and retries on
  next configure cycle
- The `nap 1` after `pg_promote()` gives PostgreSQL time to complete promotion
  before the strand proceeds
