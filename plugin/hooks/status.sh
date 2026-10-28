#!/bin/sh
dir=${CLAUDETTY_PROBE:+$CLAUDETTY_PROBE/status}; dir=${dir:-"$HOME/Library/Caches/claudetty/status"}
if [ "$1" = send ]; then
  to=$(jq -r '.tool_input.to // empty')
  app=${CLAUDETTY_PROBE:-"$HOME/Library/Application Support/ClaudeTTY"}
  tab=$(jq -r --arg to "$to" 'first(.kept[]? | select(.labels.sleep != null and (.labels.sleep == $to or .name == $to))) | "\(.group)\t\(.name)"' "$app/state.json" 2>/dev/null)
  [ -n "$tab" ] || exit 0
  group=${tab%%"	"*} tab=${tab#*"	"}
  ct=$(command -v ct) || ct="$HOME/.local/bin/ct"
  "$ct" "$group" "$tab" >/dev/null 2>&1
  i=0
  while [ $i -lt 240 ]; do
    for f in $(grep -lF "\"name\":\"$to\"" "$HOME"/.claude/sessions/*.json 2>/dev/null); do
      jq -r '"\(.pid) \(.messagingSocketPath)"' "$f" | { read -r pid sock; kill -0 "$pid" 2>/dev/null && [ -S "$sock" ]; } && [ "$(cat "$dir/$tab" 2>/dev/null)" = idle ] && exit 0
    done
    sleep 0.5; i=$((i+1))
  done
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(jq -n --arg r "$to was asleep in ClaudeTTY tab $tab and hasn't woken within 2 min. Retry the SendMessage." '$r')"
  exit 0
fi
[ -n "$ZMX_SESSION" ] || exit 0
input=$(cat)
[ "$1" = working ] && printf %s "$input" | jq -e 'has("agent_id")' >/dev/null 2>&1 && exit 0
case "$1" in idle|agent|"") event=$(printf %s "$input" | jq -r .hook_event_name);; esac
[ -d "$dir" ] || mkdir -p "$dir"
status=; { read -r status < "$dir/$ZMX_SESSION"; } 2>/dev/null
if [ "$1" = notify ]; then
  if "$HOME/.local/bin/zmx" get "$ZMX_SESSION" | tr ' \t' '\n\n' | grep -qx notify=0; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"muted in ClaudeTTY; don'"'"'t retry"}}'
  else
    message=$(printf %s "$input" | jq -j '.tool_input.message // empty')
    [ -z "$message" ] || { printf %s "$message" > "$dir/.$ZMX_SESSION.notice.$$" && mv "$dir/.$ZMX_SESSION.notice.$$" "$dir/$ZMX_SESSION.notice" && rm -f "$dir/$ZMX_SESSION.asked"; }
  fi
  exit 0
fi
case "$event/$1" in SessionStart/*|SessionEnd/*|Stop/*|SubagentStart/*|SubagentStop/*|*/working) ;; *) [ "$status" = "$1" ] && exit 0;; esac
case "$1" in working) line=Thinking;; action|waiting)
  [ "$1" = action ] && [ "$status" = waiting ] && exit 0
  line=$(printf %s "$input" | jq -j --arg kind "$1" '.tool_name as $tool | (.tool_input.command // "" | sub("^\\s*cd [^;&|]*(;|&&)\\s*"; "")) as $run
    | (if $tool != "Bash" then $tool elif $run | test("^(rg|grep|fd|find|mdfind|ls|tree|\\S*/map)\\b") then "Grep" elif $run | test("^(cat|head|tail|sed -n|less|bat)\\b") then "Read" else $tool end) as $dots | (if $kind == "action" and (.tool_name | IN("AskUserQuestion", "ExitPlanMode")) then empty
    elif .hook_event_name == "PermissionRequest" then (if .tool_name == "Bash" then .tool_input.description // "" | rtrimstr(".")
      elif (.tool_input.file_path // "") != "" then "\(.tool_name) \(.tool_input.file_path | split("/") | last)"
      elif .tool_name == "WebFetch" then "Fetch \(.tool_input.url // "" | split("/")[2] // "")"
      else "" end | if . == "" then "Allow \($tool | split("__") | last)" else . end) + "?"
    elif .tool_name == "AskUserQuestion" then .tool_input.questions[0].question // "question"
    elif .tool_name == "ExitPlanMode" then "Approve the plan?"
    elif .hook_event_name == "Notification" then .message
    elif .tool_name == "Bash" then .tool_input.description // "Bash"
    elif (.tool_input.file_path // "") != "" then "\(.tool_name) \(.tool_input.file_path | split("/") | last)"
    else .tool_name end | gsub("[\t\n]+"; " ")) + if $kind == "action" then "\t\($dots)" else "" end')
  [ -n "$line" ] || exit 0;;
esac
top=; { read -r top < "$dir/.$ZMX_SESSION.top"; } 2>/dev/null
if [ "$top" != "$CLAUDE_PID" ]; then
  ps -E -ww -o command= -p "$CLAUDE_PID" | tr ' ' '\n' | grep -q '^CLAUDE_PID=' && exit 0
  printf '%s\n' "$CLAUDE_PID" > "$dir/.$ZMX_SESSION.top"
fi
case "$event" in SessionStart|SessionEnd) "$HOME/.local/bin/zmx" set "$ZMX_SESSION" "claude=$([ "$event" = SessionStart ] && printf %s "$input" | jq -r .session_id)" >/dev/null;; esac
transcript="$dir/$ZMX_SESSION.transcript"
if [ "$event" = SessionStart ] || { [ "$1" = working ] && [ ! -f "$transcript" ]; }; then
  printf %s "$input" | jq -j '.transcript_path // empty' > "$transcript.$$" && mv "$transcript.$$" "$transcript"
fi
[ "$event" = SessionEnd ] && rm -f "$transcript"
[ "$event" = SessionStart ] && rm -f "$dir/$ZMX_SESSION.topic"
agents="$dir/$ZMX_SESSION.agents"
if [ -n "$event" ]; then
old=$(cat "$agents" 2>/dev/null)
new=$(printf %s "$input" | jq -r --arg old "$old" --arg now "$(date +%s)" '
  ($old | split("\n") | map(select(. != "") | split("\t"))) as $rows
  | (.transcript_path // "" | rtrimstr(".jsonl")) as $base
  | def agent($id): ["agent", $id, $now, "\($base)/subagents/agent-\($id).jsonl"];
  if .hook_event_name == "SubagentStart" then
    .agent_id as $id | if (.agent_type // "") == "" or any($rows[]; .[1] == $id) then $rows else $rows + [agent($id)] end
  elif .hook_event_name == "SubagentStop" then .agent_id as $id | $rows | map(select(.[1] != $id))
  elif .hook_event_name == "Stop" then
    [(.background_tasks // [])[] as $task | first(($rows[] | select(.[1] == $task.id)), if $task.type == "subagent" then agent($task.id) else ["shell", $task.id, $now, ($task.command // $task.description // "" | gsub("[\t\n]"; " "))] end)]
  elif .hook_event_name == "SessionStart" and .source == "compact" then $rows
  elif .hook_event_name == "SessionStart" or .hook_event_name == "SessionEnd" then []
  else $rows end
  | map(join("\t") + "\n") | add // ""')
[ "$new" = "$old" ] || { printf '%s\n' "$new" > "$agents.tmp" && mv "$agents.tmp" "$agents"; }
fi
[ "$1" = idle ] && rm -f "$dir/$ZMX_SESSION.action"
case "$1" in working|action|waiting)
  [ "$1" = waiting ] && last=$(head -n 1 "$dir/$ZMX_SESSION.action" 2>/dev/null)
  { [ "$1" = waiting ] && printf '%s\n' "$last"; printf %s "$line"; } > "$dir/.$ZMX_SESSION.action.$$" && mv "$dir/.$ZMX_SESSION.action.$$" "$dir/$ZMX_SESSION.action"
  [ "$1" = action ] && exit 0;;
esac
case "$1/$event" in agent/*) exit 0;; working/) [ "$status" = working ] && exit 0;; */Stop) [ "$status" = "$1" ] && exit 0;; esac
if [ "$1" = waiting ]; then
  "$HOME/.local/bin/zmx" get "$ZMX_SESSION" | tr ' \t' '\n\n' | grep -qx notify=0 || { printf %s "$line" > "$dir/.$ZMX_SESSION.notice.$$" && mv "$dir/.$ZMX_SESSION.notice.$$" "$dir/$ZMX_SESSION.notice" && : > "$dir/$ZMX_SESSION.asked"; }
elif [ "$status" = waiting ] && [ -f "$dir/$ZMX_SESSION.asked" ]; then
  rm -f "$dir/$ZMX_SESSION.notice" "$dir/$ZMX_SESSION.asked"
fi
printf %s "$1" > "$dir/.$ZMX_SESSION.$$" && mv "$dir/.$ZMX_SESSION.$$" "$dir/$ZMX_SESSION"
