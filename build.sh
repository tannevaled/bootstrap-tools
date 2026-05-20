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
mkdir -p "$PREFIX/lib"
cp -a /lib64/$LDSO "$PREFIX/lib/" 2>/dev/null || cp -a /lib/$LDSO "$PREFIX/lib/"
for lib in libc libm libpthread libdl librt libutil libcrypt libresolv libnss_dns libnss_files libnss_compat libnsl libanl; do
  for ext in so.6 so.1 so.2; do
    src=$(ls /lib64/${lib}.${ext} /lib/${lib}.${ext} 2>/dev/null | head -1)
    [ -n "$src" ] && cp -a "$src" "$PREFIX/lib/" || true
  done
done
# C++ runtime from devtoolset / gcc's own install
cp -a "$PREFIX/lib64"/libstdc++.so* "$PREFIX/lib/" 2>/dev/null || true
cp -a "$PREFIX/lib64"/libgcc_s.so*  "$PREFIX/lib/" 2>/dev/null || true
echo "::endgroup::"

# --- stage 4: patchelf RPATH=$ORIGIN/../lib on every ELF in bin/ + lib/ ---
echo "::group::relocate"
"$(dirname "$0")/relocate.sh" "$PREFIX"
echo "::endgroup::"

# --- stage 5: smoke-test ---
echo "::group::smoke-test"
"$PREFIX/bin/gcc" --version | head -1
"$PREFIX/bin/g++" --version | head -1
"$PREFIX/bin/ld"  --version | head -1
"$PREFIX/lib/$LDSO" --version | head -1
# Compile a trivial C+C++ program with the new toolchain.
echo "int main(){return 0;}" > /tmp/c.c
echo "#include <iostream>" > /tmp/cxx.cc
echo "int main(){std::cout<<\"hi\\n\";return 0;}" >> /tmp/cxx.cc
"$PREFIX/bin/gcc" -o /tmp/c   /tmp/c.c   && /tmp/c
"$PREFIX/bin/g++" -o /tmp/cxx /tmp/cxx.cc && /tmp/cxx | grep -q hi
echo "::endgroup::"

echo "bootstrap-tools built into $PREFIX"
