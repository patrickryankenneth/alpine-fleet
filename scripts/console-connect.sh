#!/usr/bin/env bash
#
# console-connect.sh — get (or create) an OCI serial console connection,
# auto-discovering the target instance and managing a persistent RSA
# key, then pull the connection-string out of the JSON response, patch
# in the key + safety flags, and either print or exec the result.
#
# Usage:
#   ./console-connect.sh [--instance-id <ocid>] [--key <path>] [--exec]
#
# --instance-id: optional. If omitted, this looks at every RUNNING
#   instance in the compartment (via oci-common.sh). If exactly one is
#   running, it's used automatically. If there's more than one, you'll
#   get a list and have to re-run with --instance-id to disambiguate —
#   this script will not guess which of several live boxes you meant.
#
# --key: optional, default ~/.ssh/oci-console-rsa. OCI's serial console
#   requires an RSA key specifically — Ed25519 keys are rejected by the
#   console proxy even though they work fine for normal instance SSH.
#   If the key doesn't exist yet, it's generated (RSA 4096, no
#   passphrase — needed since this runs non-interactively) and PERSISTED
#   to disk, not thrown away after use: the console-connection resource
#   in OCI is tied to the public key you registered when you created it,
#   so reusing the same key on future runs lets this script find and
#   reuse that existing connection instead of creating a new one every
#   time (you're capped at 10 console connections per tenancy).
#   Since there's no passphrase, treat this key file like any other
#   unlocked credential — restrict its permissions (this script does,
#   via `ssh-keygen`'s default 600) and don't copy it elsewhere.
#
# --exec: connect immediately instead of just printing the command.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/oci-common.sh"

INSTANCE_ID=""
PRIVATE_KEY="$HOME/.ssh/oci-console-rsa"
DO_EXEC=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --instance-id) INSTANCE_ID="$2"; shift 2 ;;
        --key)         PRIVATE_KEY="$2"; shift 2 ;;
        --exec)        DO_EXEC=true; shift ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: console-connect.sh [--instance-id <ocid>] [--key <path>] [--exec]" >&2
            exit 1
            ;;
    esac
done

command -v jq >/dev/null || {
    echo "FATAL: jq is required here — the connection-string contains spaces" >&2
    echo "and quoting that naive grep/sed would mangle. Install jq and retry." >&2
    exit 1
}

OCI_BIN="$(oci_resolve_bin)"
COMPARTMENT_ID="$(oci_resolve_compartment_id)"

# ---- Instance auto-discovery ----
if [ -z "$INSTANCE_ID" ]; then
    echo "[console] no --instance-id given — looking for running instances..." >&2
    RUNNING_JSON="$(oci_list_running_instances "$OCI_BIN" "$COMPARTMENT_ID")"
    COUNT="$(echo "$RUNNING_JSON" | jq 'length')"
    if [ "$COUNT" -eq 0 ]; then
        echo "FATAL: no RUNNING instances found in this compartment." >&2
        exit 1
    elif [ "$COUNT" -eq 1 ]; then
        INSTANCE_ID="$(echo "$RUNNING_JSON" | jq -r '.[0].id')"
        NAME="$(echo "$RUNNING_JSON" | jq -r '.[0].name')"
        echo "[console] found exactly one — using '$NAME' ($INSTANCE_ID)" >&2
    else
        echo "FATAL: $COUNT running instances found — ambiguous. Pick one:" >&2
        echo "$RUNNING_JSON" | jq -r '.[] | "  \(.name)\t\(.shape)\t\(.id)"' >&2
        echo "Re-run with: --instance-id <ocid>" >&2
        exit 1
    fi
fi

# ---- RSA key: reuse if present, generate+persist if not ----
if [ -f "$PRIVATE_KEY" ]; then
    KEY_TYPE="$(ssh-keygen -l -f "$PRIVATE_KEY" 2>/dev/null | grep -o '(RSA)' || true)"
    if [ -z "$KEY_TYPE" ]; then
        echo "FATAL: $PRIVATE_KEY exists but isn't an RSA key — OCI's serial" >&2
        echo "console requires RSA specifically (Ed25519 is rejected). Pass a" >&2
        echo "different --key path, or move this file aside and re-run to" >&2
        echo "generate a fresh RSA key at the default path." >&2
        exit 1
    fi
    echo "[console] reusing existing RSA key at $PRIVATE_KEY" >&2
else
    echo "[console] no key at $PRIVATE_KEY — generating a new RSA 4096 key..." >&2
    mkdir -p "$(dirname "$PRIVATE_KEY")"
    ssh-keygen -t rsa -b 4096 -N "" -f "$PRIVATE_KEY" -C "oci-console-connect" >&2
fi
PUB_KEY="${PRIVATE_KEY}.pub"

# ---- Find or create the console connection ----
echo "[console] checking for an existing active console connection..." >&2
EXISTING_JSON="$("$OCI_BIN" compute instance-console-connection list \
    --compartment-id "$COMPARTMENT_ID" \
    --instance-id "$INSTANCE_ID" \
    --output json)"

CONN_ID="$(echo "$EXISTING_JSON" | jq -r '.data[] | select(."lifecycle-state"=="ACTIVE") | .id' | head -1)"

if [ -z "$CONN_ID" ] || [ "$CONN_ID" = "null" ]; then
    echo "[console] none found — creating one (this can take ~30-60s)..." >&2
    CONN_JSON="$("$OCI_BIN" compute instance-console-connection create \
        --instance-id "$INSTANCE_ID" \
        --ssh-public-key-file "$PUB_KEY" \
        --wait-for-state ACTIVE \
        --output json)"
else
    echo "[console] reusing existing active connection $CONN_ID" >&2
    CONN_JSON="$("$OCI_BIN" compute instance-console-connection get \
        --instance-console-connection-id "$CONN_ID" \
        --output json)"
fi

RAW_CONN_STR="$(echo "$CONN_JSON" | jq -r '.data."connection-string"')"
if [ -z "$RAW_CONN_STR" ] || [ "$RAW_CONN_STR" = "null" ]; then
    echo "FATAL: could not extract connection-string from the JSON response:" >&2
    echo "$CONN_JSON" >&2
    exit 1
fi

# Two nested ssh invocations — outer + ProxyCommand — both need: the
# private key (OCI's string never embeds a key path; it assumes
# ssh-agent or a default identity, which won't be true here),
# ControlPath=none (the proxy's long OCID-as-username + hostname
# routinely blows past the ~104-108 byte Unix socket path limit on the
# default multiplexing ControlPath template), and disabled strict host
# checking (the console's host key has nothing to do with the
# instance's own).
SAFE_FLAGS="-i ${PRIVATE_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ControlPath=none"

# Bash parameter-expansion global replace — avoids sed delimiter clashes
# with slashes in $PRIVATE_KEY.
PATCHED="${RAW_CONN_STR//ssh /ssh $SAFE_FLAGS }"

echo "$PATCHED"

if $DO_EXEC; then
    echo "[console] connecting..." >&2
    exec bash -c "$PATCHED"
fi