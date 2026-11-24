#!/bin/sh
[ -n "$ZMX_SESSION" ] || exit 0
dir=${CLAUDETTY_PROBE:+$CLAUDETTY_PROBE/status}; dir=${dir:-"$HOME/Library/Caches/claudetty/status"}
payload=$(cat)
quota=$(printf %s "$payload" | jq -c '.quota // empty')
[ -n "$quota" ] && mkdir -p "$dir" && printf %s "$quota" > "$dir/.agy-quota.$$" && mv "$dir/.agy-quota.$$" "$dir/agy-quota.json"
state=$(printf %s "$payload" | jq -r 'if .tool_confirmation_pending == true or .agent_state == "authenticating" then "waiting"
  elif .agent_state == "working" or .agent_state == "tool_use" or .agent_state == "reviewing" then "working" elif .agent_state then "idle" else empty end')
[ -n "$state" ] || exit 0
status=; { read -r status < "$dir/$ZMX_SESSION"; } 2>/dev/null
[ "$status" = "$state" ] && exit 0
mkdir -p "$dir"
printf %s "$state" > "$dir/.$ZMX_SESSION.$$" && mv "$dir/.$ZMX_SESSION.$$" "$dir/$ZMX_SESSION"
