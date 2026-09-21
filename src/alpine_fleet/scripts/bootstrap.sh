#!/usr/bin/env bash
#
# alpine-fleet bootstrap.sh
#
# Stages a kexec jump from a running cloud VM's current OS into Alpine
# Linux's netboot installer with an embedded apkovl answerfile overlay.
#
set -euo pipefail

TARGET="${1:?Usage: bootstrap.sh <user>@<ip> [alpine-version] [answerfile]}"
ALPINE_VERSION="${2:-v3.24}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSWERFILE="${3:-$SCRIPT_DIR/../answerfiles/oci-e2-micro.answerfile}"
ARCH="x86_64"

[[ -f "$ANSWERFILE" ]] || { echo "FATAL: answerfile not found at $ANSWERFILE" >&2; exit 1; }
ANSWERFILE_B64="$(base64 < "$ANSWERFILE" | tr -d '\n')"

TARGET_USER="${TARGET%%@*}"
if [[ "$TARGET_USER" == "root" ]]; then
    echo "!! OCI's stock images (opc-based) reject root SSH logins outright." >&2
    echo "!! Use the image's default user instead, e.g.: opc@${TARGET#*@}" >&2
    exit 1
fi

MIRROR="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/releases/${ARCH}/netboot"
REPO="http://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/main"

echo "== alpine-fleet bootstrap =="
echo "Target:     $TARGET"
echo "Version:    $ALPINE_VERSION"
echo "Answerfile: $ANSWERFILE"
echo
echo "!! Before continuing, make sure you have a serial/console connection"
echo "!! open and confirmed working for this instance. This is your only"
echo "!! visibility once the kexec jump happens — SSH will die instantly."
read -r -p "Console confirmed and watching? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborting. Set up console access first."
    exit 1
fi

# ---- optional host-side kexec cache -------------------------------------------
# `kexec` has to run on the TARGET'S CURRENT OS (e.g. Oracle Linux 7), not on
# Alpine and not on this machine, so the cached binary must be built for that OS
# (see scripts/prepare-kexec-cache.sh). Layout: cache/kexec/<os-id>-<major>/kexec,
# e.g. cache/kexec/ol-7/kexec. A fully static binary in cache/kexec/static/kexec
# works on any x86_64 Linux. Set NO_KEXEC_CACHE=1 to ignore the cache.
KEXEC_CACHE="${KEXEC_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/alpine-fleet/kexec}"
USE_CACHED_KEXEC=0
if [[ "${NO_KEXEC_CACHE:-0}" != "1" ]]; then
    OS_ID="$(ssh -o BatchMode=yes "$TARGET" '. /etc/os-release && echo "${ID}-${VERSION_ID%%.*}"' 2>/dev/null || true)"
    for cand in "$KEXEC_CACHE/${OS_ID:-unknown}/kexec" "$KEXEC_CACHE/static/kexec"; do
        if [[ -x "$cand" ]]; then
            if scp -q -o BatchMode=yes "$cand" "$TARGET:/tmp/kexec-cached"; then
                USE_CACHED_KEXEC=1
                echo "kexec cache: HIT ($cand) for target OS '${OS_ID:-unknown}'"
                break
            fi
        fi
    done
    [[ $USE_CACHED_KEXEC == 1 ]] || echo "kexec cache: miss for target OS '${OS_ID:-unknown}' — will install kexec-tools on the target"
fi

SSH_OUT=$(mktemp)
set +e
ssh -o BatchMode=yes "$TARGET" bash -s <<REMOTE | tee "$SSH_OUT"
set -euo pipefail

cd /tmp
# Start the two netboot downloads in the background NOW: they are network-bound,
# while the package install below is CPU/disk-bound on a 1-vCPU box, so the two
# overlap instead of running back to back. Waited on (and checked) further down.
echo "[remote] fetching Alpine netboot kernel + initramfs (background)..."
( wget -q "${MIRROR}/vmlinuz-lts" -O /tmp/vmlinuz-lts && echo "[remote] kernel downloaded (t+\${SECONDS}s)" ) &
DL_KERNEL=\$!
( wget -q "${MIRROR}/initramfs-lts" -O /tmp/initramfs-lts && echo "[remote] initramfs downloaded (t+\${SECONDS}s)" ) &
DL_INITRD=\$!

if [ -x /usr/sbin/kexec ] && /usr/sbin/kexec --version >/dev/null 2>&1; then
    echo "[remote] kexec already present on the target — nothing to install"
elif [ "$USE_CACHED_KEXEC" = 1 ] && sudo install -m 0755 /tmp/kexec-cached /usr/sbin/kexec && /usr/sbin/kexec --version >/dev/null 2>&1; then
    echo "[remote] using host-cached kexec: \$(/usr/sbin/kexec --version 2>&1 | head -1) — package install skipped"
else
    echo "[remote] cached kexec unavailable or unusable — installing kexec-tools..."
    sudo rm -f /usr/sbin/kexec   # drop a cached binary that failed its --version check
    if command -v apt >/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq kexec-tools
    elif command -v dnf >/dev/null; then
        sudo dnf install -y kexec-tools
    elif command -v yum >/dev/null; then
        echo "[remote] busiest processes at start: \$(ps -eo comm --sort=-pcpu | sed 1d | head -4 | tr '\n' ' ') (t+\${SECONDS}s)"
        sudo yum makecache -q
        echo "[remote] yum metadata cached (t+\${SECONDS}s)"
        sudo yum install -y kexec-tools
    elif command -v apk >/dev/null; then
        sudo apk add kexec-tools
    else
        echo "[remote] unknown package manager, install kexec-tools manually" >&2
        exit 1
    fi
fi
echo "[remote] kexec-tools ready (t+\${SECONDS}s)"

echo "[remote] baking answerfile into an apkovl overlay..."
rm -rf /tmp/overlay /tmp/overlay.cpio.gz
mkdir -p /tmp/overlay/root
echo "$ANSWERFILE_B64" | base64 -d > /tmp/overlay/root/answers
chmod 600 /tmp/overlay/root/answers
(cd /tmp/overlay && find . | cpio -H newc -o 2>/dev/null | gzip -9 > /tmp/overlay.cpio.gz)

wait \$DL_KERNEL || { echo "[remote] kernel download failed" >&2; exit 1; }
wait \$DL_INITRD || { echo "[remote] initramfs download failed" >&2; exit 1; }
echo "[remote] netboot files downloaded (t+\${SECONDS}s)"
cat /tmp/initramfs-lts /tmp/overlay.cpio.gz > /tmp/initramfs-bundled

echo "[remote] staging kexec with bundled overlay..."
sudo kexec -l /tmp/vmlinuz-lts --initrd=/tmp/initramfs-bundled \
    --append="ip=dhcp alpine_repo=${REPO} modloop=${MIRROR}/modloop-lts console=tty0 console=ttyS0,115200"

echo "[remote] KEXEC_STAGE_OK (t+\${SECONDS}s)"
REMOTE
SSH_EXIT=$?
set -e

if [[ $SSH_EXIT -ne 0 ]] || ! grep -q "KEXEC_STAGE_OK" "$SSH_OUT"; then
    echo
    echo "!! Staging FAILED (ssh exit=$SSH_EXIT). Nothing jumped." >&2
    rm -f "$SSH_OUT"
    exit 1
fi
rm -f "$SSH_OUT"

echo
echo "== Staging confirmed on remote host =="