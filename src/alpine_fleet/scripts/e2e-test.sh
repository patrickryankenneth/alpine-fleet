#!/usr/bin/env bash
# e2e-test.sh — repeatable full-cycle test: terminate -> launch -> jump ->
# install -> harden -> assert. Usage: e2e-test.sh [--runs N] [--debug] [--prepare]
# --prepare builds the host-side kexec cache first (needs podman or docker).
#
# Each cycle terminates the state-file E2 instance (if any), then lets
# orchestrate.py launch a fresh one and drive it to the final state. Stops at
# the first failure. The serial transcript of every run is kept at
# ~/.local/state/alpine-fleet/serial-run<N>.log.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${ALPINE_FLEET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/alpine-fleet}"
export ALPINE_FLEET_STATE_DIR="$STATE_DIR"
STATE="$STATE_DIR/current-instance.json"
RUNS=1; ORCH_ARGS=(); PREPARE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)  RUNS="$2"; shift 2 ;;
    --debug) ORCH_ARGS+=(--debug); shift ;;
    --prepare) PREPARE=1; shift ;;
    *) echo "Usage: e2e-test.sh [--runs N] [--debug] [--prepare]" >&2; exit 1 ;;
  esac
done

if [[ $PREPARE == 1 ]]; then
  bash "$DIR/prepare-kexec-cache.sh" || echo "WARN: cache preparation failed — continuing without the cache" >&2
fi

fail() { echo "FAIL (run $i/$RUNS): $*" >&2; exit 1; }

for i in $(seq 1 "$RUNS"); do
  echo "================ run $i/$RUNS ================"
  start=$(date +%s)

  echo "== teardown =="
  td_start=$(date +%s)
  if [ -f "$STATE" ]; then
    TD_LOG="$(mktemp)"
    bash "$DIR/teardown-e2.sh" --yes 2>&1 | tee "$TD_LOG"; td_rc=${PIPESTATUS[0]}
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
  echo "PASS run $i/$RUNS in $(( $(date +%s) - start ))s at root@$IP"
done
echo "ALL $RUNS RUN(S) PASSED"