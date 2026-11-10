# CockroachDB runtime image on a base image of your choice.
#
# build.sh stages everything this file needs in out/ and builds it with:
#
#   docker build --pull --no-cache --platform linux/amd64 \
#     --build-arg RUNTIME_BASE_IMAGE=<your approved base image> \
#     -f Dockerfile -t crdb-runtime:v26.2.11 out/
#
# Build context (out/):
#   cockroach                   CockroachDB binary
#   cockroach.sh                entrypoint (copied from this repo)
#   lib/libgeos.so              GEOS libraries for spatial features
#   lib/libgeos_c.so
#   licenses/LICENSE            CockroachDB license
#   licenses/THIRD-PARTY-NOTICES.txt
#
# Works with glibc-based images that have microdnf, dnf, yum or apt-get:
# Red Hat UBI 8/9/10, RHEL, Amazon Linux 2023, Rocky/AlmaLinux, Debian, Ubuntu.
# Alpine (musl) is not supported: the cockroach binary needs glibc 2.17+.

ARG RUNTIME_BASE_IMAGE=registry.access.redhat.com/ubi10/ubi-minimal:latest
FROM ${RUNTIME_BASE_IMAGE}

# 1 = install every available OS update during the build. This is what clears
# "fix available" scanner findings, so leave it on unless your base image team
# already ships fully patched images. 0 = keep the base image's packages.
ARG APPLY_OS_UPDATES=1

USER 0

# Runtime packages, the same set the official cockroachdb/cockroach image adds:
#   ca-certificates  TLS certificate validation
#   tzdata           system time zone data, kept current by OS updates
#   hostname         called by the CockroachDB Helm chart and Kubernetes manifests
#   tar gzip xz      used by `kubectl cp`
#
# Package manager details:
#   --nobest              Red Hat publishes UBI images and UBI repos on separate
#                         schedules; without it a half-published update fails
#                         the build. The official image uses it for this reason.
#   --releasever=latest   Amazon Linux 2023 locks updates to the release the base
#                         image was built from, so an older base gets no updates
#                         at all without it.
#   tzdata reinstall      UBI 9 minimal ships the tzdata package without its files.
#   Package versions are deliberately not pinned: the goal is the newest fixes.
# hadolint ignore=DL3008,DL3033,DL3040,DL3041
RUN set -eu; \
    if command -v microdnf >/dev/null 2>&1; then pm=microdnf; \
    elif command -v dnf >/dev/null 2>&1; then pm=dnf; \
    elif command -v yum >/dev/null 2>&1; then pm=yum; \
    elif command -v apt-get >/dev/null 2>&1; then pm=apt-get; \
    else echo "ERROR: the base image needs microdnf, dnf, yum or apt-get" >&2; exit 1; fi; \
    os=""; \
    if [ -r /etc/os-release ]; then os="$(. /etc/os-release && echo "${ID:-}:${VERSION_ID:-}")"; fi; \
    case "$pm" in \
      microdnf|dnf) \
        rel=""; \
        if [ "$os" = "amzn:2023" ]; then rel="--releasever=latest"; fi; \
        if [ "$APPLY_OS_UPDATES" = 1 ]; then "$pm" -y ${rel:+"$rel"} update --nobest; fi; \
        "$pm" -y ${rel:+"$rel"} install --nodocs --setopt=install_weak_deps=0 \
          ca-certificates tzdata hostname tar gzip xz; \
        if [ ! -e /usr/share/zoneinfo/America/New_York ]; then "$pm" -y ${rel:+"$rel"} reinstall tzdata; fi; \
        "$pm" -y clean all ;; \
      yum) \
        if [ "$APPLY_OS_UPDATES" = 1 ]; then yum -y update; fi; \
        yum -y install ca-certificates tzdata hostname tar gzip xz; \
        if [ ! -e /usr/share/zoneinfo/America/New_York ]; then yum -y reinstall tzdata; fi; \
        yum -y clean all ;; \
      apt-get) \
        export DEBIAN_FRONTEND=noninteractive; \
        apt-get update; \
        if [ "$APPLY_OS_UPDATES" = 1 ]; then \
          apt-get -y -o APT::Get::Always-Include-Phased-Updates=true upgrade; \
        fi; \
        apt-get -y install --no-install-recommends ca-certificates tzdata hostname tar gzip xz-utils; \
        apt-get clean ;; \
    esac; \
    rm -rf /var/cache/dnf /var/cache/yum /var/lib/apt/lists/* \
           /var/log/dnf* /var/log/yum* /var/log/hawkey.log

# Non-root user: UID 10001 with primary group 0. This is the Red Hat/OpenShift
# convention, so the image also works when the platform assigns an arbitrary
# UID. The entry is written directly because useradd is missing from many
# minimal images (UBI 10 minimal, Amazon Linux 2023).
RUN set -eu; \
    if ! grep -q '^[^:]*:[^:]*:10001:' /etc/passwd; then \
      echo 'roach:x:10001:0:CockroachDB:/cockroach:/sbin/nologin' >> /etc/passwd; \
    fi; \
    mkdir -p /cockroach/cockroach-data /usr/local/lib/cockroach /licenses; \
    chown -R 10001:0 /cockroach; \
    chmod -R g=u /cockroach

# Same layout as the official image. CockroachDB looks for the GEOS libraries in
# /usr/local/lib/cockroach by default. The files stay owned by root, so the
# database process cannot modify them.
COPY cockroach.sh cockroach /cockroach/
COPY lib/libgeos.so lib/libgeos_c.so /usr/local/lib/cockroach/
COPY licenses/ /licenses/

ARG CRDB_VERSION=unknown
ARG RUNTIME_BASE_IMAGE
LABEL org.opencontainers.image.title="CockroachDB" \
      org.opencontainers.image.version="${CRDB_VERSION}" \
      org.opencontainers.image.base.name="${RUNTIME_BASE_IMAGE}" \
      org.opencontainers.image.source="https://github.com/viragtripathi/cockroachdb-custom-build" \
      name="cockroachdb" \
      summary="CockroachDB ${CRDB_VERSION}" \
      description="CockroachDB ${CRDB_VERSION} on ${RUNTIME_BASE_IMAGE}" \
      io.k8s.display-name="CockroachDB ${CRDB_VERSION}" \
      io.k8s.description="CockroachDB ${CRDB_VERSION} on ${RUNTIME_BASE_IMAGE}"

WORKDIR /cockroach/
ENV PATH=/cockroach:$PATH
EXPOSE 26257 8080

# Numeric, so Kubernetes can enforce runAsNonRoot.
USER 10001
ENTRYPOINT ["/cockroach/cockroach.sh"]
CMD ["help"]
