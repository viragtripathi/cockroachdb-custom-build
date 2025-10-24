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

## What You Get

```
Runtime Image:
├── /cockroach/cockroach    # Binary (~150MB)
├── /cockroach/libgeos/     # Spatial libraries
└── /cockroach/licenses/    # License files

Size: ~300-500MB (depends on base OS)
User: roach (UID 10001, non-root)
```

## Build Times

| Build Type | x86_64 Linux | ARM64 Mac |
|------------|--------------|-----------|
| With UI | 25-35 min | 25-35 min |
| Without UI | 15-20 min | 15-20 min |
| Cached | 2-5 min | 2-5 min |

*8-core machine, first build*

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

## Files

- `build.sh` - Production x86_64 builds
- `build-mac.sh` - Development ARM64 builds  
- `Dockerfile.builder` - x86_64 builder image
- `Dockerfile.builder.arm64` - ARM64 builder image
- `README.md` - This file
- `TROUBLESHOOTING.md` - Detailed problem solving
- `PLATFORM-NOTES.md` - ARM64 Mac context

## More Help

- Detailed docs: See `TROUBLESHOOTING.md` and `PLATFORM-NOTES.md`
- CockroachDB issues: https://github.com/cockroachdb/cockroach/discussions
- Community: https://forum.cockroachlabs.com

## License

MIT (or your choice) - See LICENSE file
