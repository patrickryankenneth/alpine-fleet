#!/usr/bin/env bash
# launch-gcp.sh — retries launching a free-tier e2-micro instance across
# whichever Always-Free-eligible zone currently has capacity, until it
# succeeds or the account's free-tier cap is already met.
#
# Mirrors launch-e2.sh's interface/behavior for GCP so orchestrate.py
# can drive either provider identically. Fully dynamic: project, zones,
# and image are resolved at runtime via lib/gcp-common.sh. Nothing
# project-specific is hardcoded, so this file is safe to commit and
# share.
#
# Unlike OCI, GCP has no per-zone "headroom" query — the only reliable
# signal for capacity is attempting the launch and reading the error,
# so this cycles through the free-tier zones on each retry rather than
# polling availability first.
#
# SSH key: set SSH_KEY_FILE (default: ~/.ssh/id_ed25519.pub) — pushed
# as instance metadata (ssh-keys), the standard mechanism for projects
# that don't have OS Login enabled.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/gcp-common.sh"

DISPLAY_NAME="${DISPLAY_NAME:-micro-worker}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
SSH_USER="${SSH_USER:-$(whoami)}"

BASE_SLEEP=15
MAX_SLEEP=120
JITTER_MAX=10
FREE_CAP=1   # GCP Always Free: 1 non-preemptible e2-micro/account/month

GCLOUD_BIN="$(gcp_resolve_bin)" || exit 1
PROJECT="$(gcp_resolve_project "$GCLOUD_BIN")" || exit 1
SHAPE="$(gcp_free_tier_shape)"
IMAGE="$(gcp_resolve_image "$GCLOUD_BIN")" || exit 1

if [ ! -f "$SSH_KEY_FILE" ]; then
  echo "FATAL: SSH public key not found at $SSH_KEY_FILE (set SSH_KEY_FILE to override)" >&2
  exit 1
fi

mapfile -t ZONES < <(gcp_list_free_tier_zones "$GCLOUD_BIN" "$PROJECT")
if [ "${#ZONES[@]}" -eq 0 ]; then
  echo "FATAL: no zones discovered in the free-tier regions." >&2
  exit 1
fi

echo "=== launch-gcp.sh ==="
echo "Project:  $PROJECT"
echo "Shape:    $SHAPE"
echo "Image:    $IMAGE"
echo "SSH key:  $SSH_KEY_FILE ($SSH_USER)"
echo "Zones:    ${ZONES[*]}"
echo

attempt=0
sleep_time=$BASE_SLEEP
ZONE=""

