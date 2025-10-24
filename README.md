# CockroachDB Custom Build Recipe

Build CockroachDB from source with your own approved base OS for enterprise security compliance.

## Why This Exists

Official CockroachDB images use a fixed Ubuntu base that may not pass your security scans. This recipe lets you:
- ✅ Use **any base OS** (RHEL, Rocky, Ubuntu, etc.)
- ✅ Build from **source** (transparent, scannable)
- ✅ Run as **non-root** (UID 10001)
- ✅ Pass **security scans** with your approved base

## Quick Start

### On x86_64 Linux (Production)
```bash
# Basic build
./build.sh

# With your base OS
RUNTIME_BASE_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal:latest" ./build.sh

# Test it
docker run --rm crdb-runtime:v25.3.0 version
```

### On ARM64 Mac (Development)
```bash
# Native ARM64 build (fast, stable)
./build-mac.sh

# Test it
docker run --rm crdb-runtime:v25.3.0-arm64 version
```

**⚠️ Important:** Build on native x86_64 Linux for production. ARM64 Mac is for development only.

## Configuration

All via environment variables:

```bash
CRDB_VERSION="v25.3.0"           # CockroachDB version
WITH_UI=1                         # 1=full UI, 0=no UI (faster)
RUNTIME_BASE_IMAGE="ubuntu:22.04" # Your approved base OS

# Example
CRDB_VERSION="v24.3.0" WITH_UI=0 RUNTIME_BASE_IMAGE="rockylinux:9" ./build.sh
```

## Common Issues

### "Out of memory"
```bash
WITH_UI=0 ./build.sh  # Skip UI
```

### "QEMU segfault" on Mac
```bash
./build-mac.sh  # Use native ARM64 build instead
```

### "Wrong architecture"
- `build.sh` → x86_64 (linux/amd64)
- `build-mac.sh` → ARM64 (linux/arm64)

Check: `docker inspect crdb-runtime:v25.3.0 | grep Architecture`

## More Help

- CockroachDB issues: https://github.com/cockroachdb/cockroach/discussions

## License

This build recipe is licensed under the MIT License - see [LICENSE](LICENSE) file.

**Note:** CockroachDB itself is licensed under the Business Source License 1.1 and/or Apache License 2.0. This MIT license only applies to the build scripts and documentation in this repository.
