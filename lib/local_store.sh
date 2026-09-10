#!/usr/bin/env bash
# The local backup directory, laid out exactly like the S3 prefix:
#   ${BACKUP_DIR}/<run id>/<artifact>
# The shared shape is what lets one prune_select serve both sides.
#
# shellcheck source=log.sh
# shellcheck source=retention.sh

# local_list_runs DIR -> run ids of the run directories under DIR.
local_list_runs() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
    { grep -E "$RUN_ID_PATTERN" || true; }
}

# prune_local DIR KEEP — delete whole run directories beyond the newest KEEP.
# Whole directories only: an artifact and its checksum can never be separated.
prune_local() {
  local dir="$1" keep="$2" run
  while IFS= read -r run; do
    [[ -n "$run" ]] || continue
    log_warn "Pruning local run ${run}"
    rm -rf -- "${dir:?}/${run}"
  done < <(local_list_runs "$dir" | prune_select "$keep")
}
