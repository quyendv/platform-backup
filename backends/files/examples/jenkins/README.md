# Jenkins home, with platform-backup/files

A production procedure for one Jenkins controller: what to back up and why,
the key that must stay out of the backup, a restore drill that proves the
backup works, a real restore after losing the server, and a planned move to a
new server, which is a different job. Every command here was run end to end
against Jenkins 2.580.1 (see [Verified](#verified)).

| File | What it is |
|---|---|
| [`.env.example`](.env.example) | The selection and the S3, schedule and retention settings |
| [`compose.yaml`](compose.yaml) | The scheduled backup (home mounted read-only) and a manual `restore` |
| [`drill.sh`](drill.sh) | The restore drill: exit 0 only if every check passes |
| [`drill-check.groovy`](drill-check.groovy) | What the drill boots Jenkins with; never part of a backup |

## Which tool for which event

| Event | Tool | You get back |
|---|---|---|
| The server is lost, or the home is damaged | **Restore from this backup** | every job, folder and setting, credentials, users and API tokens, nodes, the plugin set at the same versions. Not build history, logs or artifacts |
| A planned move to a new server | **Stop and copy the whole home** ([below](#moving-to-a-new-server)) | everything, build history and logs included |
| A job's configuration was broken by hand | **`fetch` one run and take one file** | that `config.xml` |

## What is backed up

A Jenkins home is mostly not state. One production home measured at ~60 GB
was ~30 GB of SCM caches, ~24 GB of build records and logs, and workspaces and
tool caches; the state that rebuilds the controller came to **59 MB per run,
archived in about a second** while builds were running.

Taken (`FILES_INCLUDE`):

| Path | Why |
|---|---|
| `*.xml` | global configuration, `credentials.xml`, every plugin's settings |
| `secrets/` (without `master.key`) | the keys that encrypt credentials; useless without `master.key`, see [The key](#the-key) |
| `jobs/` (without `builds/`) | every job and folder: `config.xml`, `nextBuildNumber`, and multibranch state (the last revision seen per branch, so a restore does not rebuild every branch) |
| `plugins/*/META-INF/MANIFEST.MF` | name and version of each plugin, enough to install the same set again; the plugins themselves are downloaded, not backed up |
| `?plugins/*.disabled`, `?plugins/*.pinned` | a plugin you disabled (for a security advisory, say) stays disabled after a restore |
| `?jenkins.yaml`, `?init.groovy.d` | configuration as code, when you use it |
| `?users`, `?nodes`, `?userContent`, `?fingerprints`, `?secret.key`, `?identity.key.enc`, `?.ssh/known_hosts`, `?.gitconfig` | users and API tokens, agents, user content, artifact fingerprints, legacy keys, the SSH host keys git trusts. `?` makes each optional: Jenkins creates some only once a feature is used (no `users/` until security is on) |

Left out (`FILES_EXCLUDE`), and why:

| Path | Why |
|---|---|
| `secrets/master.key` | see [The key](#the-key); `FILES_FORBID` also fails any run that contains it |
| `jobs/*/builds` | build records and logs, at every depth of folders and branches. The bulk of the home |
| `jobs/*/workspace*` | workspaces of old freestyle jobs |
| `*-atomic*tmp` | Jenkins' temp file while it saves `<file>`: measured as `config.xml-atomic<digits>tmp`, created next to the file it replaces |
| `indexing/*.log`, `computation/*.log`, `*polling.log` | multibranch and organisation scan logs, SCM polling logs: Jenkins appends to them in place, so a branch scan or a webhook during the backup would fail the run (a file changed while read). The scan *state* (`indexing.xml`) is kept |
| everything not included | `caches/`, `workspace/`, `tools/`, `.npm`, `.cache`, `logs/`, `updates/`, `war/`: regenerated |

**Why build history is not kept, not even `build.xml`:** a tar exclusion beats
an explicit include, so keeping only `builds/*/build.xml` means excluding by
name every other kind of file Jenkins and its plugins write into a build
directory (logs, `libs/`, `changelog*.xml`, `workflow-completed/`,
`archive/`, pipeline graph JSON, scanner reports, …). That list changes with
every plugin and would go stale without a sound. Numbering continues after a
restore, because `nextBuildNumber` is kept. If you need the history, that is a
[move](#moving-to-a-new-server), not a restore.

`FILES_REQUIRE` (`config.xml credentials.xml secrets/hudson.util.Secret`)
fails any run missing one of them before it is kept.

## The key

`secrets/master.key` decrypts the other keys in `secrets/`, which decrypt every
credential in `credentials.xml` and in job, folder and node configurations.
A backup that holds it hands every secret Jenkins has to anyone who can read the
bucket. So it stays out, enforced twice (`FILES_EXCLUDE` and `FILES_FORBID`),
and you hold it yourself, the way Vault's unseal keys are held.

It is created when Jenkins first starts and never changes, so export it
**once**:

```bash
ssh <jenkins-host> 'sudo cat /var/lib/jenkins/secrets/master.key' > master.key
sha256sum master.key; ssh <jenkins-host> 'sudo sha256sum /var/lib/jenkins/secrets/master.key'
```

Keep two copies in different places (a password manager attachment and one
offline), and check both hashes match the host's. Without it a restore still
brings back every job and setting, but every credential comes back unreadable
and has to be entered again by hand.

What stays readable in the archive without the key: anything that is not a
Jenkins `Secret`, such as a token pasted into an inline pipeline script, or the
content of Config File Provider managed files. Scan the first archive (the
drill's `--keep` leaves it unpacked) with a secret scanner such as `gitleaks`,
and move what it finds into credentials.

## Deploying

On the Jenkins host:

```bash
cp .env.example .env     # JENKINS_HOME_DIR, the S3 settings; daily at 02:00 UTC, 15 runs kept
docker compose up -d
docker compose run --rm backup run   # one run now, even with SCHEDULE set; read its last lines
```

Then **count the run in the bucket**, not the container's status:

```bash
aws s3 ls --recursive s3://<bucket>/<S3_PREFIX>/    # <run>/files-<run>.tar.zst, its .sha256, _COMPLETE
```

The home is mounted read-only and the container keeps only
`DAC_READ_SEARCH`. A Jenkins installed from packages runs as its own uid; the
backup reads its files regardless and records numeric owners.

**Runs while Jenkins works.** Jenkins saves by writing a temp file and renaming
it, so tar may report a directory that changed, or a temp file that vanished or
was renamed away while read. None of those tears a file Jenkins uses; the run
logs a warning and succeeds. A file changed in place while read (a log, which
is excluded) still fails the run.

## The restore drill

Run it on any Docker host other than the Jenkins host, with the `.env` the
backup uses and **your kept copy of the key**, not one taken from the server:

```bash
./drill.sh --key ./master.key --image jenkins/jenkins:2.580.1-jdk21 --expect-jobs <n>
```

`--image` must be the Jenkins version the backup came from. The drill:

1. restores the newest run (or `RESTORE_TIMESTAMP`) into a new empty directory,
   which re-runs every selection check;
2. adds the key;
3. reads the plugin manifests and installs exactly those versions with
   `jenkins-plugin-cli`;
4. boots Jenkins **with no network** (`--network none`), executors set to 0
   and in quiet-down, so nothing restored can build, push, call a webhook or
   reach an agent;
5. reads one line from its log, counts only, and passes when: no plugin and no
   item failed to load; Jenkins loaded as many jobs and folders as the restored
   home holds `config.xml` files under `jobs/`; at least one credential could be
   checked, and every one that could was decrypted; and the job count equals
   `--expect-jobs` when given. A credential whose type exposes no readable
   secret is listed by type (`DRILL-UNVERIFIED`), never by value.

Restored `init.groovy.d` scripts run during the drill too, with no network.

Everything it created is removed afterwards (the key copy is shredded).
A login realm tied to the production URL (Google, GitHub, SSO) will not work on
the drill instance; the drill does not log in.

With a wrong key it fails, which is the point:

```
drill     DRILL jobs=5 folders=2 nodes=0 credentials=4 verifiable=4 decrypted=0
DRILL FAIL 0 of 4 credentials decrypted: is this the key that belongs to the backup?
```

Run it after deploying, after upgrading Jenkins, and on a calendar.

## Restoring after losing the server

The drill's steps, on the real new host, with the network on:

1. Install **the same Jenkins version**; do not start it.
2. Restore into the empty home: set `RESTORE_TARGET_DIR` to it in `.env`, then
   `docker compose run --rm restore`. It refuses a non-empty directory.
3. Put your kept `master.key` in `<home>/secrets/`, then
   `chown -R jenkins:jenkins <home>`: owners were restored as numbers, which may
   not be this host's `jenkins`.
4. Reinstall the plugins, as root:
   ```bash
   cd <home>
   for m in plugins/*/META-INF/MANIFEST.MF; do
     tr -d '\r' <"$m" | awk -F': ' '/^Short-Name: /{n=$2} /^Plugin-Version: /{v=$2} END{print n":"v}'
   done > /tmp/plugins.txt
   rm -rf plugins/*/
   docker run --rm --user "$(id -u jenkins)" -v "$PWD/plugins:/plugins" -v /tmp/plugins.txt:/p.txt:ro \
     --entrypoint jenkins-plugin-cli jenkins/jenkins:<version>-jdk21 --plugin-file /p.txt --plugin-download-directory /plugins
   ```
5. Start Jenkins and check the log for `Failed Loading plugin` and
   `Failed Loading item`.
6. Reconnect it: the Jenkins URL (Manage Jenkins → System, stored in
   `jenkins.model.JenkinsLocationConfiguration.xml`), DNS, the login realm's
   redirect URI if the hostname changed, agents (inbound agents reconnect to the
   URL on their own), SCM webhooks if their target changed.
7. Deploy this backup on the new host.

## Moving to a new server

A planned move keeps everything, so it does not use the backup: copy the whole
home while Jenkins runs, stop it, copy the difference, start the new one.

```bash
# 1. New host: same Jenkins version installed, stopped, empty home.
# 2. First pass while the old controller keeps working (most of the bytes).
#    Through a non-root SSH user, add --rsync-path='sudo rsync' so owners survive.
sudo rsync -aHAX --numeric-ids /var/lib/jenkins/ new-host:/var/lib/jenkins/
# 3. Stop taking work, wait for running builds, stop:
#    Manage Jenkins -> Prepare for Shutdown (POST /quietDown), until no executor is busy
sudo systemctl stop jenkins
# 4. Second pass, the difference only, and remove what was deleted meanwhile:
sudo rsync -aHAX --numeric-ids --delete /var/lib/jenkins/ new-host:/var/lib/jenkins/
# 5. New host:
sudo chown -R jenkins:jenkins /var/lib/jenkins    # only if the jenkins uid differs
sudo systemctl start jenkins
```

Downtime is step 3 to step 5: the second pass copies only what changed since
the first. `caches/` and `workspace/` can be left out of both passes
(`--exclude`) to save time; Jenkins rebuilds them.

Check before cutting over: the job count, a job's build history and an old
console log, `Failed Loading plugin` absent from the log, a new build continuing
the numbering, and that credentials decrypt, from the script console:

```groovy
import com.cloudbees.plugins.credentials.CredentialsProvider
def j = jenkins.model.Jenkins.get()
def blob = { it.replaceAll(/\s/, '') ==~ /^\{[A-Za-z0-9+\/=]+\}$/ }
def values = { cr -> cr.class.methods.findAll { it.parameterCount == 0 && it.name.startsWith('get') }.collect { m ->
  def v; try { v = m.invoke(cr) } catch (Throwable t) { return [] }
  if (v instanceof hudson.util.Secret) return [v.plainText]
  if (m.name ==~ /(?i)^get.*(key|password|secret|token|passphrase).*/ && v instanceof String) return [v]
  [] }.flatten().findAll { it } }
def ctx = [j] + j.getAllItems(com.cloudbees.hudson.plugins.folder.AbstractFolder)
def n = 0, ok = 0
ctx.each { c -> CredentialsProvider.lookupStores(c).findAll { it.context == c }.each { s -> s.domains.each { d -> s.getCredentials(d).each { cr ->
  n++; if (!values(cr).any(blob)) ok++ } } } }
println("credentials=${n} decrypted=${ok} failed plugins=${j.pluginManager.failedPlugins.size()}")
```

Then cut over (step 6 of the restore above), keep the old server stopped, not
deleted, until the new one has run a few days, and move this backup to the new
host.

## Retiring an older backup

Only after: three consecutive scheduled runs **counted as objects in the
bucket**, and a passed drill with your kept key.

## Verified

2026-10-23, Jenkins 2.580.1 (the `jenkins/jenkins:2.580.1-jdk21` image), with
nested folders, five pipeline jobs and ten builds, a secret text, a
username/password and a passphrase-less SSH key at system level and a secret
text on a folder, 51 plugins:

```
backup:  91 entries, 15 147 bytes, run uploaded with its .sha256 and _COMPLETE, 11 s
drill:   DRILL jobs=5 folders=2 nodes=0 credentials=4 verifiable=4 decrypted=4
         DRILL PASS (restore, 51 plugins reinstalled, boot, checks: ~2 min)
         wrong key: decrypted=0, DRILL FAIL, exit 1; nothing left behind
         a job with a corrupt config.xml: "1 item(s) failed to load", DRILL FAIL
move:    pass 1: 2 039 files, 150 MB, 0.2 s while running; pass 2: 1 file
         new controller on the plain image: history 2 builds per job, old
         console logs readable, credentials 3/3 (before the SSH key was added), 51 plugins, 0 failed,
         next build #3 SUCCESS
real restore (steps 2-5 above): compose restore 91 entries, a second restore
         refused the non-empty home, 51 plugins reinstalled, 0 failed,
         credentials 3/3, 2 folders + 5 jobs, next build #3
temp files seen while saving: config.xml-atomic<digits>tmp (106 in 300 saves)
```
