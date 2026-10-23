#!/usr/bin/env bash
# Restore drill for a Jenkins home backed up by platform-backup/files.
#
#   ./drill.sh --key ./master.key --image jenkins/jenkins:2.580.1-jdk21 [--expect-jobs N]
#              [--env .env] [--files-image IMAGE] [--keep]
#
# Restores the newest run (or RESTORE_TIMESTAMP from the env file) into a new
# directory, adds the key you kept apart from the backup, reinstalls the
# archived plugin versions, and boots Jenkins with no network to read back what
# it loaded. Exit status 0 only if every check passes. Everything it creates is
# removed at the end (--keep leaves the restored home for inspection).
#
# Run it on any Docker host. --image must be the Jenkins version the backup was
# taken from. Needs: docker, and the env file the backup itself uses (S3
# settings and the FILES_* selection, so restore re-runs the same checks).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="" IMAGE="" EXPECT_JOBS="" ENV_FILE="${HERE}/.env" KEEP=false
FILES_IMAGE="ghcr.io/quyendv/platform-backup/files:0.7.0"
# The official image runs Jenkins as uid 1000; the restored home is given to it.
JENKINS_UID=1000
BOOT_TIMEOUT=300

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
say() { printf '\033[0;36mdrill\033[0m %s\n' "$*"; }
verdict_fail() {
  printf '\033[0;31mDRILL FAIL\033[0m %s\n' "$*"
  exit 1
}

while (($#)); do
  case "$1" in
    --key) KEY="$2" && shift 2 ;;
    --image) IMAGE="$2" && shift 2 ;;
    --expect-jobs) EXPECT_JOBS="$2" && shift 2 ;;
    --env) ENV_FILE="$2" && shift 2 ;;
    --files-image) FILES_IMAGE="$2" && shift 2 ;;
    --keep) KEEP=true && shift ;;
    -h | --help) usage && exit 0 ;;
    *) usage >&2 && exit 2 ;;
  esac
done
[[ -n "$KEY" && -n "$IMAGE" ]] || {
  usage >&2
  exit 2
}
[[ -r "$KEY" ]] || verdict_fail "cannot read the key ${KEY}"
[[ -r "$ENV_FILE" ]] || verdict_fail "cannot read the env file ${ENV_FILE}"
KEY="$(cd "$(dirname "$KEY")" && pwd)/$(basename "$KEY")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/jenkins-drill.XXXXXX")"
HOME_DIR="${WORK}/home"
NAME="jenkins-drill-$$"
mkdir -p "$HOME_DIR"

# as_root SCRIPT: a shell with the restored home at /h, as root, for the steps
# that touch files owned by Jenkins' uid.
as_root() {
  docker run --rm -v "${HOME_DIR}:/h" -v "${WORK}:/w" --entrypoint sh "$FILES_IMAGE" -c "$1"
}

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  if [[ "$KEEP" == true ]]; then
    say "kept ${HOME_DIR} (the key copy inside it is shredded)"
    as_root 'shred -u /h/secrets/master.key 2>/dev/null || true' || true
  else
    as_root 'shred -u /h/secrets/master.key 2>/dev/null || true; rm -rf /h/* /h/.[!.]* /w/*' || true
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

say "1/5 restore the backup into an empty directory"
docker run --rm --env-file "$ENV_FILE" \
  -e MODE=restore -e SCHEDULE= -e NOTIFY_ON=never -e BACKUP_DIR=/tmp/backup \
  -e FILES_RESTORE_TARGET=/target -v "${HOME_DIR}:/target" \
  --add-host host.docker.internal:host-gateway \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  "$FILES_IMAGE" || verdict_fail "restore failed"
[[ -e "${HOME_DIR}/config.xml" ]] || verdict_fail "the restored home has no config.xml"
# Every job and folder, multibranch branches and organisation folders included,
# is a config.xml under jobs/ outside builds/: what Jenkins must load back.
items_on_disk="$(as_root 'find /h/jobs -name builds -prune -o -name config.xml -print 2>/dev/null | wc -l')"

say "2/5 add the key kept apart from the backup"
docker run --rm -v "${HOME_DIR}:/h" -v "${KEY}:/key:ro" --entrypoint sh "$FILES_IMAGE" -c \
  'cp /key /h/secrets/master.key && chmod 0644 /h/secrets/master.key' ||
  verdict_fail "could not place the key"

