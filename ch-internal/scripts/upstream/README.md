# Upstream sync

Automation that merges `ubicloud/ubicloud:main` into `ClickHouse/ubicloud:clickhouse` as a daily PR.

## When it runs

- **Cron** — `13:00 UTC Mon–Fri` (06:00 PDT / 05:00 PST), via `.github/workflows/ch-internal-daily-upstream-sync.yml`.
- **Manual** — `gh workflow run ch-internal-daily-upstream-sync.yml --repo ClickHouse/ubicloud --ref <branch>` (use `--ref <branch>` to test script changes from a feature branch without merging to `clickhouse` first).
- **Local** — `./adhoc.sh` from this directory; stops with instructions if conflicts can't be auto-resolved.

## Pipeline

### Process

1. **The pipeline**: 
    -   fetches `ubicloud/main`, branches off `clickhouse`, merges, refreshes schema/model caches, opens a PR with `upstream-sync-auto` label. 
    -   On a clean merge: ready-for-review PR, CI and E2E auto-dispatched. 
    -   On conflicts: commits the markers verbatim and opens as **draft** with the `upstream-sync-conflict` label and the conflicted-file list.

2. **The reviewer** treats the PR like any other code change: walk the upstream commit list (annotated with `[m]` / `[fork]` markers for migrations and fork-modified files), confirm CI + `require-pg-e2e` are green, merge.

3. **The reviewer on a conflict PR** resolves the markers locally, force-pushes, marks the PR ready when E2E completes (the gate workflow auto-dispatches E2E once markers are gone). Marking ready is the takeover signal that prevents the next daily run from superseding the PR.

4. **The bot, next day** — replaces the previous day's PR with a fresh sync, unless one of the [actions in *Daily PR overwrite*](#daily-pr-overwrite) was taken on it.

### Conflict resolution

Bot opens the PR as draft with the `upstream-sync-conflict` label and the merge body lists the conflicted files.

```bash
git fetch origin sync/upstream-<DATE>
git checkout sync/upstream-<DATE>
# resolve markers in your editor
git add -- <files>
git commit --amend                      # edit the merge body to drop the resolved-files section
git push --force-with-lease
```

The push fires `ch-internal-pg-ubicloud-e2e-gate.yml`, which:

1. Confirms no `<<<<<<<` markers remain.
2. Auto-dispatches `ch-internal-pg-ubicloud-ci-e2e.yml`.
3. Updates the sticky `## Pre-merge checks` comment on the PR.
4. When E2E completes, flips the `require-pg-e2e` status to `success` (or `failure`).

When CI + `require-pg-e2e` are green, mark the PR **Ready for review** and merge.

### E2E gate (`require-pg-e2e`)

`.github/workflows/ch-internal-pg-ubicloud-e2e-gate.yml` posts the `require-pg-e2e` commit status on every PR against `clickhouse`:

- Non-sync PR (no `upstream-sync-auto` label and head ref doesn't start with `sync/upstream-`) → `success` immediately.
- Sync PR → mirrors the latest `pg-ubicloud-ci E2E` run for the head SHA.

Make `require-pg-e2e` a required status check in the `clickhouse` branch protection rule to enforce.

### Daily PR overwrite

Each daily run replaces the previous day's open sync PR with a new one — the old PR is closed with a "superseded" comment (its branch retained for 14 days for recovery), and a fresh sync begins. This keeps the open PR aligned with the current `upstream/main` tip.

The replacement is **skipped** — and the existing PR preserved — if any one of these actions was taken on it:

- An assignee is set.
- The PR carries `upstream-sync-conflict` and is no longer draft (the conflict was resolved and the PR was marked ready).
- A commit was pushed on top of the bot's merge (head SHA differs from the `sync-bot/<branch>` tag).

### Cleanup

`daily.sh` step 8 deletes remote `sync/upstream-*` branches (and their `sync-bot/*` tags) older than 14 days that have no open PR.

## Reference

### Scripts used by the pipeline

| Stage | Script | What it does |
|-------|--------|--------------|
| 0 | `daily.sh` | Orchestrator. Dedup/supersede, glue, tag, cleanup. |
| 1 | `01_initiate.sh` | Fetch upstream, branch off `clickhouse`, merge, run `rake test_up` (refreshes schema/static caches + model annotations), commit. Auto-resolves `cache/*` conflicts to upstream's. |
| 2 | `02_create_pr.sh` | Push branch, open PR with the upstream-commit list marked `[m]` (touches `migrate/`) and `[fork]` (touches a fork-modified file). |
| 3 | `03_dispatch_workflow.sh` | `gh workflow run` for `ch-internal-ubimirror-ci.yml` + `ch-internal-pg-ubicloud-ci-e2e.yml`. Skipped by `daily.sh` on the conflict path. |
| local | `adhoc.sh` | Local entry point. Runs 1 → 2 → 3 with defaults (interactive conflict resolution); prints stage-specific next-steps if any step fails. |

### PR Labels and Tags

| Signal | Set by | Means |
|--------|--------|-------|
| Label `upstream-sync-auto` | Stage 2, every bot PR | Dedup discriminator. |
| Label `upstream-sync-conflict` | `daily.sh` step 5 | Bot committed conflict markers; PR opens as draft. |
| Tag `sync-bot/<branch>` | `daily.sh` step 6 | Points at the bot's merge commit. Compared against PR head SHA next day. |
| Draft state | Stage 2 (`SYNC_PR_DRAFT=1`) | Conflict PRs only. Marking ready = takeover. |


### Knobs

| Env var | Default | Effect |
|---------|---------|--------|
| `SYNC_COMMIT_CONFLICTS` | unset | Set `=1` to commit conflict markers verbatim instead of stopping (used by `daily.sh`). |
| `SYNC_PR_DRAFT` | unset | Set `=1` to open the PR as draft (used by `daily.sh` on the conflict path). |
