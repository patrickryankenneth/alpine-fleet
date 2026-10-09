#!/usr/bin/env bash
# e2e-test.sh — repeatable full-cycle test: terminate -> launch -> jump ->
# install -> harden -> assert. Usage: e2e-test.sh [--runs N] [--debug] [--prepare] [--provider oci|gcp] [--tailscale]
# --prepare builds the host-side kexec cache first (needs podman or docker).
# --provider selects which cloud to test against (default: oci); it picks
# the matching teardown script and is passed through to orchestrate.py.
#
# Each cycle terminates the state-file E2 instance (if any), then lets
# orchestrate.py launch a fresh one and drive it to the final state. Stops at
# the first failure. The serial transcript of every run is kept at
# ~/.local/state/alpine-fleet/serial-run<N>.log.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${ALPINE_FLEET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/alpine-fleet}"
export ALPINE_FLEET_STATE_DIR="$STATE_DIR"
source "$DIR/lib/k3s-common.sh"
RUNS=1; ORCH_ARGS=(); PREPARE=0; PROVIDER="oci"; TAILSCALE=0; K3S=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)     RUNS="$2"; shift 2 ;;
    --debug)    ORCH_ARGS+=(--debug); shift ;;
    --prepare)  PREPARE=1; shift ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --tailscale) ORCH_ARGS+=(--tailscale); TAILSCALE=1; export TAILSCALE; shift ;;
    --k3s)       ORCH_ARGS+=(--tailscale --k3s); TAILSCALE=1; K3S=1; export TAILSCALE; shift ;;
    *) echo "Usage: e2e-test.sh [--runs N] [--debug] [--prepare] [--provider oci|gcp] [--tailscale] [--k3s]" >&2; exit 1 ;;
  esac
done
STATE="$STATE_DIR/current-instance-$PROVIDER.json"

case "$PROVIDER" in
  oci) TEARDOWN_SCRIPT="teardown-e2.sh" ;;
  gcp) TEARDOWN_SCRIPT="teardown-gcp.sh" ;;
  *) echo "Usage: e2e-test.sh: unknown --provider '$PROVIDER' (must be oci or gcp)" >&2; exit 1 ;;
esac
ORCH_ARGS+=(--provider "$PROVIDER")

if [[ $PREPARE == 1 ]]; then
  bash "$DIR/prepare-kexec-cache.sh" --provider "$PROVIDER" || echo "WARN: cache preparation failed — continuing without the cache" >&2
fi

fail() { echo "FAIL (run $i/$RUNS): $*" >&2; exit 1; }

