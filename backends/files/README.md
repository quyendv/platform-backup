# files

`ghcr.io/quyendv/platform-backup/files`

Backs up a selection of files under one directory as a `tar.zst`, and checks
the selection before the run is kept: paths that must be there, and paths that
must never be. For applications whose state is a directory rather than a
database: a CI server's home, a reverse proxy's configuration tree, an
application's settings directory.

The choices below were measured; the record is
[the design](../../docs/superpowers/specs/2026-10-23-files-backend-design.md).
[examples/jenkins/](examples/jenkins/) is a complete, tested case.

## Choosing what to take

A directory usually holds far more than its state: on the Jenkins home the
design measured, ~60 GB of caches, logs and workspaces around 88 MB of state.
Taking "the directory" is the expensive mistake; leaving out one essential
file is the dangerous one, because the archive is still valid and restores into
something unusable. Four variables express the selection:

- **`FILES_INCLUDE`** — paths or bash globs relative to `FILES_ROOT`, separated
  by spaces or newlines. `**` crosses directories. The image expands them
  itself (tar does not expand globs in the names it is given), so
  `plugins/*/META-INF/MANIFEST.MF` takes one small file per plugin and nothing
  else. **Every entry must match something**: a typo or a moved file fails the
  run instead of quietly shrinking the backup. Globs do not match dotfiles
  unless they name them (`.ssh/known_hosts`).
- **`FILES_EXCLUDE`** — GNU tar `--exclude` patterns. Wildcards cross `/` and a
  pattern matches at any depth, so `jobs/*/builds` also drops
  `jobs/a/jobs/b/builds`. **An exclusion beats an include**: a file named in
  `FILES_INCLUDE` under an excluded directory is still left out. To keep one
  kind of file out of an excluded subtree, exclude its siblings by name instead.
- **`FILES_REQUIRE`** — paths that must be in the archive. A run without one
  fails before it is kept, so a selection cannot silently lose the file that
  makes the rest usable.
- **`FILES_FORBID`** — patterns no archived path may match, with the same rules
  as `FILES_EXCLUDE`. A run that would ship one fails. Name your keys here even
  when `FILES_EXCLUDE` already leaves them out: that turns "the key is never in
  the backup" from a convention into a checked property.

Paths containing whitespace cannot be written as they are; a glob reaches
them (`my?dir` for `my dir`).

## How the copy is made

- `tar --numeric-owner` through `zstd -10`, streamed, from the expanded list.
- **A file that changes while it is read, and is still there afterwards, fails
  the run** (tar exit 1). A torn file uploaded as a good backup is worse than a
  failed run, which is reported and tried again at the next schedule. Logs
  written in place do this, which is one more reason to exclude them.
- **Saving by temp file and rename does not fail it** (most applications,
  Jenkins included). That makes tar report a directory whose entries changed, a
  temp file removed before it was read, or a temp file that changed and was
  renamed away before tar finished. None of those tears a file the application
  uses, so each is logged as a warning. The temp files themselves may land in
  the archive; exclude them by name if you know it (the Jenkins example does).
- Consistency is per file, not across files: two files changed together can be
  archived one before and one after the change.
- Before a run is kept, verify reads the whole archive back: valid zstd, a
  readable tar with at least one entry, every `FILES_REQUIRE` path present and
  no `FILES_FORBID` match. A run that fails it never becomes a run directory.

## Variables

| Variable | Required | Default | Notes |
|---|:--:|---|---|
| `FILES_ROOT` | ✅ | — | The directory backed up, as mounted in the container |
| `FILES_INCLUDE` | | `.` | Paths or globs to take; each must match |
| `FILES_EXCLUDE` | | *(empty)* | tar `--exclude` patterns |
| `FILES_REQUIRE` | | *(empty)* | Paths every archive must hold |
| `FILES_FORBID` | | *(empty)* | Patterns no archived path may match |
| `FILES_RESTORE_TARGET` | | `FILES_ROOT` | Where restore extracts |
| `FILES_RESTORE_OVERWRITE` | | `false` | Allow restore into a non-empty target |

Plus the [shared variables](../../README.md#environment).

## Running it

Backups only read. Run as root (the image's default) with every capability
dropped except `DAC_READ_SEARCH`, which reads any file whatever its owner, and
mount the directory **read-only**:

```bash
docker run --rm --cap-drop ALL --cap-add DAC_READ_SEARCH \
  -v /srv/app:/data:ro \
  -e FILES_ROOT=/data -e FILES_INCLUDE='config *.yaml' -e FILES_EXCLUDE='cache' \
  -e AWS_ACCESS_KEY_ID=xxx -e AWS_SECRET_ACCESS_KEY=yyy \
  -e AWS_ENDPOINT_URL_S3=https://minio.example.com \
  -e S3_BUCKET=backups -e S3_PREFIX=backups/app \
  ghcr.io/quyendv/platform-backup/files:latest
```

In Kubernetes, [k8s/cronjob.yaml](k8s/cronjob.yaml) mounts the claim read-only
next to the application (`podAffinity`, for ReadWriteOnce volumes).

## Docker

[`docker/compose.yaml`](docker/compose.yaml) runs the image on a schedule, with
a pinned release tag and a persistent `/backup` volume.

```bash
cd backends/files/docker
cp ../.env.example .env        # FILES_*, FILES_SOURCE, the S3 settings, SCHEDULE
docker compose up -d
docker compose run --rm backup run   # one backup now
docker compose ps                    # (healthy) once a run has succeeded
```

`FILES_SOURCE` is the host directory, mounted read-only at `/data`. With
`SCHEDULE` set, add `RESTART_POLICY=unless-stopped` so the container comes back
after a reboot; with `SCHEDULE` empty it takes one backup and exits, and the
restart policy must stay `no`.

## Restore

Restore verifies the archive first, then extracts it with owners, modes and
numeric ids as archived. It needs root with `CHOWN`, `DAC_OVERRIDE` and `FOWNER`
and a writable target.

- **The target must be empty** (a directory holding only `lost+found` counts as
  empty). That is the common case: a rebuilt server, a new volume. It is
  created if missing.
- **`FILES_RESTORE_OVERWRITE=true`** extracts over a non-empty target: archived
  files replace their namesakes, **nothing else is touched or deleted**. Stop
  the application first; a running one cannot be detected.
- Excluded files are not restored, by definition. Whatever the application
  needs that the backup deliberately leaves out (a key held elsewhere, plugins
  downloaded again) is a step of your own runbook.
- **One file out of a run:** `MODE=fetch` with `FETCH_DECOMPRESS=true`
  downloads and unpacks the `.tar`, then `tar -xf` what you need.

```bash
docker compose run --rm restore    # newest run into FILES_RESTORE_DIR (./restored)
```

`RESTORE_TIMESTAMP=YYYYMMDD_HHMMSS` picks a run; empty is the newest.

## Limits

- Consistency is per file (above).
- Empty directories that match no include are not recreated.
- One directory per run. Several roots are several releases (or several
  services in one compose file).
