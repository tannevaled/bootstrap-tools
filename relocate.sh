#!/usr/bin/env bash
# Relocate every ELF in <prefix>/{bin,lib,libexec} to use
# $ORIGIN-relative RPATHs so the tarball is portable to any path.
#
# Usage:
#   ./relocate.sh <prefix>
#
# Idempotent — safe to re-run.

set -euo pipefail

PREFIX=${1:?usage: $0 <prefix>}
PREFIX=$(realpath "$PREFIX")

PATCHELF=$(command -v patchelf || true)
if [ -z "$PATCHELF" ]; then
  # If patchelf isn't on PATH, try the bootstrap-tools' own copy
  # (build.sh installs one under bin/). Otherwise the user must
  # install patchelf separately.
  if [ -x "$PREFIX/bin/patchelf" ]; then
    PATCHELF="$PREFIX/bin/patchelf"
  else
    echo "relocate.sh: patchelf not found on PATH or in $PREFIX/bin/" >&2
    echo "  install patchelf (e.g. \`apt install patchelf\`) and re-run" >&2
    exit 2
  fi
fi

# Walk every regular file under bin/, lib/, libexec/, sbin/. Skip
# symlinks (their targets will be handled separately).
find "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/libexec" "$PREFIX/sbin" 2>/dev/null \
    -type f \
    \( -name '*.so' -o -name '*.so.*' -o ! -name '*.*' \) \
  | while read -r f; do
  # Skip if not an ELF
  if ! file -b "$f" 2>/dev/null | grep -qE 'ELF.*(executable|shared object)'; then
    continue
  fi

  # Compute the relative path from this ELF to $PREFIX/lib.
  rel=$(realpath --relative-to="$(dirname "$f")" "$PREFIX/lib")
  new_rpath="\$ORIGIN/$rel"

  cur_rpath=$($PATCHELF --print-rpath "$f" 2>/dev/null || true)
  if [ "$cur_rpath" != "$new_rpath" ]; then
    $PATCHELF --force-rpath --set-rpath "$new_rpath" "$f" 2>/dev/null || {
      echo "  (skip) $f — patchelf refused" >&2
      continue
    }
  fi

  # Fix PT_INTERP for exec'able ELFs (not .so shared libs).
  case "$f" in
    */bin/*|*/sbin/*)
      cur_interp=$($PATCHELF --print-interpreter "$f" 2>/dev/null || true)
      if [ -n "$cur_interp" ] && [[ "$cur_interp" != "$PREFIX/lib/"* ]]; then
        ldso=$(basename "$cur_interp")
        if [ -e "$PREFIX/lib/$ldso" ]; then
          $PATCHELF --set-interpreter "$PREFIX/lib/$ldso" "$f" 2>/dev/null || true
        fi
      fi
      ;;
  esac
done

echo "relocate.sh: done; all ELFs under $PREFIX use \$ORIGIN-relative RPATH"
