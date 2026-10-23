#!/usr/bin/env bash
# files adapter: a selection of files under one directory, as one tar.zst.
#
# A directory has no dump tool and no consistent snapshot, and the hard part is
# choosing, not copying. Three measured facts about GNU tar shape the adapter
# (see docs/superpowers/specs/2026-10-23-files-backend-design.md):
#
#   - tar does not expand globs in the names it is given, so the include list
#     is expanded here and handed to tar through -T.
#   - --exclude wildcards cross '/' and are unanchored, so `jobs/*/builds`
#     reaches every depth; and an exclusion beats an explicit include.
#   - A directory written by atomic rename reads cleanly; tar exit 1 (a file
#     changed or vanished while read) fails the run rather than ship a torn file.
#
# Sourced by lib/main.sh, which has already loaded lib/log.sh and lib/env.sh.

backend_name() { printf 'files'; }
backend_caps() { printf 'fetch restore'; }

: "${FILES_INCLUDE:=.}"
: "${FILES_EXCLUDE:=}"
: "${FILES_REQUIRE:=}"
: "${FILES_FORBID:=}"
: "${FILES_RESTORE_OVERWRITE:=false}"

# _files_words NAME -> the entries of a whitespace- or newline-separated list,
# one per line. No globbing happens here: entries are printed as written.
_files_words() {
  local -a words
  read -r -d '' -a words <<<"${!1:-}" || true
  ((${#words[@]} == 0)) || printf '%s\n' "${words[@]}"
}

# _files_expand -> every path FILES_INCLUDE matches, relative to FILES_ROOT, one
# per line. Dies naming the first entry that matches nothing: a typo or a moved
# file must fail the run, not quietly shrink the backup. globstar lets `**`
# cross directories; dotglob stays off, so a glob names dotfiles explicitly.
_files_expand() {
  (
    cd -- "$FILES_ROOT" || die "Cannot enter FILES_ROOT ${FILES_ROOT}"
    shopt -s globstar
    shopt -u nullglob dotglob
    # The default applies when the variable is set empty too, not only unset.
    FILES_INCLUDE="${FILES_INCLUDE:-.}"
    local pattern
    local -a matches
    while IFS= read -r pattern; do
      # The pattern is meant to glob here, unquoted.
      # shellcheck disable=SC2206
      matches=($pattern)
      if ((${#matches[@]} == 1)) && [[ "${matches[0]}" == "$pattern" && ! -e "$pattern" && ! -L "$pattern" ]]; then
        die "FILES_INCLUDE entry '${pattern}' matches nothing under ${FILES_ROOT}"
      fi
      printf '%s\n' "${matches[@]}"
    done < <(_files_words FILES_INCLUDE)
  )
}

backend_validate() {
  case "${MODE:-backup}" in
    # fetch only reads the object store.
    fetch) return 0 ;;
  esac
  require_env FILES_ROOT
  [[ -d "$FILES_ROOT" ]] || die "FILES_ROOT ${FILES_ROOT} is not a directory (is it mounted?)"
  [[ "${MODE:-backup}" == restore ]] && return 0
  [[ -r "$FILES_ROOT" && -x "$FILES_ROOT" ]] || die "FILES_ROOT ${FILES_ROOT} is not readable by uid $(id -u)"
  _files_expand >/dev/null
}

# _files_excludes -> one --exclude=PATTERN argument per FILES_EXCLUDE entry.
_files_excludes() {
  local pattern
  while IFS= read -r pattern; do
    printf -- '--exclude=%s\n' "$pattern"
  done < <(_files_words FILES_EXCLUDE)
}

# _files_tar_benign ERRFILE: status 0 when tar's exit 1 is explained entirely
# by changes that cannot tear a file: a directory whose entries changed while it
# was listed (an application saving by temp-file-and-rename does that, measured
# at 2 runs in 60 under a busy writer), or a file that vanished before it was
# opened. A regular file that changed while read is a torn copy and is not
# benign; neither is anything unrecognised, or an exit 1 with no explanation.
_files_tar_benign() {
  local line path seen=0
  while IFS= read -r line; do
    line="${line#tar: }"
    case "$line" in
      *": File removed before we read it") ;;
      *": file changed as we read it")
        path="${line%: file changed as we read it}"
        [[ -d "${FILES_ROOT}/${path}" && ! -L "${FILES_ROOT}/${path}" ]] || return 1
        ;;
      *) return 1 ;;
    esac
    seen=1
  done <"$1"
  ((seen == 1))
}

backend_dump() {
  local dir="$1" name="files-${RUN_ID}.tar.zst" list="$1/.files.list" errs="$1/.files.err"
  local -a excludes codes

  log_info "$(tar --version | sed -n 1p), $(zstd --version)"
  _files_expand >"$list" || die "Expanding FILES_INCLUDE failed"
  mapfile -t excludes < <(_files_excludes)

  # Both statuses are read straight away. tar exit 1 means something changed or
  # vanished while it was read; a torn file uploaded as a good backup is worse
  # than a failed run, so only the changes _files_tar_benign accepts pass.
  tar -C "$FILES_ROOT" --numeric-owner -cf - "${excludes[@]}" -T "$list" 2>"$errs" |
    zstd -q -10 -T0 >"${dir}/${name}"
  codes=("${PIPESTATUS[@]}")
  rm -f -- "$list"
  [[ ! -s "$errs" ]] || cat -- "$errs" >&2
  if ((codes[0] == 1)) && _files_tar_benign "$errs"; then
    log_warn "tar saw directories change or files vanish while it read them; no file was torn"
    codes[0]=0
  fi
  rm -f -- "$errs"
  ((codes[0] == 0)) || die "tar failed (exit ${codes[0]}) archiving ${FILES_ROOT}"
  ((codes[1] == 0)) || die "zstd failed (exit ${codes[1]})"

  printf '%s' "$name"
}

# _files_listing ARCHIVE -> the archive's entries, one per line, directories
# without their trailing slash. Fails if the archive cannot be read whole.
_files_listing() {
  local archive="$1"
  local -a codes
  zstd -dc -- "$archive" | tar -tf - | sed 's|/$||'
  codes=("${PIPESTATUS[@]}")
  ((codes[0] == 0 && codes[1] == 0)) || {
    printf 'Cannot list %s (zstd exit %s, tar exit %s)\n' "$archive" "${codes[0]}" "${codes[1]}" >&2
    return 1
  }
}

# _files_matches PATTERN ENTRY: status 0 when ENTRY matches PATTERN the way tar
# --exclude matches by default (wildcards cross '/', unanchored, and a matched
# directory takes everything under it). One definition, so FILES_FORBID means
# exactly what the same pattern would mean in FILES_EXCLUDE.
_files_matches() {
  local p="$1" e="$2"
  # Unquoted on the right of == on purpose: these are patterns.
  # shellcheck disable=SC2053
  [[ "$e" == $p || "$e" == */$p || "$e" == $p/* || "$e" == */$p/* ]]
}

backend_verify() {
  local archive="$1" listing entry pattern required count
  zstd -q -t -- "$archive" || die "Artifact is not a valid zstd stream: ${archive}"
  listing="$(mktemp)"
  _files_listing "$archive" >"$listing" || {
    rm -f -- "$listing"
    die "Artifact is not a readable tar archive: ${archive}"
  }
  count="$(wc -l <"$listing")"
  ((count > 0)) || {
    rm -f -- "$listing"
    die "Artifact holds no entries: ${archive}"
  }

  local missing=""
  while IFS= read -r required; do
    grep -Fxq -- "$required" "$listing" || missing+="${missing:+, }${required}"
  done < <(_files_words FILES_REQUIRE)
  [[ -z "$missing" ]] || {
    rm -f -- "$listing"
    die "FILES_REQUIRE path(s) not in the archive: ${missing}"
  }

  local forbidden=""
  while IFS= read -r pattern; do
    while IFS= read -r entry; do
      if _files_matches "$pattern" "$entry"; then
        forbidden="'${entry}', which matches FILES_FORBID '${pattern}'"
        break 2
      fi
    done <"$listing"
  done < <(_files_words FILES_FORBID)
  rm -f -- "$listing"
  [[ -z "$forbidden" ]] || die "Archive holds ${forbidden}"

  log_info "Archive holds ${count} entries; required paths present, no forbidden path"
}

# _files_target_empty DIR: status 0 when DIR holds nothing but lost+found, which
# a freshly formatted volume always has.
_files_target_empty() {
  [[ -z "$(find "$1" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit)" ]]
}

backend_restore() {
  local archive="$1" target="${FILES_RESTORE_TARGET:-$FILES_ROOT}" count
  local -a codes

  backend_verify "$archive"
  mkdir -p -- "$target" || die "Cannot create the restore target ${target}"
  if ! _files_target_empty "$target"; then
    bool_is_true FILES_RESTORE_OVERWRITE ||
      die "Restore target ${target} is not empty; set FILES_RESTORE_OVERWRITE=true to extract over it (nothing is deleted)"
    log_warn "Extracting over ${target}: archived files replace their namesakes, everything else stays"
  fi
  log_warn "Restore writes into ${target}: the application must be stopped (a running one cannot be detected)"

  zstd -dc -- "$archive" | tar -C "$target" -xf - --same-owner --numeric-owner --preserve-permissions
  codes=("${PIPESTATUS[@]}")
  ((codes[0] == 0)) || die "zstd failed (exit ${codes[0]}) reading ${archive}"
  ((codes[1] == 0)) || die "tar failed (exit ${codes[1]}) extracting into ${target}"

  count="$(_files_listing "$archive" | wc -l)"
  log_ok "Restored ${count} entries into ${target}"
}
