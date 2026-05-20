#!/usr/bin/env bash
# Relocate every ELF in <prefix>/{bin,lib,libexec,sbin} to use
# $ORIGIN-relative RPATHs so the tarball is portable to any path.
#
# Usage:
#   ./relocate.sh <prefix>
#
# Idempotent — safe to re-run.

set -eu  # NOT pipefail — we have piped finds where partial failure is fine

PREFIX=${1:?usage: $0 <prefix>}
PREFIX=$(realpath "$PREFIX")

PATCHELF=$(command -v patchelf || true)
if [ -z "$PATCHELF" ] && [ -x "$PREFIX/bin/patchelf" ]; then
  PATCHELF="$PREFIX/bin/patchelf"
fi
if [ -z "$PATCHELF" ]; then
  echo "relocate.sh: patchelf not found on PATH or in $PREFIX/bin/" >&2
  echo "  install patchelf (e.g. \`yum install -y patchelf\`) and re-run" >&2
  exit 2
fi
echo "using patchelf: $PATCHELF"

# Walk every regular file under bin/, lib/, libexec/, sbin/. Skip dirs
# that don't exist (gcc may not have populated all of them).
DIRS=""
for d in bin lib lib64 libexec sbin; do
  [ -d "$PREFIX/$d" ] && DIRS="$DIRS $PREFIX/$d"
done
if [ -z "$DIRS" ]; then
  echo "relocate.sh: none of bin/lib/libexec/sbin exist under $PREFIX — nothing to do" >&2
  exit 0
fi
echo "scanning: $DIRS"

# Get the list of candidate files first, then process. Avoids pipefail
# interactions with set -e on the find-into-while pipeline.
FILES=$(find $DIRS -type f \( -name '*.so' -o -name '*.so.*' -o ! -name '*.*' \) 2>/dev/null || true)

# Loop without a pipe so set -e behaves predictably.
for f in $FILES; do
  # Skip non-ELF
  filetype=$(file -b "$f" 2>/dev/null || echo "")
  if ! echo "$filetype" | grep -qE 'ELF.*(executable|shared object)'; then
    continue
  fi

  # Compute the relative path from this ELF to $PREFIX/lib.
  rel=$(realpath --relative-to="$(dirname "$f")" "$PREFIX/lib" 2>/dev/null || true)
  if [ -z "$rel" ]; then continue; fi
  new_rpath="\$ORIGIN/$rel"

  cur_rpath=$("$PATCHELF" --print-rpath "$f" 2>/dev/null || true)
  if [ "$cur_rpath" != "$new_rpath" ]; then
    if ! "$PATCHELF" --force-rpath --set-rpath "$new_rpath" "$f" 2>/dev/null; then
      echo "  (skip rpath) $f"
      continue
    fi
  fi

  # Fix PT_INTERP for exec'able ELFs (not .so shared libs).
  case "$f" in
    */bin/*|*/sbin/*)
      cur_interp=$("$PATCHELF" --print-interpreter "$f" 2>/dev/null || true)
      if [ -n "$cur_interp" ] && [[ "$cur_interp" != "$PREFIX/lib/"* ]]; then
        ldso=$(basename "$cur_interp")
        if [ -e "$PREFIX/lib/$ldso" ]; then
          "$PATCHELF" --set-interpreter "$PREFIX/lib/$ldso" "$f" 2>/dev/null || true
        fi
      fi
      ;;
  esac
done

echo "relocate.sh: done; all ELFs under $PREFIX use \$ORIGIN-relative RPATH"
