#!/usr/bin/env bash
# Scan an image with Trivy, separating what a rebuild fixes from what it can't.
#
#   ./scan.sh IMAGE
#
# 1. OS packages: exits 1 if any finding has a fix available, at any severity
#    (set SEVERITY to narrow it, for example SEVERITY=HIGH,CRITICAL). Rebuilding
#    with ./build.sh picks those fixes up. Also exits 1 if Trivy cannot identify
#    the image's operating system, because its packages would go unchecked.
# 2. CockroachDB binary (Go standard library and Go modules): reported only.
#    These are fixed by a newer CockroachDB release, not by rebuilding.
#
# Uses a local `trivy` if one is installed, otherwise the Trivy container image
# (TRIVY_IMAGE). TRIVY_* settings such as TRIVY_DB_REPOSITORY are passed on.
set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE}"
SEVERITY="${SEVERITY:-UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL}"
TRIVY_IMAGE="${TRIVY_IMAGE:-docker.io/aquasec/trivy:0.76.2}"
if [[ -z "${CONTAINER_CLI:-}" ]]; then
  if command -v docker >/dev/null 2>&1; then CONTAINER_CLI=docker; else CONTAINER_CLI=podman; fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Turn Ctrl-C and SIGTERM into a normal exit so the EXIT trap cleans up.
trap 'exit 130' INT
trap 'exit 143' TERM
"$CONTAINER_CLI" save -o "$work/image.tar" "$IMAGE" >/dev/null

trivy_env=()
while IFS='=' read -r name _; do
  case "$name" in
    TRIVY_IMAGE) ;;
    TRIVY_*) trivy_env+=(-e "$name") ;;
  esac
done < <(env)

# The image archive is copied into the Trivy container instead of bind-mounted,
# which SELinux, remote Docker hosts and some Docker setups don't allow.
trivy_image() {
  if command -v trivy >/dev/null 2>&1; then
    trivy image --quiet --scanners vuln --exit-code 0 --output /dev/stdout --input "$work/image.tar" "$@"
    return
  fi
  local cid="" status=0
  cid="$("$CONTAINER_CLI" create ${trivy_env[@]+"${trivy_env[@]}"} -v trivy-cache:/root/.cache \
    "$TRIVY_IMAGE" image --quiet --scanners vuln --exit-code 0 --output /dev/stdout --input /tmp/image.tar "$@")" || true
  # Never pass an empty name to rm: Podman treats `rm ""` and `rmi ""` as "all".
  if [[ -z "$cid" ]]; then
    echo "ERROR: could not create a container from $TRIVY_IMAGE" >&2
    return 2
  fi
  "$CONTAINER_CLI" cp "$work/image.tar" "$cid:/tmp/image.tar" >/dev/null || status=$?
  if ((status == 0)); then "$CONTAINER_CLI" start --attach "$cid" || status=$?; fi
  "$CONTAINER_CLI" rm "$cid" >/dev/null 2>&1 || true
  return "$status"
}

# One line per OS result: "<os family> <number of fixable findings>".
os_summary="$(trivy_image --pkg-types os --ignore-unfixed --severity "$SEVERITY" --format template \
  --template '{{range .}}{{if eq .Class "os-pkgs"}}{{.Type}} {{len .Vulnerabilities}}{{"\n"}}{{end}}{{end}}')" || {
  echo "ERROR: trivy failed" >&2
  exit 2
}
os_family="" os_fixable=0
read -r os_family os_fixable <<<"$os_summary" || true

echo "== OS packages: findings with a fix available ($SEVERITY) =="
if [[ -z "$os_family" ]]; then
  echo "FAIL: Trivy did not recognize the operating system in $IMAGE, so its packages were not checked"
  exit 1
fi
echo "$os_family: $os_fixable"
if ((os_fixable > 0)); then
  trivy_image --skip-db-update --format table --pkg-types os --ignore-unfixed --severity "$SEVERITY"
fi

echo
echo "== CockroachDB binary: findings ($SEVERITY), fixed by newer CockroachDB releases =="
trivy_image --skip-db-update --format table --pkg-types library --severity "$SEVERITY"

echo
if ((os_fixable > 0)); then
  echo "FAIL: $IMAGE has $os_fixable OS findings with a fix available; rebuild it with ./build.sh"
  exit 1
fi
echo "PASS: no OS findings with a fix available in $IMAGE"
