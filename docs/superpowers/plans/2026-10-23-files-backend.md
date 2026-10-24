# files backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A seventh image, `platform-backup/files`, that archives a checked selection of files under one directory as `tar.zst`, with a tested Jenkins example and restore drill, and then a `files` engine in the Helm chart.

**Architecture:** One adapter, `backends/files/backend.sh`, on the unchanged driver in `lib/`. The adapter expands include globs itself (tar does not), streams `tar | zstd`, and its verify step lists the archive once and checks `FILES_REQUIRE`/`FILES_FORBID` against that listing. A worked example under `backends/files/examples/jenkins/` carries the production procedure and an automated drill.

**Tech Stack:** bash 5, GNU tar 1.35, zstd 1.5, Alpine 3.22, bats 1.14, Docker Compose, MinIO (integration), Jenkins LTS (example), Helm 4 + helm-unittest (chart).

**Spec:** `docs/superpowers/specs/2026-10-23-files-backend-design.md`

## Global Constraints

- `lib/` is not changed. Adding the backend touches only what CLAUDE.md lists: `backend.sh`, Dockerfile, `.env.example`, `k8s/`, `docker/compose.yaml`, bake target, docs.
- Logs go to stderr; `backend_dump` echoes only the artifact name on stdout.
- Every command in `backend_dump`/`backend_restore` is checked by name (`|| die …`), and a pipeline's statuses through `PIPESTATUS`, because errexit is off in the driver's context.
- Never pipe into `head` under pipefail; use `find -print -quit` or read a file.
- Artifact name: `files-${RUN_ID}.tar.zst`. Compression: `zstd -10 -T0`.
- tar is GNU tar. Dump: `tar -C "$FILES_ROOT" --numeric-owner -cf - --exclude=<p>… -T <list>` (exclusion defaults: wildcards, cross `/`, unanchored). tar exit 1 fails the run.
- Variables and defaults, verbatim: `FILES_ROOT` (required), `FILES_INCLUDE` (`.`), `FILES_EXCLUDE` (empty), `FILES_REQUIRE` (empty), `FILES_FORBID` (empty), `FILES_RESTORE_TARGET` (`FILES_ROOT`), `FILES_RESTORE_OVERWRITE` (`false`). Lists are whitespace/newline separated.
- Backup: root, `cap_drop: ALL`, `cap_add: DAC_READ_SEARCH`, source mounted read-only. Restore: writable mount, `CHOWN`, `DAC_OVERRIDE`, `FOWNER`.
- shfmt `-i 2 -ci`; shellcheck clean; bats setups `set -euo pipefail`; English in every file.
- This repo and helm-charts are personal public repos: no company, host or person names in code, docs, examples or commits.
- Branch `feat/files-backend` off `develop`; nothing is pushed, merged or tagged without the owner's go-ahead.

## Review Focus

- `FILES_ROOT` is a symlink to the real directory (common for `/var/lib/<app>`): the archive must hold the target's files, not one symlink entry. → Task 2 test `a symlinked root is archived through the link`.
- A symlink inside the root pointing outside it: archived as a link, its target never followed or read. → Task 2 test `a symlink inside the root is kept as a link`.
- An include that expands to thousands of paths (a jobs tree): no "argument list too long", no SIGPIPE. → Task 1 test `3000 matched paths are listed in full`.
- A fresh volume used as restore target holds only `lost+found`: it counts as empty. → Task 3 test `a target holding only lost+found is empty`.
- A file unreadable to the image (non-root run without `DAC_READ_SEARCH`): the run fails naming tar's error, not "artifact too small". → Task 2 test `an unreadable file fails the dump`.

---

### Task 1: Adapter skeleton, validation and include expansion

**Files:**
- Create: `backends/files/backend.sh`
- Test: `test/unit/files.bats`

**Interfaces:**
- Produces: `backend_name` → `files`; `backend_caps` → `fetch restore`; `backend_validate`; `_files_words VAR` → the variable's entries, one per line; `_files_expand` → every path matched by `FILES_INCLUDE`, relative to `FILES_ROOT`, one per line, dies naming the first entry that matches nothing.

