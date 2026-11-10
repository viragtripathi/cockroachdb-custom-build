# Toolchain image for BUILD_MODE=source (build.sh builds and runs it).
#
# Mirrors the compiler and build-tool parts of CockroachDB's own builder image
# (build/bazelbuilder/Dockerfile in the CockroachDB repository) without its
# CI-only tools. Bazel downloads the Go SDK, Node.js and the Linux cross
# compilers at pinned, checksummed versions, so they are not installed here.
# The image runs natively on amd64 and arm64 hosts and can target either
# architecture.

ARG BUILDER_BASE_IMAGE=docker.io/library/ubuntu:24.04
FROM ${BUILDER_BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive

# Build tools come from the distribution's signed repositories, unpinned so
# that each rebuild picks up their security fixes.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      autoconf bison ca-certificates clang-20 curl g++ git libncurses-dev libtinfo-dev \
      llvm make netbase patch python-is-python3 python3 python3-venv unzip xz-utils zip \
 && update-alternatives --install /usr/bin/clang clang /usr/bin/clang-20 100 \
      --slave /usr/bin/clang++ clang++ /usr/bin/clang++-20 \
 && ln -sf /usr/bin/llvm-nm /usr/bin/nm \
 && rm -rf /var/lib/apt/lists/*

# cmake and patchelf: the versions and checksums upstream's builder uses.
# bazelisk: reads .bazelversion from the CockroachDB source and fetches the
# matching Bazel release.
ARG CMAKE_VERSION=3.20.3
ARG PATCHELF_VERSION=0.17.2
ARG BAZELISK_VERSION=v1.30.0
RUN arch="$(uname -m)" \
 && case "$arch" in \
      x86_64) cmake_sha=97bf730372f9900b2dfb9206fccbcf92f5c7f3b502148b832e77451aa0f9e0e6 \
              patchelf_sha=a3fb9c1de3512bc91f27cc47297d6d6cf208adee9b64ed719130da59ac13e26b \
              bazelisk_arch=amd64 \
              bazelisk_sha=a248ae2b2b62b5baebb748f6fba7203bff1a27e5d01b55399a8406744cb539e8 ;; \
      aarch64) cmake_sha=77620f99e9d5f39cf4a49294c6a68c89a978ecef144894618974b9958efe3c2a \
               patchelf_sha=e5165eb592a317e1f6da0ac7fcbccf60d7fb8e5ac1f0d7336a9be51c23308b06 \
               bazelisk_arch=arm64 \
               bazelisk_sha=b2bcc040c213b44586b121bda6d983c35df121b917c3a7a66fb16f2fa0df1a4f ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/cmake.tgz \
      "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-${arch}.tar.gz" \
 && curl -fsSL -o /tmp/patchelf.tgz \
      "https://github.com/NixOS/patchelf/releases/download/${PATCHELF_VERSION}/patchelf-${PATCHELF_VERSION}-${arch}.tar.gz" \
 && curl -fsSL -o /tmp/bazelisk \
      "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-${bazelisk_arch}" \
 && printf '%s  %s\n' "$cmake_sha" /tmp/cmake.tgz "$patchelf_sha" /tmp/patchelf.tgz \
      "$bazelisk_sha" /tmp/bazelisk > /tmp/SHA256SUMS \
 && sha256sum -c /tmp/SHA256SUMS \
 && tar --strip-components=1 -C /usr -xzf /tmp/cmake.tgz \
 && tar --strip-components=1 -C /usr -xzf /tmp/patchelf.tgz \
 && install -m 0755 /tmp/bazelisk /usr/local/bin/bazel \
 && rm -f /tmp/cmake.tgz /tmp/patchelf.tgz /tmp/bazelisk /tmp/SHA256SUMS

# Bazel should not run as root. build.sh mounts a named volume on ~/.cache so
# Bazel's caches survive between builds.
RUN useradd --create-home --uid 10001 --shell /bin/bash builder \
 && mkdir -p /home/builder/.cache /work \
 && chown builder:builder /home/builder/.cache /work

USER 10001
WORKDIR /work
CMD ["/bin/bash"]
