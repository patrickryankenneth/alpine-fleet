#!/usr/bin/env bash
# tailscale-common.sh: mint keys, find/delete fleet devices by alias.
# Only ever touches devices carrying $TS_TAG.
TS_API="https://api.tailscale.com/api/v2"
TS_TAG="${TS_TAG:-tag:fleet}"
TS_TAILNET="${TS_TAILNET:--}"
TS_KEY_FILE="${TS_KEY_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/alpine-fleet/tailscale-key}"

ts_token() {
  if [ -n "${TS_API_KEY:-}" ]; then printf '%s' "$TS_API_KEY"; return 0; fi
  if [ -r "$TS_KEY_FILE" ]; then tr -d '[:space:]' < "$TS_KEY_FILE"; return 0; fi
  cat >&2 <<MSG
FATAL: no Tailscale API key found. Provide one of:
  export TS_API_KEY=tskey-api-...
  or save it to $TS_KEY_FILE (chmod 600):
    mkdir -p "\$(dirname "$TS_KEY_FILE")"
    read -rs k && printf '%s' "\$k" > "$TS_KEY_FILE" && chmod 600 "$TS_KEY_FILE"
Create a key at https://login.tailscale.com/admin/settings/keys
MSG
  return 1
}

# token goes via a config fd, not argv, so it never shows in `ps`
_ts_curl() {
  local tok; tok="$(ts_token)" || return 1
  curl -fsS --config <(printf 'user = "%s:"\n' "$tok") "$@"
}

ts_check() {
  _ts_curl "$TS_API/tailnet/$TS_TAILNET/devices" | jq -e '.devices | length >= 0' >/dev/null
}

ts_find_fleet_devices() {
  _ts_curl "$TS_API/tailnet/$TS_TAILNET/devices" | jq -c --arg a "$1" --arg t "$TS_TAG" \
    '.devices[] | select(((.name|split(".")[0]) | test("^" + $a + "(-[0-9]+)?$")) and ((.tags // []) | index($t))) | {id,name}'
}

ts_delete_alias() {
  local alias="$1" row id
  while read -r row; do
    [ -n "$row" ] || continue
    id="$(jq -r .id <<<"$row")"
    echo "Tailscale: deleting stale device $(jq -r .name <<<"$row")"
    _ts_curl -X DELETE "$TS_API/device/$id" >/dev/null
  done < <(ts_find_fleet_devices "$alias")
}

ts_mint_key() {
  local body
  body="$(jq -n --arg t "$TS_TAG" --argjson e "${1:-3600}" \
    '{capabilities:{devices:{create:{reusable:false,ephemeral:false,preauthorized:true,tags:[$t]}}},expirySeconds:$e}')"
  _ts_curl -X POST -H 'Content-Type: application/json' -d "$body" \
    "$TS_API/tailnet/$TS_TAILNET/keys" | jq -r '.key // empty'
}

ts_wait_alias() {
  local end=$((SECONDS + ${2:-600}))
  while [ $SECONDS -lt $end ]; do
    [ -n "$(ts_find_fleet_devices "$1")" ] && return 0
    sleep 10
  done
  return 1
}

# id<TAB>name<TAB>online<TAB>tags for <alias> or <alias>-N, any tag
ts_list_alias_any() {
  _ts_curl "$TS_API/tailnet/$TS_TAILNET/devices" | jq -r --arg a "$1" \
    '.devices[] | select((.name|split(".")[0]) | test("^" + $a + "(-[0-9]+)?$"))
     | [.id, .name, (.connectedToControl|tostring), ((.tags // [])|join(","))] | @tsv'
}

# Free up <alias>. Stale offline fleet devices go silently; anything else
# (online, or not tag:fleet) needs a y/N confirm unless TS_REPLACE=1.
ts_claim_alias() {
  local id name online tags ans state
  while IFS=$'\t' read -r id name online tags; do
    [ -n "$id" ] || continue
    if [ "$online" = "false" ] && [[ ",$tags," == *",$TS_TAG,"* ]]; then
      :
    elif [ "${TS_REPLACE:-0}" != "1" ]; then
      state=offline; [ "$online" = "true" ] && state=ONLINE
      echo "Tailscale: '$name' already exists (tags: ${tags:-none}, $state)." >&2
      [ -r /dev/tty ] || { echo "FATAL: not interactive; set TS_REPLACE=1 to remove it." >&2; return 1; }
      read -r -p "Remove it so the new node can take this name? [y/N] " ans </dev/tty
      [[ "$ans" =~ ^[yY]$ ]] || { echo "Aborted." >&2; return 1; }
    fi
    echo "Tailscale: removing $name"
    _ts_curl -X DELETE "$TS_API/device/$id" >/dev/null
  done < <(ts_list_alias_any "$1")
}
