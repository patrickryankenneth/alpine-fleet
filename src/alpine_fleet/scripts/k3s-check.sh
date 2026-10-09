#!/usr/bin/env bash
# k3s-check.sh <node-name>: pod pinned to the node must resolve cluster DNS.
set -euo pipefail
NODE="${1:?Usage: k3s-check.sh <node-name>}"
if [ -n "${K3S_KUBECTL:-}" ]; then K="$K3S_KUBECTL"
elif command -v k3s >/dev/null; then K="k3s kubectl"; else K=kubectl; fi
POD="fleetcheck-$$"
trap '$K delete pod "$POD" --now --ignore-not-found >/dev/null 2>&1 || true' EXIT

SVC_IP="$($K get svc kubernetes -o jsonpath='{.spec.clusterIP}')"
$K run "$POD" --image=docker.io/library/busybox:1.36 --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"$NODE\",\"tolerations\":[{\"key\":\"fleet\",\"operator\":\"Exists\"}]}}" \
  -- sleep 120 >/dev/null
$K wait --for=condition=Ready "pod/$POD" --timeout=90s >/dev/null \
  || { echo "FAIL: check pod never became Ready on $NODE" >&2; $K describe pod "$POD" | tail -15 >&2; exit 1; }
OUT="$($K exec "$POD" -- nslookup kubernetes.default.svc.cluster.local 2>&1)" || true
if echo "$OUT" | grep -q "Address: *$SVC_IP"; then
  echo "[k3s] OK: pod on $NODE resolves cluster DNS ($SVC_IP)"
else
  echo "FAIL: pod DNS on $NODE did not return $SVC_IP" >&2; echo "$OUT" >&2; exit 1
fi
