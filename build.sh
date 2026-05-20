#!/usr/bin/env bash
# bootstrap-tools build script
#
# Usage:
#   ./build.sh <triple> <prefix>
#
#   triple   linux+x86-64 | linux+aarch64
#   prefix   where to install (e.g. /opt/bootstrap-tools/v0.1.0)
#
# Expected to run inside the manylinux2014 container (quay.io/pypa/
# manylinux2014_{x86_64,aarch64}). On the host:
#
#   docker run --rm --platform linux/amd64 \
#       -v $PWD:/work -w /work \
#       quay.io/pypa/manylinux2014_x86_64 \
#       bash -c 'source /opt/rh/devtoolset-10/enable && ./build.sh linux+x86-64 /opt/bootstrap-tools/v0.1.0'
#
# Outputs `${prefix}/{bin,lib,include,...}` with $ORIGIN-relative
# RPATHs (run relocate.sh post-extraction on the consumer side).

set -euo pipefail

# Resolve our own script directory to an absolute path early. Later
# stages `cd` into deep subdirs, so $(dirname "$0") returning `.` would
# break the relocate.sh invocation in stage 4.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TRIPLE=${1:?usage: $0 <triple> <prefix>}
PREFIX=${2:?usage: $0 <triple> <prefix>}

# Pinned versions for the seed. Bump these in lockstep with a fresh
# release tag of this repo.
GCC_VER=9.5.0
BINUTILS_VER=2.32
# glibc is whatever manylinux2014 ships (2.17), reused as-is — no
# recompile, just patchelf-relocated.

NPROC=$(nproc)
SRCDIR=/work/build/src
BUILDDIR=/work/build/build
mkdir -p "$SRCDIR" "$BUILDDIR" "$PREFIX"

case "$TRIPLE" in
  linux+x86-64)  ARCH=x86_64;   LDSO=ld-linux-x86-64.so.2 ;;
  linux+aarch64) ARCH=aarch64;  LDSO=ld-linux-aarch64.so.1 ;;
  *) echo "unknown triple: $TRIPLE" >&2; exit 64 ;;
esac

# --- stage 1: binutils ---
echo "::group::binutils $BINUTILS_VER"
cd "$SRCDIR"
[ -f "binutils-$BINUTILS_VER.tar.xz" ] || curl -fsSLO "https://mirror.kumi.systems/gnu/binutils/binutils-$BINUTILS_VER.tar.xz"
tar -xJf "binutils-$BINUTILS_VER.tar.xz"
cd "binutils-$BINUTILS_VER"
mkdir -p build && cd build
../configure \
  --prefix="$PREFIX" \
  --disable-werror --disable-nls \
  --enable-ld=yes --disable-gold \
  > /tmp/binutils-configure.log
# gold is deprecated upstream (Feb 2025); skip it. Also dodges
# binutils 2.32 vs gcc 10 strictness: gold/errors.h:87 references
# `std::string` without `#include <string>`, fails to compile on
# devtoolset-10's gcc 10. We don't need gold anyway.
make --jobs "$NPROC"
make install
echo "::endgroup::"

# --- stage 2: gcc ---
echo "::group::gcc $GCC_VER"
cd "$SRCDIR"
[ -f "gcc-$GCC_VER.tar.xz" ] || curl -fsSLO "https://mirror.kumi.systems/gnu/gcc/gcc-$GCC_VER/gcc-$GCC_VER.tar.xz"
tar -xJf "gcc-$GCC_VER.tar.xz"
cd "gcc-$GCC_VER"
./contrib/download_prerequisites  # gmp + mpfr + mpc + isl
mkdir -p build && cd build
../configure \
  --prefix="$PREFIX" \
  --enable-languages=c,c++,fortran \
  --disable-bootstrap \
  --disable-multilib --disable-nls \
  --disable-libsanitizer --disable-lto --disable-plugin \
  --with-system-zlib \
  --with-pkgversion="pkgx bootstrap-tools $GCC_VER" \
  > /tmp/gcc-configure.log
make --jobs "$NPROC"
make install
echo "::endgroup::"

