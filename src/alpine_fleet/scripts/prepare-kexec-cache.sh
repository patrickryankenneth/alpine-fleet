#!/usr/bin/env bash
# prepare-kexec-cache.sh — build the host-side kexec cache that bootstrap.sh
# picks up automatically (~/.cache/alpine-fleet/kexec/<os-id>/kexec, or
# $KEXEC_CACHE). One cache per target OS, since kexec has to run on the
# TARGET'S CURRENT OS (whatever the stock cloud image ships), not on this
# machine and not on Alpine — a CachyOS build needs a far newer glibc than
# either target has, and a musl (Alpine) build won't run on either.
#
# Usage: prepare-kexec-cache.sh [--provider oci|gcp|all] [--force]
#   --provider oci   Oracle Linux 7 (stock OCI image)  -> cache/ol-7
#   --provider gcp   Debian 12 (stock GCP image)       -> cache/debian-12
#   --provider all   build every known target (default)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_BASE="${KEXEC_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/alpine-fleet/kexec}"

PROVIDER="all"; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    *) echo "Usage: prepare-kexec-cache.sh [--provider oci|gcp|all] [--force]" >&2; exit 1 ;;
  esac
done

ENGINE="$(command -v podman || command -v docker || true)"
[[ -n "$ENGINE" ]] || { echo "FATAL: need podman or docker to build the cache" >&2; exit 1; }

build_ol7() {
  local out="$CACHE_BASE/ol-7"
  local image="${KEXEC_BUILD_IMAGE_OCI:-docker.io/library/oraclelinux:7}"
  if [[ -x "$out/kexec" && $FORCE != 1 ]]; then
    echo "kexec cache already present: $out/kexec (use --force to rebuild)"
    return 0
  fi
  mkdir -p "$out"
  echo "== building kexec cache for Oracle Linux 7 (oci) with $(basename "$ENGINE") ($image) =="
  "$ENGINE" run --rm -v "$out:/out:Z" "$image" bash -c '
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
  echo "== done: $out/kexec =="
}

build_debian12() {
  local out="$CACHE_BASE/debian-12"
  local image="${KEXEC_BUILD_IMAGE_GCP:-docker.io/library/debian:12-slim}"
  if [[ -x "$out/kexec" && $FORCE != 1 ]]; then
    echo "kexec cache already present: $out/kexec (use --force to rebuild)"
    return 0
  fi
  mkdir -p "$out"
  echo "== building kexec cache for Debian 12 (gcp) with $(basename "$ENGINE") ($image) =="
  # DEBIAN_FRONTEND=noninteractive matters here for the same reason it does
  # in bootstrap.sh: kexec-tools asks a debconf question ("Should kexec-tools
  # handle reboots?") that plain -y does not answer.
  "$ENGINE" run --rm -v "$out:/out:Z" "$image" bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq kexec-tools
bin="$(command -v kexec || find / -xdev -type f -name kexec 2>/dev/null | head -1)"
if [ -z "$bin" ]; then
  echo "FATAL: no kexec binary found after installing kexec-tools." >&2
  exit 1
fi
echo "binary: $bin"
echo "--- libraries the binary needs (they must exist on the target):"
ldd "$bin"
"$bin" --version
install -m 0755 "$bin" /out/kexec
'
  echo "== done: $out/kexec =="
}

case "$PROVIDER" in
  oci) build_ol7 ;;
  gcp) build_debian12 ;;
  all) build_ol7; build_debian12 ;;
  *) echo "Usage: prepare-kexec-cache.sh: unknown --provider '$PROVIDER' (must be oci, gcp, or all)" >&2; exit 1 ;;
esac

echo
echo "bootstrap.sh will now copy the matching cached binary to the target instead of installing kexec-tools there."
