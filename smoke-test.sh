#!/usr/bin/env bash
# Functional checks for a CockroachDB image built with this repo.
#
#   ./smoke-test.sh IMAGE [EXPECTED_VERSION]
#
# Starts a throwaway single-node cluster from IMAGE and checks what Kubernetes
# deployments and applications rely on: a numeric non-root user, the official
# image's entrypoint contract (used by the CockroachDB Helm chart), the OS
# tools the manifests call, spatial (GEOS) and time zone support.
# Exits non-zero if any check fails.
set -euo pipefail

IMAGE="${1:?usage: $0 IMAGE [EXPECTED_VERSION]}"
EXPECTED_VERSION="${2:-}"
if [[ -z "${CONTAINER_CLI:-}" ]]; then
  if command -v docker >/dev/null 2>&1; then CONTAINER_CLI=docker; else CONTAINER_CLI=podman; fi
fi
CLI="$CONTAINER_CLI"
NAME="crdb-smoke-test-$$"
failures=0

pass() { printf '  PASS  %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
  failures=$((failures + 1))
}
# expect DESCRIPTION SUBSTRING COMMAND...
# Passes when COMMAND succeeds and its output contains SUBSTRING ("" = any output).
expect() {
  local desc="$1" want="$2" out
  shift 2
  if out="$("$@" 2>&1)" && [[ "$out" == *"$want"* ]]; then
    pass "$desc"
  else
    fail "$desc" "$(printf '%s' "$out" | tail -n 2 | tr '\n' ' ' | cut -c1-240)"
  fi
}

cleanup() { "$CLI" rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Turn Ctrl-C and SIGTERM into a normal exit so the EXIT trap cleans up.
trap 'exit 130' INT
trap 'exit 143' TERM

platform="$("$CLI" image inspect --format '{{.Os}}/{{.Architecture}}' "$IMAGE")"
run() { "$CLI" run --rm --platform "$platform" "$@"; }
in_image() { run --entrypoint /bin/sh "$IMAGE" -ec "$1"; }

echo "Smoke test: $IMAGE ($platform)"

echo "Image configuration"
user="$("$CLI" image inspect --format '{{.Config.User}}' "$IMAGE")"
if [[ "$user" =~ ^[0-9]+(:[0-9]+)?$ && "${user%%:*}" != 0 ]]; then
  pass "numeric non-root USER ($user), which Kubernetes runAsNonRoot can verify"
else
  fail "numeric non-root USER" "USER is '${user:-<unset>}'; runAsNonRoot can only verify a numeric UID"
fi
expect "entrypoint is /cockroach/cockroach.sh, as in the official image" '"/cockroach/cockroach.sh"' \
  "$CLI" image inspect --format '{{json .Config.Entrypoint}}' "$IMAGE"

echo "Binary"
version_out="$(run "$IMAGE" version 2>&1 || true)"
field() { awk -F': +' -v k="$1" '$1 == k {print $2}' <<<"$version_out"; }
tag="$(field 'Build Tag')"
if [[ -n "$tag" ]]; then
  pass "cockroach $tag ($(field 'Build Type') build, $(field 'Go Version'), $(field 'Platform'))"
else
  fail "cockroach version runs" "$(tail -n 2 <<<"$version_out" | tr '\n' ' ')"
fi
if [[ -n "$EXPECTED_VERSION" ]]; then
  if [[ "$tag" == "$EXPECTED_VERSION" ]]; then pass "version is $EXPECTED_VERSION"; else fail "version is $EXPECTED_VERSION" "got '$tag'"; fi
fi
if [[ -n "$tag" && "$(field 'Build Type')" != release ]]; then
  warn "not a release build (Build Type: $(field 'Build Type')); fine for testing, not for production"
fi

echo "Entrypoint and OS contents"
expect "'shell' mode, used by the Helm chart (shell -ecx ...)" "ok" run "$IMAGE" shell -ec 'echo ok'
expect "'bash' mode" "ok" run "$IMAGE" bash -c 'echo ok'
expect "COCKROACH_ARGS replaces the arguments" "Build Tag" run -e COCKROACH_ARGS=version "$IMAGE"
# shellcheck disable=SC2016  # $t expands inside the container, not here
expect "hostname, tar, gzip and xz installed (Kubernetes manifests, kubectl cp)" "" \
  in_image 'for t in hostname tar gzip xz; do command -v "$t" >/dev/null || { echo "missing: $t"; exit 1; }; done'
expect "CA certificate bundle present" "" \
  in_image 'test -s /etc/pki/tls/certs/ca-bundle.crt || test -s /etc/ssl/certs/ca-certificates.crt'
expect "system time zone data present" "" in_image 'test -e /usr/share/zoneinfo/America/New_York'
expect "GEOS libraries in /usr/local/lib/cockroach" "" \
  in_image 'test -s /usr/local/lib/cockroach/libgeos.so && test -s /usr/local/lib/cockroach/libgeos_c.so'
expect "license files in /licenses" "" \
  in_image 'test -s /licenses/LICENSE && test -s /licenses/THIRD-PARTY-NOTICES.txt'
expect "database user cannot replace the binary or entrypoint" "" \
  in_image '! mv /cockroach/cockroach /cockroach/moved 2>/dev/null && ! touch /cockroach/new 2>/dev/null'
# 1000 is the Helm chart's runAsUser; 54321 stands in for an arbitrary OpenShift
# UID (rootless Podman cannot run UIDs above 65535, such as OpenShift's ranges).
for uid in 1000 54321; do
  expect "store directory writable as UID $uid in group 0 (Helm chart, OpenShift)" "" \
    run --user "$uid:0" --entrypoint /bin/sh "$IMAGE" -ec \
    'touch /cockroach/cockroach-data/.probe && rm /cockroach/cockroach-data/.probe'
done

echo "Running node"
"$CLI" run -d --name "$NAME" --platform "$platform" "$IMAGE" \
  start-single-node --insecure --listen-addr=127.0.0.1:26257 --http-addr=127.0.0.1:8080 >/dev/null
sql() { "$CLI" exec "$NAME" /cockroach/cockroach sql --insecure --host=127.0.0.1:26257 --format=tsv -e "$1"; }
ready=0
for _ in $(seq 1 90); do
  if sql 'SELECT 1' >/dev/null 2>&1; then ready=1; break; fi
  if [[ "$("$CLI" inspect --format '{{.State.Running}}' "$NAME" 2>/dev/null)" != true ]]; then break; fi
  sleep 2
done
if ((ready)); then
  pass "single node starts as the image user and serves SQL"
  expect "SQL write and read" "ok" \
    sql "CREATE TABLE smoke (k INT PRIMARY KEY, v STRING); INSERT INTO smoke VALUES (1, 'ok'); SELECT v FROM smoke"
  expect "spatial functions (GEOS loads)" "POLYGON" \
    sql "SELECT ST_AsText(ST_Buffer(ST_GeomFromText('POINT(0 0)'), 1, 'quad_segs=1'))"
  expect "time zone conversion (America/New_York)" "2026-07-01 08:00:00" \
    sql "SELECT (TIMESTAMPTZ '2026-07-01 12:00:00+00:00' AT TIME ZONE 'America/New_York')::STRING"
else
  fail "single node starts as the image user and serves SQL" \
    "$("$CLI" logs "$NAME" 2>&1 | tail -n 3 | tr '\n' ' ' | cut -c1-240)"
fi

echo
if ((failures)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All checks passed"
