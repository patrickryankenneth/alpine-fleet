#!/usr/bin/env bash
#
# alpine-fleet provision-and-stage.sh
#
# Combines two things that used to be separate manual steps:
#   1. "ensure this OCI instance is actually RUNNING and reachable"
#      (reattach boot volume if detached, start if stopped, poll for
#      RUNNING, resolve its public IP, wait for sshd) — logic lifted
#      from the ssh-oracle-vm healing wrapper.
#   2. "stage a kexec jump into Alpine's netboot installer" — logic
#      from bootstrap.sh.
#
# What this script deliberately does NOT do: run `kexec -e`. The jump
# itself is a one-way door for the current boot, and the only real
# safety net is a human watching a serial/console connection when it
# happens. Automating that away removes your only chance to notice a
# bad boot param before it panics. This script gets you right up to
# that point and tells you the exact next command to run yourself.
#
# Usage:
#   ./provision-and-stage.sh <instance-ocid> <ssh-key-path> [ssh-user] [alpine-version]
#
# Example:
#   ./provision-and-stage.sh ocid1.instance.oc1.phx.xxxx ~/.ssh/id_ed25519 ubuntu v3.20
#
set -euo pipefail

INSTANCE_ID="${1:?Usage: provision-and-stage.sh <instance-ocid> <ssh-key-path> [ssh-user] [alpine-version]}"
SSH_KEY="${2:?Missing ssh key path}"
SSH_USER="${3:-ubuntu}"
ALPINE_VERSION="${4:-v3.20}"
ARCH="x86_64"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/releases/${ARCH}/netboot"
REPO="http://dl-cdn.alpinelinux.org/alpine/${ALPINE_VERSION}/main"

START_TIMEOUT=240
SSH_WAIT_TIMEOUT=90

probe() { timeout 2 bash -c "exec 3<>/dev/tcp/$1/22" 2>/dev/null; }

log() { echo "[provision-and-stage] $*" >&2; }

# ---------------------------------------------------------------------
# Step 1: ensure the instance is RUNNING, reattaching the boot volume
# first if it got detached (this happens if a previous session ended
# mid-troubleshoot, e.g. after a boot-volume-attachment detach).
# ---------------------------------------------------------------------
ensure_running() {
    local status
    status="$(oci compute instance get --instance-id "$INSTANCE_ID" \
        --query 'data."lifecycle-state"' --raw-output)"
    log "current status: $status"

    if [[ "$status" == "RUNNING" ]]; then
        log "already running, skipping start."
        return
    fi

    log "attempting start..."
    if ! oci compute instance action --instance-id "$INSTANCE_ID" --action START \
            --query 'data."lifecycle-state"' --raw-output 2>/tmp/start-err.log; then
        if grep -q "Boot volume is not currently attached" /tmp/start-err.log; then
            log "boot volume detached, reattaching first..."
            local boot_vol
            boot_vol="$(oci compute boot-volume-attachment list \
                --instance-id "$INSTANCE_ID" --compartment-id "$(get_compartment)" \
                --query 'data[0]."boot-volume-id"' --raw-output 2>/dev/null || true)"
            if [[ -z "$boot_vol" || "$boot_vol" == "null" ]]; then
                log "FAILED: could not determine boot volume id automatically."
                log "Find it manually with: oci compute boot-volume list --compartment-id <id>"
                exit 1
            fi
            oci compute boot-volume-attachment attach \
                --instance-id "$INSTANCE_ID" --boot-volume-id "$boot_vol" \
                --wait-for-state ATTACHED
            oci compute instance action --instance-id "$INSTANCE_ID" --action START \
                --query 'data."lifecycle-state"' --raw-output
        else
            cat /tmp/start-err.log >&2
            exit 1
        fi
    fi

    local deadline=$((SECONDS + START_TIMEOUT))
    while (( SECONDS < deadline )); do
        status="$(oci compute instance get --instance-id "$INSTANCE_ID" \
            --query 'data."lifecycle-state"' --raw-output 2>/dev/null)"
        log "polling: status=$status (${SECONDS}s elapsed)"
        [[ "$status" == "RUNNING" ]] && return
        sleep 3
    done
    log "FAILED: never reached RUNNING within ${START_TIMEOUT}s"
    exit 1
}

