#!/usr/bin/env bash
# oci-common.sh — shared, dynamic OCI discovery functions.
#
# Nothing tenancy-specific is hardcoded here. Every value is resolved at
# runtime from the local OCI CLI config or live API calls, so this file
# is safe to commit and share — it contains no OCIDs, no AD names, no
# subnet/image IDs.
#
# Usage: source this file from another script, then call the functions.
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/oci-common.sh"

# ---- OCI binary resolution ----
oci_resolve_bin() {
  local bin="${OCI_BIN:-}"
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    echo "$bin"
    return 0
  fi
  # Common conda/venv install location, then fall back to PATH.
  for candidate in "$HOME"/miniforge3/envs/*/bin/oci "$HOME"/miniconda3/envs/*/bin/oci; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  local found
  found="$(command -v oci || true)"
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi
  echo "FATAL: no working oci binary found (checked OCI_BIN, conda envs, PATH)" >&2
  return 1
}

# ---- Compartment ID ----
# The tenancy OCID IS the root compartment OCID in OCI's model, so reading
# it from the CLI config's 'tenancy=' line gives the root compartment with
# no separate lookup needed. Override with COMPARTMENT_ID env var if the
# user wants a non-root compartment.
oci_resolve_compartment_id() {
  if [ -n "${COMPARTMENT_ID:-}" ]; then
    echo "$COMPARTMENT_ID"
    return 0
  fi
  local config_file="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
  if [ ! -f "$config_file" ]; then
    echo "FATAL: OCI config not found at $config_file" >&2
    return 1
  fi
  local id
  id=$(grep '^tenancy' "$config_file" | head -1 | cut -d'=' -f2 | tr -d ' ')
  if [ -z "$id" ]; then
    echo "FATAL: could not find 'tenancy=' in $config_file" >&2
    return 1
  fi
  echo "$id"
}

# ---- Availability domains ----
# Returns AD names one per line, e.g.:
#   AbCd:PHX-AD-1
#   AbCd:PHX-AD-2
#   AbCd:PHX-AD-3
# Discovered live from the API — never hardcoded, so this works in any
# tenancy/region without editing.
oci_list_availability_domains() {
  local oci_bin="$1"
  local compartment_id="$2"
  "$oci_bin" iam availability-domain list \
    --compartment-id "$compartment_id" \
    --query "data[].name" \
    --raw-output 2>/dev/null | tr -d '[]"' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sed '/^$/d'
}

# ---- Per-AD scoped limit availability (e.g. E2.1.Micro count) ----
oci_get_availability_ad() {
  local oci_bin="$1" compartment_id="$2" limit_name="$3" ad="$4"
  "$oci_bin" limits resource-availability get \
    --compartment-id "$compartment_id" \
    --service-name compute \
    --limit-name "$limit_name" \
    --availability-domain "$ad" \
    --query "data.available" \
    --raw-output 2>/dev/null
}

# ---- Region-wide scoped limit availability (e.g. A1 core/memory pool) ----
# Must NOT pass --availability-domain: regional-scope limits reject it
# ("Parameter 'availabilityDomain' should be null for this limit's scope
# type") — confirmed empirically against standard-a1-core-regional-count
# and standard-a1-memory-regional-count.
oci_get_availability_regional() {
  local oci_bin="$1" compartment_id="$2" limit_name="$3"
  "$oci_bin" limits resource-availability get \
    --compartment-id "$compartment_id" \
    --service-name compute \
    --limit-name "$limit_name" \
    --query "data.available" \
    --raw-output 2>/dev/null
}

# ---- Running instance count by shape ----
oci_count_running_by_shape() {
  local oci_bin="$1" compartment_id="$2" shape="$3"
  "$oci_bin" compute instance list \
    --compartment-id "$compartment_id" \
    --lifecycle-state RUNNING \
    --all \
    --query "length(data[?shape=='$shape'])" \
    --raw-output 2>/dev/null
}

# ---- Subnet discovery ----
# Picks the first subnet found in the compartment. If there is more than
# one, this is a guess, not a certain answer — callers should print what
# was picked so the user can verify or override with SUBNET_ID.
oci_resolve_subnet_id() {
  local oci_bin="$1" compartment_id="$2"
  if [ -n "${SUBNET_ID:-}" ]; then
    echo "$SUBNET_ID"
    return 0
  fi
  local all_subnets count picked
  all_subnets=$("$oci_bin" network subnet list \
    --compartment-id "$compartment_id" \
    --all \
    --query "data[].{id:id,name:\"display-name\"}" \
    --output json 2>/dev/null)
  count=$(echo "$all_subnets" | grep -c '"id"')
  picked=$(echo "$all_subnets" | grep -m1 '"id"' | sed -E 's/.*"id": "([^"]+)".*/\1/')
  if [ -z "$picked" ]; then
    echo "FATAL: no subnets found in compartment $compartment_id" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "WARNING: multiple subnets found ($count) — picked the first one. Set SUBNET_ID to override." >&2
  fi
  echo "$picked"
}

# ---- Image discovery ----
# Picks the newest Oracle Linux image compatible with the given shape.
# This is a default, not a guarantee it's the image the user actually
# wants — print what was picked, allow IMAGE_ID override.
oci_resolve_image_id() {
  local oci_bin="$1" compartment_id="$2" shape="$3"
  if [ -n "${IMAGE_ID:-}" ]; then
    echo "$IMAGE_ID"
    return 0
  fi
  local picked
  picked=$("$oci_bin" compute image list \
    --compartment-id "$compartment_id" \
    --operating-system "Oracle Linux" \
    --shape "$shape" \
    --sort-by TIMECREATED \
    --sort-order DESC \
    --query "data[0].id" \
    --raw-output 2>/dev/null)
  if [ -z "$picked" ] || [ "$picked" = "null" ]; then
    echo "FATAL: could not find an Oracle Linux image compatible with $shape. Set IMAGE_ID to override." >&2
    return 1
  fi
  echo "$picked"
}

# ---- Running instances as JSON: [{id, name, shape}, ...] ----
oci_list_running_instances() {
  local oci_bin="$1" compartment_id="$2"
  "$oci_bin" compute instance list \
    --compartment-id "$compartment_id" \
    --lifecycle-state RUNNING \
    --all \
    --output json 2>/dev/null \
    | jq '[(.data // [])[] | {id: .id, name: ."display-name", shape: .shape}]'
}
