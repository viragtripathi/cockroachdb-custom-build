# CockroachDB Custom Build - Troubleshooting Guide

Common issues and solutions when building CockroachDB from source.

---

## Table of Contents

1. [Build Failures](#build-failures)
2. [Runtime Issues](#runtime-issues)
3. [Platform-Specific Problems](#platform-specific-problems)
4. [Performance Issues](#performance-issues)
5. [Security Scan Failures](#security-scan-failures)

---

## Build Failures

### Error: "Bazel version mismatch"

**Symptoms:**
```
ERROR: The project you're trying to build requires Bazel 7.6.0 (running 7.5.0)
```

**Cause:** CockroachDB requires a specific Bazel version (set in `.bazelversion`)

**Solution:**
```bash
# Bazelisk automatically downloads the correct version
# Ensure you're using Bazelisk, not a system Bazel:
which bazel  # Should point to bazelisk

# If you have system Bazel installed, remove it:
sudo apt-get remove bazel  # Ubuntu/Debian
brew uninstall bazel       # macOS

# Then reinstall Bazelisk as per Dockerfile.builder
```

---

### Error: "Go version mismatch"

**Symptoms:**
```
ERROR: Go version 1.22.x detected, but CockroachDB requires 1.23.12
```

**Cause:** CockroachDB's go.mod specifies exact Go version

**Solution:**

1. Check CRDB's required version:
   ```bash
   grep "^go " cockroach/go.mod
   ```

2. Update `Dockerfile.builder`:
   ```dockerfile
   ARG GO_VERSION=1.23.12  # Match go.mod
   ```

3. Rebuild builder image:
   ```bash
   docker build --no-cache -f Dockerfile.builder -t crdb-builder:local .
   ```

---

### Error: "Node.js version too old"

**Symptoms:**
```
error gyp ERR! node-gyp@10.0.0 requires Node.js ^18.17.0 || >=20.5.0
```

**Cause:** UI build requires modern Node.js

**Solution:**

Update Node.js version in `Dockerfile.builder`:
```dockerfile
RUN curl -fsSL https://nodejs.org/dist/v20.18.0/node-v20.18.0-linux-x64.tar.xz ...
```

Or skip UI build:
```bash
WITH_UI=0 ./build.sh
```

---

### Error: "Out of memory"

**Symptoms:**
```
ERROR: BUILD failed with error: Out of memory
c++: fatal error: Killed signal terminated program cc1plus
```

**Cause:** Bazel builds are memory-intensive (peak ~8GB)

**Solutions:**

1. **Limit Bazel's memory:**
   ```bash
   # In cockroach/.bazelrc.user
   build --local_ram_resources=6144  # Limit to 6GB
   build --jobs=4  # Reduce parallelism
   ```

2. **Increase Docker memory:**
   ```bash
   # Docker Desktop: Settings → Resources → Memory → 12GB+
   # Or for docker run:
   docker run --memory=10g --rm -t ...
   ```

3. **Build without UI** (uses less memory):
   ```bash
   WITH_UI=0 ./build.sh
   ```

4. **Use swap** (slower but prevents OOM):
   ```bash
   sudo fallocate -l 8G /swapfile
   sudo chmod 600 /swapfile
   sudo mkswap /swapfile
   sudo swapon /swapfile
   ```

---

### Error: "Disk space full"

**Symptoms:**
```
ERROR: no space left on device
```

**Cause:** Bazel cache + build artifacts require ~30-50GB

**Solution:**

1. **Check disk space:**
   ```bash
   df -h
   ```

2. **Clean Docker:**
   ```bash
   docker system prune -a --volumes -f
   ```

3. **Clean Bazel cache:**
   ```bash
   rm -rf ~/.cache/bazel
   # Or in project:
   rm -rf cockroach/bazel-*
   ```

4. **Use external volume** (for Docker):
   ```bash
   # Mount a larger disk
   docker run --rm -t \
     -v /mnt/large-disk/bazel-cache:/home/builder/.cache/bazel \
     ...
   ```

---

### Error: "Git clone failed"

**Symptoms:**
```
fatal: unable to access 'https://github.com/cockroachdb/cockroach.git/': 
Could not resolve host: github.com
```

**Causes:**
- No internet connectivity
- Corporate firewall blocking GitHub
- Git needs proxy configuration

**Solutions:**

1. **Check connectivity:**
   ```bash
   curl -I https://github.com
   ```

2. **Configure Git proxy:**
   ```bash
   git config --global http.proxy http://proxy.corp.com:8080
   git config --global https.proxy http://proxy.corp.com:8080
   ```

3. **Use SSH instead of HTTPS:**
   ```bash
   # In build.sh, change git clone URL:
   git clone git@github.com:cockroachdb/cockroach.git
   ```

4. **Use pre-downloaded source** (air-gapped):
   ```bash
   # Download elsewhere, then:
   tar -xzf cockroach-v25.3.0.tar.gz
   mv cockroach-25.3.0 cockroach
   # Skip git clone in build.sh
   ```

---

### Error: "Bazel build failed with exit code 1"

**Generic Bazel errors require examining logs:**

```bash
# Run with verbose output:
docker run --rm -t \
  -v "${PWD}/cockroach":/work/cockroach \
  -v "${PWD}/out":/work/out \
  -w /work/cockroach \
  crdb-builder:local \
  bash -lc 'bazel build --verbose_failures --sandbox_debug //pkg/cmd/cockroach:cockroach'

# Check Bazel logs:
less cockroach/bazel-out/_bazel.log
```

**Common sub-errors:**

- **Missing dependency:** Update `Dockerfile.builder` with required package
- **Network timeout:** Add `--http_timeout=600` to Bazel command
- **Corrupt cache:** Clean with `bazel clean --expunge`

---

## Runtime Issues

### Error: "Binary won't start"

**Symptoms:**
```
docker: Error response from daemon: failed to create task
```

**Causes:**
- Architecture mismatch (ARM vs x86_64)
- Missing shared libraries

**Solution:**

1. **Check architecture:**
   ```bash
   docker run --rm crdb-runtime:v25.3.0 uname -m
   # Should match your target (x86_64 or aarch64)
   ```

2. **Check for missing libs:**
   ```bash
   docker run --rm crdb-runtime:v25.3.0 ldd /cockroach/cockroach
   # Look for "not found"
   ```

3. **Install missing dependencies in runtime image:**
   ```dockerfile
   # In Dockerfile.runtime, add:
   RUN apt-get update && apt-get install -y libstdc++6 && rm -rf /var/lib/apt/lists/*
   ```

---

### Error: "permission denied" when starting

**Symptoms:**
```
Error: cannot create directory: permission denied
```

**Cause:** Non-root user can't write to volume paths

**Solution:**

1. **Fix directory ownership:**
   ```bash
   mkdir -p ./cockroach-data
   chown -R 10001:10001 ./cockroach-data
   
   docker run -v ./cockroach-data:/cockroach-data crdb-runtime:v25.3.0 start ...
   ```

2. **Or run with user flag:**
   ```bash
   docker run --user 10001:10001 ...
   ```

---

### Error: "libgeos.so: cannot open shared object file"

**Symptoms:**
```
error while loading shared libraries: libgeos.so.3.12.2: cannot open shared object file
```

**Cause:** Geospatial library not in expected location

**Solution:**

1. **Verify libgeos copied correctly:**
   ```bash
   docker run --rm crdb-runtime:v25.3.0 ls -la /cockroach/libgeos/
   ```

2. **Set LD_LIBRARY_PATH in runtime image:**
   ```dockerfile
   # In Dockerfile.runtime:
   ENV LD_LIBRARY_PATH=/cockroach/libgeos:$LD_LIBRARY_PATH
   ```

3. **Or create symlink:**
   ```dockerfile
   RUN ln -s /cockroach/libgeos/libgeos.so.* /usr/lib/x86_64-linux-gnu/
   ```

---

### Error: "cockroach version shows wrong version"

**Symptoms:**
```
$ docker run --rm crdb-runtime:v25.3.0 version
Build Tag:    v24.3.0   # Wrong!
```

**Cause:** Cached old build

**Solution:**

```bash
# Clean completely:
rm -rf out cockroach Dockerfile.runtime
docker rmi crdb-builder:local crdb-runtime:v25.3.0

# Rebuild:
CRDB_VERSION=v25.3.0 ./build.sh
```

---

## Platform-Specific Problems

### macOS / Podman Issues

#### Problem: "QEMU segmentation fault"

**Symptoms:**
```
qemu-x86_64-static: QEMU internal SIGSEGV
Segmentation fault (core dumped)
```

**Cause:** Podman on ARM Mac uses QEMU emulation for x86_64, which is unstable

**Solution:**

Use the ARM64 build script for testing:
```bash
./build-mac.sh
```

**For production x86_64 builds:** Use a Linux x86_64 machine or CI/CD.

---

#### Problem: "WARNING: image platform mismatch"

**Symptoms:**
```
WARNING: image platform (linux/amd64) does not match the expected platform (linux/arm64)
```

**Cause:** Pulling x86_64 images on ARM Mac

**Solution:**

This is informational only. Podman will emulate. For native builds, use:
```bash
docker build --platform linux/arm64 ...
```

---

### Ubuntu / Debian Issues

#### Problem: "GPG key errors"

**Symptoms:**
```
GPG error: http://archive.ubuntu.com/ubuntu jammy InRelease: 
The following signatures couldn't be verified
```

**Cause:** Podman on macOS has GPG key issues

**Solution:**

Already handled in `Dockerfile.builder` with `--allow-unauthenticated` flag. This is safe for build-time only. For production base images, use properly signed repos.

---

### Red Hat / CentOS Issues

#### Problem: "Package not found"

**Symptoms:**
```
No package clang available
```

**Cause:** RHEL/CentOS use different package names

**Solution:**

Update `Dockerfile.builder` for RHEL:
```dockerfile
FROM registry.access.redhat.com/ubi9/ubi:latest

RUN dnf install -y \
    ca-certificates curl git gcc gcc-c++ clang llvm \
    python3 python3-devel cmake \
    zip unzip rsync \
 && dnf clean all
```

---

## Performance Issues

### Build is extremely slow (>2 hours)

**Expected times:**
- First build: 20-40 minutes (with UI) on 8-core
- Cached builds: 2-5 minutes

**If much slower:**

1. **Check CPU allocation:**
   ```bash
   # Docker:
   docker info | grep CPUs
   # Should be at least 4
   
   # Increase in Docker Desktop: Settings → Resources → CPUs
   ```

2. **Check I/O bottleneck:**
   ```bash
   # During build:
   iostat -x 1
   # If %util near 100%, disk is bottleneck
   
   # Solution: Use SSD, or mount build on faster disk
   ```

3. **Enable Bazel remote cache:**
   See [CUSTOMIZATION.md](CUSTOMIZATION.md#build-optimizations)

4. **Build without UI:**
   ```bash
   WITH_UI=0 ./build.sh  # Saves 10-15 minutes
   ```

---

### Runtime performance is poor

**CockroachDB performance tuning is beyond this guide, but check:**

1. **Storage:** Use local SSD, not network storage
2. **Resources:** Allocate sufficient CPU/RAM (4 cores, 8GB minimum per node)
3. **Networking:** Low-latency network between nodes

---

## Security Scan Failures

### Trivy/Grype finds HIGH vulnerabilities

**In base OS packages:**

```bash
# Update packages in Dockerfile.runtime:
RUN apt-get update && apt-get upgrade -y && apt-get clean
```

**In CockroachDB dependencies:**

- Check if CVE applies to CockroachDB's usage
- Update CRDB version: newer versions may have fixes
- Report to Cockroach Labs if genuine issue

---

### Scan tool reports "unknown" OS

**Symptoms:**
```
Unable to detect OS for image crdb-runtime:v25.3.0
```

**Cause:** Minimal base images may lack `/etc/os-release`

**Solution:**

```dockerfile
# In Dockerfile.runtime, ensure OS metadata:
RUN echo 'NAME="Your Base OS"' > /etc/os-release
RUN echo 'VERSION="1.0"' >> /etc/os-release
```

---

### Corporate scanner rejects image

**Common policy violations:**

1. **Non-approved base OS**
   - Solution: Use `RUNTIME_BASE_IMAGE` with approved base

2. **Running as root**
   - Already fixed: runs as UID 10001

3. **Missing security labels**
   - Add to Dockerfile.runtime:
     ```dockerfile
     LABEL security.contact="your-team@corp.com"
     LABEL security.classification="internal"
     ```

4. **Secrets in image**
   - Verify: `docker history crdb-runtime:v25.3.0`
   - Never COPY credentials or keys

---

## Getting Help

### Collect Debug Information

```bash
# System info
uname -a
docker --version
df -h
free -h

# Build logs
./build.sh > build-full.log 2>&1

# Image inspection
docker inspect crdb-runtime:v25.3.0
docker history crdb-runtime:v25.3.0

# Binary info
docker run --rm crdb-runtime:v25.3.0 version --build-tag
docker run --rm crdb-runtime:v25.3.0 ldd /cockroach/cockroach
```

### Resources

- **CockroachDB Build Docs**: https://github.com/cockroachdb/cockroach/blob/master/BUILD.md
- **CockroachDB Community**: https://forum.cockroachlabs.com
- **Bazel Documentation**: https://bazel.build/docs
- **This Recipe Issues**: [Your repo issues page]

### Reporting Issues

When reporting issues with this build recipe, include:

1. ✅ Full build command used
2. ✅ Complete error output (not just last line)
3. ✅ Output of debug commands above
4. ✅ What you've tried already

---

## Known Limitations

### What This Recipe Doesn't Support

❌ **Windows containers** - CockroachDB requires Linux
❌ **Alpine with musl** - CRDB requires glibc (gcompat workaround possible)
❌ **Versions older than v21.x** - May require different Go/Bazel versions
❌ **ARM32** - Only ARM64 and x86_64 supported
❌ **Building on Windows/macOS without Docker** - Requires Linux environment

### Workarounds

- **Windows users:** Use WSL2 + Docker Desktop
- **macOS users:** Use the provided `build-mac.sh` for ARM64, or use Linux VM for x86_64
- **Alpine users:** Add gcompat layer or use glibc-based base

---

Still stuck? Check [CUSTOMIZATION.md](CUSTOMIZATION.md) for advanced scenarios or open an issue with debug info!
