#!/usr/bin/env bash
#
# console-connect-gcp.sh — discover the target instance and its zone,
# ensure serial port access is enabled on it, then print (or exec) the
# `gcloud compute connect-to-serial-port` command for it.
#
# Mirrors console-connect.sh's (OCI) interface so orchestrate.py can
# drive either provider identically:
#   ./console-connect-gcp.sh [--instance-id <name>] [--key <path>] [--exec]
#
# --instance-id: optional. GCP instances are identified by NAME, not an
#   OCID, but the flag name is kept for interface parity with the OCI
#   script. If omitted, every RUNNING instance in the current gcloud
#   project (across all zones) is checked; exactly one -> used
#   automatically, more than one -> you get a list and must
#   disambiguate with --instance-id.
#
# --key: accepted but ignored. GCP's serial-port SSH proxy manages its
#   own key under the hood (via `gcloud compute connect-to-serial-port`
#   itself) — there is no user-supplied key file the way OCI's console
#   proxy requires.
#
# --exec: connect immediately instead of just printing the command.
#
# Nothing here is hardcoded: project comes from `gcloud config
# get-value project` (whatever the caller is already authed/configured
# against), instance + zone are discovered live via the Compute API.
#
set -euo pipefail

INSTANCE_NAME=""
DO_EXEC=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id) INSTANCE_NAME="$2"; shift 2 ;;
        --key)         shift 2 ;;   # accepted for interface parity, unused
        --exec)        DO_EXEC=true; shift ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: console-connect-gcp.sh [--instance-id <name>] [--key <path>] [--exec]" >&2
            exit 1
            ;;
    esac
done

command -v gcloud >/dev/null || {
    echo "FATAL: gcloud CLI not found on PATH." >&2
    exit 1
}
command -v jq >/dev/null || {
    echo "FATAL: jq is required to parse gcloud's JSON output." >&2
    exit 1
}

PROJECT="$(gcloud config get-value project 2>/dev/null)"
if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
    echo "FATAL: no gcloud project configured. Run: gcloud config set project PROJECT_ID" >&2
    exit 1
fi
echo "[console] using project '$PROJECT'" >&2

# ---- Instance auto-discovery (across all zones in this project) ----
if [ -z "$INSTANCE_NAME" ]; then
    echo "[console] no --instance-id given — looking for running instances..." >&2
    RUNNING_JSON="$(gcloud compute instances list \
        --project "$PROJECT" \
        --filter="status=RUNNING" \
        --format=json)"
    COUNT="$(echo "$RUNNING_JSON" | jq 'length')"
    if [ "$COUNT" -eq 0 ]; then
        echo "FATAL: no RUNNING instances found in project '$PROJECT'." >&2
        exit 1
    elif [ "$COUNT" -eq 1 ]; then
        INSTANCE_NAME="$(echo "$RUNNING_JSON" | jq -r '.[0].name')"
        ZONE="$(echo "$RUNNING_JSON" | jq -r '.[0].zone' | sed 's#.*/##')"
        echo "[console] found exactly one — using '$INSTANCE_NAME' (zone: $ZONE)" >&2
    else
        echo "FATAL: $COUNT running instances found — ambiguous. Pick one:" >&2
        echo "$RUNNING_JSON" | jq -r '.[] | "  \(.name)\t\(.machineType | split("/") | last)\t\(.zone | split("/") | last)"' >&2
        echo "Re-run with: --instance-id <name>" >&2
        exit 1
    fi
else
    echo "[console] looking up zone for instance '$INSTANCE_NAME'..." >&2
    ZONE="$(gcloud compute instances list \
        --project "$PROJECT" \
        --filter="name=$INSTANCE_NAME" \
        --format='value(zone.basename())')"
    if [ -z "$ZONE" ]; then
        echo "FATAL: instance '$INSTANCE_NAME' not found in project '$PROJECT'." >&2
        exit 1
    fi
fi

# ---- Ensure serial port access is enabled ----
SERIAL_ENABLED="$(gcloud compute instances describe "$INSTANCE_NAME" \
    --project "$PROJECT" --zone "$ZONE" \
    --format='value(metadata.items.filter("key:serial-port-enable").extract("value").flatten())' 2>/dev/null || true)"

if [ "$SERIAL_ENABLED" != "TRUE" ] && [ "$SERIAL_ENABLED" != "true" ]; then
    echo "[console] serial-port-enable not set — enabling it now..." >&2
    gcloud compute instances add-metadata "$INSTANCE_NAME" \
        --project "$PROJECT" --zone "$ZONE" \
        --metadata serial-port-enable=TRUE >&2
else
    echo "[console] serial port access already enabled" >&2
fi

CONN_CMD="gcloud compute connect-to-serial-port ${INSTANCE_NAME} --project=${PROJECT} --zone=${ZONE} --port=1"

echo "$CONN_CMD"

if $DO_EXEC; then
    echo "[console] connecting..." >&2
    exec bash -c "$CONN_CMD"
fi
