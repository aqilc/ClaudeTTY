<div align="center">
  <h1><img src="media/icon.png" width="64" align="absmiddle" alt=""> ClaudeTTY</h1>
  <p>A fast, undying cmux for Claude Code.</p>
  <p><a href="https://github.com/aqilc/ClaudeTTY/releases/latest/download/ClaudeTTY.dmg"><img src="media/download.svg" width="200" alt="Download for Mac"></a><br><sub>macOS 26 or later, Apple Silicon</sub></p>
</div>

<img src="media/hero.png" width="900" alt="ClaudeTTY with five groups in the sidebar and Claude working in two tabs">

Features
--------

<img src="media/survive.gif" width="50%" align="right" alt="The app is killed and reopened with every tab still running">

### Persistent Tabs

Every tab runs in a [zmx](https://github.com/neurosnap/zmx) session outside the app, like tmux without the tmux. Quit it, crash it or update it, and every Claude is still mid-edit when it opens again. Same when Claude Code updates itself. The Claudes you already had open stay up and still get tracked. After a reboot each tab comes back in its group with `claude --resume`.

<br clear="all"><br>

<img src="media/dots.gif" width="50%" align="left" alt="The tab dots for each activity">

### The dots

Each tab's dots move differently depending on what its Claude is doing and turn amber when it's waiting on you, so with 4 Claudes in a group you can tell which one needs you. Tabs also show how much context they've used.

<br clear="all"><br>

<img src="media/panes.png" width="50%" align="right" alt="A group split into panes, each with its own tab bar">

### Groups and panes

I keep each project in a group and its Claudes as tabs. Groups can be colored, pinned and put in folders. Splits and shortcuts are the ones you know from iTerm, and <kbd>⌘</kbd>-click opens links and file paths even while Claude Code has the mouse.

<br clear="all"><br>

<img src="media/mod.gif" width="50%" align="left" alt="Editing the source, running install.sh, and the open app switching to the new build">

### Modding it

The whole app is about 5,500 lines of Swift in three files, so it's pretty easy to mod. Change something (or ask Claude to), run `./install.sh` and the open window switches to the new build like magic, tabs and all.

<br clear="all"><br>

<img src="media/sidebar.gif" width="50%" align="right" alt="Dragging the sidebar edge shut, open again and shut again in one drag">

### Dragging the sidebar shut

Satisfying. <kbd>⌘</kbd><kbd>B</kbd> for less satisfaction but some more practicality.

<br clear="all"><br>

Smaller Things I Like
---------------------

- Click "3 agents" under a group and pick one, and that subagent's transcript opens in a pane right next to its Claude, live. Pretty fun to watch them work.
- Drop a screenshot on a Claude tab and it attaches as `[Image #1]`, same as Claude Code's own paste, and other files go in as @ mentions. <kbd>⌘</kbd><kbd>V</kbd> on a copied image works too.
- The menu bar icon shows you how many tabs want your input, so I close the window but can come back when I remember instead of being constantly bothered.
- Idle groups show the last thing their Claude said and how long ago, which is usually enough for me to remember what I was even doing there.
- The dots wait a quarter second before switching, so a Claude flying through a bunch of quick file reads doesn't turn into a strobe light.
- <kbd>⌘</kbd><kbd>P</kbd> <kbd>↩</kbd> takes you back to the tab you were just in, basically <kbd>⌘</kbd><kbd>Tab</kbd> for tabs.
- <kbd>⌘</kbd><kbd>⇧</kbd><kbd>T</kbd> reopens the tab you just closed, like in a browser, and if it had a Claude in it you get that same Claude back. Pretty handy when you close the wrong one.
- Right-click a tab to schedule a message, like a prompt for when your limits reset.
- If you answer a permission prompt from somewhere else, the notification goes away on its own instead of sitting there forever.
- The close dialog lists what's still running in the tab and for how long.

Compared to cmux and Others
---------------------------

| | ClaudeTTY | cmux | Superset | Warp | Wave | Ghostty |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Tabs keep running after a quit or crash | ✅ | only through tmux | ✅ | ❌ | SSH only, opt-in | ❌ |
| Shows what each Claude is doing | ✅ | a needs-attention ring | working and done | with its plugin | ❌ | ❌ |
| Claude can run other tabs | ✅ | CLI and socket | CLI, MCP and SDK | ❌ | `wsh` CLI | ❌ |
| Memory with one idle tab | 68 MB | 1,029 MB (15×) | 359 MB | 895 MB | 556 MB | 84 MB |
| Idle CPU | 0.03% | 3.1% (103×) | 1.9% | 3.2% | 1.9% | 0.7% |
| Launch to first window | 307 ms | 701 ms | 889 ms | 829 ms | 1,226 ms | 302 ms |
| App size | 20 MB | 454 MB | 1.5 GB | 872 MB | 531 MB | 62 MB |

<sub>All on my M4 Pro (48 GB) with macOS 27.0 and one window with one tab. Launch is the median of 5, memory is Activity Monitor's footprint 20 s after launch (ClaudeTTY's includes the zmx process holding the tab) and CPU is over the 30 s after that. cmux 0.65.2, Superset 1.39.0, Warp 0.2026.10.14 and Wave 0.14.5 on fresh profiles, Ghostty 1.3.1. Without tmux, cmux reopens your layout and restarts Claude into its last conversation, but whatever was running is gone (<a href="https://github.com/manaflow-ai/cmux">cmux README</a>).</sub>

