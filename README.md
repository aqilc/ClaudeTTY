<p align="center">
  <img src="media/icon.png" width="128" alt="">
</p>

<h1 align="center">ClaudeTTY</h1>

<p align="center">
  A Mac terminal for running as much Claude Code as you'll ever need.<br>
  <sub>Built on libghostty + zmx. All tabs run in the background so updates/crashes are headache-free.</sub>
</p>

<p align="center">
  <a href="https://github.com/aqilc/ClaudeTTY/releases/latest/download/ClaudeTTY.dmg"><img src="media/download.svg" width="236" alt="Download for Mac"></a><br>
  <sub>macOS 26 or later, Apple Silicon</sub>
</p>

<p align="center">
  <img src="media/hero.png" width="900" alt="ClaudeTTY with five groups in the sidebar and Claude working in two tabs">
</p>

I made this because I let Claude write the code and only step in to make an edit now and then. You don't really need file trees or editors for that, so I took them out. I don't look at code most of the time, and with Claude doing the work there's not much need to. Edits I would make also feel worthless since they're just normal code anyways, so it's going to get replaced eventually.

I was using cmux before this. It's a good app, but it was buggy for me (crashed a lot; updates killed everything; memory leaks; it'd pile up a bajillion unread notifications that didn't work properly), it only really tracks one Claude per workspace, and it ships a browser, a file viewer, port lists and a lot more that was used once in a while but didn't deserve its space. ClaudeTTY keeps the layout I liked (groups in a sidebar, tabs in the titlebar) and gets rid of the bloat.

