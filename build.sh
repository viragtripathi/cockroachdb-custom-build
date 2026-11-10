#!/usr/bin/env bash
# Build a CockroachDB container image on a base image you approve.
#
#   ./build.sh                                        # official binary on UBI 10 minimal
#   RUNTIME_BASE_IMAGE=<registry>/<base>:<tag> ./build.sh
#   CRDB_VERSION=v25.2.27 TARGET_ARCH=amd64 ./build.sh
#   BUILD_MODE=source ./build.sh                      # compile from source (needs repo access)
#
# Every setting is an environment variable; README.md lists them all.
set -euo pipefail

# Resolve a relative CRDB_TARBALL against the caller's directory before moving
# to the repository directory.
if [[ -n "${CRDB_TARBALL:-}" && "$CRDB_TARBALL" != /* ]]; then CRDB_TARBALL="$PWD/$CRDB_TARBALL"; fi
cd "$(dirname "${BASH_SOURCE[0]}")"

CRDB_VERSION="${CRDB_VERSION:-v26.2.11}"
BUILD_MODE="${BUILD_MODE:-release}"
RUNTIME_BASE_IMAGE="${RUNTIME_BASE_IMAGE:-registry.access.redhat.com/ubi10/ubi-minimal:latest}"
IMAGE="${IMAGE:-crdb-runtime:${CRDB_VERSION}}"
APPLY_OS_UPDATES="${APPLY_OS_UPDATES:-1}"
PULL_BASE_IMAGE="${PULL_BASE_IMAGE:-1}"
SMOKE_TEST="${SMOKE_TEST:-auto}"
# BUILD_MODE=release
CRDB_DOWNLOAD_URL="${CRDB_DOWNLOAD_URL:-https://binaries.cockroachdb.com}"
CRDB_TARBALL="${CRDB_TARBALL:-}"
CRDB_SHA256="${CRDB_SHA256:-}"
# BUILD_MODE=source
CRDB_REPO_URL="${CRDB_REPO_URL:-https://github.com/cockroachlabs/cockroach.git}"
WITH_UI="${WITH_UI:-1}"
BUILDER_BASE_IMAGE="${BUILDER_BASE_IMAGE:-ubuntu:24.04}"
BAZEL_CACHE_VOLUME="${BAZEL_CACHE_VOLUME-crdb-bazel-cache}" # set to "" to disable the cache
BAZEL_EXTRA_FLAGS="${BAZEL_EXTRA_FLAGS:-}"

log() { printf '==> %s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

case "$(uname -m)" in
  x86_64 | amd64) HOST_ARCH=amd64 ;;
  aarch64 | arm64) HOST_ARCH=arm64 ;;
  *) die "unsupported host architecture: $(uname -m)" ;;
esac
TARGET_ARCH="${TARGET_ARCH:-$HOST_ARCH}"
[[ "$TARGET_ARCH" == amd64 || "$TARGET_ARCH" == arm64 ]] ||
  die "TARGET_ARCH must be amd64 or arm64, not '$TARGET_ARCH'"
[[ "$BUILD_MODE" == release || "$BUILD_MODE" == source ]] ||
  die "BUILD_MODE must be release or source, not '$BUILD_MODE'"

if [[ -z "${CONTAINER_CLI:-}" ]]; then
  if command -v docker >/dev/null 2>&1; then
    CONTAINER_CLI=docker
  elif command -v podman >/dev/null 2>&1; then
    CONTAINER_CLI=podman
  else
    die "docker or podman is required"
  fi
fi

BUILD_CONTAINER=""
STAGING_DIR=""
cleanup() {
  if [[ -n "$BUILD_CONTAINER" ]]; then "$CONTAINER_CLI" rm -f "$BUILD_CONTAINER" >/dev/null 2>&1 || true; fi
  if [[ -n "$STAGING_DIR" ]]; then rm -rf "$STAGING_DIR"; fi
}
trap cleanup EXIT

is_release_tag() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$ ]]; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Download (or take CRDB_TARBALL), verify and unpack the official release.
stage_release() {
  local name="cockroach-${CRDB_VERSION}.linux-${TARGET_ARCH}.tgz"
  local tarball="$CRDB_TARBALL" cached=0 expected actual f

  if [[ "$WITH_UI" != 1 ]]; then
    log "WITH_UI only applies to BUILD_MODE=source; release binaries include the DB Console"
  fi
  if [[ -z "$tarball" ]]; then
    # Cache the tarball and its checksum file so rebuilds don't need the network.
    tarball=".downloads/$name"
    cached=1
    mkdir -p .downloads
    for f in "$name" "$name.sha256sum"; do
      [[ -s ".downloads/$f" ]] && continue
      log "Downloading $CRDB_DOWNLOAD_URL/$f"
      if ! curl -fSL --retry 3 -o ".downloads/$f.part" "$CRDB_DOWNLOAD_URL/$f"; then
        rm -f ".downloads/$f.part"
        die "could not download $CRDB_DOWNLOAD_URL/$f. Check CRDB_VERSION" \
          "(release tags look like v26.2.11) and your network or proxy settings."
      fi
      mv ".downloads/$f.part" ".downloads/$f"
    done
  fi
  [[ -s "$tarball" ]] || die "release tarball not found: $tarball"

  expected="$CRDB_SHA256"
  if [[ -z "$expected" && -s "$tarball.sha256sum" ]]; then
    expected="$(awk '{print $1}' "$tarball.sha256sum")"
  fi
  if [[ -z "$expected" ]]; then
    expected="$(curl -fsSL --retry 3 "$CRDB_DOWNLOAD_URL/$name.sha256sum" | awk '{print $1}')" ||
      die "could not fetch $CRDB_DOWNLOAD_URL/$name.sha256sum; set CRDB_SHA256"
  fi
  expected="$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "no valid SHA-256 for $name; set CRDB_SHA256"
  actual="$(sha256_of "$tarball")"
  if [[ "$actual" != "$expected" ]]; then
    if ((cached)); then rm -f "$tarball" "$tarball.sha256sum"; fi
    die "checksum mismatch for $name: expected $expected, got $actual"
  fi
  log "Verified $name (sha256 $actual)"

  STAGING_DIR="$(mktemp -d)"
  tar -xzf "$tarball" -C "$STAGING_DIR" --strip-components=1
  for f in cockroach lib/libgeos.so lib/libgeos_c.so LICENSE THIRD-PARTY-NOTICES.txt; do
    [[ -s "$STAGING_DIR/$f" ]] || die "$name does not contain $f"
  done
  install -m 0755 "$STAGING_DIR/cockroach" out/cockroach
  install -m 0644 "$STAGING_DIR/lib/libgeos.so" "$STAGING_DIR/lib/libgeos_c.so" out/lib/
  install -m 0644 "$STAGING_DIR/LICENSE" "$STAGING_DIR/THIRD-PARTY-NOTICES.txt" out/licenses/
  rm -rf "$STAGING_DIR"
  STAGING_DIR=""
}

# Runs inside the builder container. Mirrors the flags of CockroachDB's own
# release build (pkg/release/build.go): optimized, PGO, C dependencies built
# from source with the hermetic cross toolchain for the target architecture.
# shellcheck disable=SC2016  # expanded by bash inside the container
SOURCE_BUILD_SCRIPT='
set -euo pipefail
mkdir -p /work/cockroach /work/out/lib /work/out/licenses
# cp, not tar: on macOS/virtiofs mounts tar reports spurious "file changed" errors.
cp -R /src/. /work/cockroach/
cd /work/cockroach
flags=(-c opt --config=force_build_cdeps --config=pgo "--config=$BAZEL_CONFIG" --norun_validations)
read -r -a extra <<<"$BAZEL_EXTRA_FLAGS"
bazel build "${flags[@]}" "${extra[@]}" "--workspace_status_command=$STAMP" "$TARGET" //c-deps:libgeos
bin_dir="$(bazel info "${flags[@]}" "${extra[@]}" bazel-bin)"
install -m 0755 "$bin_dir/$BINARY" /work/out/cockroach
install -m 0644 "$bin_dir/c-deps/libgeos_foreign/lib/libgeos.so" \
  "$bin_dir/c-deps/libgeos_foreign/lib/libgeos_c.so" /work/out/lib/
install -m 0644 LICENSE licenses/THIRD-PARTY-NOTICES.txt /work/out/licenses/
'

# Clone the source and compile it in the builder container.
stage_source() {
  local config triple target binary stamp ctx
  case "$TARGET_ARCH" in
    amd64) config=crosslinuxbase triple=x86_64-pc-linux-gnu ;;
    arm64) config=crosslinuxarmbase triple=aarch64-unknown-linux-gnu ;;
  esac
  if [[ "$WITH_UI" == 1 ]]; then
    target=//pkg/cmd/cockroach:cockroach binary=pkg/cmd/cockroach/cockroach_/cockroach
  else
    target=//pkg/cmd/cockroach-short:cockroach-short
    binary=pkg/cmd/cockroach-short/cockroach-short_/cockroach-short
  fi
  # A distinct channel keeps custom builds out of Cockroach Labs' crash reports.
  stamp="./build/bazelutil/stamp.sh -t $triple -c source-build"
  if is_release_tag "$CRDB_VERSION"; then stamp="$stamp -b release"; fi

  # The C dependencies (GEOS, PROJ, krb5, jemalloc) are public git submodules.
  log "Cloning $CRDB_REPO_URL at $CRDB_VERSION"
  rm -rf cockroach
  git -c advice.detachedHead=false clone --quiet --depth 1 --recurse-submodules --shallow-submodules \
    --branch "$CRDB_VERSION" "$CRDB_REPO_URL" cockroach ||
    die "could not clone $CRDB_REPO_URL at $CRDB_VERSION (a tag or branch). The CockroachDB source repository" \
      "is private: you need read access and git credentials (for example 'gh auth login')." \
      "Without access, use BUILD_MODE=release."

  log "Building the builder image for linux/$HOST_ARCH (it cross-compiles to linux/$TARGET_ARCH)"
  ctx="$(mktemp -d)"
  "$CONTAINER_CLI" build --platform "linux/$HOST_ARCH" -f Dockerfile.builder \
    --build-arg "BUILDER_BASE_IMAGE=$BUILDER_BASE_IMAGE" -t crdb-builder:local "$ctx"
  rmdir "$ctx"

  BUILD_CONTAINER="crdb-source-build-$$"
  local -a create=(create --name "$BUILD_CONTAINER" --platform "linux/$HOST_ARCH"
    -v "$PWD/cockroach:/src:ro"
    -e "BAZEL_CONFIG=$config" -e "STAMP=$stamp" -e "TARGET=$target" -e "BINARY=$binary"
    -e "BAZEL_EXTRA_FLAGS=$BAZEL_EXTRA_FLAGS")
  if [[ -n "$BAZEL_CACHE_VOLUME" ]]; then create+=(-v "$BAZEL_CACHE_VOLUME:/home/builder/.cache"); fi
  create+=(crdb-builder:local bash -c "$SOURCE_BUILD_SCRIPT")
  "$CONTAINER_CLI" "${create[@]}" >/dev/null

  log "Compiling CockroachDB for linux/$TARGET_ARCH (a first build takes 10 minutes or more)"
  "$CONTAINER_CLI" start --attach "$BUILD_CONTAINER"
  "$CONTAINER_CLI" cp "$BUILD_CONTAINER:/work/out/." out/
  "$CONTAINER_CLI" rm "$BUILD_CONTAINER" >/dev/null
  BUILD_CONTAINER=""
}

build_image() {
  local -a args=(build --platform "linux/$TARGET_ARCH" --no-cache -f Dockerfile -t "$IMAGE"
    --build-arg "RUNTIME_BASE_IMAGE=$RUNTIME_BASE_IMAGE"
    --build-arg "APPLY_OS_UPDATES=$APPLY_OS_UPDATES"
    --build-arg "CRDB_VERSION=$CRDB_VERSION")
  if [[ "$PULL_BASE_IMAGE" == 1 ]]; then args+=(--pull); fi
  log "Building $IMAGE on $RUNTIME_BASE_IMAGE"
  "$CONTAINER_CLI" "${args[@]}" out
}

run_smoke_test() {
  local -a args=("$IMAGE")
  if is_release_tag "$CRDB_VERSION"; then args+=("$CRDB_VERSION"); fi
  case "$SMOKE_TEST" in
    0) return 0 ;;
    1) ;;
    *)
      if [[ "$TARGET_ARCH" != "$HOST_ARCH" ]]; then
        log "Skipping the smoke test of a $TARGET_ARCH image on a $HOST_ARCH host (SMOKE_TEST=1 runs it under emulation)"
        return 0
      fi
      ;;
  esac
  CONTAINER_CLI="$CONTAINER_CLI" ./smoke-test.sh "${args[@]}"
}

log "CockroachDB $CRDB_VERSION, linux/$TARGET_ARCH, BUILD_MODE=$BUILD_MODE, base $RUNTIME_BASE_IMAGE"
rm -rf out
mkdir -p out/lib out/licenses
if [[ "$BUILD_MODE" == release ]]; then stage_release; else stage_source; fi
install -m 0755 cockroach.sh out/cockroach.sh
build_image
run_smoke_test

cat <<EOF

Built $IMAGE (CockroachDB $CRDB_VERSION, linux/$TARGET_ARCH, base $RUNTIME_BASE_IMAGE)
Next steps:
  ./scan.sh $IMAGE                       # vulnerability scan
  $CONTAINER_CLI tag $IMAGE <registry>/cockroachdb:$CRDB_VERSION
  $CONTAINER_CLI push <registry>/cockroachdb:$CRDB_VERSION
EOF