get_compartment() {
    oci compute instance get --instance-id "$INSTANCE_ID" \
        --query 'data."compartment-id"' --raw-output
}

# ---------------------------------------------------------------------
# Step 2: resolve public IP, with retry (VNIC attachment can lag
# slightly behind the instance reaching RUNNING).
# ---------------------------------------------------------------------
get_public_ip() {
    local ip=""
    for attempt in 1 2 3 4 5; do
        ip="$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" \
            --query 'data[0]."public-ip"' --raw-output 2>/dev/null || true)"
        [[ -n "$ip" && "$ip" != "null" ]] && { echo "$ip"; return; }
        log "  waiting for public IP (attempt $attempt)..."
        sleep 3
    done
    log "FAILED: no public IP after retries"
    exit 1
}

# ---------------------------------------------------------------------
# Step 3: wait for sshd to actually accept connections.
# ---------------------------------------------------------------------
wait_for_ssh() {
    local ip="$1"
    local deadline=$((SECONDS + SSH_WAIT_TIMEOUT))
    while (( SECONDS < deadline )); do
        probe "$ip" && { log "sshd is accepting connections on $ip"; return; }
        log "  sshd not ready yet (${SECONDS}s elapsed)..."
        sleep 3
    done
    log "FAILED: sshd never came up on $ip"
    exit 1
}

# ---------------------------------------------------------------------
# Step 4: stage kexec on the remote box (mirrors scripts/bootstrap.sh).
# ---------------------------------------------------------------------
stage_kexec() {
    local ip="$1"
    log "staging kexec on ${SSH_USER}@${ip}..."
    ssh -i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        "${SSH_USER}@${ip}" bash -s <<REMOTE
set -euo pipefail
echo "[remote] installing kexec-tools..."
if command -v apt >/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y -qq kexec-tools
elif command -v dnf >/dev/null; then
    sudo dnf install -y kexec-tools
elif command -v apk >/dev/null; then
    sudo apk add kexec-tools
else
    echo "[remote] unknown package manager" >&2; exit 1
fi

cd /tmp
echo "[remote] fetching Alpine netboot files..."
wget -q "${MIRROR}/vmlinuz-lts"
wget -q "${MIRROR}/initramfs-lts"

echo "[remote] staging kexec..."
sudo kexec -l /tmp/vmlinuz-lts --initrd=/tmp/initramfs-lts \\
    --append="ip=dhcp alpine_repo=${REPO} modloop=${MIRROR}/modloop-lts console=ttyS0,115200"
echo "[remote] staged."
REMOTE
}

main() {
    ensure_running
    local ip
    ip="$(get_public_ip)"
    log "public IP: $ip"
    wait_for_ssh "$ip"
    stage_kexec "$ip"

    cat >&2 <<EOF

== Staged and ready ==
Instance:   $INSTANCE_ID
IP:         $ip

Next steps (manual, on purpose):
  1. Set up a console connection for THIS instance if you don't have one:
       oci compute instance-console-connection create \\
         --instance-id $INSTANCE_ID \\
         --ssh-public-key-file ~/.ssh/oci_console_rsa.pub \\
         --wait-for-state ACTIVE
  2. Open the console connection-string in a separate terminal and confirm
     it's live and watching.
  3. SSH in and jump:
       ssh -i $SSH_KEY ${SSH_USER}@${ip}
       sudo kexec -e
  4. Watch the console. Once you see 'localhost login:', log in as root
     and run: setup-alpine -f answerfiles/oci-e2-micro.answerfile
  5. After it finishes and reboots, run scripts/post-install.sh on the
     instance to add your SSH key to the persistent disk install.
EOF
}

main
