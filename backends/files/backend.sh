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
