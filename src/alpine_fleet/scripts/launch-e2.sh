#!/usr/bin/env bash
# launch-e2.sh — retries launching a free-tier E2.1.Micro instance against
# whichever AD(s) currently show headroom, until it succeeds or the
# tenancy's free-tier cap is already met. On success, resolves and prints
# the new instance's OCID and public IP.
#
# Fully dynamic: compartment ID, AD list, subnet, and image are all
# resolved at runtime via lib/oci-common.sh. No tenancy-specific values
# are hardcoded, so this file is safe to commit and share.
#
# Required override if auto-discovery doesn't pick the right subnet/image
# for your setup: set SUBNET_ID / IMAGE_ID env vars before running.
# SSH key: set SSH_KEY_FILE (default: ~/.ssh/id_ed25519.pub).

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/oci-common.sh"

SHAPE="VM.Standard.E2.1.Micro"
E2_CAP=2
DISPLAY_NAME="${DISPLAY_NAME:-micro-worker}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

BASE_SLEEP=15
MAX_SLEEP=120
JITTER_MAX=10
DISCOVERY_INTERVAL=60

OCI_BIN="$(oci_resolve_bin)" || exit 1
COMPARTMENT_ID="$(oci_resolve_compartment_id)" || exit 1
SUBNET_ID="$(oci_resolve_subnet_id "$OCI_BIN" "$COMPARTMENT_ID")" || exit 1
SUBNET_NAME=$("$OCI_BIN" network subnet get --subnet-id "$SUBNET_ID" --query "data.\"display-name\"" --raw-output 2>/dev/null)
IMAGE_ID="$(oci_resolve_image_id "$OCI_BIN" "$COMPARTMENT_ID" "$SHAPE")" || exit 1

if [ ! -f "$SSH_KEY_FILE" ]; then
  echo "FATAL: SSH public key not found at $SSH_KEY_FILE (set SSH_KEY_FILE to override)" >&2
  exit 1
fi

mapfile -t ADS < <(oci_list_availability_domains "$OCI_BIN" "$COMPARTMENT_ID")
if [ "${#ADS[@]}" -eq 0 ]; then
  echo "FATAL: no availability domains discovered." >&2
  exit 1
fi

echo "=== launch-e2.sh ==="
echo "Compartment: $COMPARTMENT_ID"
echo "Subnet:      $SUBNET_ID (${SUBNET_NAME:-unknown name})"
echo "Image:       $IMAGE_ID"
echo "SSH key:     $SSH_KEY_FILE"
echo "ADs:         ${ADS[*]}"
echo

attempt=0
sleep_time=$BASE_SLEEP

while true; do
  CURRENT=$(oci_count_running_by_shape "$OCI_BIN" "$COMPARTMENT_ID" "$SHAPE")
  CURRENT="${CURRENT:-0}"
  if [ "$CURRENT" -ge "$E2_CAP" ]; then
    echo "Already at cap ($CURRENT/$E2_CAP RUNNING). Nothing to launch. Exiting."
    exit 0
  fi

  # Find an AD with headroom this pass.
  TARGET_AD=""
  for AD in "${ADS[@]}"; do
    AVAIL=$(oci_get_availability_ad "$OCI_BIN" "$COMPARTMENT_ID" "vm-standard-e2-1-micro-count" "$AD")
    if [ -n "$AVAIL" ] && [ "$AVAIL" -gt 0 ] 2>/dev/null; then
      TARGET_AD="$AD"
      break
    fi
  done

  ts=$(date '+%Y-%m-%d %H:%M:%S')
  if [ -z "$TARGET_AD" ]; then
    echo "$ts No AD currently shows headroom. Sleeping ${DISCOVERY_INTERVAL}s..."
    sleep "$DISCOVERY_INTERVAL"
    continue
  fi

  attempt=$((attempt+1))
  echo "$ts Attempt #$attempt against $TARGET_AD (have $CURRENT/$E2_CAP)..."

  OUT=$("$OCI_BIN" compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$TARGET_AD" \
    --shape "$SHAPE" \
    --display-name "$DISPLAY_NAME" \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --ssh-authorized-keys-file "$SSH_KEY_FILE" \
    --assign-public-ip true \
    --wait-for-state RUNNING \
    2>&1)
  STATUS=$?

  if [ $STATUS -eq 0 ]; then
    echo "$ts *** SUCCESS on attempt #$attempt (AD: $TARGET_AD) ***"
    break
  fi

  if echo "$OUT" | grep -qiE "LimitExceeded|InternalError|Out of host capacity|TooManyRequests|OutOfHostCapacity"; then
    echo "$ts Capacity/limit error (expected) — retrying."
  else
    echo "$ts UNEXPECTED error:"
    echo "$OUT"
  fi

  jitter=$((RANDOM % JITTER_MAX))
  wait_now=$((sleep_time + jitter))
  echo "$ts Sleeping ${wait_now}s..."
  sleep "$wait_now"
  sleep_time=$((sleep_time * 2))
  [ $sleep_time -gt $MAX_SLEEP ] && sleep_time=$MAX_SLEEP
done

echo
echo "=== Resolving new instance details ==="
NEW_INSTANCE_ID=$("$OCI_BIN" compute instance list \
  --compartment-id "$COMPARTMENT_ID" \
  --lifecycle-state RUNNING --all \
  --query "max_by(data[?shape=='$SHAPE'], &\"time-created\").id" \
  --raw-output 2>/dev/null)

if [ -z "$NEW_INSTANCE_ID" ] || [ "$NEW_INSTANCE_ID" = "null" ]; then
  echo "FATAL: could not resolve new instance OCID after apparent success." >&2
  exit 1
fi
echo "New instance OCID: $NEW_INSTANCE_ID"

echo "Waiting for public IP to attach..."
PUBLIC_IP=""
for i in $(seq 1 20); do
  PUBLIC_IP=$("$OCI_BIN" compute instance list-vnics \
    --instance-id "$NEW_INSTANCE_ID" \
    --query "data[0].\"public-ip\"" \
    --raw-output 2>/dev/null)
  if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ]; then
    break
  fi
  echo "  ...not yet (attempt $i/20), sleeping 5s"
  sleep 5
done

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ]; then
  echo "FATAL: RUNNING but no public IP after waiting." >&2
  echo "Instance OCID for manual follow-up: $NEW_INSTANCE_ID" >&2
  exit 1
fi

echo
echo "=== DONE ==="
echo "Instance OCID: $NEW_INSTANCE_ID"
echo "Public IP:     $PUBLIC_IP"

STATE_DIR="${ALPINE_FLEET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/alpine-fleet}"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/current-instance.json"
if command -v jq >/dev/null; then
  jq -n \
    --arg id "$NEW_INSTANCE_ID" \
    --arg ip "$PUBLIC_IP" \
    --arg name "$DISPLAY_NAME" \
    --arg shape "$SHAPE" \
    --arg ssh_user "opc" \
    --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{instance_id:$id, public_ip:$ip, display_name:$name, shape:$shape, ssh_user:$ssh_user, created_at:$created}' \
    > "$STATE_FILE"
  echo "State saved: $STATE_FILE"
else
  echo "WARNING: jq not found — skipped writing $STATE_FILE. Install jq if you want" >&2
  echo "downstream scripts (orchestrate.py) to auto-discover this instance." >&2
fi