#!/usr/bin/env bash
set -euo pipefail

CRDB_VERSION="${CRDB_VERSION:-v25.3.0}"             # pin the tag/branch you want
WITH_UI="${WITH_UI:-1}"                             # 1 = full UI; 0 = cockroach-short
RUNTIME_BASE_IMAGE="${RUNTIME_BASE_IMAGE:-ubuntu:22.04}"  # custom base

rm -rf out cockroach Dockerfile.runtime && mkdir -p out

# 1) Builder image
docker build -f Dockerfile.builder -t crdb-builder:local .

# 2) Source checkout
git clone --depth 1 --branch "${CRDB_VERSION}" https://github.com/cockroachdb/cockroach.git

# 3) Build inside Linux (non-root user)
TARGET="//pkg/cmd/cockroach:cockroach"
OUTBIN="cockroach"
if [[ "${WITH_UI}" != "1" ]]; then
  TARGET="//pkg/cmd/cockroach-short:cockroach-short"
  OUTBIN="cockroach-short"
fi

docker run --rm -t \
  -v "${PWD}/cockroach":/work/cockroach \
  -v "${PWD}/out":/work/out \
  -w /work/cockroach \
  crdb-builder:local \
  bash -lc '
    set -euo pipefail
    # Optional: prefetch deps for repeatable builds
    # bazel fetch //pkg/cmd/cockroach:cockroach //pkg:all_tests

    # Build geos + chosen binary
    if [[ "'"${WITH_UI}"'" == "1" ]]; then
      bazel build //pkg/cmd/cockroach:cockroach //pkg/cmd/geos:geos
      cp -v bazel-bin/pkg/cmd/cockroach/cockroach_/cockroach /work/out/
    else
      bazel build //pkg/cmd/cockroach-short:cockroach-short //pkg/cmd/geos:geos
      cp -v bazel-bin/pkg/cmd/cockroach-short/cockroach-short_/cockroach-short /work/out/
    fi

    # Copy GEOS shared libs for runtime
    mkdir -p /work/out/geos
    rsync -a bazel-bin/pkg/cmd/geos/ /work/out/geos/ --include="*/" --include="*.so*" --exclude="*"

    # Licenses for the runtime image
    rsync -a licenses /work/out/licenses
  '

# Normalize name so runtime COPY is stable
if [[ "${WITH_UI}" != "1" && -f out/cockroach-short ]]; then
  mv out/cockroach-short out/cockroach
fi

# 4) Create runtime image (base is swappable)
cat > Dockerfile.runtime <<'EOF'
ARG RUNTIME_BASE_IMAGE
FROM ${RUNTIME_BASE_IMAGE}

# Minimal CA certs across common distros; ignore failures on non-matching managers
RUN (command -v apt-get >/dev/null && apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*) || true
RUN (command -v microdnf >/dev/null && microdnf install -y ca-certificates && microdnf clean all) || true
RUN (command -v dnf >/dev/null && dnf install -y ca-certificates && dnf clean all) || true
RUN (command -v yum >/dev/null && yum install -y ca-certificates && yum clean all) || true

# Non-root runtime user
RUN useradd -m -u 10001 roach
USER roach
WORKDIR /cockroach

COPY --chown=roach:roach out/cockroach /cockroach/cockroach
COPY --chown=roach:roach out/geos /cockroach/libgeos
COPY --chown=roach:roach out/licenses /cockroach/licenses

ENTRYPOINT ["/cockroach/cockroach"]
CMD ["help"]
EOF

docker build \
  --build-arg RUNTIME_BASE_IMAGE="${RUNTIME_BASE_IMAGE}" \
  -t crdb-runtime:${CRDB_VERSION} \
  -f Dockerfile.runtime .

echo "Built crdb-runtime:${CRDB_VERSION} (base=${RUNTIME_BASE_IMAGE}). Try:"
echo "  docker run --rm crdb-runtime:${CRDB_VERSION} version"