say "3/5 reinstall the archived plugin versions"
# Short-Name and Plugin-Version of each archived manifest. The unpacked plugin
# directories hold only that manifest, so they go: Jenkins unpacks each plugin
# again from the downloaded archive.
# Runs in the helper container; expands there.
# shellcheck disable=SC2016
as_root '
  for m in /h/plugins/*/META-INF/MANIFEST.MF; do
    tr -d "\r" <"$m" | awk -F": " "/^Short-Name: /{n=\$2} /^Plugin-Version: /{v=\$2} END{print n\":\"v}"
  done >/w/plugins.txt
  rm -rf /h/plugins/*/
  mkdir -p /h/init.groovy.d
  chown -R '"${JENKINS_UID}:${JENKINS_UID}"' /h' || verdict_fail "could not read the plugin manifests"
say "    $(wc -l <"${WORK}/plugins.txt") plugins"
docker run --rm --user "$JENKINS_UID" -v "${HOME_DIR}:/var/jenkins_home" -v "${WORK}/plugins.txt:/plugins.txt:ro" \
  --entrypoint jenkins-plugin-cli "$IMAGE" \
  --plugin-file /plugins.txt --plugin-download-directory /var/jenkins_home/plugins >"${WORK}/plugins.log" 2>&1 ||
  {
    tail -20 "${WORK}/plugins.log"
    verdict_fail "plugin installation failed"
  }

say "4/5 boot it with no network"
cp "${HERE}/drill-check.groovy" "${WORK}/drill-check.groovy"
as_root 'cp /w/drill-check.groovy /h/init.groovy.d/ && chown '"${JENKINS_UID}:${JENKINS_UID}"' /h/init.groovy.d/drill-check.groovy'
docker run -d --name "$NAME" --network none -v "${HOME_DIR}:/var/jenkins_home" \
  -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" "$IMAGE" >/dev/null
line=""
for ((i = 0; i < BOOT_TIMEOUT; i += 5)); do
  line="$(docker logs "$NAME" 2>&1 | grep -m1 '^DRILL jobs=' || true)"
  [[ -z "$line" ]] || break
  [[ "$(docker inspect -f '{{.State.Running}}' "$NAME")" == true ]] || break
  sleep 5
done
docker logs "$NAME" >"${WORK}/jenkins.log" 2>&1
[[ -n "$line" ]] || {
  tail -30 "${WORK}/jenkins.log"
  verdict_fail "Jenkins never printed the DRILL line within ${BOOT_TIMEOUT}s"
}

say "5/5 check what it loaded"
say "    ${line}"
grep '^DRILL-UNVERIFIED' "${WORK}/jenkins.log" | sort | uniq -c | sed 's/^/drill     /' || true
count() { sed -nE "s/.* $1=([0-9]+).*/\1/p" <<<"$line"; }
jobs="$(count jobs)" folders="$(count folders)" credentials="$(count credentials)"
verifiable="$(count verifiable)" decrypted="$(count decrypted)"
failed_plugins="$(grep -c 'Failed Loading plugin' "${WORK}/jenkins.log" || true)"
failed_items="$(grep -c 'Failed Loading item' "${WORK}/jenkins.log" || true)"

((failed_plugins == 0)) || {
  grep 'Failed Loading plugin' "${WORK}/jenkins.log" | head -5
  verdict_fail "${failed_plugins} plugin(s) failed to load"
}
((failed_items == 0)) || {
  grep 'Failed Loading item' "${WORK}/jenkins.log" | head -5
  verdict_fail "${failed_items} item(s) failed to load"
}
((jobs + folders == items_on_disk)) ||
  verdict_fail "Jenkins loaded ${jobs} jobs and ${folders} folders, the restored home holds ${items_on_disk}"
((credentials == 0 || verifiable > 0)) ||
  verdict_fail "none of the ${credentials} credentials could be checked, so the key is unproven"
((decrypted == verifiable)) ||
  verdict_fail "${decrypted} of ${verifiable} credentials decrypted: is this the key that belongs to the backup?"
[[ -z "$EXPECT_JOBS" ]] || ((jobs == EXPECT_JOBS)) ||
  verdict_fail "${jobs} jobs restored, ${EXPECT_JOBS} expected"
printf '\033[0;32mDRILL PASS\033[0m jobs=%s folders=%s credentials=%s verifiable=%s decrypted=%s\n' \
  "$jobs" "$folders" "$credentials" "$verifiable" "$decrypted"