# --- stage 3: copy host runtime libs from manylinux2014 ---
# These are glibc 2.17 + libstdc++ etc. from the container, which IS
# our intended ABI baseline. We don't rebuild them; we ship them.
echo "::group::copy runtime libs"
# Detect where the dynamic linker actually lives — manylinux2014's
# layout differs slightly between arches (x86_64 → /lib64, aarch64 →
# /lib). Search both, pick whichever exists, don't rely on a fallback
# OR-chain that interacts badly with `set -e`.
LDSO_SRC=""
for d in /lib64 /lib; do
  if [ -e "$d/$LDSO" ]; then LDSO_SRC="$d/$LDSO"; break; fi
done
if [ -z "$LDSO_SRC" ]; then
  echo "FATAL: $LDSO not found under /lib64 or /lib"
  ls -la /lib64/ld-linux* /lib/ld-linux* 2>&1 || true
  exit 65
fi

mkdir -p "$PREFIX/lib"
# IMPORTANT: cp -L (dereference) for the glibc files — they're often
# symlinks pointing back into /lib64 by absolute path, which won't
# survive extraction onto a consumer's machine. cp -L resolves to the
# real file. The SONAME embedded in the file is what consumers use to
# find it, so we don't need to preserve the original filename chain.
cp -L "$LDSO_SRC" "$PREFIX/lib/$LDSO"
echo "copied $LDSO_SRC -> $PREFIX/lib/$LDSO (dereferenced)"

for lib in libc libm libpthread libdl librt libutil libcrypt libresolv libnss_dns libnss_files libnss_compat libnsl libanl; do
  for ext in so.6 so.1 so.2; do
    for d in /lib64 /lib; do
      if [ -e "$d/${lib}.${ext}" ]; then
        cp -L "$d/${lib}.${ext}" "$PREFIX/lib/${lib}.${ext}"
        echo "  $d/${lib}.${ext}"
        break
      fi
    done
  done
done

# C++ runtime from devtoolset / gcc's own install. After gcc install,
# these end up at $PREFIX/lib64/ (x86_64 multilib convention) — copy
# (dereferencing) to $PREFIX/lib/ so consumers find them via the
# canonical lib/ path. The originals stay in lib64/ — gcc's own
# internals refer to them there.
for lib in libstdc++ libgcc_s libatomic libquadmath libgfortran; do
  for f in "$PREFIX/lib64/${lib}.so"* "$PREFIX/lib/${lib}.so"*; do
    if [ -e "$f" ] && [ ! -L "$f" ]; then
      base=$(basename "$f")
      if [ ! -e "$PREFIX/lib/$base" ]; then
        cp -L "$f" "$PREFIX/lib/$base"
        echo "  $f"
      fi
    fi
  done
done

# Sanity: confirm ld-linux actually lives where we said.
echo "--- contents of $PREFIX/lib ---"
ls -la "$PREFIX/lib" | head -20
echo "::endgroup::"

# --- stage 4: patchelf RPATH=$ORIGIN/../lib on every ELF in bin/ + lib/ ---
echo "::group::relocate"
"$SCRIPT_DIR/relocate.sh" "$PREFIX"
echo "::endgroup::"

# --- stage 5: smoke-test ---
echo "::group::smoke-test"
"$PREFIX/bin/gcc" --version | head -1
"$PREFIX/bin/g++" --version | head -1
"$PREFIX/bin/ld"  --version | head -1
# Don't run "$LDSO --version" — glibc 2.17's ld.so doesn't support it.
# Just confirm the file exists and is the expected ELF type.
[ -f "$PREFIX/lib/$LDSO" ] || { echo "FATAL: $PREFIX/lib/$LDSO missing"; exit 1; }
file "$PREFIX/lib/$LDSO" | head -1

# Compile a trivial C+C++ program with the new toolchain.
echo "int main(){return 0;}" > /tmp/c.c
cat > /tmp/cxx.cc <<'CEOF'
#include <iostream>
int main(){std::cout<<"hi\n";return 0;}
CEOF
"$PREFIX/bin/gcc" -o /tmp/c   /tmp/c.c
/tmp/c
echo "C ok"
"$PREFIX/bin/g++" -o /tmp/cxx /tmp/cxx.cc
/tmp/cxx | grep -q hi
echo "C++ ok"
echo "::endgroup::"

echo "bootstrap-tools built into $PREFIX"
