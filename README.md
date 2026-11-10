# CockroachDB Custom Image Recipe

Build a CockroachDB container image on a base OS you approve, with every available OS security update applied when the image is built.

## Why this exists

The official `cockroachdb/cockroach` images are built once per release, on Red Hat UBI, and are not rebuilt afterwards. New CVEs keep being published against the OS packages frozen inside them, so the longer a release image is in use, the more a scanner finds. A release image built in June 2025 showed more than 500 findings when scanned with Trivy in November 2026. Most were in base OS packages rather than in CockroachDB, and more than half of those already had a fixed package available.

Rebuilding on a current base fixes those, and that's what this recipe does:

- The binary is the official release tarball from binaries.cockroachdb.com, checked against its SHA-256 checksum. Building from source is optional.
- The base can be any glibc image: Red Hat UBI 10 or 9, Amazon Linux 2023, Rocky or AlmaLinux, Debian or Ubuntu, or your organization's approved image from an internal registry.
- Every available OS update is installed during the build. That includes Amazon Linux 2023, where a plain `dnf upgrade` on an older base installs nothing.
- The image has the same file layout and entrypoint arguments as the official one, but runs as non-root UID 10001. The CockroachDB Helm chart and Operator work with it unchanged; for your own manifests, see [Moving from the official image](#moving-from-the-official-image).
- `smoke-test.sh` starts the image and tests SQL, spatial functions, time zones, the Helm entrypoint and file permissions. `scan.sh` fails if any OS package has a fix available.

## Disclaimer

This repository is a reference recipe. You are responsible for the images you build and run with it.

- If you're a Cockroach Labs customer, talk to your account team before running custom images in production, so you know how they fit your support agreement. Images built in the default release mode contain the official Cockroach Labs binary; `BUILD_MODE=source` produces a custom build.
- Follow the CockroachDB license terms (see [License](#license)).

Use at your own risk. The maintainers of this repository are not responsible for issues caused by images built with it.

## Quick start

You need Docker or Podman and `curl` (plus `git` for source builds). Linux and macOS hosts work, amd64 or arm64.

```bash
git clone https://github.com/viragtripathi/cockroachdb-custom-build.git
cd cockroachdb-custom-build

# CockroachDB v26.2.11 on UBI 10 minimal, for this machine's architecture
./build.sh

# For x86_64 clusters, on your approved base image
TARGET_ARCH=amd64 RUNTIME_BASE_IMAGE=registry.example.com/approved/base:latest ./build.sh
```

`build.sh` downloads and verifies the release, builds the image, and runs `smoke-test.sh` against it when the image matches the machine's architecture. The image only gets its name if the smoke test passes. A release build usually takes a minute or two.

Building for the other architecture (for example amd64 on an arm64 machine) runs the base image's package manager under emulation. Docker Desktop and Podman on macOS handle that out of the box. On Linux, register QEMU first, for example with `docker run --privileged --rm tonistiigi/binfmt --install all` or the `qemu-user-static` package.

```bash
./scan.sh crdb-runtime:v26.2.11      # exits 1 if an OS package has a fix available

# Push it, for example to Amazon ECR
aws ecr get-login-password --region us-east-1 |
  docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com
docker tag crdb-runtime:v26.2.11 123456789012.dkr.ecr.us-east-1.amazonaws.com/cockroachdb:v26.2.11
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/cockroachdb:v26.2.11
```

Pin `CRDB_VERSION` to the release your cluster runs, for example `CRDB_VERSION=v25.2.27`.

## What the scans show

Trivy 0.76.2 on 2026-11-09, CockroachDB v26.2.11, linux/amd64, all severities:

| Base image | OS findings with a fix | OS findings without a fix yet | CockroachDB binary | Total |
|---|---|---|---|---|
| UBI 10 minimal (default) | 0 | 0 | 14 (4 high) | 14 |
| Amazon Linux 2023, minimal or standard | 0 | 0 | 14 (4 high) | 14 |
| UBI 9 minimal | 0 | 218 | 14 (4 high) | 232 |
| Amazon Linux 2023 image from August 2025 | 0 | 0 | 14 (4 high) | 14 |
| Same August 2025 base, `APPLY_OS_UPDATES=0` | 370 (252 high) | 0 | 14 (4 high) | 384 |

The last two rows are why the build applies OS updates: a base image that is a few months old carries hundreds of packages whose fixes were never installed.

The binary findings are Go standard library CVEs compiled into CockroachDB, so rebuilding the image cannot remove them. Only a CockroachDB release built with a newer Go can. v26.2.11 is built with Go 1.25.13; its 4 high findings are fixed in Go 1.26.10 and later. The latest v25.2 release, v25.2.27, is built with Go 1.23.12 and has 59 binary findings (1 critical, 25 high). If your scanning policy covers application binaries, plan for the newest release line; see [Upgrade CockroachDB](https://www.cockroachlabs.com/docs/stable/upgrade-cockroach-version).

## Choosing a base image

Any glibc-based image with `microdnf`, `dnf`, `yum` or `apt-get` works. Each of these was built and smoke-tested:

| Base | Image | Notes |
|---|---|---|
| Red Hat UBI 10 minimal (default) | `registry.access.redhat.com/ubi10/ubi-minimal` | Same base as the official v26.2 images. On x86_64 it needs an x86-64-v3 CPU; see [Troubleshooting](#troubleshooting). |
| Red Hat UBI 9 minimal | `registry.access.redhat.com/ubi9/ubi-minimal` | Base of the official v25.x images. Runs on older x86_64 CPUs. Carries more findings Red Hat has not fixed. |
| Amazon Linux 2023 | `public.ecr.aws/amazonlinux/amazonlinux:2023-minimal` or `:2023` | Updates come from the newest Amazon Linux 2023 release (`--releasever=latest`). |
| Rocky Linux 9, AlmaLinux 9 minimal | `docker.io/rockylinux/rockylinux:9-minimal`, `docker.io/almalinux/9-minimal` | RHEL 9 rebuilds. |
| Debian 13, Ubuntu 24.04 | `docker.io/library/debian:trixie-slim`, `docker.io/library/ubuntu:24.04` | Updates via `apt-get upgrade --with-new-pkgs`, including Ubuntu's phased updates. |
| Amazon Linux 2 | `docker.io/library/amazonlinux:2` | Builds, but Amazon Linux 2 reached end of support on 2026-06-30. Use Amazon Linux 2023. |
| Your approved image | `registry.example.com/approved/base:tag` | Mirror it in your registry and set `RUNTIME_BASE_IMAGE`. |

Use fully qualified image names as shown: Podman on RHEL and Fedora refuses short names such as `rockylinux/rockylinux:9-minimal` when it can't prompt.

Alpine is not supported: the CockroachDB binary needs glibc 2.17 or newer and Alpine uses musl.

If your platform team already ships fully patched base images and doesn't want packages changed, set `APPLY_OS_UPDATES=0`. The image is then only as current as its base.

## Configuration

Everything is set through environment variables. On/off settings take `0` or `1`; anything else is rejected.

| Variable | Default | Purpose |
|---|---|---|
| `CRDB_VERSION` | `v26.2.11` | CockroachDB release tag. Release mode needs a tag such as `v26.2.11`; source mode also accepts a branch. |
| `RUNTIME_BASE_IMAGE` | `registry.access.redhat.com/ubi10/ubi-minimal:latest` | Base image. |
| `TARGET_ARCH` | this machine's | `amd64` or `arm64`. |
| `IMAGE` | `crdb-runtime:$CRDB_VERSION` | Name of the image to build. |
| `APPLY_OS_UPDATES` | `1` | Install all available OS updates during the build. `0` keeps the base image's packages. |
| `PULL_BASE_IMAGE` | `1` | Pull the newest base image first. Set `0` for a base image that only exists locally. |
| `SMOKE_TEST` | `auto` | Run `smoke-test.sh` after building, and only name the image if it passes: `auto` (when the image matches this machine's architecture), `1`, or `0`. |
| `BUILD_MODE` | `release` | `release` packages the official binary. `source` compiles it; see [Building from source](#building-from-source). |
| `CONTAINER_CLI` | `docker`, else `podman` | Container tool. |
| `CRDB_DOWNLOAD_URL` | `https://binaries.cockroachdb.com` | Where release tarballs are downloaded from. Point it at an internal mirror if needed. |
| `CRDB_TARBALL` | | Path to an already downloaded `cockroach-<version>.linux-<arch>.tgz`. |
| `CRDB_SHA256` | | Expected SHA-256 of the tarball. Without it, the script reads `<tarball>.sha256sum` next to the file, or downloads it from `CRDB_DOWNLOAD_URL`. |
| `CRDB_REPO_URL` | `https://github.com/cockroachlabs/cockroach.git` | Source repository (source mode). |
| `WITH_UI` | `1` | Source mode: `0` builds `cockroach-short`, without the DB Console. |
| `BUILDER_BASE_IMAGE` | `docker.io/library/ubuntu:24.04` | Source mode: base of the builder image. |
| `BAZEL_CACHE_VOLUME` | `crdb-bazel-cache` | Source mode: named volume that keeps Bazel's caches between builds. Empty disables it. |
| `BAZEL_EXTRA_FLAGS` | | Source mode: extra Bazel flags, for example `--jobs=4`. |

`scan.sh` reads two settings of its own: `SEVERITY` (default: all severities) narrows which OS findings fail the scan, and `TRIVY_IMAGE` (default `docker.io/aquasec/trivy:0.76.2`) picks the scanner image. It passes any `TRIVY_*` variables on to Trivy.

The [`Dockerfile`](Dockerfile) can also be used without `build.sh`: put the files listed at its top in a directory and pass that directory as the build context.

## What's in the image

The layout matches the official image:

| Path | Contents |
|---|---|
| `/cockroach/cockroach` | CockroachDB binary. It and its directory are owned by root, so the database process cannot modify or replace it. |
| `/cockroach/cockroach.sh` | Entrypoint. |
| `/cockroach/cockroach-data` | Default store directory, the only path the database user can write to. |
| `/usr/local/lib/cockroach/` | GEOS libraries for spatial features. CockroachDB looks here by default. |
| `/licenses/` | CockroachDB `LICENSE` and `THIRD-PARTY-NOTICES.txt`. |

The image adds the same packages as the official one (`ca-certificates`, `tzdata`, `hostname`, `tar`, `gzip`, `xz`) plus `bash` for the Operator, applies all OS updates, uses `/cockroach` as the working directory, and exposes ports 26257 and 8080.

It runs as UID 10001 with group 0. The numeric `USER` lets Kubernetes enforce `runAsNonRoot`. The store directory is writable by group 0, so the image also runs under another UID, such as `runAsUser: 1000` in the Helm chart or an arbitrary UID on OpenShift.

The entrypoint accepts the same arguments as the official image:

| Arguments | Runs |
|---|---|
| `shell ARGS...` | `/bin/sh ARGS...`. The Helm chart starts nodes with `shell -ecx "exec /cockroach/cockroach start ..."`. |
| `bash ARGS...` | `/bin/bash ARGS...` |
| anything else | `/cockroach/cockroach ARGS...`, for example `start`, `sql` or `version`. |

If `COCKROACH_ARGS` is set, it replaces the arguments. One thing is left out: the official image's first-start helper for `start-single-node`, which generates certificates and reads `COCKROACH_DATABASE`, `COCKROACH_USER`, `COCKROACH_PASSWORD` and `/docker-entrypoint-initdb.d`. Use `--insecure` for local testing, or mount certificates.

## Moving from the official image

The official image runs as root by default; this one doesn't. The CockroachDB Helm chart and Operator already set a pod security context, so they need no changes. If you run CockroachDB from your own manifests or compose files, check these before switching an existing cluster:

- The data volume must be writable by the pod's user. Setting `securityContext.fsGroup` (any group ID) makes Kubernetes give the volume to that group and add the group to the pod's user. Data written by the official image is owned by root, so for an existing volume use `fsGroup`, or `chown` it once with an init container. Add `fsGroupChangePolicy: OnRootMismatch` so a large store isn't re-chowned on every restart.
- With Docker Compose or `docker run`, there is no `fsGroup`: `chown -R 10001:0` an existing data directory once, or run the container with `user: "0"`.
- CockroachDB only accepts a group-readable key file if root owns it and its group is the process's primary group. For keys mounted from a Secret, either set `runAsGroup` to the same ID as `fsGroup` and use `defaultMode: 0440`, or copy the keys into an `emptyDir` with an init container that runs as the pod's user and sets mode 0400. The Helm chart does the latter.
- To keep the old behavior while you migrate, you can run the image as root with `runAsUser: 0`, at the cost of the non-root default.

## Keeping the image clean

Findings come back as new CVEs are published, so a clean scan today won't stay clean. Plan to rebuild:

1. Rebuild on a schedule (weekly is a reasonable default) and whenever CockroachDB publishes a patch release for your version.
2. Gate the push on `./scan.sh`, or on your own scanner. `scan.sh` exits 1 when an OS package has a fix available, at any severity, and also when Trivy can't identify the image's OS.
3. Roll out the new image like any CockroachDB patch upgrade, with a rolling restart.

A scheduled GitHub Actions job, for example:

```yaml
on:
  schedule: [{ cron: "0 6 * * 1" }]
  workflow_dispatch:
jobs:
  image:
    runs-on: ubuntu-latest
    env:
      CRDB_VERSION: v26.2.11
      IMAGE: registry.example.com/cockroachdb:v26.2.11
    steps:
      - uses: actions/checkout@v7
      # Log in to your registry first if the base image is private.
      - run: ./build.sh
        env:
          TARGET_ARCH: amd64
          RUNTIME_BASE_IMAGE: registry.example.com/approved/base:latest
      - run: ./scan.sh "$IMAGE"
      - run: docker push "$IMAGE"
```

## Restricted networks

The build needs three things from the network, and each can come from inside yours:

| Needed | Default source | Internal alternative |
|---|---|---|
| Base image | Public registry | A copy in your registry, set as `RUNTIME_BASE_IMAGE`. |
| OS updates | The repositories configured in the base image | Your base image's own repository configuration, such as Satellite, Artifactory or a mirror. |
| CockroachDB release | binaries.cockroachdb.com | `CRDB_DOWNLOAD_URL` pointing at a mirror, or `CRDB_TARBALL`. |

For an air-gapped build host:

```bash
# On a machine with internet access
curl -fLO https://binaries.cockroachdb.com/cockroach-v26.2.11.linux-amd64.tgz
curl -fLO https://binaries.cockroachdb.com/cockroach-v26.2.11.linux-amd64.tgz.sha256sum

# Copy both files to the build host, then
CRDB_TARBALL=./cockroach-v26.2.11.linux-amd64.tgz TARGET_ARCH=amd64 \
  RUNTIME_BASE_IMAGE=registry.example.com/approved/base:latest ./build.sh
```

`build.sh` checks that the tarball is the release named by `CRDB_VERSION` and `TARGET_ARCH`, not just that it matches its checksum file. For a stronger guarantee than a checksum file that travels with the tarball, set `CRDB_SHA256` to a value you obtained separately.

Behind a proxy, `curl` reads `HTTPS_PROXY`, and the image build uses your container engine's proxy settings (for Docker, `~/.docker/config.json`). If `CRDB_DOWNLOAD_URL` contains credentials, `build.sh` masks them in its messages; a `~/.netrc` file keeps them out of the environment entirely.

`scan.sh` runs the Trivy image unless `trivy` is installed. Set `TRIVY_IMAGE` to a mirrored copy, and `TRIVY_DB_REPOSITORY` to a mirror of the vulnerability database.

## Building from source

`BUILD_MODE=source` compiles CockroachDB with the toolchain and flags Cockroach Labs uses for release builds:

- Bazel downloads hermetic cross-compilers, so any amd64 or arm64 host can compile either architecture. An Apple Silicon Mac compiles production x86_64 binaries without emulation; only the runtime image's package step runs emulated.
- Optimized, profile-guided build, with the C dependencies (GEOS, PROJ, krb5, jemalloc) compiled from source.
- Stamped as a release build of the tag, so `cockroach version` reports `v26.2.11` and `Build Type: release`. The build channel is `source-build`, which keeps custom binaries out of Cockroach Labs' crash reporting.

Requirements:

- Read access to the CockroachDB source, which now lives in a private repository, `github.com/cockroachlabs/cockroach`. The clone runs on the host with your git credentials (for example after `gh auth login`). Point `CRDB_REPO_URL` at a mirror if you have one; without access, use the default release mode.
- Network access to github.com and storage.googleapis.com, where Bazel fetches its toolchains and dependencies.
- Enough resources. Testing used a 10-CPU, 20 GB container VM, and a full build used about 15 GB of disk (13 GB of Bazel cache plus a 1 GB source checkout). On macOS, give the Docker or Podman VM at least that much.

```bash
BUILD_MODE=source TARGET_ARCH=amd64 ./build.sh
```

On that VM the compile took about 10 minutes (arm64 host, amd64 target), plus the one-time dependency downloads. Bazel's caches stay in the `crdb-bazel-cache` volume, so later builds are faster. To remove them, run `docker volume rm crdb-bazel-cache`.

## Troubleshooting

`exec format error` when the container starts means the image was built for a different architecture than the node. Build with `TARGET_ARCH=amd64` for x86_64 nodes. The same error during a cross-architecture build means the host has no emulation set up; see [Quick start](#quick-start).

If the build succeeds but the smoke test reports `No such image`, Docker is using a `docker-container` buildx builder, which doesn't load images into the local store. Switch back with `docker buildx use default`.

`Fatal glibc error: CPU does not support x86-64-v3` comes from UBI 10, which needs an x86-64-v3 CPU (AVX2, BMI2, FMA and others). Older CPUs don't qualify, and neither do VMs with a masked CPU model, such as VMware EVC baselines, the default Proxmox CPU type or Hyper-V compatibility mode. Switch the base to UBI 9 or Amazon Linux 2023, or expose the host CPU to the VM.

If pulling the base image fails with `pull access denied` because the image only exists locally, set `PULL_BASE_IMAGE=0`.

`could not clone ... The CockroachDB source repository is private` means source mode can't read the repository with your credentials. Get access, or use `BUILD_MODE=release`.

If a source build runs out of memory, give the container VM more memory or limit parallelism with `BAZEL_EXTRA_FLAGS=--jobs=4`.

Podman works as is: `build.sh` uses it when `docker` isn't installed, and `CONTAINER_CLI=podman` forces it.

## License

The scripts and documentation in this repository are MIT licensed; see [LICENSE](LICENSE).

CockroachDB is licensed separately. Version 24.3 and later use the [CockroachDB Software License](https://www.cockroachlabs.com/cockroachdb-software-license/); earlier versions use the Business Source License 1.1 and Apache License 2.0. Images built with this recipe include CockroachDB's `LICENSE` and `THIRD-PARTY-NOTICES.txt` in `/licenses`. See the [licensing FAQs](https://www.cockroachlabs.com/docs/stable/licensing-faqs) for details.
