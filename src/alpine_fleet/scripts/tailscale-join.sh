#!/usr/bin/env bash
# tailscale-join.sh <user@host> <alias>
# Installs tailscale on an Alpine host over SSH, joins it with a single-use
# preauthorized key (sent over stdin, never written to disk), waits for the alias.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/tailscale-common.sh"

TARGET="${1:?Usage: tailscale-join.sh <user@host> <alias>}"
ALIAS="${2:?alias required}"

ts_check
ts_claim_alias "$ALIAS"
KEY="$(ts_mint_key 900)"
[ -n "$KEY" ] || { echo "FATAL: could not mint a Tailscale key" >&2; exit 1; }

REMOTE_CMD=$(cat <<'R'
set -e
read -r A
read -r K
grep -q '/community$' /etc/apk/repositories || \
  grep -m1 '/main$' /etc/apk/repositories | sed 's#/main$#/community#' >> /etc/apk/repositories
sed -i 's|^#\(.*/community\)$|\1|' /etc/apk/repositories
apk update -q
apk add --quiet tailscale
modprobe tun 2>/dev/null || true
grep -qx tun /etc/modules || echo tun >> /etc/modules
SVC=$(ls /etc/init.d | grep -m1 '^tailscale') || { echo "no tailscale init script" >&2; exit 1; }
grep -q GOMEMLIMIT /etc/conf.d/tailscale 2>/dev/null || echo 'export GOMEMLIMIT=40MiB' >> /etc/conf.d/tailscale
rc-update add "$SVC" default
rc-service "$SVC" stop 2>/dev/null || true
rm -f /var/lib/tailscale/tailscaled.state
rc-service "$SVC" start
sleep 2
tailscale up --auth-key="$K" --hostname="$A" --advertise-tags=tag:fleet
tailscale ip -4
R
)

_SSHO="-o BatchMode=yes -o StrictHostKeyChecking=accept-new"
MEM_BEFORE="$(ssh $_SSHO "$TARGET" 'awk "/MemAvailable/ {print int(\$2/1024)}" /proc/meminfo' 2>/dev/null || echo "")"
echo "[tailscale] joining $TARGET as '$ALIAS'..."
printf '%s\n%s\n' "$ALIAS" "$KEY" | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "$REMOTE_CMD"
unset KEY

ts_wait_alias "$ALIAS" 120 || { echo "FATAL: '$ALIAS' never appeared in the tailnet" >&2; exit 1; }
NAME="$(ts_find_fleet_devices "$ALIAS" | jq -r .name | head -1)"
if [ "${NAME%%.*}" != "$ALIAS" ]; then
  echo "WARN: registered as '$NAME', not '$ALIAS' (name collision)" >&2
fi
echo "[tailscale] joined as $NAME"
sleep 5
TS_RSS="$(ssh $_SSHO "$TARGET" 'awk "/VmRSS/ {print int(\$2/1024)}" /proc/$(pgrep tailscaled | head -1)/status' 2>/dev/null || echo "")"
MEM_AFTER="$(ssh $_SSHO "$TARGET" 'awk "/MemAvailable/ {print int(\$2/1024)}" /proc/meminfo' 2>/dev/null || echo "")"
if [ -n "$TS_RSS" ]; then
  echo "[tailscale] RAM: tailscaled uses ${TS_RSS} MB"
  if [ -n "$MEM_BEFORE" ] && [ -n "$MEM_AFTER" ]; then
    echo "[tailscale] RAM available: ${MEM_BEFORE} MB -> ${MEM_AFTER} MB (-$((MEM_BEFORE - MEM_AFTER)) MB)"
  fi
fi

ssh-keygen -R "$NAME" >/dev/null 2>&1 || true; ssh-keygen -R "$ALIAS" >/dev/null 2>&1 || true
TS_IP="$(_ts_curl "$TS_API/tailnet/$TS_TAILNET/devices" | jq -r --arg n "$NAME" '.devices[] | select(.name==$n) | .addresses[0]' | head -1)"
OK=0
for _i in 1 2 3 4 5 6; do
  if timeout 15 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 "${TARGET%@*}@${TS_IP:-$NAME}" true 2>/dev/null; then OK=1; break; fi
  sleep 5
done
if [ "$OK" = 1 ]; then
  echo "[tailscale] SSH over the tailnet works: ssh ${TARGET%@*}@$NAME"
else
  echo "WARN: joined, but SSH over the tailnet failed (probably the ACL, see below)" >&2
fi
