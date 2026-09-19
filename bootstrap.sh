#!/usr/bin/env bash
#
# alpine-fleet bootstrap.sh
#
# Stages a kexec jump from a running cloud VM's current OS into Alpine
# Linux's netboot installer. Does NOT perform the jump itself (kexec -e)
# — that is left as an explicit, separate step so you have a chance to
# confirm your console/serial connection is live and watching first.
#
# Usage:
#   ./bootstrap.sh <ssh-user>@<instance-ip> [alpine-version]
#
# Example:
#   ./bootstrap.sh ubuntu@129.146.82.223 v3.20
#
set -euo pipefail

TARGET="${1:?Usage: bootstrap.sh <user>@<ip> [alpine-version]}"
ALPINE_VERSION="${2:-v3.20}"
ARCH="x86_64"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/releases/${ARCH}/netboot"
REPO="http://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/main"

echo "== alpine-fleet bootstrap =="
echo "Target:  $TARGET"
echo "Version: $ALPINE_VERSION"
echo
echo "!! Before continuing, make sure you have a serial/console connection"
echo "!! open and confirmed working for this instance. This is your only"
echo "!! visibility once the kexec jump happens — SSH will die instantly."
read -r -p "Console confirmed and watching? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborting. Set up console access first (see README)."
    exit 1
fi

ssh "$TARGET" bash -s <<REMOTE
set -euo pipefail

echo "[remote] installing kexec-tools..."
if command -v apt >/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y -qq kexec-tools
elif command -v dnf >/dev/null; then
    sudo dnf install -y kexec-tools
elif command -v apk >/dev/null; then
    sudo apk add kexec-tools
else
    echo "[remote] unknown package manager, install kexec-tools manually" >&2
    exit 1
fi

cd /tmp
echo "[remote] fetching Alpine netboot kernel + initramfs..."
wget -q "${MIRROR}/vmlinuz-lts"
wget -q "${MIRROR}/initramfs-lts"

echo "[remote] staging kexec (not jumping yet)..."
sudo kexec -l /tmp/vmlinuz-lts --initrd=/tmp/initramfs-lts \\
    --append="ip=dhcp alpine_repo=${REPO} modloop=${MIRROR}/modloop-lts console=ttyS0,115200"

echo "[remote] kexec staged successfully."
echo "[remote] Run 'sudo kexec -e' on the target to jump. This script does"
echo "[remote] NOT do that for you — confirm your console is watching first."
REMOTE

echo
echo "== Staging complete =="
echo "SSH into $TARGET and run: sudo kexec -e"
echo "Then watch your console connection for boot output."
echo "Once you see 'localhost login:', log in as root and run: setup-alpine"
echo "(see answerfiles/ for a non-interactive answer file)"
