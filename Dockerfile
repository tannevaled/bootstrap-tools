# bootstrap-tools build container
#
# Base: PyPA's official manylinux2014 image. CentOS 7 derivative with
# glibc 2.17 (the ABI baseline we want to bake into the seed) and
# devtoolset-10 (gcc 10) for stage-1 compilation.
#
# Architecture is selected at build time via --build-arg ARCH=x86_64
# or ARCH=aarch64. Default is x86_64. The base image name resolves to
# quay.io/pypa/manylinux2014_${ARCH}.
ARG ARCH=x86_64
FROM quay.io/pypa/manylinux2014_${ARCH} AS builder

# Re-declare ARG inside FROM scope.
ARG ARCH

ENV LANG=C.UTF-8

# Build dependencies. manylinux2014 ships devtoolset-10 (gcc 10) and
# binutils 2.30; we use them for the stage-1 compile of gcc 9.5 and
# binutils 2.32.
SHELL ["/bin/bash", "-c"]
RUN source /opt/rh/devtoolset-10/enable && gcc --version

# Tooling needed by build.sh / relocate.sh. Manylinux2014 (CentOS 7)
# base doesn't ship patchelf in its yum repos, so we fetch the static
# upstream release. texinfo (makeinfo) and file are in the base repos.
RUN yum install -y -q file texinfo && yum clean all

ARG PATCHELF_VERSION=0.18.0
RUN case "$(uname -m)" in \
      x86_64)  PE_ARCH=x86_64 ;; \
      aarch64) PE_ARCH=aarch64 ;; \
      *) echo "unknown arch $(uname -m)" >&2; exit 1 ;; \
    esac && \
    curl -fsSLO "https://github.com/NixOS/patchelf/releases/download/${PATCHELF_VERSION}/patchelf-${PATCHELF_VERSION}-${PE_ARCH}.tar.gz" && \
    tar -xzf "patchelf-${PATCHELF_VERSION}-${PE_ARCH}.tar.gz" ./bin/patchelf && \
    install -m 755 bin/patchelf /usr/local/bin/patchelf && \
    rm -rf bin patchelf-${PATCHELF_VERSION}-${PE_ARCH}.tar.gz && \
    patchelf --version

# Allow the gcc / binutils / glibc tarballs to be cached between
# rebuilds — we copy them in rather than fetching at build time.
WORKDIR /work
COPY build.sh relocate.sh /work/

# Run the cascade. Output: /opt/bootstrap-tools/v<ver>/{bin,lib,include,...}
RUN chmod +x build.sh relocate.sh \
  && source /opt/rh/devtoolset-10/enable \
  && ./build.sh "linux+${ARCH/_/-}" /opt/bootstrap-tools

# Produce the final tarball.
RUN cd /opt && tar --owner=0 --group=0 -cJf /work/bootstrap-tools-linux+${ARCH/_/-}.tar.xz bootstrap-tools

# Stage 2: minimal output image with only the tarball, for easy extraction.
FROM scratch AS dist
COPY --from=builder /work/bootstrap-tools-linux+*.tar.xz /
