# bootstrap-tools

Pre-built minimal toolchain seed bottle for [pkgxdev/pantry][pantry].
Closes the chicken-and-egg bootstrap problem for the GNU toolchain.

> Starter implementation. Reference: [pkgxdev/pantry#12972][rfc] (RFC).
> The canonical home for this would be `pkgxdev/bootstrap-tools`; this
> repo exists for review and iteration. Maintainers can fork-merge or
> rewrite as they see fit.

## What it produces

A single self-contained tarball per architecture, published to
GitHub Releases:

```text
bootstrap-tools-<ver>-linux+x86-64.tar.xz    (~80 MB)
bootstrap-tools-<ver>-linux+aarch64.tar.xz   (~80 MB)
```

Contents (relocatable via `$ORIGIN` RPATH after extraction):

```text
bootstrap-tools/v<ver>/
├── bin/
│   ├── gcc, g++, gfortran                # gcc 9.5
│   ├── ld, as, ar, ranlib, nm, ...       # binutils 2.32
│   ├── make, m4, awk, sed, grep, ...     # GNU userland
│   └── sh, bash, perl, python
├── lib/
│   ├── libc.so.6, ld-linux-*.so.*        # glibc 2.17 (manylinux2014 / RHEL 7 ABI baseline)
│   ├── libstdc++.so.*, libgcc_s.so.*
│   └── libm, libpthread, libdl, ...
├── include/
└── relocate.sh                           # post-extract patchelf RPATH=$ORIGIN/../lib
```

## Why glibc 2.17 baseline

It's the minimum ABI shared by:

- CentOS 7 / RHEL 7 (still in extended support)
- manylinux2014 (the Python wheel baseline ~all recent wheels target)
- Debian 9 (Stretch)
- Ubuntu 14.04 (Trusty)

Binaries linked against glibc 2.17 run unmodified on every active
Linux distro from 2014-onwards.

## How pantry recipes consume it

Once the [`build.sysroot:` directive][sysroot-pr] (pkgxdev/brewkit#343) lands,
a recipe can target this seed:

```yaml
build:
  sysroot:
    libc: pkgx.sh/bootstrap-tools
  dependencies:
    pkgx.sh/bootstrap-tools: '*'
```

This routes `gcc` at the bootstrap-tools libc 2.17 — the bottle the
recipe produces is guaranteed-portable to any manylinux2014+ host.

## Build it locally

```sh
./build.sh linux+x86-64    # ~90 min on a CI runner
./build.sh linux+aarch64   # same, on an aarch64 runner
```

Produces `dist/bootstrap-tools-<ver>-<arch>.tar.xz`.

Each `build.sh` invocation runs in a `quay.io/pypa/manylinux2014_<arch>`
container (the official PyPA manylinux2014 image — glibc 2.17 native,
maintained, and with devtoolset-10 for the seed compilation).

## CI

`.github/workflows/release.yml` matrix-builds both architectures when a
tag `v*` is pushed, then uploads each tarball + a SHA-256 manifest to
the corresponding GitHub Release.

## Layout philosophy

This isn't `pkgx.sh/coreutils` or a normal pantry recipe. It's a
**seed**: a relocatable, version-pinned snapshot of "enough toolchain
to build everything else". Like nixpkgs's `bootstrap-tools` or
conda-forge's `sysroot_linux-64`.

Per-package pantry recipes (`gnu.org/gcc`, `gnu.org/glibc`, etc.) build
from source on top of this seed. They produce the *real* dist.pkgx.dev
bottles. The seed exists only to break the circular dependency
(building gcc requires a gcc).

## Reference

- [pkgxdev/pantry#12972][rfc] — full RFC with background and discussion
- [pkgxdev/pantry#12968][glibc-pr] — gnu.org/glibc recipe (the use case that surfaced this gap)
- [pkgxdev/brewkit#343][sysroot-pr] — `build.sysroot:` directive (the recipe-side counterpart)
- [pkgm/notes/session-2026-05-19.md][notes19], [-20.md][notes20] — empirical record

[pantry]: https://github.com/pkgxdev/pantry
[rfc]: https://github.com/pkgxdev/pantry/issues/12972
[glibc-pr]: https://github.com/pkgxdev/pantry/pull/12968
[sysroot-pr]: https://github.com/pkgxdev/brewkit/pull/343
[notes19]: https://github.com/tannevaled/notes/blob/main/session-2026-05-19.md
[notes20]: https://github.com/tannevaled/notes/blob/main/session-2026-05-20.md