while true; do
  CURRENT=$(gcp_count_running_free_tier "$GCLOUD_BIN" "$PROJECT" "$SHAPE")
  CURRENT="${CURRENT:-0}"
  if [ "$CURRENT" -ge "$FREE_CAP" ]; then
    echo "Already at free-tier cap ($CURRENT/$FREE_CAP RUNNING $SHAPE)."
    if command -v jq >/dev/null; then
      RUNNING_JSON="$(gcp_list_running_instances "$GCLOUD_BIN" "$PROJECT")"
      SHAPE_JSON="$(echo "$RUNNING_JSON" | jq --arg shape "$SHAPE" '[.[] | select(.shape==$shape)]')"
      echo
      echo "Currently running $SHAPE instances (free-tier regions):"
      echo "$SHAPE_JSON" | jq -r --arg dn "$DISPLAY_NAME" \
        '.[] | (if (.name == $dn or (.name | startswith($dn + "-"))) then "  [reclaimable] " else "  [leave alone]  " end) + "\(.name)\t\(.zone)"'
      # Same convention as launch-e2.sh: only a name matching what THIS
      # script itself would create counts as safe to reclaim.
      STALE_NAME="$(echo "$SHAPE_JSON" | jq -r --arg dn "$DISPLAY_NAME" \
        '[.[] | select(.name == $dn or (.name | startswith($dn + "-")))][0].name // empty')"
      STALE_ZONE="$(echo "$SHAPE_JSON" | jq -r --arg dn "$DISPLAY_NAME" \
        '[.[] | select(.name == $dn or (.name | startswith($dn + "-")))][0].zone // empty')"
      if [ "${RECLAIM_STALE:-0}" = "1" ] && [ -n "$STALE_NAME" ]; then
        echo
        echo "RECLAIM_STALE=1 — terminating $STALE_NAME ($STALE_ZONE) and retrying..."
        "$DIR/teardown-gcp.sh" --instance-id "$STALE_NAME" --zone "$STALE_ZONE" --yes
        continue
      fi
      echo
      if [ -n "$STALE_NAME" ]; then
        echo "Instance marked [reclaimable] matches DISPLAY_NAME='$DISPLAY_NAME' and is almost certainly a"
        echo "leftover test-rig instance. Either:"
        echo "  - re-run with RECLAIM_STALE=1 to free it automatically and keep going, or"
        echo "  - terminate it yourself: $DIR/teardown-gcp.sh --instance-id $STALE_NAME --zone $STALE_ZONE --yes"
      else
        echo "That instance doesn't match DISPLAY_NAME='$DISPLAY_NAME' — it looks like a real, non-test instance."
        echo "Free up your account's slot yourself before retrying: $DIR/teardown-gcp.sh --list"
      fi
    fi
    echo "Nothing to launch. Exiting."
    exit 0
  fi

  attempt=$((attempt+1))
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  ZONE="${ZONES[$(( (attempt - 1) % ${#ZONES[@]} ))]}"
  echo "$ts Attempt #$attempt against $ZONE (have $CURRENT/$FREE_CAP)..."

  OUT=$("$GCLOUD_BIN" compute instances create "$DISPLAY_NAME" \
    --project "$PROJECT" \
    --zone "$ZONE" \
    --machine-type "$SHAPE" \
    --image "$IMAGE" \
    --metadata "ssh-keys=${SSH_USER}:$(cat "$SSH_KEY_FILE")" \
    --format=json \
    2>&1)
  STATUS=$?

  if [ $STATUS -eq 0 ]; then
    echo "$ts *** SUCCESS on attempt #$attempt (zone: $ZONE) ***"
    break
  fi

  if echo "$OUT" | grep -qiE "ZONE_RESOURCE_POOL_EXHAUSTED|QUOTA_EXCEEDED|does not have enough resources|RESOURCE_POOL_EXHAUSTED"; then
    echo "$ts Capacity/quota error (expected) — retrying in another zone."
  elif echo "$OUT" | grep -qiE "already exists"; then
    echo "$ts FATAL: an instance named '$DISPLAY_NAME' already exists. Tear it down first or set DISPLAY_NAME." >&2
    exit 1
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
PUBLIC_IP=$("$GCLOUD_BIN" compute instances describe "$DISPLAY_NAME" \
  --project "$PROJECT" --zone "$ZONE" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null)

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "null" ]; then
  echo "FATAL: RUNNING but no public IP found." >&2
  echo "Instance for manual follow-up: $DISPLAY_NAME (zone $ZONE)" >&2
  exit 1
fi

echo
echo "=== DONE ==="
echo "Instance name: $DISPLAY_NAME"
echo "Zone:          $ZONE"
echo "Public IP:     $PUBLIC_IP"

STATE_DIR="${ALPINE_FLEET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/alpine-fleet}"
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/current-instance-gcp.json"
if command -v jq >/dev/null; then
  jq -n \
    --arg id "$DISPLAY_NAME" \
    --arg ip "$PUBLIC_IP" \
    --arg name "$DISPLAY_NAME" \
    --arg shape "$SHAPE" \
    --arg zone "$ZONE" \
    --arg ssh_user "$SSH_USER" \
    --arg provider "gcp" \
    --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{instance_id:$id, public_ip:$ip, display_name:$name, shape:$shape, zone:$zone, ssh_user:$ssh_user, provider:$provider, created_at:$created}' \
    > "$STATE_FILE"
  echo "State saved: $STATE_FILE"
else
  echo "WARNING: jq not found — skipped writing $STATE_FILE. Install jq if you want" >&2
  echo "downstream scripts (orchestrate.py) to auto-discover this instance." >&2
fi
