---
name: ct
description: Drive ClaudeTTY tabs from the shell - list them with their Claude state, wait for one to finish or ask, follow state changes, bring one forward, type into one, read its screen or close it. Use when inside a ClaudeTTY tab (ZMX_SESSION is set) and asked to watch, steer or coordinate other tabs or sessions.
---

# ct: ClaudeTTY from the shell

A tab is a zmx session; `<tab>` is its session name (`ct list`'s second column, `$ZMX_SESSION` for this one). States: `working`, `waiting` (asks you), `idle`, `asleep` (slept: no zmx session, still in the sidebar; `ct <group> <tab>` wakes it), `shell` (no Claude in front).

| Do | Command |
|---|---|
| Open a tab (a group's first tab takes its name), or move a live tab to that group | `ct <group> [<tab> [command…]]` |
| Open a tab in a new pane beside a tab's, as ⌘D | `ct split <tab> right\|down\|left\|up <name> [command…]` |
| List tabs: group, tab, title, state, folder, context (its Claude's tokens, blank for a shell) | `ct list` (tab-separated) or `ct list --json` |
| Follow states: each tab's now, then a line per change (`<tab>\t<state>`, `asleep` when it sleeps, `closed` when it ends) | `ct events` |
| Wait until a tab holds a state (exit 1 if it ends first) | `ct wait <tab> idle` |
| Bring a tab forward | `ct focus <tab>` |
| Type into a tab (`\r` = Enter) | `zmx send <tab> "text"` then `zmx send <tab> $'\r'` |
| Read what is typed in its prompt box, not yet sent (empty if none; exit 1 if no Claude box shows) | `ct prompt <tab>` |
| Read its screen | `zmx history <tab> \| tail -60` |
| Close it | `zmx kill <tab>` |
| Leave this tab a notice | `ct notify <text>` |

Both return once the tab's session runs, and do nothing to a tab already in that group, so a layout is a script of `ct` lines you can rerun:

```sh
cd ~/project
ct web dev bun run dev
ct split dev right agent claude
ct split agent down tests
```

A tab opens in the folder `ct` runs from, so a task gets its own worktree and Claude in one line:

```sh
git worktree add ../fix-login && cd ../fix-login && ct tasks fix-login claude
```

zmx is linked beside `ct` (`~/.local/bin`). A group named `list`, `events`, `wait`, `focus`, `split`, `notify`, `prompt`, `reload` or `help`, or starting with `-`, can't be opened with `ct`, nor a tab named `logs` (zmx's own folder). Rename in the app: a zmx label set from outside doesn't reach the running app.
