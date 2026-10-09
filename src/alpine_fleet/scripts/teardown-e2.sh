#!/usr/bin/env bash
# teardown-e2.sh — list running instances, or terminate one E2.1.Micro.
# Usage: teardown-e2.sh --list
#        teardown-e2.sh [--instance-id <ocid>] [--yes]   (default target: state file)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/oci-common.sh"
source "$SCRIPT_DIR/lib/tailscale-common.sh"
source "$SCRIPT_DIR/lib/k3s-common.sh"
STATE_FILE="${ALPINE_FLEET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/alpine-fleet}/current-instance-oci.json"

TARGET=""; YES=false; LIST=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id) TARGET="$2"; shift 2 ;;
        --yes)         YES=true; shift ;;
        --list)        LIST=true; shift ;;
        *) echo "Usage: teardown-e2.sh [--list] [--instance-id <ocid>] [--yes]" >&2; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 1; }
OCI_BIN="$(oci_resolve_bin)"
COMPARTMENT_ID="$(oci_resolve_compartment_id)"
RUNNING_JSON="$(oci_list_running_instances "$OCI_BIN" "$COMPARTMENT_ID")"

if $LIST; then
    echo "$RUNNING_JSON" | jq -r '.[] | "\(.name)\t\(.shape)\t\(.id)"'
    exit 0
fi

if [ -z "$TARGET" ]; then
    [ -f "$STATE_FILE" ] || { echo "FATAL: no --instance-id and no $STATE_FILE" >&2; exit 1; }
    TARGET="$(jq -r '.instance_id' "$STATE_FILE")"
fi

ROW="$(echo "$RUNNING_JSON" | jq -c --arg id "$TARGET" '.[] | select(.id==$id)')"
[ -n "$ROW" ] || { echo "FATAL: $TARGET is not among RUNNING instances." >&2; exit 1; }
NAME="$(echo "$ROW" | jq -r .name)"; SHAPE="$(echo "$ROW" | jq -r .shape)"

case "$SHAPE" in
    *E2.1.Micro*) ;;
    *) echo "FATAL: refusing to terminate shape '$SHAPE' — E2.1.Micro only." >&2; exit 1 ;;
esac

echo "Target: $NAME  ($SHAPE)"
echo "        $TARGET"
if ! $YES; then
    echo "Dry run. Re-run with --yes to TERMINATE this instance and DELETE its boot volume."
    exit 0
fi

"$OCI_BIN" compute instance terminate \
    --instance-id "$TARGET" \
    --preserve-boot-volume false \
    --force \
    --wait-for-state SUCCEEDED

K3S_NODE="$(jq -r '.k3s_node // empty' "$STATE_FILE" 2>/dev/null || true)"
if [ -n "$K3S_NODE" ]; then k3s_delete_node "$K3S_NODE"; fi

TS_NAME="${TS_ALIAS:-}"
[ -n "$TS_NAME" ] || TS_NAME="$(jq -r '.ts_alias // empty' "$STATE_FILE" 2>/dev/null || true)"
if [ -n "$TS_NAME" ] || [ "${TAILSCALE:-0}" = "1" ]; then
    ts_delete_alias "${TS_NAME:-oci-node}" || echo "WARN: Tailscale cleanup failed" >&2
fi

if [ -f "$STATE_FILE" ] && [ "$(jq -r '.instance_id' "$STATE_FILE")" = "$TARGET" ]; then
    mv "$STATE_FILE" "$STATE_FILE.terminated"
fi
echo "Terminated $NAME."