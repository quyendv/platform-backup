#!/usr/bin/env bash
# SHA-256 sidecars. Every artifact gets one, so a restore can prove the bytes it
# downloaded are the bytes that were uploaded.
#
# shellcheck source=log.sh

# write_checksum FILE — writes FILE.sha256 beside FILE.
# The sidecar records the bare filename, never the path it happened to be
# written from, so `sha256sum -c` still works after the pair is downloaded
# somewhere else.
write_checksum() {
  local file="$1" dir base
  dir="$(dirname -- "$file")"
  base="$(basename -- "$file")"
  (cd "$dir" && sha256sum -- "$base" >"${base}.sha256")
}

# verify_checksum FILE — fails when the sidecar is missing or does not match.
verify_checksum() {
  local file="$1" dir base
  dir="$(dirname -- "$file")"
  base="$(basename -- "$file")"
  [[ -f "${file}.sha256" ]] || {
    log_error "Checksum file missing: ${file}.sha256"
    return 1
  }
  (cd "$dir" && sha256sum -c --status -- "${base}.sha256")
}
