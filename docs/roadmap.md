# Roadmap

Work that has been considered and deliberately not started. An entry is a
checklist to pick up later, not a commitment.

## Deduplicated filesystem backups (restic or kopia)

The `files` backend writes a whole `tar.zst` on every run. That is the right
shape until a tree is large and changes little per run, such as a Jenkins home
with its build history, or repositories on a git server. Then every run pays
for the full size in time, upload and storage.

- [ ] Confirm the need on a real tree: archive size, daily change rate, run
      time and storage cost of the current `files` backend.
- [ ] Choose the tool. Default to restic: one binary, suited to a job that runs
      and exits, S3 backend, encrypted repository. Evaluate kopia only if
      per-path policies or its server turn out to be needed.
- [ ] Make it a new backend rather than a mode of `files`. There is no single
      artifact to checksum and no run folder to prune, so it cannot follow
      `backend_dump`. It is the first backend that needs a change in `lib/`:
      keep `_run_and_report` and the notifier, and replace the
      artifact, checksum and prune steps.
- [ ] Give it its own `S3_PREFIX`. `prune_select` must never see a repository,
      and `forget --prune` must never see run folders.
- [ ] Decide retention (`forget --keep-*`) and how `KEEP_REMOTE` maps to it, and
      when the memory- and time-hungry `prune` runs.
- [ ] Handle stale repository locks left by a killed job, without unlocking a
      repository another job is really using.
- [ ] Schedule `check`, including a `--read-data-subset`, and report its outcome
      like any other run.
- [ ] Manage the repository password. It is lost-key-means-lost-data, like any
      backup encryption key: keep a second copy offline.
- [ ] Settle consistency per application. A deduplicating tool still reads a
      live tree. For git, prefer a mirror or `git bundle`, or a volume snapshot,
      over reading a repository mid-write. For Jenkins, `builds/` is
      append-mostly and suits this well.
- [ ] Add a restore drill to `test:integration`, and measure backup and restore
      on a synthetic tree before documenting any numbers.

## PostgreSQL: several databases in one job

One job backs up one database today.

- [ ] Decide what is worth orchestrating across databases beyond running one
      job per database.
- [ ] Decide where globals belong: one shared dump or one alongside each
      database, and how restore finds and applies them.

## PostgreSQL: faster dump and restore of large databases

The custom-format dump is single-threaded, and restore streams through a pipe,
which cannot use `pg_restore -j`.

- [ ] Measure dump and restore on a synthetic dataset first to identify the
      bottleneck before changing the artifact format.
- [ ] Evaluate a directory format for parallel dump, or a seekable archive for
      parallel restore, including the local disk space each needs.
- [ ] Decide how the format fits verification, compression, upload and fetch
      before adding parallelism controls.

## Migration beyond PostgreSQL and MongoDB

- [ ] Redis `MODE=migrate`: copy directly between servers, with identity guards
      before destructive operations and verification of the resulting keys.
- [ ] Evaluate migrate for etcd, Vault, SQLite and files separately; these
      backends currently refuse the mode.
- [ ] For continuous replication or near-zero downtime, use PostgreSQL logical
      replication or MongoDB `mongosync` instead of a one-time copy. Assess a
      separate long-running workflow before adding replication orchestration.
