#!/usr/bin/env bash
# prepare-kexec-cache.sh — build the host-side kexec cache that bootstrap.sh
# picks up automatically (~/.cache/alpine-fleet/kexec/ol-7/kexec, or $KEXEC_CACHE).
#
# Why a container: kexec runs on the TARGET'S CURRENT OS (Oracle Linux 7 on the
# stock OCI image), so it must be an Oracle Linux 7 binary. A CachyOS build needs a
# far newer glibc than OL7 has, and an Alpine (musl) build won't run there either.
# The container gives us OL7's own userland, so the extracted binary matches the target.
#
# Usage: prepare-kexec-cache.sh [--force]
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${KEXEC_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/alpine-fleet/kexec}/ol-7"
IMAGE="${KEXEC_BUILD_IMAGE:-docker.io/library/oraclelinux:7}"

if [[ -x "$OUT/kexec" && "${1:-}" != "--force" ]]; then
  echo "kexec cache already present: $OUT/kexec (use --force to rebuild)"
  exit 0
fi

ENGINE="$(command -v podman || command -v docker || true)"
[[ -n "$ENGINE" ]] || { echo "FATAL: need podman or docker to build the cache" >&2; exit 1; }
mkdir -p "$OUT"

echo "== building kexec cache for Oracle Linux 7 with $(basename "$ENGINE") ($IMAGE) =="
"$ENGINE" run --rm -v "$OUT:/out:Z" "$IMAGE" bash -c '
set -euo pipefail
yum install -y -q yum-utils cpio
mkdir -p /tmp/dl /tmp/x
cd /tmp/dl
yumdownloader -q kexec-tools
rpm="$(ls kexec-tools-*.rpm | head -1)"
echo "package: $rpm"
cd /tmp/x
rpm2cpio "/tmp/dl/$rpm" | cpio -idm
# Do not guess the path inside the RPM: find the binary wherever it landed.
bin="$(find /tmp/x -type f -name kexec | head -1)"
if [ -z "$bin" ]; then
  echo "FATAL: no kexec binary found in the RPM. Package contents:" >&2
  rpm -qlp "/tmp/dl/$rpm" >&2
  exit 1
fi
echo "binary inside the RPM: ${bin#/tmp/x}"
echo "--- libraries the binary needs (they must exist on the target):"
ldd "$bin"
"$bin" --version
install -m 0755 "$bin" /out/kexec
'
echo "== done: $OUT/kexec =="
echo "bootstrap.sh will now copy this to the target instead of installing kexec-tools there."