Letting Claude Run Your Tabs
----------------------------

ClaudeTTY installs a Claude Code plugin and a `ct` command, so the Claude in one tab can open, watch and steer the others:

```sh
ct list                          # every tab, its group, folder and Claude state
ct web dev bun run dev           # open tab "dev" in group "web", running a command
ct split dev right agent claude  # a new pane beside it with Claude in it
ct wait agent idle               # block until that Claude is done
zmx send agent "run the tests"   # type into it
```

Don't even look at this, this is meant so your Claude has fine grained orchestration abilities and can accept prompts and other things for you without you ever having to step in. My terminal teaches it to Claude automatically, in as few tokens as possible (~75 to be exact).

Install
-------

[Download ClaudeTTY.dmg](https://github.com/aqilc/ClaudeTTY/releases/latest/download/ClaudeTTY.dmg), open it and drag ClaudeTTY to Applications.

<details>
<summary>Build from source</summary>

You need Xcode and Zig 0.16 (`brew install zig@0.16`).

```sh
./deps.sh     # builds GhosttyKit from pinned, patched Ghostty source and fetches zmx
./install.sh  # builds and signs ~/Applications/ClaudeTTY.app
```

install.sh signs with your Apple Development identity if you have one and otherwise offers to make a local one, so macOS remembers the app's permissions between builds. It also restarts the app, everything running as it was.
</details>

Limitations
-----------

I think it's pretty much done, so apart from bugs and small niceties I won't be adding much. If you need something else there's probably a terminal tool for it, like [terminal-browser](https://terminal-browser.com/) for the web or [ttt](https://github.com/eugenioenko/ttt) (I used vim anw). And since ClaudeTTY is fast they run better here than in a lot of dedicated GUI apps, even cmux. Ask your agent to add the functionality you need for those tools.

Pull requests are off for the same reason. If you want it to do something else, fork it and change it. Bug reports and cool feature requests that land with my philosophy in Issues are welcome.

License
-------

[CC BY-NC-SA 4.0](LICENSE)

FAQ
---

### Why make another terminal?

> I used cmux for a while and loved the layout, but it was buggy for me. It crashed a lot, updates killed everything I had running (which hurts when Claude's in the middle of an edit), it leaked memory and it'd pile up a bajillion unread notifications that didn't even work properly. It also only really tracks one Claude per workspace.
>
> So I kept the parts I liked, groups in the sidebar and tabs in the titlebar with the same shortcuts, and left out the browser, file viewer and port lists since I barely opened them. I let Claude write the code and only step in for an edit now and then, so I don't need a file tree or an editor either. Edits I would make also feel worthless since they're just normal code anyways, so it's going to get replaced eventually.
