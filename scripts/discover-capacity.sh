#!/usr/bin/env bash
# discover-capacity.sh — read-only free-tier headroom discovery.
# No launching. Fully dynamic: compartment ID, AD list, and every limit
# check are resolved live — nothing tenancy-specific is hardcoded, so
# this file is safe to commit and share as-is.
#
# Exit code: 0 if any headroom found, 1 if fully at cap.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/oci-common.sh"

OCI_BIN="$(oci_resolve_bin)" || exit 1
COMPARTMENT_ID="$(oci_resolve_compartment_id)" || exit 1

E2_CAP=2
A1_CORE_CAP=2
A1_MEM_CAP=12

echo "Compartment: $COMPARTMENT_ID"

mapfile -t ADS < <(oci_list_availability_domains "$OCI_BIN" "$COMPARTMENT_ID")
if [ "${#ADS[@]}" -eq 0 ]; then
  echo "FATAL: no availability domains discovered for this compartment/region." >&2
  exit 1
fi
echo "Discovered ${#ADS[@]} availability domain(s): ${ADS[*]}"
echo

E2_HEADROOM=0
A1_HEADROOM=0

echo "--- E2.1.Micro (cap: $E2_CAP total, per-AD scoped) ---"
for AD in "${ADS[@]}"; do
  AVAIL=$(oci_get_availability_ad "$OCI_BIN" "$COMPARTMENT_ID" "vm-standard-e2-1-micro-count" "$AD")
  AVAIL="${AVAIL:-0}"
  echo "  $AD: available=$AVAIL"
  if [ "$AVAIL" -gt 0 ] 2>/dev/null; then
    E2_HEADROOM=1
  fi
done

echo
echo "--- A1.Flex core (cap: $A1_CORE_CAP OCPU total, region-wide pool) ---"
A1_CORE_AVAIL=$(oci_get_availability_regional "$OCI_BIN" "$COMPARTMENT_ID" "standard-a1-core-regional-count")
A1_CORE_AVAIL="${A1_CORE_AVAIL:-0}"
echo "  region: available=$A1_CORE_AVAIL"

echo
echo "--- A1.Flex memory (cap: $A1_MEM_CAP GB total, region-wide pool) ---"
A1_MEM_AVAIL=$(oci_get_availability_regional "$OCI_BIN" "$COMPARTMENT_ID" "standard-a1-memory-regional-count")
A1_MEM_AVAIL="${A1_MEM_AVAIL:-0}"
echo "  region: available=$A1_MEM_AVAIL"

echo
E2_RUNNING=$(oci_count_running_by_shape "$OCI_BIN" "$COMPARTMENT_ID" "VM.Standard.E2.1.Micro")
E2_RUNNING="${E2_RUNNING:-0}"
echo "Cross-check — E2.1.Micro instances actually RUNNING: $E2_RUNNING / $E2_CAP"

# A1 needs BOTH core and memory headroom to be launchable.
if [ "$A1_CORE_AVAIL" -gt 0 ] 2>/dev/null && [ "$A1_MEM_AVAIL" -gt 0 ] 2>/dev/null; then
  A1_HEADROOM=1
fi

echo
[ "$E2_HEADROOM" -eq 1 ] && echo "E2.1.Micro: headroom detected." || echo "E2.1.Micro: NO headroom."
[ "$A1_HEADROOM" -eq 1 ] && echo "A1.Flex:    headroom detected." || echo "A1.Flex:    NO headroom."

# Exit 0 if E2 has headroom (this repo's focus). Pass --any to also count A1.
if [ "$E2_HEADROOM" -eq 1 ]; then
  exit 0
elif [ "${1:-}" = "--any" ] && [ "$A1_HEADROOM" -eq 1 ]; then
  exit 0
fi
exit 1