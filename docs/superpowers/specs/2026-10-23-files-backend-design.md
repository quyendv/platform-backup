# files backend — design

Date: 2026-10-23
Status: draft, awaiting review
Scope: a selection of files under one directory, archived as one `tar.zst` per run. The typical
case is an application whose state is a directory of configuration files rather than a database:
a CI server's home, a reverse proxy's config tree, an application's settings directory.

## Why this needs a record

Every other backend copies a database through that database's own tool. A directory has no such
tool and no consistent snapshot, and the hard part is not copying but **choosing**: the same
directory usually also holds caches, logs and build output that are hundreds of times larger than
the state worth keeping, and a selection that silently drops one essential file produces a backup
that restores into something unusable. The design below is shaped by that, and by three measured
facts about GNU tar that decide how selection is expressed.

## Measurements

Run on 2026-10-23 with GNU tar 1.35 and zstd 1.5.5 against a live Jenkins 2.580 home (166
plugins, ~980 job configs including multibranch children) while builds were running.

**Selection is the whole size.** The home directory held ~60 GB: ~30 GB of SCM caches, ~24 GB of
build logs, the rest workspaces and tool caches. The state needed to rebuild the server:

```
6578 entries, 88 MB raw -> 59 MB tar.zst (-10), ~1 s per run
```

A backup that takes "the directory" is three orders of magnitude larger than one that takes the
right parts of it.

**tar does not expand globs in the names it is given.** Expressing the selection only as
exclusions (`--exclude 'plugins/*.jpi'`, `--exclude 'plugins/*/WEB-INF'`, …) still archived
77 MB of unpacked plugin content, because every exclusion has to anticipate every file. The one
file per plugin that matters, `plugins/*/META-INF/MANIFEST.MF` (name and version, 0.2 MB for all
169), can only be *included* by name, and tar archives `plugins/*/META-INF/MANIFEST.MF` literally
or not at all. The include list is therefore expanded by the adapter, with bash `globstar`, and
handed to tar through `-T`.

**Exclusion wildcards cross `/`.** For `--exclude`, GNU tar's default is `--wildcards-match-slash`
and `--no-anchored`, so `jobs/*/builds` excluded build directories at every depth of nested
folders (`jobs/a/jobs/b/branches/c/builds`): 0 entries under any `/builds/` in the archive. The
same defaults mean `secrets/master.key` also excludes `x/secrets/master.key`. For exclusion that
breadth is the safe direction, and it is documented rather than changed.

**A directory written by atomic rename reads cleanly.** Three consecutive runs during builds: tar
exit 0, no warnings. The application writes its configuration as temp-file-then-rename, so tar
reads either the old inode or the new one whole. The files written in place (build logs) were
excluded. A directory written in place would produce `file changed as we read it` (tar exit 1),
which is handled below.

**Alpine's `tar` is BusyBox.** It has none of `-T` with globs expanded elsewhere, wildcard
exclusion semantics or `--numeric-owner` as measured above. The image installs GNU `tar`.

## Design

`backends/files/backend.sh`, following the adapter contract (`lib/` unchanged):

| Function | Behaviour |
|---|---|
| `backend_name` | `files` |
| `backend_caps` | `fetch restore` |
| `backend_validate` | `FILES_ROOT` required, an existing readable directory. Every `FILES_INCLUDE` entry must match at least one path (a typo or a moved file fails the run, it does not shrink the backup) |
| `backend_dump <dir>` | expand `FILES_INCLUDE` relative to `FILES_ROOT` (`globstar`, `nullglob` off), write the list to a file, `tar -C "$FILES_ROOT" --numeric-owner --wildcards -cf - --exclude … -T list \| zstd -10 -T0`; both statuses checked (PIPESTATUS); echoes `files-<run>.tar.zst` |
| `backend_verify <path>` | `zstd -t`; `tar -t` lists at least one entry; every `FILES_REQUIRE` path is present; no entry matches a `FILES_FORBID` pattern |
| `backend_restore <path>` | see below |

**tar exit 1 fails the run.** It means a file changed, or vanished, while it was read. A torn file
uploaded as a successful backup is silent corruption, which is worse than a failed run reported to
the operator; the next scheduled run tries again. If a real directory turns out to change under
every run, that is measured and revisited, not pre-empted with a tolerance switch.

**`FILES_REQUIRE` and `FILES_FORBID` turn the selection into something checked.** The two ways a
file selection fails are both silent: an essential file falls out of it (the archive is valid and
useless), or a file that must never leave the host falls into it (a key shipped next to what it
protects). `FILES_REQUIRE` names files whose absence fails verification; `FILES_FORBID` names
patterns whose presence does. Both run in `backend_verify`, before the run is promoted, so a
failed check never becomes a run directory.

