#!/usr/bin/env bash
# Scan an image with Trivy, separating what a rebuild fixes from what it can't.
#
#   ./scan.sh IMAGE
#
# 1. OS packages: exits 1 if any finding at SEVERITY (default CRITICAL,HIGH)
#    has a fix available. Rebuilding with ./build.sh picks those fixes up.
# 2. CockroachDB binary (Go standard library and Go modules): reported only.
#    These are fixed by a newer CockroachDB release, not by rebuilding.
#
# Uses a local `trivy` if one is installed, otherwise the Trivy container image
# (set TRIVY_IMAGE to use an internal mirror).
set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE}"
SEVERITY="${SEVERITY:-CRITICAL,HIGH}"
TRIVY_IMAGE="${TRIVY_IMAGE:-docker.io/aquasec/trivy:latest}"
if [[ -z "${CONTAINER_CLI:-}" ]]; then
  if command -v docker >/dev/null 2>&1; then CONTAINER_CLI=docker; else CONTAINER_CLI=podman; fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$CONTAINER_CLI" save -o "$work/image.tar" "$IMAGE" >/dev/null

trivy_image() {
  if command -v trivy >/dev/null 2>&1; then
    trivy image --quiet --scanners vuln --input "$work/image.tar" "$@"
  else
    "$CONTAINER_CLI" run --rm -v "$work:/scan:ro" -v trivy-cache:/root/.cache "$TRIVY_IMAGE" \
      image --quiet --scanners vuln --input /scan/image.tar "$@"
  fi
}

echo "== OS packages: $SEVERITY findings with a fix available =="
os_status=0
trivy_image --pkg-types os --ignore-unfixed --severity "$SEVERITY" --exit-code 3 || os_status=$?

echo
echo "== CockroachDB binary: $SEVERITY findings (fixed by newer CockroachDB releases) =="
trivy_image --skip-db-update --pkg-types library --severity "$SEVERITY"

echo
case "$os_status" in
  0) echo "PASS: no fixable $SEVERITY OS vulnerabilities in $IMAGE" ;;
  3)
    echo "FAIL: $IMAGE has fixable $SEVERITY OS vulnerabilities; rebuild it with ./build.sh"
    exit 1
    ;;
  *)
    echo "ERROR: trivy failed (exit $os_status)" >&2
    exit "$os_status"
    ;;
esac
