#!/usr/bin/env bash
# Prove an image's tooling actually executes.
#
# Building for another architecture only proves the layers assembled. This runs
# every binary the backend depends on, which is what catches a package that has
# no build for that arch or a binary fetched for the wrong one.
#
# Usage:
#   test/smoke.sh                              # all backends, host arch
#   test/smoke.sh --platform linux/arm64       # all backends, emulated arm64
#   test/smoke.sh --platform linux/arm64 vault # one backend
#
# arm64 needs emulation registered first:
#   docker run --privileged --rm tonistiigi/binfmt --install arm64
set -euo pipefail

REGISTRY="${REGISTRY:-ghcr.io/quyendv/platform-backup}"
PLATFORM=""
declare -a BACKENDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      PLATFORM="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      BACKENDS+=("$1")
      shift
      ;;
  esac
done
[[ ${#BACKENDS[@]} -gt 0 ]] || BACKENDS=(postgresql mongodb etcd vault redis)

image_for() {
  case "$1" in
    postgresql) printf '%s/postgresql:pg17' "$REGISTRY" ;;
    redis) printf '%s/redis:redis8' "$REGISTRY" ;;
    *) printf '%s/%s:latest' "$REGISTRY" "$1" ;;
  esac
}

# The binaries each backend cannot work without.
tools_for() {
  local common='aws --version; supercronic -test /dev/null'
  case "$1" in
    postgresql) printf '%s; pg_dump --version; pg_restore --version; psql --version; pg_isready --version' "$common" ;;
    mongodb) printf '%s; mongodump --version; mongorestore --version' "$common" ;;
    etcd) printf '%s; etcdctl version' "$common" ;;
    vault) printf '%s; vault version' "$common" ;;
    # redis-server matters as much as redis-cli here: restore stages the RDB on it.
    redis) printf '%s; redis-cli --version; redis-server --version' "$common" ;;
  esac
}

pass() { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() {
  printf '\033[0;31mFAIL\033[0m %s\n' "$*" >&2
  FAILED=1
}

FAILED=0
declare -a platform_arg=()
[[ -n "$PLATFORM" ]] && platform_arg=(--platform "$PLATFORM")

for backend in "${BACKENDS[@]}"; do
  image="$(image_for "$backend")"
  arch="$(docker image inspect "$image" --format '{{.Architecture}}' 2>/dev/null || echo '?')"

  if ! out="$(docker run --rm "${platform_arg[@]}" --entrypoint bash "$image" \
    -c "set -e; $(tools_for "$backend")" 2>&1)"; then
    fail "${backend} (${arch}): a required tool did not run"
    printf '%s\n' "$out" | tail -5 >&2
    continue
  fi

  # The driver must also load and reject a bad mode, which exercises lib/ end
  # to end inside the image.
  if ! out="$(docker run --rm "${platform_arg[@]}" -e MODE=nonsense "$image" 2>&1)" &&
    [[ "$out" == *"Unknown MODE"* ]]; then
    pass "${backend} (${arch}): tools run and the driver loads"
  else
    fail "${backend} (${arch}): driver did not reject an unknown MODE"
    printf '%s\n' "$out" | tail -3 >&2
  fi
done

exit "$FAILED"