Restore, in order, stopping at the first failure:

1. Verify the artifact as above.
2. The target is `FILES_RESTORE_TARGET`, default `FILES_ROOT`. If it is not empty, refuse unless
   `FILES_RESTORE_OVERWRITE=true`. The common restore is into a fresh, empty directory (a rebuilt
   server); writing over a live one is the exception and has to be asked for.
3. Extract with `--same-owner --numeric-owner --preserve-permissions`. With `OVERWRITE`, files in
   the archive replace their namesakes and **nothing else in the target is touched or deleted**.
   Restoring one file out of a run is `MODE=fetch` with `FETCH_DECOMPRESS=true` and a manual
   `tar -x`, not a restore.

Excluded files are not restored, by definition: whatever the application needs that the backup
deliberately leaves out (a key held separately, plugins downloaded again) is the operator's step,
and the backend's documentation says so.

### Variables

| Variable | Default | Meaning |
|---|---|---|
| `FILES_ROOT` | — | The directory archived; every other path is relative to it |
| `FILES_INCLUDE` | `.` | Paths or bash globs (`**` allowed), separated by whitespace or newlines. Each must match something |
| `FILES_EXCLUDE` | *(empty)* | GNU tar `--exclude` patterns: wildcards cross `/`, unanchored |
| `FILES_REQUIRE` | *(empty)* | Paths that must be in the archive, checked by verify |
| `FILES_FORBID` | *(empty)* | Patterns no archived path may match, checked by verify |
| `FILES_RESTORE_TARGET` | `FILES_ROOT` | Where restore extracts |
| `FILES_RESTORE_OVERWRITE` | `false` | Allow restore into a non-empty target |

Whitespace-separated lists mean a path containing whitespace cannot be named directly; a glob
matching it can (`'my dir'` → `my?dir`). Stated in the README.

Image: the shared Alpine base plus GNU `tar` and `zstd`. One image, no matrix.

## Running it

Backups only read. Run as root so every file is readable regardless of its owner, with every
capability dropped except `DAC_READ_SEARCH`, and mount the directory **read-only**: unlike SQLite
there is no lock to take part in, so nothing is ever written to it. Restore needs a writable mount
and `CHOWN`, `DAC_OVERRIDE`, `FOWNER` to put owners and modes back.

On Docker hosts the directory is a bind mount; in Kubernetes, the chart's file-store mount (below).

## Limitations, to be documented with the backend

- Consistency is per file, not across files. Two files the application changes together can be
  archived one before and one after a change. Directories written by atomic rename never yield a
  torn file; in-place writers fail the run (tar exit 1).
- Restore does not stop the application and cannot tell whether it is running. Stop it first, as
  for every other backend's restore.
- Empty directories that match no include are not recreated.

## Helm chart (quyendv/helm-charts, `charts/platform-backup`)

The chart already schedules one store per release and mounts a claim for file-based engines
(`fileStore`, used by sqlite). `files` reuses that:

- `engine` accepts `files` (values, schema enum, README, NOTES).
- `FILES_ROOT` is `fileStore.mountPath` (plus an optional `files.subPath`); `fileStore.enabled`
  is required for `files`, and `fileStore.readOnly` should be `true` (documented, and the example
  sets it).
- New values `files.include`, `files.exclude`, `files.require`, `files.forbid` (lists, joined with
  newlines into the variables), and the restore pair for a manual restore Job.
- Security context for `files`: drop all, add `DAC_READ_SEARCH`.
- unittest cases for the env mapping and the `fileStore` requirement, a `ci/files-values.yaml`,
  an example values file. Chart minor bump; `appVersion` follows the image release that ships
  `files`.

The chart change lands only after the image is released and has passed a real restore.

## Testing

- Unit (bats): validation (missing root, an include that matches nothing, a literal path that does
  not exist); the include expansion (globstar, names with spaces through a glob); tar's failure,
  including exit 1, fails the dump; verify catches a missing `FILES_REQUIRE` path and a present
  `FILES_FORBID` match; restore refuses a non-empty target without `OVERWRITE` and moves nothing.
- Integration: a directory with nested folders, an excluded subtree at several depths, a file
  matching `FILES_FORBID` outside the excludes (verify must fail), and a writer replacing files by
  rename during the dump; round trip into an empty target with byte-for-byte comparison, owners
  and modes; an in-place writer during the dump fails the run.
- `test/smoke.sh`: GNU tar (not BusyBox) and zstd run in the image.