- [ ] **Step 1: Write the failing tests** in `test/unit/files.bats` (setup sources `lib/log.sh`, `lib/env.sh`, the adapter; `RUN_ID=20260101_000000`; a tree under `$BATS_TEST_TMPDIR/root` with `a.xml`, `b.xml`, `jobs/x/config.xml`, `jobs/x/builds/1/log`, `plugins/p1/META-INF/MANIFEST.MF`, `plugins/p1.jpi`, `secrets/master.key`, `secrets/hudson.util.Secret`, `.ssh/known_hosts`):
  - `validate fails without FILES_ROOT` → status ≠ 0, output contains `FILES_ROOT`.
  - `validate fails when FILES_ROOT is not a directory` (a file, then a missing path).
  - `validate fails naming an include that matches nothing` (`FILES_INCLUDE='*.xml nope/*'`) → output contains `nope/*`.
  - `a literal include that does not exist fails` (`FILES_INCLUDE='missing.xml'`).
  - `globs expand relative to the root, including **` → `FILES_INCLUDE='*.xml plugins/*/META-INF/MANIFEST.MF'` gives exactly `a.xml b.xml plugins/p1/META-INF/MANIFEST.MF` (sorted).
  - `the default include is the whole root` → `_files_expand` prints `.`.
  - `newlines and spaces both separate entries`.
  - `3000 matched paths are listed in full` → 3000 files under `many/`, `FILES_INCLUDE='many/*'`, line count 3000, status 0.
  - `validate succeeds in fetch mode with no FILES_ROOT` (`MODE=fetch`).

- [ ] **Step 2: Run** `mise exec -- bats test/unit/files.bats` — expect failures (`backend.sh` missing).

