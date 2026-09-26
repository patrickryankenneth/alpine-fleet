#!/usr/bin/env bash
# gcp-common.sh — shared, dynamic GCP discovery functions, scoped to
# Always-Free-eligible e2-micro instances only.
#
# Nothing project-specific is hardcoded except the three regions GCP's
# Always Free tier actually covers (us-west1, us-central1, us-east1) —
# that's a program constant, not a tenancy detail. Override with
# GCP_FREE_REGIONS (space-separated) if that ever changes. Everything
# else (project, zones, image) is resolved live, so this file is safe
# to commit and share.
#
# Usage: source this file from another script, then call the functions.
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/gcp-common.sh"

FREE_TIER_SHAPE_DEFAULT="e2-micro"

# ---- gcloud binary resolution ----
gcp_resolve_bin() {
  local bin="${GCLOUD_BIN:-}"
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    echo "$bin"
    return 0
  fi
  local found
  found="$(command -v gcloud || true)"
  if [ -n "$found" ]; then
    echo "$found"
    return 0
  fi
  echo "FATAL: no working gcloud binary found (checked GCLOUD_BIN, PATH)" >&2
  return 1
}

# ---- Project ----
gcp_resolve_project() {
  local gcloud_bin="$1"
  if [ -n "${GCP_PROJECT:-}" ]; then
    echo "$GCP_PROJECT"
    return 0
  fi
  local project
  project="$("$gcloud_bin" config get-value project 2>/dev/null)"
  if [ -z "$project" ] || [ "$project" = "(unset)" ]; then
    echo "FATAL: no gcloud project configured. Run: gcloud config set project PROJECT_ID (or set GCP_PROJECT)" >&2
    return 1
  fi
  echo "$project"
}

# ---- Always-Free-eligible regions ----
# GCP's Always Free tier only covers e2-micro in these three regions.
# This is a program constant, not something to discover live — override
# with GCP_FREE_REGIONS if Google ever changes the list.
gcp_free_tier_regions() {
  if [ -n "${GCP_FREE_REGIONS:-}" ]; then
    printf '%s\n' $GCP_FREE_REGIONS
    return 0
  fi
  printf '%s\n' us-west1 us-central1 us-east1
}

# ---- Free-tier machine type ----
gcp_free_tier_shape() {
  echo "${GCP_FREE_SHAPE:-$FREE_TIER_SHAPE_DEFAULT}"
}

# ---- Build gcloud --filter clauses from the free regions ----
# Two variants because the field differs by resource type:
#  - instances have a `zone` field (a URL ending .../zones/us-east1-c)
#  - a zone resource itself has no `zone` field — only `name` (its own
#    zone name, e.g. us-east1-c) and `region`
_gcp_region_zone_filter() {
  local r filter=""
  for r in $(gcp_free_tier_regions); do
    filter="${filter:+$filter OR }zone:${r}-*"
  done
  echo "$filter"
}

_gcp_region_name_filter() {
  local r filter=""
  for r in $(gcp_free_tier_regions); do
    filter="${filter:+$filter OR }name:${r}-*"
  done
  echo "$filter"
}

# ---- Zones within the free-tier regions ----
# Returns zone names one per line, discovered live so this doesn't rot
# if Google adds/removes zones within those regions.
gcp_list_free_tier_zones() {
  local gcloud_bin="$1" project="$2"
  "$gcloud_bin" compute zones list \
    --project "$project" \
    --filter="($(_gcp_region_name_filter)) AND status=UP" \
    --format="value(name)" 2>/dev/null
}

# ---- Running free-tier-shape count, scoped to the free-tier regions ----
# Mirrors oci_count_running_by_shape's role: tells the caller whether
# they're already at the Always-Free cap (1 non-preemptible
# e2-micro/account/month) before attempting to launch another.
gcp_count_running_free_tier() {
  local gcloud_bin="$1" project="$2" shape="$3"
  "$gcloud_bin" compute instances list \
    --project "$project" \
    --filter="status=RUNNING AND machineType:$shape AND ($(_gcp_region_zone_filter))" \
    --format="value(name)" 2>/dev/null | grep -c . || true
}

# ---- Image discovery ----
# Picks the current image for the given family/project. Defaults to
# Debian's stable family since every project's public catalog has it;
# override with IMAGE_PROJECT / IMAGE_FAMILY if you kexec from
# something else.
gcp_resolve_image() {
  local gcloud_bin="$1"
  local image_project="${IMAGE_PROJECT:-debian-cloud}"
  local image_family="${IMAGE_FAMILY:-debian-12}"
  local picked
  picked="$("$gcloud_bin" compute images describe-from-family "$image_family" \
    --project "$image_project" \
    --format="value(selfLink)" 2>/dev/null)"
  if [ -z "$picked" ]; then
    echo "FATAL: could not resolve image family '$image_family' in project '$image_project'. Set IMAGE_PROJECT/IMAGE_FAMILY to override." >&2
    return 1
  fi
  echo "$picked"
}

# ---- Running instances as JSON: [{id, name, shape, zone}, ...] ----
# Scoped to the free-tier regions so teardown/list stay consistent with
# what launch-gcp.sh is allowed to create.
gcp_list_running_instances() {
  local gcloud_bin="$1" project="$2"
  "$gcloud_bin" compute instances list \
    --project "$project" \
    --filter="status=RUNNING AND ($(_gcp_region_zone_filter))" \
    --format=json 2>/dev/null \
    | jq '[(. // [])[] | {id: (.id|tostring), name: .name, shape: (.machineType | split("/") | last), zone: (.zone | split("/") | last)}]'
}