for i in $(seq 1 "$RUNS"); do
  echo "================ run $i/$RUNS ================"
  start=$(date +%s)

  echo "== teardown =="
  td_start=$(date +%s)
  PREV_TS=""; PREV_K3S=""; td_rc=0
  if [ -f "$STATE" ]; then
    TD_LOG="$(mktemp)"
    PREV_TS="$(jq -r '.ts_alias // empty' "$STATE" 2>/dev/null || true)"
    PREV_K3S="$(jq -r '.k3s_node // empty' "$STATE" 2>/dev/null || true)"
    bash "$DIR/$TEARDOWN_SCRIPT" --yes 2>&1 | tee "$TD_LOG"; td_rc=${PIPESTATUS[0]}
    if [[ $td_rc -ne 0 ]]; then
      if grep -q "not among RUNNING instances" "$TD_LOG"; then
        echo "instance in the state file is already gone (e.g. an interrupted earlier run) — clearing stale state"
        rm -f "$STATE"
      else
        rm -f "$TD_LOG"; fail "teardown"
      fi
    fi
    rm -f "$TD_LOG"
  else
    echo "no state file — nothing to tear down"
  fi

  if [[ $TAILSCALE == 1 && -n "$PREV_TS" && $td_rc -eq 0 ]]; then
    gone=0
    for _ in 1 2 3 4 5 6; do
      if ! tailscale status 2>/dev/null | awk '{print $2}' | grep -qx "$PREV_TS"; then gone=1; break; fi
      sleep 2
    done
    [[ $gone == 1 ]] || fail "tailnet device '$PREV_TS' still present after teardown"
    echo "tailnet cleanup ok: $PREV_TS removed"
  fi

  if [[ $K3S == 1 && -n "$PREV_K3S" && $td_rc -eq 0 ]]; then
    gone=0
    for _ in 1 2 3 4 5 6; do
      if ! $(k3s_kubectl) get node "$PREV_K3S" >/dev/null 2>&1; then gone=1; break; fi
      sleep 2
    done
    [[ $gone == 1 ]] || fail "k3s node '$PREV_K3S' still registered after teardown"
    echo "k3s cleanup ok: $PREV_K3S removed"
  fi

  echo "teardown took $(( $(date +%s) - td_start ))s"
  echo "== orchestrate (launch + jump + install + harden) =="
  python3 "$DIR/orchestrate.py" "${ORCH_ARGS[@]}" || fail "orchestrate (see $STATE_DIR/serial.log)"
  cp "$STATE_DIR/serial.log" "$STATE_DIR/serial-run$i.log" 2>/dev/null || true

  echo "== assert =="
  [ -f "$STATE" ] || fail "no state file after orchestrate"
  IP="$(jq -r .public_ip "$STATE")"
  OUT="$(ssh -o ControlPath=none -o ControlMaster=no -o PreferredAuthentications=publickey \
        -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 "root@$IP" \
        'echo __PROBE_OK__; cat /etc/alpine-release; mount | grep " / "; awk -F: "\$1==\"root\"{print \"root_shadow=\" substr(\$2,1,1)}" /etc/shadow; awk "/MemTotal/{t=\$2} /MemAvailable/{a=\$2} END{printf \"used_mb=%d\n\",(t-a)/1024}" /proc/meminfo; /usr/sbin/sshd -T 2>/dev/null | grep -E "^(permitrootlogin|passwordauthentication) "; true')" \
        || fail "ssh to root@$IP"
  echo "$OUT"
  echo "$OUT" | grep -q '__PROBE_OK__'      || fail "probe marker missing (forced-command banner?)"
  echo "$OUT" | grep -qE '^3\.[0-9]+'       || fail "not Alpine"
  echo "$OUT" | grep -q '/dev/sda'          || fail "/ not on /dev/sda*"
  echo "$OUT" | grep -qE '^root_shadow=[!*]'  || fail "root password not disabled (shadow field should start with '*' or '!')"
  echo "$OUT" | grep -q '^passwordauthentication no' || fail "sshd still allows password authentication"
  echo "$OUT" | grep -qE '^permitrootlogin (prohibit-password|without-password)' || fail "PermitRootLogin is not key-only"
  if [[ $TAILSCALE == 1 ]]; then
    TS_NAME="$(jq -r '.ts_alias // empty' "$STATE")"
    [ -n "$TS_NAME" ] || fail "no ts_alias in state file (tailscale join failed?)"
    ts_ok=0
    for _ in 1 2 3 4 5 6; do
      if ssh -o ControlPath=none -o ControlMaster=no -o BatchMode=yes -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 "root@$TS_NAME" \
           'tailscale ip -4' >/dev/null 2>&1; then ts_ok=1; break; fi
      sleep 5
    done
    [[ $ts_ok == 1 ]] || fail "ssh over tailnet to root@$TS_NAME"
    echo "tailnet ok: ssh root@$TS_NAME"
  fi
  if [[ $K3S == 1 ]]; then
    K3S_NODE="$(jq -r '.k3s_node // empty' "$STATE")"
    [ -n "$K3S_NODE" ] || fail "no k3s_node in state file (k3s join failed?)"
    bash "$DIR/k3s-check.sh" "$K3S_NODE" || fail "pod DNS on k3s node $K3S_NODE"
    echo "k3s ok: $K3S_NODE"
  fi
  echo "PASS run $i/$RUNS in $(( $(date +%s) - start ))s at root@$IP"
done
echo "ALL $RUNS RUN(S) PASSED"