#!/usr/bin/env bash
# teardown-gcp.sh — list running free-tier instances, or delete one
# e2-micro instance. Mirrors teardown-e2.sh's interface for GCP.
# Usage: teardown-gcp.sh --list
#        teardown-gcp.sh [--instance-id <name>] [--zone <zone>] [--yes]
#        (default target: state file)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/gcp-common.sh"
source "$SCRIPT_DIR/lib/tailscale-common.sh"
source "$SCRIPT_DIR/lib/k3s-common.sh"
STATE_FILE="${ALPINE_FLEET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/alpine-fleet}/current-instance-gcp.json"

TARGET=""; ZONE=""; YES=false; LIST=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id) TARGET="$2"; shift 2 ;;
        --zone)        ZONE="$2"; shift 2 ;;
        --yes)         YES=true; shift ;;
        --list)        LIST=true; shift ;;
        *) echo "Usage: teardown-gcp.sh [--list] [--instance-id <name>] [--zone <zone>] [--yes]" >&2; exit 1 ;;
    esac
done

command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 1; }
GCLOUD_BIN="$(gcp_resolve_bin)"
PROJECT="$(gcp_resolve_project "$GCLOUD_BIN")"
RUNNING_JSON="$(gcp_list_running_instances "$GCLOUD_BIN" "$PROJECT")"

if $LIST; then
    echo "$RUNNING_JSON" | jq -r '.[] | "\(.name)\t\(.shape)\t\(.zone)"'
    exit 0
fi

if [ -z "$TARGET" ]; then
    [ -f "$STATE_FILE" ] || { echo "FATAL: no --instance-id and no $STATE_FILE" >&2; exit 1; }
    TARGET="$(jq -r '.instance_id' "$STATE_FILE")"
    [ -n "$ZONE" ] || ZONE="$(jq -r '.zone // empty' "$STATE_FILE")"
fi

ROW="$(echo "$RUNNING_JSON" | jq -c --arg id "$TARGET" '.[] | select(.name==$id)')"
[ -n "$ROW" ] || { echo "FATAL: $TARGET is not among RUNNING instances." >&2; exit 1; }
NAME="$(echo "$ROW" | jq -r .name)"; SHAPE="$(echo "$ROW" | jq -r .shape)"
[ -n "$ZONE" ] || ZONE="$(echo "$ROW" | jq -r .zone)"

case "$SHAPE" in
    e2-micro) ;;
    *) echo "FATAL: refusing to terminate shape '$SHAPE' — e2-micro only." >&2; exit 1 ;;
esac

echo "Target: $NAME  ($SHAPE, zone $ZONE)"
if ! $YES; then
    echo "Dry run. Re-run with --yes to DELETE this instance and its boot disk."
    exit 0
fi

"$GCLOUD_BIN" compute instances delete "$NAME" \
    --project "$PROJECT" \
    --zone "$ZONE" \
    --quiet

K3S_NODE="$(jq -r '.k3s_node // empty' "$STATE_FILE" 2>/dev/null || true)"
if [ -n "$K3S_NODE" ]; then k3s_delete_node "$K3S_NODE"; fi

TS_NAME="${TS_ALIAS:-}"
[ -n "$TS_NAME" ] || TS_NAME="$(jq -r '.ts_alias // empty' "$STATE_FILE" 2>/dev/null || true)"
if [ -n "$TS_NAME" ] || [ "${TAILSCALE:-0}" = "1" ]; then
    ts_delete_alias "${TS_NAME:-gcp-node}" || echo "WARN: Tailscale cleanup failed" >&2
fi

if [ -f "$STATE_FILE" ] && [ "$(jq -r '.instance_id' "$STATE_FILE")" = "$TARGET" ]; then
    mv "$STATE_FILE" "$STATE_FILE.terminated"
fi
echo "Terminated $NAME."