I'm keeping it that way on purpose. I think it's pretty much done, so apart from bugs and small niceties I won't be adding much. If you need something else, there's probably a terminal tool for it, like [terminal-browser](https://terminal-browser.com/) for the web or [ttt](https://github.com/eugenioenko/ttt) (I used vim anw). And since ClaudeTTY is fast, they run better here than a lot of dedicated GUI apps do, even when talking about cmux. Ask your agent to add the functionality you need for those tools.

For the same reason pull requests are turned off on this repo. If you want it to do something else, fork it and change it (see "Change it yourself" below). Bug reports and cool feature requests that land with my philosophy in Issues are welcome.

## Looks (top tier, animated throughout)

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="media/dots.gif" alt="The tab dots for each activity">
      <p><b>See what every Claude is doing.</b> Each tab's dots move differently for thinking, writing, reading, searching and running code, and turn amber when that Claude is waiting on you. Tabs also show how much context they've used. Notifications won't spam you either, you only get the latest one per tab and it goes away once you open the tab.</p>
    </td>
    <td width="50%" valign="top">
      <img src="media/survive.gif" alt="The app is killed and reopened with every tab still running">
      <p><b>You can't lose something if you want to.</b> Each tab runs in a <a href="https://github.com/neurosnap/zmx">zmx</a> session outside the app. Quit, crash or update it and your tabs are all still there, and any Claude that was working keeps working. Same when Claude Code auto-updates, the Claudes you already had open stay up and ClaudeTTY still tracks them.</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="media/panes.png" alt="A group split into panes, each with its own tab bar">
      <p><b>Groups, tabs and panes.</b> Color and pin groups in the sidebar. <kbd>⌘</kbd><kbd>D</kbd> splits groups into panes, <kbd>⌃</kbd><kbd>1</kbd>–<kbd>9</kbd> jumps between tabs, and <kbd>⌘</kbd>-click opens links, file names and paths, even while Claude Code has the mouse.</p>
    </td>
    <td width="50%" valign="top">
      <img src="media/mod.gif" alt="Editing the source, running install.sh, and the open app switching to the new build">
      <p><b>Change it yourself.</b> The whole app is about 5,500 lines of Swift in three files. Change something (or ask Claude to), run <code>./install.sh</code>, and the open window switches to the new build like magic.</p>
    </td>
  </tr>
  <tr>
    <td colspan="2" align="center">
      <img src="media/sidebar.gif" width="700" alt="Dragging the sidebar edge shut, open again and shut again in one drag">
      <p><b>Drag the sidebar shut.</b> Satisfying. <kbd>⌘</kbd><kbd>B</kbd> for less satisfaction but some more practicality.</p>
    </td>
  </tr>
</table>

## Comparison with others in its space.

| | ClaudeTTY | cmux | Superset | Warp | Wave | Ghostty |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Tabs keep running after a quit or crash | ✅ | opt-in, through tmux | ✅ | ❌ | SSH only, opt-in | ❌ |
| Shows what each Claude is doing | ✅ | needs-attention ring | working and done | with its plugin | ❌ | ❌ |
| Claude can run other tabs | ✅ | CLI and socket | CLI, MCP and SDK | ❌ | `wsh` CLI | ❌ |
| Swift on top of the terminal core | 353 KB | 114 MB | none (Electron) | none (Rust) | none (Electron) | 1.5 MB |
| Launch to first window | 307 ms | 701 ms | 889 ms | 829 ms | 1,226 ms | 302 ms |
| Memory, one idle tab | 68 MB | 1,029 MB | 359 MB | 895 MB | 556 MB | 84 MB |
| Idle CPU | 0.03% | 3.1% | 1.9% | 3.2% | 1.9% | 0.7% |
| App size | 20 MB | 454 MB | 1.5 GB | 872 MB | 531 MB | 62 MB |

<sub>Measured on an M4 Pro (48 GB) with macOS 27.0, one window with one tab, median of 5 launches, memory as Activity Monitor's footprint 20 s after launch, CPU over the next 30 s. cmux 0.65.2, Superset 1.39.0, Warp 0.2026.10.14 and Wave 0.14.5 on fresh profiles, Ghostty 1.3.1. ClaudeTTY's memory includes the zmx process that holds the tab, and Swift sizes are GitHub's language counts. Without tmux, cmux reopens your layout and restarts Claude into its last conversation, but whatever was running is gone. (<a href="https://github.com/manaflow-ai/cmux">cmux README</a>, <a href="https://superset.sh/blog/terminal-daemon-deep-dive">Superset</a>, <a href="https://docs.warp.dev/terminal/sessions/session-restoration">Warp</a>, <a href="https://docs.waveterm.dev/durable-sessions">Wave</a>, <a href="https://ghostty.org/docs/config/reference">Ghostty docs</a>)</sub>
## Smaller things I like

- After a reboot every tab opens again in its group, and each Claude picks its conversation back up with `claude --resume`.
- Click "3 agents" under a group and pick one, and that subagent's transcript opens in a pane right next to its Claude, live. Pretty fun to watch them work.
- Drop a screenshot on a Claude tab and it attaches as [Image #1], same as Claude Code's own paste, and other files go in as @ mentions. <kbd>⌘</kbd><kbd>V</kbd> on a copied image works too.
- Claude tabs title the same as the name Claude Code gives the conversation.
- The menu bar icon shows you how many tabs want your input, so I close the window but can come back when I remember instead of being constantly bothered.
- idle groups show the last thing their Claude said and how long ago, which is usually enough for me to remember what I was even doing there.
- The dots wait a quarter second before switching, so a Claude flying through a bunch of quick file reads doesn't turn into a strobe light.
- <kbd>⌘</kbd><kbd>P</kbd> <kbd>↩</kbd> takes you back to the tab you were just in, basically <kbd>⌘</kbd><kbd>Tab</kbd> for tabs.
- If you right-click a group and pick Sort by State, waiting groups stay at the top in the sidebar.
- Holding <kbd>⌃</kbd> shows each tab's number.
- <kbd>⌘</kbd><kbd>⇧</kbd><kbd>T</kbd> reopens the last tab you closed, in the same group and spot. A Claude tab resumes its conversation with the same flags it was started with, and a shell gets its folder and scrollback back.
- Groups can go in folders (right-click a group, Move to Folder). Clicking a folder collapses it, and that's all a folder does, it's just for sorting. <kbd>⌘</kbd>-click or <kbd>⇧</kbd>-click selects several groups if you want to move a bunch at once.
- Right-click a tab and pick Schedule Message… to have it typed in at a set time, so you can queue up a message for Claude or a command for later.
- It updates itself. It checks GitHub at launch and once a day, downloads the new version in the background and waits for you to pick Restart to Update in the ClaudeTTY menu.
- If you answer a permission prompt from somewhere else, the notification goes away on its own instead of sitting there forever.
- Shell tabs come back scrolled to where you left them after an update, not dumped at the bottom.
- Closing a tab first tells you what's still running in it, like the Claude, its agents and shells, and how long each job's been going.

## Let Claude run the other tabs

ClaudeTTY installs a Claude Code plugin and a `ct` command, so the Claude in one tab can open, watch and steer the others:

```sh
ct list                          # every tab, its group, folder and Claude state
ct web dev bun run dev           # open tab "dev" in group "web", running a command
ct split dev right agent claude  # a new pane beside it with Claude in it
ct wait agent idle               # block until that Claude is done
zmx send agent "run the tests"   # type into it
```

Don't even look at this, this is meant so your Claude has fine grained orchestration abilities and can accept prompts and other things for you without you ever having to step in. My terminal teaches it to Claude automatically, in as few tokens as possible (~75 to be exact).

## Install

[Download ClaudeTTY.dmg](https://github.com/aqilc/ClaudeTTY/releases/latest/download/ClaudeTTY.dmg), open it and drag ClaudeTTY to Applications.

<details>
<summary>Build from source (macOS 26 or later, Apple Silicon)</summary>

You need Xcode and Zig 0.16 (`brew install zig@0.16`).

```sh
./deps.sh     # builds GhosttyKit from pinned, patched Ghostty source and fetches zmx
./install.sh  # builds and signs ~/Applications/ClaudeTTY.app
```

install.sh signs with your Apple Development identity if you have one and otherwise offers to make a local one, so macOS remembers the app's permissions between builds. It also restarts the app, everything running as it was.
</details>

## License

[CC BY-NC-SA 4.0](LICENSE)
