#!/usr/bin/env bash
# k3s-common.sh: helpers shared by the teardown and e2e scripts.
k3s_kubectl() {
  if [ -n "${K3S_KUBECTL:-}" ]; then echo "$K3S_KUBECTL"
  elif command -v k3s >/dev/null; then echo "k3s kubectl"
  elif command -v kubectl >/dev/null; then echo "kubectl"; fi
}
# Remove the Node object so the cluster doesn't keep a dead worker. Never fatal.
k3s_delete_node() {
  local n="$1" k; k="$(k3s_kubectl)"
  if [ -z "$k" ]; then echo "WARN: no kubectl here; run: kubectl delete node $n" >&2; return 0; fi
  $k delete node "$n" --ignore-not-found --wait=false \
    || echo "WARN: could not delete k3s node '$n'; run: kubectl delete node $n" >&2
  return 0
}
