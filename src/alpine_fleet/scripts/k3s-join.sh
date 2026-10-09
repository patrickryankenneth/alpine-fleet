#!/usr/bin/env bash
# k3s-join.sh <user@host> <node-name>
# Env: K3S_TAINT=1|0, K3S_TOKEN_CMD, K3S_URL, K3S_VERSION, K3S_KUBECTL
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:?Usage: k3s-join.sh <user@host> <node-name>}"
NAME="${2:?node name required}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/alpine-fleet"
die() { echo "FATAL: $*" >&2; exit 1; }
if [ -n "${K3S_KUBECTL:-}" ]; then K="$K3S_KUBECTL"
elif command -v k3s >/dev/null; then K="k3s kubectl"; else K=kubectl; fi

# 1. version: from the cluster's control plane, so the agent always matches
VER="${K3S_VERSION:-$($K get nodes -l node-role.kubernetes.io/control-plane \
  -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}' 2>/dev/null || true)}"
case "$VER" in *+k3s*) ;; *) die "could not read a k3s server version from the cluster (got '${VER}'). Set K3S_VERSION." ;; esac

# 2. API URL: env > config file > kubeconfig (127.0.0.1 -> this machine's tailscale IP)
if [ -n "${K3S_URL:-}" ]; then URL="$K3S_URL"
elif [ -s "$CONF/k3s-url" ]; then URL="$(<"$CONF/k3s-url")"
else
  URL="$($K config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  case "$URL" in
    *127.0.0.1*|*localhost*)
      TSIP="$(tailscale ip -4 2>/dev/null | head -1)" || true
      [ -n "$TSIP" ] || die "kubeconfig points at localhost and this machine has no tailscale IP"
      URL="${URL/127.0.0.1/$TSIP}"; URL="${URL/localhost/$TSIP}" ;;
  esac
fi
[ -n "$URL" ] || die "no API URL. Put it in $CONF/k3s-url (e.g. https://100.x.y.z:6443)"
HP="${URL#*://}"; HOST="${HP%%:*}"; PORT="${HP##*:}"; [ "$PORT" = "$HP" ] && PORT=6443

# 3. token: TOKEN_CMD > config file > local node-token
if [ -n "${K3S_TOKEN_CMD:-}" ]; then TOKEN="$(bash -c "$K3S_TOKEN_CMD")"
elif [ -s "$CONF/k3s-token" ]; then
  [ "$(stat -c %a "$CONF/k3s-token")" = 600 ] || echo "WARN: chmod 600 $CONF/k3s-token" >&2
  TOKEN="$(<"$CONF/k3s-token")"
elif [ -r /var/lib/rancher/k3s/server/node-token ]; then TOKEN="$(</var/lib/rancher/k3s/server/node-token)"
elif sudo -n true 2>/dev/null; then TOKEN="$(sudo -n cat /var/lib/rancher/k3s/server/node-token)"
else die "no token. Save it to $CONF/k3s-token (chmod 600) or use --k3s-token-cmd"
fi
[ -n "$TOKEN" ] || die "empty k3s token"

REMOTE_CMD=$(cat <<'R'
set -e
read -r NAME; read -r URL; read -r VER; read -r TAINT; read -r TOKEN
apk add -q curl iptables ip6tables
code="$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "$URL/ping" || true)"
case "$code" in 000|"") echo "FATAL: $URL not reachable from this node over the tailnet. Check the ACL (tag:fleet -> server :6443) and the server's firewall." >&2; exit 1 ;; esac
rc-update add cgroups default >/dev/null 2>&1 || true
rc-service cgroups start >/dev/null 2>&1 || true
modprobe br_netfilter; modprobe overlay
for m in br_netfilter overlay; do grep -qx "$m" /etc/modules || echo "$m" >> /etc/modules; done
# tailscaled's nftables rules can break iptables-save, which k3s needs
if ! iptables-save >/dev/null 2>&1; then
  grep -q TS_DEBUG_FIREWALL_MODE /etc/conf.d/tailscale || echo 'export TS_DEBUG_FIREWALL_MODE=iptables' >> /etc/conf.d/tailscale
  rc-service tailscale restart; sleep 5
fi
NODE_IP="$(tailscale ip -4 | head -1)"
TAINT_ARGS=""; [ "$TAINT" = 1 ] && TAINT_ARGS="--node-taint fleet=true:NoSchedule"
export INSTALL_K3S_VERSION="$VER" K3S_URL="$URL" K3S_TOKEN="$TOKEN" INSTALL_K3S_SKIP_START=true
curl -sfL https://get.k3s.io | sh -s - agent --node-name "$NAME" --node-ip "$NODE_IP" \
  --flannel-iface tailscale0 --node-label fleet=true $TAINT_ARGS \
  || echo "installer exited non-zero (iptables noise on Alpine); continuing" >&2
[ -x /etc/init.d/k3s-agent ] || { echo "FATAL: installer did not create k3s-agent service" >&2; exit 1; }
rc-service k3s-agent start || true
R
)

echo "[k3s] joining $NAME to $URL as $VER..."
printf '%s\n%s\n%s\n%s\n%s\n' "$NAME" "$URL" "$VER" "${K3S_TAINT:-1}" "$TOKEN" \
  | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$TARGET" "$REMOTE_CMD"
unset TOKEN

for _i in $(seq 1 40); do $K get node "$NAME" >/dev/null 2>&1 && break; sleep 3; done
$K wait --for=condition=Ready "node/$NAME" --timeout=120s >/dev/null \
  || die "node $NAME never became Ready (ssh in and check: rc-service k3s-agent status; tail /var/log/k3s.log)"
echo "[k3s] node $NAME is Ready"
bash "$DIR/k3s-check.sh" "$NAME"