- [ ] **Step 3: Implement** in `backends/files/backend.sh`: header comment pointing at the spec (style of `backends/sqlite/backend.sh`); defaults block for the seven variables; `backend_validate` (fetch: return 0; restore: require `FILES_ROOT` or `FILES_RESTORE_TARGET`'s parent directory; backup: `require_env FILES_ROOT`, directory, readable, then `_files_expand >/dev/null`). `_files_expand` runs in a subshell: `cd -- "$FILES_ROOT"`, `shopt -s globstar` (nullglob and dotglob off), for each entry of `_files_words FILES_INCLUDE` expand into an array and treat "the only match equals the pattern and `[[ ! -e ]]`" as no match.

- [ ] **Step 4: Run** the bats file — all pass. Run `mise run lint:sh fmt:check`.

- [ ] **Step 5: Commit** `feat(files): adapter validation and include expansion`.

### Task 2: Dump and verify

**Files:**
- Modify: `backends/files/backend.sh`
- Test: `test/unit/files.bats`, `test/unit/adapters.bats`

**Interfaces:**
- Consumes: `_files_words`, `_files_expand` (Task 1).
- Produces: `backend_dump DIR` → echoes `files-${RUN_ID}.tar.zst`; `_files_listing ARCHIVE` → archive entries one per line (directories without trailing `/`); `_files_matches PATTERN ENTRY` → status 0 when ENTRY matches with tar exclusion semantics; `backend_verify ARCHIVE`.

`_files_matches` rule (one definition, used for `FILES_FORBID`, mirrors tar `--exclude`): with bash `[[ == ]]` patterns, where `*` crosses `/`, ENTRY matches when any of `ENTRY == P`, `ENTRY == */P`, `ENTRY == P/*`, `ENTRY == */P/*` holds.

- [ ] **Step 1: Write the failing tests:**
  - `dump archives the selection and nothing excluded` → `FILES_INCLUDE='*.xml jobs plugins/*/META-INF/MANIFEST.MF secrets'`, `FILES_EXCLUDE='secrets/master.key jobs/*/builds'`; listing contains `a.xml`, `jobs/x/config.xml`, `plugins/p1/META-INF/MANIFEST.MF`, `secrets/hudson.util.Secret`; contains no `master.key`, no `/builds/`, no `p1.jpi`; output is exactly `files-20260101_000000.tar.zst`.
  - `excludes reach every depth` → `jobs/a/jobs/b/branches/c/builds/9/log` absent with `FILES_EXCLUDE='jobs/*/builds'`.
  - `owners are numeric in the archive` → `tar -tv --numeric-owner` shows the uid.
  - `a symlinked root is archived through the link` → `FILES_ROOT` a symlink to the tree; listing has `a.xml`.
  - `a symlink inside the root is kept as a link` → `link -> /etc`; archive has `link` as a symlink entry and no `link/passwd`.
  - `tar exit 1 fails the dump` → stub `tar` exiting 1 (PATH stub as in `adapters.bats`), status ≠ 0, output names tar.
  - `an unreadable file fails the dump` → skip when `id -u` is 0; `chmod 000 secret`; status ≠ 0.
  - `_files_matches follows tar exclusion semantics` → table: (`secrets/master.key`, `secrets/master.key`)=0, (`secrets/master.key`, `x/secrets/master.key`)=0, (`jobs/*/builds`, `jobs/a/jobs/b/builds/1/log`)=0, (`secrets/master.key`, `secrets/master.key.bak`)=1, (`*.jpi`, `plugins/p1.jpi`)=0.
  - `verify fails when a FILES_REQUIRE path is missing` → names the path.
  - `verify fails when an entry matches FILES_FORBID` → archive built without the exclude; names the entry.
  - `verify fails on a corrupt archive` → truncated file.
  - `verify passes a good archive` → status 0.
  - In `adapters.bats`: `files fails when tar fails` (same shape as `sqlite fails when VACUUM INTO fails`).

- [ ] **Step 2: Run** — expect failures.

- [ ] **Step 3: Implement** `backend_dump` (write `_files_expand` output to `${dir}/.files.list`, build `--exclude=` args from `_files_words FILES_EXCLUDE`, `tar … -T list | zstd -q -10 -T0 > artifact`, read `PIPESTATUS` into an array immediately, die on either non-zero naming tar or zstd, remove the list, echo the name), `_files_listing` (`zstd -dc | tar -tf -` into a temp file, strip one trailing `/`; check both statuses), `_files_matches`, `backend_verify` (`zstd -t`; listing non-empty; each `FILES_REQUIRE` entry present exactly; no entry matches any `FILES_FORBID` pattern; `log_info` the entry count).

- [ ] **Step 4: Run** bats, lint, fmt — pass.

- [ ] **Step 5: Commit** `feat(files): dump and verify with required and forbidden paths`.

### Task 3: Restore

**Files:**
- Modify: `backends/files/backend.sh`
- Test: `test/unit/files.bats`

**Interfaces:**
- Consumes: `backend_verify` (Task 2).
- Produces: `_files_target_empty DIR` → 0 when DIR has no entry but `lost+found`; `backend_restore ARCHIVE`.

- [ ] **Step 1: Write the failing tests:**
  - `restore into an empty target recreates the selection byte for byte` → round trip, `diff -r` over the selected paths, modes equal.
  - `restore refuses a non-empty target and writes nothing` → target holds `keep.txt`; status ≠ 0; output names `FILES_RESTORE_OVERWRITE`; target listing unchanged.
  - `overwrite replaces namesakes and leaves everything else` → `FILES_RESTORE_OVERWRITE=true`; `a.xml` replaced, `keep.txt` still there.
  - `a target holding only lost+found is empty`.
  - `a missing target directory is created`.
  - `restore stops before extracting when verify fails` → corrupt archive, target untouched.

- [ ] **Step 2: Run** — expect failures.

- [ ] **Step 3: Implement** `backend_restore`: target = `${FILES_RESTORE_TARGET:-$FILES_ROOT}`; `backend_verify` first; `mkdir -p`; refuse non-empty unless `parse_bool`/`bool_is_true FILES_RESTORE_OVERWRITE`; `log_warn` that the application must be stopped; `zstd -dc | tar -C target -xf - --same-owner --numeric-owner --preserve-permissions`, both statuses checked; `log_ok` with the count. Never deletes.

- [ ] **Step 4: Run** bats, lint, fmt — pass.

- [ ] **Step 5: Commit** `feat(files): restore into an empty or explicitly overwritten target`.

### Task 4: Image and build wiring

**Files:**
- Create: `backends/files/Dockerfile`
- Modify: `docker-bake.hcl`, `compose.yaml`, `test/smoke.sh`, `.github/workflows/ci.yml`, `.github/workflows/release.yml`, `.github/workflows/arm64.yml`, `test/integration/run.sh:5` (usage line only)

**Interfaces:**
- Produces: image `ghcr.io/quyendv/platform-backup/files:latest` (local build), bake target `files` in group `default`.

- [ ] **Step 1: Dockerfile** — copy of `backends/sqlite/Dockerfile` with title/description for files and `apk add … tar zstd` instead of `sqlite`; same supercronic, labels, `COPY backends/files/backend.sh`.
- [ ] **Step 2: Wiring** — bake target `files` (shape of `mongodb`), added to `group "default"`; dev `compose.yaml` service `files` (profile `files`, read-only bind mount comment, `cap_drop: [ALL]`, `cap_add: [DAC_READ_SEARCH]`, volume `files_backup`); `ci.yml` path filter `files: backends/files/**`, its env and the backend loop; `release.yml` options, `all` list and the name `case`; `arm64.yml` options; `smoke.sh` default list and `files) printf '%s; tar --version | grep -q "GNU tar"; zstd --version' "$common"`.
- [ ] **Step 3: Verify** — `mise run check` passes; `mise run build` builds `files`; `test/smoke.sh files` prints PASS.
- [ ] **Step 4: Commit** `feat(files): image, bake target and CI wiring`.

### Task 5: Backend documentation and deploy files

**Files:**
- Create: `backends/files/README.md`, `backends/files/.env.example`, `backends/files/docker/compose.yaml`, `backends/files/k8s/cronjob.yaml`, `backends/files/k8s/restore-job.yaml`
- Modify: `README.md` (images table, backend links, modes table + footnote), `CHANGELOG.md` (`[Unreleased]` → Added), `test/unit/env_keys.bats` (scan `backends/*/examples/*/.env.example` and `backends/*/examples/*/compose.yaml` too; add the example's compose-only keys to `compose_native`)

- [ ] **Step 1: Write** the README in the sqlite README's shape: what it backs up, how the selection works (the three measured tar facts, briefly, linking the spec), the variables table (Global Constraints, verbatim), running it (caps, read-only mount), restore (empty target rule, overwrite, single-file recovery via `fetch`), limitations (spec section), and a link to `examples/jenkins/`. `.env.example`, `docker/compose.yaml` (pinned release tag placeholder `0.7.0`, persistent `/backup`, `restore` profile) and the two k8s manifests follow the sqlite ones, with `fileStore`-style placeholders for the claim and pod labels.
- [ ] **Step 2: Verify** — `mise exec -- bats test/unit/env_keys.bats` passes; then add `FILES_TYPO=1` to `.env.example`, see it fail, remove it.
- [ ] **Step 3: Commit** `docs(files): README, deploy files and changelog`.

### Task 6: Integration test against MinIO

**Files:**
- Modify: `test/integration/run.sh` (`test_files`, `services_for`, cleanup, default list)

- [ ] **Step 1: Write `test_files`**, using `backup_image` and a named volume tree seeded through the image: nested `jobs/a/jobs/b/builds/` at three depths, `secrets/master.key`, files owned by uid 1001 mode 0640, a symlink to `/etc`. Cases, each a `pass`/`fail`:
  1. backup with the Jenkins-shaped selection while a writer replaces `jobs/a/config.xml` by rename every 50 ms → run folder uploaded.
  2. `restore` into an empty volume → `diff -r` against the selection, owners and modes kept, no `builds/`, no `master.key`, symlink still a link.
  3. backup with `master.key` not excluded and `FILES_FORBID=secrets/master.key` → the run fails and **no new run folder** appears in S3.
  4. a writer appending in place to an included file during the dump → the run fails (tar exit 1).
- [ ] **Step 2: Run** `mise run test:integration files` — all PASS.
- [ ] **Step 3: Commit** `test(files): end-to-end backup and restore against MinIO`.

### Task 7: Jenkins example and drill

**Files:**
- Create: `backends/files/examples/jenkins/README.md`, `.env.example`, `compose.yaml`, `drill.sh`, `drill-check.groovy`

**Interfaces:**
- Consumes: the image (Task 4), `MODE=restore` (Task 3).
- Produces: `drill.sh --key PATH [--image IMAGE] [--expect-jobs N] [--env FILE]`, exit 0 only when every check in the spec's step 5 passes; prints `DRILL PASS` or `DRILL FAIL: <reason>`.

- [ ] **Step 1: Write** `drill-check.groovy`: on init, `Jenkins.get().doQuietDown()`; count `Job` items, `Folder`-like `ItemGroup` items, nodes, credentials from `SystemCredentialsProvider` plus folder stores, and credentials whose every `Secret`-typed property has a non-empty `getPlainText()`; print exactly `DRILL jobs=%d folders=%d nodes=%d credentials=%d decrypted=%d`.
- [ ] **Step 2: Write** `drill.sh` (bash, `set -euo pipefail`, shellcheck clean, trap cleanup): steps 1-6 of the spec; plugins from manifests via `awk` over `Short-Name:`/`Plugin-Version:` (strip CR); install with `jenkins-plugin-cli --plugin-file … --plugin-download-directory <home>/plugins`; start `--network none -v home:/var/jenkins_home`; wait up to 300 s for the `DRILL` line or `Jenkins is fully up`; shred the key copy and remove the home on exit.
- [ ] **Step 3: Write** the example `.env.example` (selection from the spec, verbatim), `compose.yaml` (bind `${JENKINS_HOME_DIR:-/var/lib/jenkins}:/jenkins-home:ro`, `FILES_ROOT=/jenkins-home`, caps, `restore` profile writing to `${RESTORE_TARGET_DIR}`), and `README.md` (the procedure from the spec's Examples section: selection table with what is left out and why, exporting the key once to two places, deploy, restore, drill, retiring an older backup after three counted runs and a passed drill).
- [ ] **Step 4: Verify** — `mise run check` (shellcheck/shfmt cover `drill.sh`; env_keys covers the example).
- [ ] **Step 5: Commit** `docs(files): Jenkins example with an automated restore drill`.

### Task 8: Verification on a real Jenkins (test VM)

**Files:**
- Modify: `docs/superpowers/specs/2026-10-23-files-backend-design.md` (append "Verified" with the measured output)

Test VM: a disposable Ubuntu 24.04 host with Docker; nothing on it is kept.

- [ ] **Step 1:** Ship the local image: `docker save ghcr.io/quyendv/platform-backup/files:latest | ssh <vm> docker load`; copy `examples/jenkins/` to the VM.
- [ ] **Step 2:** On the VM start MinIO and `jenkins/jenkins:lts-jdk21` with setup wizard off; seed through the Jenkins script console or JCasC: two folders (one nested), five pipeline jobs, two builds each, a secret-text and a username/password credential, plugins `workflow-aggregator`, `credentials-binding`, `cloudbees-folder`.
- [ ] **Step 3:** Run the example compose once (`docker compose run --rm backup run`); count the run's objects in MinIO; record size and duration.
- [ ] **Step 4:** Copy `secrets/master.key` out to a file; `drill.sh --key <file> --expect-jobs 5 --image jenkins/jenkins:<same version>` → `DRILL PASS`, `decrypted=2 credentials=2`.
- [ ] **Step 5:** Negative: `drill.sh --key <random 256-byte file>` → `DRILL FAIL`, `decrypted=0`.
- [ ] **Step 6:** Append the outputs to the spec under "Verified (date)"; tear the VM's containers and volumes down.
- [ ] **Step 7: Commit** `docs(files): verified on a disposable Jenkins`.

### Task 9: Helm chart `files` engine (helm-charts repo, after Task 8 and the image release)

**Files (in `~/workspace/helm-charts/charts/platform-backup`):**
- Modify: `values.yaml`, `values.schema.json`, `templates/cronjob.yaml`, `templates/_helpers.tpl`, `README.md`, `CHANGELOG.md`, `Chart.yaml` (version `0.2.0`, `appVersion` = the release that ships files)
- Create: `ci/files-values.yaml`, `examples/values-files-example.yaml`, tests in `tests/cronjob_test.yaml` and `tests/filestore_test.yaml`

- [ ] **Step 1: Failing unittest cases:** `engine: files` renders image `…/files:<tag>`; `FILES_ROOT` equals `fileStore.mountPath` (+ `files.subPath`); `files.include` list renders `FILES_INCLUDE` joined by newlines (same for exclude, require, forbid); `engine: files` without `fileStore.enabled` fails rendering with a message; security context drops ALL and adds `DAC_READ_SEARCH`.
- [ ] **Step 2: Run** the chart's unittest target (see the repo `Makefile`) — fail.
- [ ] **Step 3: Implement** values (`files.subPath`, `files.include`, `files.exclude`, `files.require`, `files.forbid`), schema enum and types, template env and the `fileStore` requirement, docs.
- [ ] **Step 4: Run** unittest and lint targets — pass; `helm template` with `ci/files-values.yaml` reviewed by eye.
- [ ] **Step 5: Commit** on branch `feat/platform-backup-files-engine` `feat(platform-backup): files engine`.
