ClaudeTTY Plugin
================

This is the Claude Code plugin behind [ClaudeTTY](https://github.com/aqilc/ClaudeTTY), a macOS terminal for running a bunch of Claude Code sessions in tabs. It tells the sidebar what each session is doing (working, waiting on you, idle) and teaches Claude the `ct` command, which lets the session in one tab open, watch and steer the others.

You don't need to install it yourself. The app installs it on launch and updates it with each release. It only does anything inside a ClaudeTTY tab, and outside one every hook exits right away.

What It Runs
------------

Every hook runs [`hooks/status.sh`](hooks/status.sh) with `sh`. It needs `jq`, makes no network calls and only writes under `~/Library/Caches/claudetty/status/`, one set of small files per tab:

- the tab's state, and the line the sidebar shows under it (a Bash command's description, a file tool's file name, or the question Claude is asking)
- the tab's notice when Claude sends a push notification or asks you something
- the path to the tab's transcript, which the sidebar reads to show when Claude is writing
- the tab's running subagents and background shells, for the agents menu

It also sets a `claude=<session id>` label on the tab's [zmx](https://github.com/neurosnap/zmx) session, and runs `ps` on its own Claude Code process once to tell a nested instance from the tab's own.

There are two cases where it answers a tool call instead of just watching:

- A `PushNotification` in a tab you muted from its right-click menu gets denied, which also stops the push to your phone.
- A `SendMessage` to a session that's asleep in a ClaudeTTY tab wakes that tab with `ct`, reading the app's `state.json` and `~/.claude/sessions/` to find it, and waits up to 2 minutes for it to come back before sending. If it doesn't wake, the send gets denied with a note to retry. This one runs from any terminal.

The `ct` Skill
--------------

[`skills/ct/SKILL.md`](skills/ct/SKILL.md) is a short table of `ct` commands. Claude only reads it when it's working inside a ClaudeTTY tab and you ask it to deal with other tabs.

License
-------

[CC BY-NC-SA 4.0](../LICENSE), same as the app.
