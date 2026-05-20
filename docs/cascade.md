# Cascade procedure

How the bootstrap-tools tarball is built, and how pantry recipes
consume it.

## Build (this repo's job)

```text
quay.io/pypa/manylinux2014_<arch>             ← base image
  │  glibc 2.17, devtoolset-10 (gcc 10), binutils 2.30
  │
  ├─→ stage 1: build binutils 2.32
  │     ../configure --prefix=$PREFIX --disable-werror --disable-nls
  │     make -j && make install
  │     → $PREFIX/bin/{ld,as,ar,...}
  │
  ├─→ stage 2: build gcc 9.5
  │     ./contrib/download_prerequisites   (gmp, mpfr, mpc, isl)
  │     ../configure --prefix=$PREFIX --enable-languages=c,c++,fortran
  │                  --disable-bootstrap --disable-multilib --disable-nls
  │                  --disable-libsanitizer --disable-lto --disable-plugin
  │     make -j && make install
  │     → $PREFIX/bin/{gcc,g++,gfortran,cpp,...}
  │
  ├─→ stage 3: bundle runtime libs
  │     cp /lib64/{ld-linux*,libc.so.6,libm.so.6,libpthread.so.0,
  │                libdl.so.2,libstdc++.so.6,libgcc_s.so.1,...} $PREFIX/lib/
  │
  ├─→ stage 4: patchelf RPATH=$ORIGIN/../lib on every ELF
  │     (see relocate.sh)
  │     → tarball usable from ANY path the consumer extracts to
  │
  └─→ stage 5: smoke-test
        $PREFIX/bin/gcc --version
        $PREFIX/bin/gcc -o /tmp/c /tmp/c.c && /tmp/c
        $PREFIX/bin/g++ -o /tmp/cxx /tmp/cxx.cc && /tmp/cxx | grep hi
        ⇒ if pass, tar -cJf bootstrap-tools-<ver>-<triple>.tar.xz
```

Total time per arch on a clean CI runner: ~90 min.

## Consume (pantry recipe's job)

After [pkgxdev/brewkit#343](https://github.com/pkgxdev/brewkit/pull/343) merges:

```yaml
# projects/gnu.org/glibc/package.yml (for the older-version branch)
build:
  sysroot:
    libc: pkgx.sh/bootstrap-tools
  dependencies:
    pkgx.sh/bootstrap-tools: '*'
  script:
    - $SYSROOT/bin/gcc --version  # gcc 9.5 from the bootstrap tarball
    - ../configure --prefix={{prefix}} ...
    - make && make install
```

`build.sysroot.libc` triggers brewkit to export `CC` / `CXX` / `CPP` /
`SYSROOT` pointing at the bootstrap-tools install. The recipe doesn't
need to know any absolute paths.

## Verify reproducibility

```sh
# In two separate fresh CI runs of the same tag:
sha256sum -b bootstrap-tools-v0.1.0-linux+x86-64.tar.xz
# Should match across runs (no timestamps in the tarball; tar
# `--owner=0 --group=0` strips uid/gid; build.sh produces
# deterministic output given the same source tarballs).
```

Known non-determinism sources (TODO: investigate / fix):
- gmp/mpfr/mpc source download via `./contrib/download_prerequisites`
  may pull a different snapshot if the upstream URL changes
- `make` parallelism can affect linker output order in some rare cases

## Versioning

Tag pattern: `v<major>.<minor>.<patch>`. Bumping rules:

- `<patch>`: re-bake from the same gcc/binutils/glibc versions
- `<minor>`: change gcc or binutils version
- `<major>`: change glibc ABI baseline (e.g. drop from 2.17 to a newer)

The pantry recipe (`pkgx.sh/bootstrap-tools/package.yml`) pins a
specific version. Pin bumps are coordinated PRs.
