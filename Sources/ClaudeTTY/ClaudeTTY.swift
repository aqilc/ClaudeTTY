// Runtime callbacks follow Ghostty's macOS app (Ghostty.App.swift), MIT, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
import AppKit
import Carbon
import CryptoKit
import GhosttyKit
import Network
import ServiceManagement
import Charts
import SwiftUI
import UserNotifications

let deps = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/claudetty-deps").path
let contents = URL(fileURLWithPath: Bundle.main.executablePath!).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path
let bundled = FileManager.default.fileExists(atPath: contents + "/Helpers/zmx")
let zmx = bundled ? contents + "/Helpers/zmx" : deps + "/zmx-1.0/zig-out/bin/zmx"
let zmxDir = ProcessInfo.processInfo.environment["ZMX_DIR"] ?? NSTemporaryDirectory() + "zmx-\(getuid())"
let probe = ProcessInfo.processInfo.environment["CLAUDETTY_PROBE"]
let statusDir = probe.map { $0 + "/status" } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/claudetty/status").path
let projectsDir = probe.map { $0 + "/projects" } ?? NSHomeDirectory() + "/.claude/projects"
let storeDir = (probe.map { ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"].map { $0 + "/.claude/plugins" } ?? $0 } ?? NSHomeDirectory() + "/.claude/plugins") + "/store"
let colors: [(name: String, color: NSColor)] = [("red", .systemRed), ("orange", .systemOrange), ("yellow", .systemYellow), ("green", .systemGreen), ("teal", .systemTeal), ("blue", .systemBlue), ("purple", .systemPurple), ("gray", .systemGray)]

struct Pull: Equatable { let number: Int, open: Bool, glyph: String?, url: String, added: Int, removed: Int }

struct Tab: Equatable, Codable {
    private enum CodingKeys: CodingKey { case name, group, cwd, labels }

    let name: String
    var group: String
    let cwd: String
    var labels: [String: String] = [:]
    var pid: Int32?
    var ended: Int32?
    var old = false

    static func == (lhs: Tab, rhs: Tab) -> Bool { lhs.name == rhs.name }

    var topic: String?
    var title: String { labels["title"] ?? topic ?? name }
    var from: String { labels["host"].map { $0 + " › " } ?? "" }
    var onHost: String { labels["host"].map { String(name.dropFirst($0.count + 1)) } ?? name }

    var folder: String { pid.flatMap(directory) ?? cwd }
    var frontFolder: String { pid.flatMap(foreground).flatMap(directory) ?? folder }

    var claude: String? {
        if labels["host"] != nil { return labels["state"].flatMap { $0 == "shell" ? nil : $0 } }
        guard let pid, isClaude(pid) || isAgy(pid) else { return labels["sleep"] != nil || status == "asleep" ? "asleep" : nil }
        let state = status ?? "", ended = (state == "working" || state == "waiting") && interrupted ? "idle" : state
        return ended == "idle" && listed.contains { $0[0] == "shell" } ? "background" : ended
    }

    private var status: String? { try? String(contentsOfFile: statusDir + "/" + name, encoding: .utf8) }

    private var interrupted: Bool {
        guard let message = transcript.map(lastMessages)?.first, message["type"] as? String == "user", let content = (message["message"] as? [String: Any])?["content"] else { return false }
        return ((content as? String) ?? (content as? [[String: Any]])?.first?["text"] as? String)?.hasPrefix("[Request interrupted by user") == true
    }

    var tasks: [[String]] { claude == nil ? [] : listed }

    var listed: [[String]] {
        guard let text = try? String(contentsOfFile: statusDir + "/" + name + ".agents", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 3).map(String.init) }.filter { $0.count == 4 }
    }

    var action: (text: String, tool: String?, ask: String?, worker: String?, at: Date)? {
        let path = statusDir + "/" + name + ".action"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let at = modified(path) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), first = lines[0].split(separator: "\t", maxSplits: 1).map(String.init)
        let ask = lines.count > 1 ? lines[1].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init) : []
        return (first.first == "Thinking" && writing(since: at) ? "Writing" : first.first ?? "", first.count > 1 ? first[1] : nil, ask.first, ask.count > 1 ? ask[1] : nil, at)
    }

    var mark: String? {
        if labels["host"] != nil { return labels["mark"].flatMap { $0.isEmpty ? nil : $0 } }
        switch claude {
        case "waiting": return "blocked"
        case "background": return "background"
        case "working":
            guard let action else { return "default" }
            switch action.tool {
            case "Edit", "Write", "MultiEdit", "NotebookEdit": return "write"
            case "Read": return "read"
            case "Grep", "Glob", "WebSearch", "WebFetch": return "search"
            case "Bash": return "code"
            case nil: return action.text == "Thinking" ? "think" : action.text == "Writing" ? "compose" : "default"
            default: return "default"
            }
        default: return nil
        }
    }

    private func writing(since thinking: Date) -> Bool {
        for message in transcript.map(lastMessages) ?? [] { return message["type"] as? String == "assistant" && ((message["timestamp"] as? String).flatMap(stamps.date) ?? .distantPast) > thinking }
        return false
    }

    var context: Int? {
        guard claude != nil, let usage = transcript.map(lastMessages)?.lazy.compactMap({ ($0["message"] as? [String: Any])?["usage"] as? [String: Any] }).first else { return nil }
        return ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
    }

    var reply: [String: Any]? { transcript.map(lastMessages)?.first { (($0["message"] as? [String: Any])?["model"] as? String)?.hasPrefix("claude") == true } }
    var transcript: String? { try? String(contentsOfFile: statusDir + "/" + name + ".transcript", encoding: .utf8) }
    var session: String? { transcript.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } }
}

let stamps = { let format = ISO8601DateFormatter(); format.formatOptions.insert(.withFractionalSeconds); return format }()

func lastMessages(_ path: String) -> [[String: Any]] {
    var info = stat()
    guard stat(path, &info) == 0 else { return [] }
    let end = UInt64(info.st_size), stamp = info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec
    if let cached = parsed[path], cached.stamp == stamp, cached.size == end { return cached.messages }
    guard let file = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? file.close() }
    var window: UInt64 = 65_536, messages: [[String: Any]] = []
    while true {
        let start = end > window ? end - window : 0
        try? file.seek(toOffset: start)
        let lines = (try? file.readToEnd())?.split(separator: UInt8(ascii: "\n")) ?? []
        messages = lines.dropFirst(start > 0 ? 1 : 0).reversed().compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]).flatMap { ["assistant", "user"].contains($0["type"] as? String) ? $0 : nil }
        }
        if start == 0 || messages.contains(where: { $0["type"] as? String == "assistant" }) { break }
        window *= 4
    }
    parsed[path] = (stamp, end, messages)
    return messages
}
private var parsed: [String: (stamp: Int, size: UInt64, messages: [[String: Any]])] = [:]

func json(_ path: String) -> [String: Any]? { (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
private var reads: [String: (at: Double, value: Any?)] = [:]
func reread<T>(_ path: String, _ parse: (String) -> T?) -> T? {
    let at = modified(path)?.timeIntervalSince1970 ?? -1
    if let read = reads[path], read.at == at { return read.value as? T }
    let value = at < 0 ? nil : parse(path)
    reads[path] = (at, value)
    return value
}

func modified(_ path: String) -> Date? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
}

indirect enum Layout: Equatable {
    case pane(String)
    case split(across: Bool, [Layout])

    init?(_ text: String) {
        var rest = Substring(text)
        guard let layout = Self.parse(&rest), rest.isEmpty else { return nil }
        self = layout
    }

    private static func parse(_ rest: inout Substring) -> Layout? {
        guard let kind = rest.first, kind == "h" || kind == "v", rest.dropFirst().first == "-" else {
            let id = rest.prefix { $0.isNumber }
            rest = rest.dropFirst(id.count)
            return id.isEmpty ? nil : .pane(String(id))
        }
        rest = rest.dropFirst(2)
        var parts: [Layout] = []
        while let part = parse(&rest) {
            parts.append(part)
            guard rest.first == "." else { break }
            rest = rest.dropFirst()
        }
        guard rest.first == "_", parts.count > 1 else { return nil }
        rest = rest.dropFirst()
        return .split(across: kind == "h", parts)
    }

    var text: String {
        switch self {
        case .pane(let id): id
        case .split(let across, let parts): (across ? "h-" : "v-") + parts.map(\.text).joined(separator: ".") + "_"
        }
    }

    var panes: [String] {
        switch self {
        case .pane(let id): [id]
        case .split(_, let parts): parts.flatMap(\.panes)
        }
    }

    func splitting(_ pane: String, with new: String, across: Bool, before: Bool) -> Layout {
        switch self {
        case .pane(let id):
            guard id == pane else { return self }
            return .split(across: across, before ? [.pane(new), self] : [self, .pane(new)])
        case .split(let way, var parts):
            if way == across, let index = parts.firstIndex(of: .pane(pane)) {
                parts.insert(.pane(new), at: before ? index : index + 1)
                return .split(across: way, parts)
            }
            return .split(across: way, parts.map { $0.splitting(pane, with: new, across: across, before: before) })
        }
    }

    func removing(_ pane: String) -> Layout? {
        switch self {
        case .pane(let id):
            return id == pane ? nil : self
        case .split(let way, let parts):
            let rest = parts.compactMap { $0.removing(pane) }
            return rest.count > 1 ? .split(across: way, rest) : rest.first
        }
    }
}

func foreground(_ pid: Int32) -> Int32? {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
    return Int32(info.e_tpgid)
}

func directory(_ pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
}

func isClaude(_ pid: Int32) -> Bool {
    guard let front = foreground(pid) else { return false }
    let path = binary(front)
    return path.contains("/claude/versions/") || path.hasSuffix("/ClaudeCode.app/Contents/MacOS/claude") || path.isEmpty && started(front)?.strings.first?.hasSuffix("/claude") == true
}

func isAgy(_ pid: Int32) -> Bool { foreground(pid).map(binary)?.contains("/antigravity-cli/") == true }

func binary(_ pid: Int32) -> String {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    proc_pidpath(pid, &path, UInt32(path.count))
    return String(cString: path)
}

func inode(_ path: String) -> ino_t? {
    var info = stat()
    return stat(path, &info) == 0 ? info.st_ino : nil
}

func started(_ pid: Int32) -> (count: Int, strings: [String])? {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
    return (buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }, buffer[4..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
}

@main
final class ClaudeTTY: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    static let shared = ClaudeTTY()
    private var app: ghostty_app_t?
    private var window: NSWindow!
    private var tabs: [Tab] = []
    private var selected: Tab?
    private var lastTab: [String: Tab] = [:]
    private var recent: [String] = []
    private static let soundKey = "notification sound " + zmxDir
    private static let secureKey = "secure keyboard entry " + zmxDir
    private static let linksKey = "ct links " + zmxDir
    private static let renameKey = "rename session " + zmxDir
    static let followKey = "focus follows mouse " + zmxDir
    private var securing = false
    private static let hotkeyKey = "show and hide hotkey " + zmxDir
    private static let hotkeys = [("⌥Space", kVK_Space, optionKey), ("⌃`", kVK_ANSI_Grave, controlKey)]
    private static let recordedKey = hotkeyKey + " recorded"
    private static var keys: [(String, Int, Int)] {
        let saved = UserDefaults.standard.stringArray(forKey: recordedKey) ?? []
        guard saved.count == 3, let code = Int(saved[1]), let mods = Int(saved[2]), !hotkeys.contains(where: { $0.0 == saved[0] }) else { return hotkeys }
        return hotkeys + [(saved[0], code, mods)]
    }
    private var hotkey: EventHotKeyRef?
    private static let sortKey = "sort by state " + zmxDir
    private static let folderIndent: CGFloat = 10
    private static let collapsedKey = "collapsed folders " + zmxDir
    private static let buttonsKey = "hide pane buttons " + zmxDir
    private static let askKey = "claude asks permission " + zmxDir
    private static let codeKey = "claude code mode " + zmxDir
    private static let classicKey = "classic renderer " + zmxDir
    private static let wakeKey = "no idle sleep " + zmxDir
    private static let warmKey = "keep asleep tabs warm " + zmxDir
    private static let contextKey = "hide context size " + zmxDir
    private static let freeSizeKey = "free size " + zmxDir
    private static let scheduledKey = "scheduled " + zmxDir
    private static let themeKey = "theme " + zmxDir
    private var guide: Guide?
    private var themeWatch: NSKeyValueObservation?
    static var light: Bool { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua }
    private static let lookKey = "look " + zmxDir
    private static let lookDefaults = ["cursor-style": "block", "cursor-style-blink": "", "background-opacity": "0.8", "background-blur": "15", "window-padding-x": "8", "window-padding-y": "4,8"]
    private static var look: [String: String] {
        var look = lookDefaults
        for (key, value) in UserDefaults.standard.dictionary(forKey: lookKey) as? [String: String] ?? [:] where look[key] != nil { look[key] = value }
        look["background-blur"] = ["10": "4", "30": "15"][look["background-blur"]!] ?? look["background-blur"]
        if look["window-padding-x"] == "1" { look["window-padding-x"] = "0" }
        for (key, steps) in ["background-opacity": transparencies, "background-blur": blurs] where !steps.contains(where: { $0.value == look[key] }) { look[key] = lookDefaults[key] }
        return look
    }
    private static let transparencies = [("Off", "1"), ("Low", "0.9"), ("Medium", "0.8"), ("High", "0.65")].map { (title: $0, value: $1) }
    private static let blurs = [("Off", "0"), ("Low", "4"), ("Medium", "15"), ("High", "60")].map { (title: $0, value: $1) }
    static var padding: CGSize {
        CGSize(width: Double(look["window-padding-x"]!) ?? 8, height: look["window-padding-y"]!.split(separator: ",").compactMap { Double($0) }.reduce(0, +))
    }
    private var folderBadges: [String: Ping] = [:]
    private var meters: [String: NSTextField] = [:]
    private var shown: Set<String> = []
    private var panes: [String: (bar: PaneBar?, body: Body)] = [:]
    private var folderIcon: (folder: String, image: NSImage)?
    private var arranged = ""
    private var held: [String: CALayer]?
    private var veil: CALayer?
    private static let motionKey = "pane motion " + zmxDir
    private var placed: Set<String> = []
    private let titleButtons = NSStackView()
    private let titleHover = BarHover()
    private var surfaces: [String: SurfaceView] = [:]
    private var chats: [String: Chat] = [:]
    private var parked: [String: Chat] = [:]
    private var switches: [String: NSSegmentedControl] = [:]
    private var sidePanel = ClaudeTTY.saved?.sidePanel ?? true
    private var drafts = ClaudeTTY.saved?.drafts ?? [:]
    private var unsent = ClaudeTTY.saved?.unsent ?? [:] {
        didSet {
            let changed = Set(unsent.keys).union(oldValue.keys).filter { unsent[$0] != oldValue[$0] }
            guard !changed.isEmpty else { return }
            changed.forEach { chats[$0]?.refresh() }
            armOutbox()
            save()
        }
    }
    private var outbox: Timer?
    private var commands: [String: [String]] = [:]
    private var scrolls = ClaudeTTY.saved?.scrolled ?? [:]
    private var closedTabs: [(tab: Tab, index: Int, command: [String]?, history: Data?)] = []
    private let sidebar = NSStackView()
    private let tabBar = TabStrip()
    private let terminal = NSView()
    private let scratch = Scratch()
    private let backing = NSView()
    private let header = NSView()
    private var side: NSView!
    private var sidebarShown = true
    private var zoomed: [String: String] = [:]
    private var editing: Row?
    private var toggles = 0
    private var sideSlide: NSLayoutConstraint!
    private var sideWidth: NSLayoutConstraint!
    private var sidebarWidth = ClaudeTTY.saved?.sidebarWidth ?? 180
    private let edge = SidebarEdge()
    private var watches: [DispatchSourceFileSystemObject] = []
    private var probeDrag = NSPoint.zero
    private var claudeExits: [Int32: DispatchSourceProcess] = [:]
    private var activities: [String: ActivityView] = [:]
    private var groupRows: [String: Row] = [:]
    private var folderRows: [String: Row] = [:]
    private var pulls: [String: (pull: Pull?, asked: Date)] = [:]
    private var replies: [String: (stamp: Date, reply: (text: String, at: Date)?)] = [:]
    private var verbs: [String: (at: Date, verb: String?)] = [:]
    private var tails: [String: Process] = [:]
    private var transcripts: [String: (path: String, watch: DispatchSourceFileSystemObject)] = [:]
    private var fronts: [String] = []
    private var spinner: Timer?
    private var tabSparks: [String: Spark] = [:]
    private var progresses: [String: (report: ghostty_action_progress_report_s, at: Date)] = [:]
    private var tabRings: [String: ProgressRing] = [:]
    private var turn = 0
    private var rebuilds = 0
    private var oldApp: DispatchSourceProcess?
    private var predecessor = ClaudeTTY.saved?.handover.flatMap { kill($0.pid, 0) == 0 ? $0 : nil }
    private var hidden = false
    private let groupsMenu = NSMenu(title: "Groups")
    private var iconDrawn: String?
    private var statusItem: NSStatusItem?
    private var hintTimer: Timer?
    private var pills: [KeyPill] = []
    private var paneRows: [Row] = []
    private var tabRows: [String: Row] = [:]
    private var hintModifier = "⌘"
    private static let port = "dev.claudetty.app" + (probe.map { "." + $0 } ?? "") as CFString
    private static var server: CFMessagePort?
    private static let keeperPort = "dev.claudetty.keeper" + (probe.map { "." + $0 } ?? "") as CFString
    private static let kept: Set = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "ZMX_DIR", "CLAUDETTY_PROBE", "CLAUDETTY_RELEASES", "XDG_CONFIG_HOME", "CFFIXED_USER_HOME"]
    static let executable = URL(fileURLWithPath: Bundle.main.executablePath!).resolvingSymlinksInPath().path
    private static let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    private static let released = bundle.hasSuffix(".app") && Bundle(path: bundle)?.object(forInfoDictionaryKey: "ClaudeTTYSource") == nil
    private static let held = released
    private static let releases = ProcessInfo.processInfo.environment["CLAUDETTY_RELEASES"] ?? "https://api.github.com/repos/aqilc/ClaudeTTY/releases/latest"
    private static var build: Int? { (try? FileManager.default.attributesOfItem(atPath: executable))?[.systemFileNumber] as? Int }
    private var running = ClaudeTTY.build
    private struct State: Codable {
        struct Handover: Codable { let pid: Int32, window: Int, hidden: Bool }
        var frame: NSRect, display: UInt32
        var sidebar: Bool, scroll: CGFloat
        var selected: String?, shown: [String], lastTab: [String: String], zoomed: [String: String], recent: [String]
        var handover: Handover?
        var fullScreen: Bool?, scrolled: [String: UInt64]?
        var boot: Int?, kept: [Tab]?, resume: [String: String]?, sidebarWidth: CGFloat?
        var asleep: [String: [String]]?
        var flags: [String: String]?
        var given: NSRect?, givenIn: NSRect?
        var sidePanel: Bool?
        var unsent: [String: [Outgoing]]?, drafts: [String: String]?
        var tabs: [Tab] { (kept ?? []).map { var tab = $0; tab.labels["folder"] = tab.labels["folder"]?.uppercased(); return tab } }
    }
    static let stateFile = probe.map { $0 + "/state.json" } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/ClaudeTTY/state.json").path
    private static let saved = (try? Data(contentsOf: URL(fileURLWithPath: stateFile))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    private var saving = false
    private var normalFrame = NSRect.zero
    private var given: (frame: NSRect, room: NSRect)?
    private var fitted: NSRect?
    private var menuMarks: [(item: NSMenuItem, mark: String)] = []
    private var menuTimer: Timer?
    private enum Swap { case running, failed }
    private var newer: (version: String, page: URL, swap: Swap)?
    private var updateWait: Timer?
    private struct Notice: Equatable { let text: String, at: Date; var bannered: Bool }
    private var notices: [String: Notice] = [:]
    private var dismissed: [String: Date] = [:]
    private var lastBanner = Date.distantPast
    private var retryBanner: Timer?
    private var probeWasActive = false
    private var look: (tab: String, since: Date, timer: Timer)?

    static func main() {
        if let password = ProcessInfo.processInfo.environment["CLAUDETTY_ASKPASS"] { print(password); exit(0) }
        let ready = ProcessInfo.processInfo.environment["CLAUDETTY_READY"].flatMap(Int32.init)
        if ready == nil {
            switch CommandLine.arguments.dropFirst().first {
            case "--app":
                for key in ProcessInfo.processInfo.environment.keys where !kept.contains(key) { unsetenv(key) }
                setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
            case "notify": exit(notice())
            case "list", "events", "wait": exit(states())
            case "prompt":
                guard CommandLine.arguments.count == 3, let draft = prompt(CommandLine.arguments[2]) else { exit(failed("prompt <tab>: no Claude prompt box on its screen")) }
                if !draft.isEmpty { print(draft) }
                exit(0)
            case "--attach": attach()
            case "--serve": exit(serve())
            case "--keeper": exit(keeper())
            case "--share-flag": print(Share.flag()); exit(0)
            case "--share": exit(Share.supervise())
            case "--share-serve": Bridge().run()
            case "reload": exit(reload())
            case "help", "-h", "--help":
                print("""
                ct <group> [<tab> [command…]]               open a tab, or move a live one to <group>
                ct split <tab> right|down|left|up <name> [command…]
                ct list [--json] | events | wait <tab> <state> | focus <tab> | prompt <tab> | restart <tab> | notify <text> | reload
                """)
                exit(0)
            case let flag? where flag.hasPrefix("-"): exit(failed("doesn't know \(flag). ct help lists its commands"))
            default: exit(request())
            }
        }
        guard probe != nil || executable.hasSuffix(".app/Contents/MacOS/ClaudeTTY") else { exit(failed("runs as the app only from a bundle, or as a probe (CLAUDETTY_PROBE=<dir>)")) }
        let listening = listen()
        if let ready { close(ready) }
        unsetenv("CLAUDETTY_READY")
        guard listening else { exit(0) }
        setenv("GHOSTTY_RESOURCES_DIR", bundled ? contents + "/Resources/ghostty" : deps + "/ghostty-1.4/zig-out/share/ghostty", 0)
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else { fatalError("ghostty_init failed") }
        let app = NSApplication.shared
        app.delegate = shared
        app.setActivationPolicy(probe == nil ? .regular : .accessory)
        app.run()
    }

    private static func listen() -> Bool {
        server = CFMessagePortCreateLocal(nil, port, { _, _, data, _ in
            let problem = (data as Data?).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.flatMap { ClaudeTTY.shared.open($0) }
            return problem.map { Unmanaged.passRetained(Data($0.utf8) as CFData) }
        }, nil, nil)
        return server != nil
    }

    private static func request() -> Int32 {
        var args = Array(CommandLine.arguments.dropFirst()), focus = tcgetpgrp(0) == getpgrp()
        if args.first == "focus" {
            guard args.count == 2, let tab = sessions().first(where: { $0.name == args[1] }) else { return failed("focus <tab>: no such tab") }
            (args, focus) = ([tab.group, tab.name], true)
        }
        if args.first == "split", args.count < 4 || !["right", "down", "left", "up"].contains(args[2]) { return failed("split <tab> right|down|left|up <name> [command…]") }
        if args.first == "restart", args.count != 2 { return failed("restart <tab>") }
        let running = CFMessagePortCreateRemote(nil, port) != nil
        if executable.hasSuffix(".app/Contents/MacOS/ClaudeTTY"), !running || focus {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = focus && probe == nil
            configuration.createsNewApplicationInstance = !running
            configuration.arguments = ["--app"]
            configuration.environment = ProcessInfo.processInfo.environment.filter { kept.contains($0.key) }
            let opened = DispatchSemaphore(value: 0)
            var app: NSRunningApplication?
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), configuration: configuration) { launched, _ in
                app = launched
                opened.signal()
            }
            opened.wait()
            guard let app else { return failed("didn't start") }
            let deadline = Date() + 30
            while !running, !app.isTerminated, CFMessagePortCreateRemote(nil, port) == nil, Date() < deadline { usleep(50_000) }
        } else if !running {
            var ends: [Int32] = [0, 0]
            pipe(&ends)
            spawn(keeping: ends[1])
            close(ends[1])
            var byte: UInt8 = 0
            _ = read(ends[0], &byte, 1)
        }
        guard CFMessagePortCreateRemote(nil, port) != nil else { return failed("didn't start") }
        if let problem = send(["args": args, "cwd": FileManager.default.currentDirectoryPath, "path": ProcessInfo.processInfo.environment["PATH"] ?? "", "focus": focus, "from": ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? ""]) { return failed(problem) }
        let name = args.first == "split" ? args[3] : args.count > 1 ? args[1] : args.first
        let deadline = Date() + 10
        while let name, !FileManager.default.fileExists(atPath: zmxDir + "/" + name), Date() < deadline { usleep(50_000) }
        return 0
    }

    @discardableResult static func spawn(_ args: [String] = [], environment given: [String]? = nil, keeping ready: Int32? = nil) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd in Int32(0)...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) }
        if let ready { posix_spawn_file_actions_addinherit_np(&actions, ready) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        if !args.isEmpty {
        } else if disclaims(executable, probe: probe) {
            if let disclaim = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
                _ = unsafeBitCast(disclaim, to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32).self)(&attributes, 1)
            } else {
                fputs("ClaudeTTY can't disclaim: tabs ask for permissions as the app that ran ct\n", stderr)
            }
        } else if probe != nil {
            fputs("ClaudeTTY probe: no responsibility disclaim\n", stderr)
        }
        let environment = given ?? ProcessInfo.processInfo.environment.filter { kept.contains($0.key) }.map { "\($0)=\($1)" } + ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"] + (ready.map { ["CLAUDETTY_READY=\($0)"] } ?? [])
        let argv = ([executable] + args).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        var pid: pid_t = 0
        posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        return pid
    }

    static func disclaims(_ executable: String, probe: String?) -> Bool { probe == nil && executable.hasSuffix(".app/Contents/MacOS/ClaudeTTY") }

    private static func settle() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path, bin = home + "/.local/bin"
        try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for (name, target) in [("ct", executable), ("zmx", zmx), ("claudetty-serve", executable)] where !FileManager.default.fileExists(atPath: bin + "/" + name) {
            try? FileManager.default.removeItem(atPath: bin + "/" + name)
            try? FileManager.default.createSymbolicLink(atPath: bin + "/" + name, withDestinationPath: target)
        }
        let marketplace = contents + "/Resources/plugin"
        guard let version = json(marketplace + "/claudetty/.claude-plugin/plugin.json")?["version"] as? String else { return }
        let installed = json(home + "/.claude/plugins/installed_plugins.json")?["plugins"] as? [String: [[String: Any]]] ?? [:]
        guard !installed.keys.contains(where: { $0.hasPrefix("claudetty@") && $0 != "claudetty@claudetty" }) else { return }
        let ours = installed["claudetty@claudetty"]
        guard ours?.contains(where: { $0["version"] as? String == version }) != true else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "claude plugin marketplace add \"$0\" && claude plugin $1 claudetty@claudetty", marketplace, ours == nil ? "install" : "update"]
        process.environment = ["HOME": home, "PATH": bin + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func agyStatusLine() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard probe == nil || home != String(cString: getpwuid(getuid()).pointee.pw_dir) else { return }
        let path = home + "/.gemini/antigravity-cli/settings.json", temp = path + ".claudetty"
        let script = contents + "/Resources/plugin/claudetty/hooks/agy.sh"
        guard FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent), FileManager.default.fileExists(atPath: script) else { return }
        let text = FileManager.default.fileExists(atPath: path) ? try? String(contentsOfFile: path, encoding: .utf8) : "{}"
        guard let text, let settings = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], settings["statusLine"] == nil, let open = text.firstIndex(of: "{") else { return }
        let command = "sh '\(script.replacingOccurrences(of: "'", with: "'\\''"))' 2>/dev/null || :"
        let line = try! JSONSerialization.data(withJSONObject: ["type": "command", "command": command, "stack_with_default": true] as [String: Any], options: [.sortedKeys, .withoutEscapingSlashes])
        let added = text.replacingCharacters(in: open...open, with: "{\n  \"statusLine\": " + String(decoding: line, as: UTF8.self) + (settings.isEmpty ? "" : ","))
        let mode = (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] ?? 0o644
        guard FileManager.default.createFile(atPath: temp, contents: Data(added.utf8), attributes: [.posixPermissions: mode]), let written = json(temp), Set(written.keys) == Set(settings.keys + ["statusLine"]), Darwin.rename(temp, path) == 0 else {
            try? FileManager.default.removeItem(atPath: temp)
            return
        }
    }

    private static func attach() -> Never {
        let args = ["attach"] + CommandLine.arguments.dropFirst(2)
        tabEnv()
        if args.count == 4 { shellMarks() }
        if args.count > 3, disclaims(executable, probe: probe), !FileManager.default.fileExists(atPath: zmxDir + "/" + args[3]), let keeper = CFMessagePortCreateRemote(nil, keeperPort) {
            var size = winsize()
            _ = ioctl(0, TIOCGWINSZ, &size)
            let request = try! JSONSerialization.data(withJSONObject: ["args": args, "env": ProcessInfo.processInfo.environment.map { "\($0)=\($1)" }, "cwd": FileManager.default.currentDirectoryPath, "rows": size.ws_row, "cols": size.ws_col])
            var reply: Unmanaged<CFData>?
            _ = CFMessagePortSendRequest(keeper, 0, request as CFData, 5, 10, CFRunLoopMode.defaultMode.rawValue, &reply)
        }
        execv(zmx, ([zmx] + args).map { strdup($0) } + [nil])
        exit(127)
    }

    private static func shellMarks() {
        let env = ProcessInfo.processInfo.environment
        guard let resources = env["GHOSTTY_RESOURCES_DIR"].map({ $0 + "/shell-integration" }) else { return }
        setenv("GHOSTTY_SHELL_FEATURES", (env["GHOSTTY_SHELL_FEATURES"] ?? "").split(separator: ",").filter { !$0.hasPrefix("cursor") }.joined(separator: ","), 1)
        switch ((env["SHELL"] ?? "") as NSString).lastPathComponent {
        case "zsh":
            if let own = env["ZDOTDIR"] { setenv("GHOSTTY_ZSH_ZDOTDIR", own, 1) }
            setenv("ZDOTDIR", resources + "/zsh", 1)
        case "fish":
            setenv("XDG_DATA_DIRS", resources + ":" + (env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"), 1)
            setenv("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", resources, 1)
        default: break
        }
    }

    private static func keeper() -> Int32 {
        let local = CFMessagePortCreateLocal(nil, keeperPort, { _, _, data, _ in
            guard let request = (data as Data?).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return nil }
            if let pid = request["watch"] as? Int { ClaudeTTY.watch(pid_t(pid)) }
            if let pid = request["unwatch"] as? Int { ClaudeTTY.watched.removeValue(forKey: pid_t(pid))?.cancel() }
            guard let args = request["args"] as? [String], let env = request["env"] as? [String] else { return nil }
            var size = winsize(ws_row: request["rows"] as? UInt16 ?? 24, ws_col: request["cols"] as? UInt16 ?? 80, ws_xpixel: 0, ws_ypixel: 0)
            var master: Int32 = 0, slave: Int32 = 0
            guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            for fd in Int32(0)...2 { posix_spawn_file_actions_adddup2(&actions, slave, fd) }
            posix_spawn_file_actions_addchdir_np(&actions, request["cwd"] as? String ?? NSHomeDirectory())
            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
            var pid: pid_t = 0
            let argv = ([zmx] + args).map { strdup($0) } + [nil], envp = env.map { strdup($0) } + [nil]
            let spawned = posix_spawn(&pid, zmx, &actions, &attributes, argv, envp) == 0
            (argv + envp).forEach { free($0) }
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
            close(slave)
            if spawned {
                var seen = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                var ready = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
                let deadline = Date() + 5
                while seen.range(of: Data(" created".utf8)) == nil, Date() < deadline, poll(&ready, 1, 100) >= 0 {
                    guard ready.revents != 0 else { continue }
                    let count = read(master, &buffer, buffer.count)
                    guard count > 0 else { break }
                    seen.append(contentsOf: buffer[..<count])
                }
                kill(pid, SIGHUP)
                waitpid(pid, nil, 0)
            }
            close(master)
            return nil
        }, nil, nil)
        guard let local else { return failed("keeper: another keeper holds the port") }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMessagePortCreateRunLoopSource(nil, local, 0), .commonModes)
        for app in NSWorkspace.shared.runningApplications where app.executableURL?.resolvingSymlinksInPath().path == executable { watch(app.processIdentifier) }
        CFRunLoopRun()
        return 0
    }

    private static var watched: [pid_t: DispatchSourceProcess] = [:]

    private static func watch(_ pid: pid_t) {
        guard watched[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main), since = Date()
        source.setEventHandler {
            source.cancel()
            guard watched.removeValue(forKey: pid) != nil, Date() > since + 10 else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = ["--app"]
            configuration.environment = ProcessInfo.processInfo.environment.filter { kept.contains($0.key) }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundle), configuration: configuration)
        }
        watched[pid] = source
        source.resume()
    }

    static func tellKeeper(_ key: String) {
        guard let keeper = CFMessagePortCreateRemote(nil, keeperPort) else { return }
        CFMessagePortSendRequest(keeper, 0, try! JSONSerialization.data(withJSONObject: [key: getpid()]) as CFData, 1, 0, nil, nil)
    }

    private static func keep() {
        let keeper = SMAppService.agent(plistName: "dev.claudetty.keeper.plist")
        let fake = probe.map { $0 + "/keeper" }
        let call = { (name: String, real: () throws -> Void) -> Void in
            guard let fake else { try? real(); return }
            try? ((try? String(contentsOfFile: fake, encoding: .utf8)) ?? "").appending(name + "\n").write(toFile: fake, atomically: true, encoding: .utf8)
        }
        call("register") { try keeper.register() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            defer { call("checked") {} }
            tellKeeper("watch")
            let enabled = fake.map { (try? String(contentsOfFile: $0, encoding: .utf8))?.hasPrefix("enabled") == true } ?? (keeper.status == .enabled)
            guard enabled, CFMessagePortCreateRemote(nil, keeperPort) == nil else { return }
            call("unregister") { try keeper.unregister() }
            call("register") { try keeper.register() }
        }
    }

    private static func reload() -> Int32 {
        let source = CommandLine.arguments.dropFirst(2).first ?? Bundle(path: bundle)?.object(forInfoDictionaryKey: "ClaudeTTYSource") as? String
        guard bundle.hasSuffix(".app"), let script = source.flatMap({ [$0, $0 + "/app/apple/ClaudeTTY"].map { $0 + "/install.sh" }.first { access($0, X_OK) == 0 } }) else { return failed("reload <path to a ClaudeTTY checkout>") }
        setenv("APP", bundle, 1)
        execv(script, [strdup(script), nil])
        return failed("reload: couldn't run \(script)")
    }

    private static func notice() -> Int32 {
        let text = CommandLine.arguments.dropFirst(2).joined(separator: " ")
        guard let tab = ProcessInfo.processInfo.environment["ZMX_SESSION"], !text.isEmpty else { return failed("notify <text> runs in a ClaudeTTY tab") }
        try? FileManager.default.createDirectory(atPath: statusDir, withIntermediateDirectories: true)
        return (try? text.write(toFile: statusDir + "/" + tab + ".notice", atomically: true, encoding: .utf8)) == nil ? failed("notify couldn't write") : 0
    }

    private static func watch(_ path: String, _ handler: @escaping () -> Void) -> DispatchSourceFileSystemObject {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: Darwin.open(path, O_EVTONLY), eventMask: .write, queue: .main)
        watch.setEventHandler(handler: handler)
        watch.resume()
        return watch
    }

    private static func serve() -> Int32 {
        let words = (ProcessInfo.processInfo.environment["SSH_ORIGINAL_COMMAND"] ?? "").split(separator: " ", omittingEmptySubsequences: false).map { decoded(String($0)) }
        func fits(_ name: String) -> Bool { !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && name.utf8.count <= 100 && name.rangeOfCharacter(from: .controlCharacters) == nil }
        func live(_ name: String) -> Bool {
            var info = stat()
            return fits(name) && lstat(zmxDir + "/" + name, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
        }
        func started(_ name: String) -> Bool {
            let deadline = Date() + 10
            while !live(name), Date() < deadline { usleep(50_000) }
            return live(name)
        }
        switch (words.first, words.count) {
        case ("list", 2) where words[1] == "--json", ("events", 1): return states(words)
        case ("watch", 1):
            let tick = { print(""); fflush(stdout) }, watches = [statusDir, zmxDir, (stateFile as NSString).deletingLastPathComponent].map { watch($0) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: tick) } }
            tick()
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in tick() }
            withExtendedLifetime(watches) { RunLoop.main.run() }
            return 0
        case ("attach", 2) where fits(words[1]):
            if !live(words[1]), let problem = send(["op": ["wake", words[1]]]) ?? (started(words[1]) ? nil : "didn't wake \(words[1])") { return failed(problem) }
            execv(zmx, [zmx, "attach", words[1]].map { strdup($0) } + [nil])
            return 127
        case ("sleep", 2) where fits(words[1]), ("end", 2) where fits(words[1]), ("new", 3) where fits(words[1]) && fits(words[2]),
             ("label", 4) where fits(words[1]) && pairedLabels.contains(words[2]) && words[3].utf8.count <= 1000:
            if let problem = send(["op": words]) ?? (words[0] != "new" || started(words[2]) ? nil : "didn't start \(words[2])") { return failed(problem) }
            return 0
        case ("unpair", 1) where CommandLine.arguments.count == 3 && CommandLine.arguments[2].hasPrefix("claudetty:"):
            return revoke(String(CommandLine.arguments[2].dropFirst(10))).map(failed) ?? 0
        default: return failed("serves list --json, events, watch, attach <tab>, sleep <tab>, end <tab>, new <tab> <name>, label <tab> <key> <value> and unpair only")
        }
    }

    static let pairedLabels = ["title", "color", "pinned", "order", "rank", "notify", "named", "group"]

    private static func send(_ request: [String: Any]) -> String? {
        guard let app = CFMessagePortCreateRemote(nil, port) else { return "isn't open" }
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(app, 0, try! JSONSerialization.data(withJSONObject: request) as CFData, 5, 30, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess else { return "didn't answer (\(status))" }
        return (reply?.takeRetainedValue() as Data?).flatMap { $0.isEmpty ? nil : String(decoding: $0, as: UTF8.self) }
    }

    private static func states(_ args: [String] = Array(CommandLine.arguments.dropFirst())) -> Int32 {
        func state(_ tab: Tab) -> String { tab.claude.map { $0.isEmpty ? "idle" : $0 } ?? "shell" }
        func tabs() -> [Tab] {
            let live = sessions(), saved = (try? Data(contentsOf: URL(fileURLWithPath: stateFile))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
            return live + (saved?.tabs ?? []).filter { $0.labels["sleep"] != nil && !live.contains($0) }
        }
        if args.first == "list" {
            let keys = ["group", "tab", "title", "state", "folder", "context"]
            let found = tabs(), rows = found.map { tab in Dictionary(uniqueKeysWithValues: zip(keys, [tab.group, tab.name, tab.title, state(tab), tab.folder, tab.context.map(String.init) ?? ""])) }
            let marked = zip(rows, found).map { row, tab in
                let notice = statusDir + "/" + tab.name + ".notice"
                return (row as [String: Any]).merging(["mark": tab.mark ?? "", "labels": tab.labels, "notice": (try? String(contentsOfFile: notice, encoding: .utf8)) ?? "", "noticed": modified(notice).map { String($0.timeIntervalSince1970) } ?? ""]) { $1 }
            }
            if args.last == "--json" { print(String(decoding: try! JSONSerialization.data(withJSONObject: marked, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)) }
            else { for row in rows { print(keys.map { row[$0]! }.joined(separator: "\t")) } }
            return 0
        }
        let wait = args.first == "wait" ? Array(args.dropFirst()) : []
        guard args.first == "events" || wait.count == 2 else { return failed("wait <tab> working|waiting|background|idle|shell") }
        var last: [String: String] = [:]
        func check() {
            var now = tabs().map { ($0.name, state($0)) }
            for name in last.keys where !now.contains(where: { $0.0 == name }) {
                let status = statusDir + "/" + name
                if (try? String(contentsOfFile: status, encoding: .utf8)) == "asleep", modified(status) ?? .distantPast > modified(stateFile) ?? .distantPast { now.append((name, "asleep")) }
            }
            if let tab = wait.first {
                guard let held = now.first(where: { $0.0 == tab }) else { exit(failed("wait: no tab \(tab)")) }
                if held.1 == wait[1] { exit(0) }
                return
            }
            for (name, state) in now where last[name] != state { print(name + "\t" + state) }
            for name in last.keys where !now.contains(where: { $0.0 == name }) { print(name + "\tclosed") }
            fflush(stdout)
            last = Dictionary(now, uniquingKeysWith: { first, _ in first })
        }
        check()
        let watches = [statusDir, zmxDir, (stateFile as NSString).deletingLastPathComponent].map { watch($0) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check) } }
        withExtendedLifetime(watches) { dispatchMain() }
    }

    static func terminalTheme(_ face: NSFont?) -> Chat.Theme {
        guard let config = config() else { return Chat.Theme(ink: light ? .black : .white, palette: [], font: .monospacedSystemFont(ofSize: 13, weight: .regular)) }
        defer { ghostty_config_free(config) }
        func color(_ c: ghostty_config_color_s) -> NSColor { NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1) }
        var ink = ghostty_config_color_s(), palette = ghostty_config_palette_s(), size: Float = 13
        _ = ghostty_config_get(config, &ink, "foreground", 10)
        _ = ghostty_config_get(config, &palette, "palette", 7)
        _ = ghostty_config_get(config, &size, "font-size", 9)
        let colors = withUnsafeBytes(of: palette.colors) { Array($0.bindMemory(to: ghostty_config_color_s.self).prefix(16)) }
        let font = face.flatMap { NSFont(descriptor: $0.fontDescriptor, size: CGFloat(size)) } ?? .monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
        return Chat.Theme(ink: color(ink), palette: colors.map(color), font: font)
    }

    private static func config(scratch: Bool = false) -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        ghostty_config_load_default_files(config)
        let overrides = NSTemporaryDirectory() + "claudetty.conf"
        var look = look
        if scratch { (look["window-padding-x"], look["window-padding-y"]) = ("12", "8,8") }
        if scratch || look["background-opacity"] != "1" { look["background-opacity"] = "0" }
        look["background-blur"] = nil
        let ground = light ? ["theme = Apple System Colors Light", "background = #ffffff", "foreground = #000000"] : ["background = #000000"]
        let keys = ["keybind = super+shift+t=unbind", "keybind = super+z=text:\\x1f"]
        try? (ground + keys + ["window-padding-color = extend"] + look.sorted { $0.key < $1.key }.map { "\($0) = \($1)" }).joined(separator: "\n").write(toFile: overrides, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, overrides)
        ghostty_config_finalize(config)
        return config
    }

    private func paintScratch() {
        scratch.paint()
        guard let surface = scratch.surface?.surface, let config = Self.config(scratch: true) else { return }
        ghostty_surface_update_config(surface, config)
        ghostty_config_free(config)
    }

    private func paint() {
        window.isOpaque = Self.look["background-opacity"] == "1"
        window.backgroundColor = window.isOpaque ? Self.light ? .white : .black : .clear
        defer { edges() }
        paintScratch()
        guard !window.isOpaque else { return backing.layer!.sublayers = nil }
        Self.ground(backing.layer!, light: Self.light)
    }

    private func edges() {
        func fill(_ body: Body?) -> NSColor? {
            guard let edge = body?.subviews.lazy.compactMap({ ($0 as? SurfaceView)?.edge }).first, edge.explicit || window.isOpaque else { return nil }
            return edge.color
        }
        func wear(_ view: NSView, _ color: NSColor?) {
            view.layer?.backgroundColor = color?.cgColor
            view.appearance = color.map { NSAppearance(named: $0.redComponent * 0.299 + $0.greenComponent * 0.587 + $0.blueComponent * 0.114 > 0.5 ? .aqua : .darkAqua) } ?? nil
        }
        wear(header, panes.values.first { $0.bar == nil }.flatMap { fill($0.body) })
        for view in [tabBar, titleButtons] { view.appearance = header.appearance }
        for pane in panes.values {
            pane.bar.map { wear($0, fill(pane.body)) }
            pane.body.layer?.backgroundColor = fill(pane.body)?.cgColor
        }
    }

    static func ground(_ layer: CALayer, light: Bool) {
        let opacity = Double(look["background-opacity"]!)!, radius = Int(look["background-blur"]!)!
        let tint = CALayer()
        tint.backgroundColor = NSColor(white: light ? 1 : 0, alpha: opacity).cgColor
        layer.sublayers = [tint]
        if opacity < 1, radius > 0, let backdrop = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init(), let filter = NSClassFromString("CAFilter") as? NSObject.Type {
            let blur = filter.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur").takeUnretainedValue() as! NSObject
            blur.setValuesForKeys(["inputRadius": radius, "inputNormalizeEdges": true])
            backdrop.filters = [blur]
            layer.insertSublayer(backdrop, at: 0)
        }
        for sublayer in layer.sublayers! {
            sublayer.frame = layer.bounds
            sublayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        }
    }

    private static func failed(_ reason: String) -> Int32 {
        fputs("ClaudeTTY \(reason)\n", stderr)
        return 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(link(_:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        NSApp.servicesProvider = self
        if probe == nil, Bundle.main.bundleIdentifier == "dev.claudetty.app" { LSSetDefaultHandlerForURLScheme("ct" as CFString, "dev.claudetty.app" as CFString) }
        DispatchQueue.global(qos: .utility).async { let path = Self.shellPath(); DispatchQueue.main.async { Self.loginPath = path } }
        if Self.disclaims(Self.executable, probe: probe) {
            Self.keep()
            if bundled { DispatchQueue.global(qos: .utility).async(execute: Self.settle) }
        } else if let probe, FileManager.default.fileExists(atPath: probe + "/keeper") { Self.keep() }
        if bundled { DispatchQueue.global(qos: .utility).async(execute: Self.agyStatusLine) }
        theme()
        lit = Self.light
        guard let config = Self.config() else { fatalError("ghostty_config_new failed") }
        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in DispatchQueue.main.async { ClaudeTTY.shared.app.map(ghostty_app_tick) } },
            action_cb: { _, target, action in ClaudeTTY.shared.perform(target, action) },
            read_clipboard_cb: { userdata, location, state, _, _, _ in ClaudeTTY.readClipboard(userdata, location, state) },
            confirm_read_clipboard_cb: { userdata, request, state, kind in
                guard let view = ClaudeTTY.view(userdata), let surface = view.surface else { return }
                guard kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let content = request.pointee.contents else { return ghostty_surface_deny_clipboard_request(surface, state) }
                let text = String(decoding: UnsafeRawBufferPointer(start: content.pointee.data, count: content.pointee.len), as: UTF8.self)
                DispatchQueue.main.async { ClaudeTTY.shared.pasting(text, view, state) }
            },
            write_clipboard_cb: { _, location, content, count, _ in ClaudeTTY.writeClipboard(location, content, count) },
            close_surface_cb: { userdata, _ in DispatchQueue.main.async { ClaudeTTY.shared.name(ClaudeTTY.view(userdata)).map { ClaudeTTY.shared.closing([$0]) } } })
        guard let app = ghostty_app_new(&runtime, config) else { fatalError("ghostty_app_new failed") }
        ghostty_config_free(config)
        self.app = app
        ghostty_app_set_focus(app, true)

        tabs = Self.sessions()
        let restored = (Self.saved?.tabs ?? []).filter { !tabs.contains($0) && (Self.saved?.boot != Self.boot || $0.labels["sleep"] != nil || Self.saved?.asleep?[$0.name] != nil) }
        for tab in restored { commands[tab.name] = Self.saved?.asleep?[tab.name] ?? Self.saved?.resume?[tab.name].map { Self.claude((Self.saved?.flags?[tab.name] ?? Self.bypass) + Self.resume(tab, $0), env: Self.codeMode(tab.transcript ?? Self.projects(tab.folder) + "/" + $0 + ".jsonl")) } }
        tabs += restored
        if !restored.isEmpty, let kept = Self.saved?.kept {
            let place = Dictionary(kept.enumerated().map { ($1.name, $0) }) { first, _ in first }
            tabs.sort { place[$0.name, default: .max] < place[$1.name, default: .max] }
        }
        hidden = predecessor?.hidden ?? false
        if let old = predecessor?.pid {
            let reclaim = { [unowned self] in
                oldApp?.cancel()
                oldApp = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.resendSizes() }
            }
            oldApp = Self.onExit(old, reclaim)
            if kill(old, 0) != 0 { reclaim() }
        }
        if let saved = Self.saved {
            lastTab = saved.lastTab.compactMapValues { name in tabs.first { $0.name == name } }
            (shown, zoomed, recent) = (Set(saved.shown), saved.zoomed, saved.recent)
        }
        readNotices(fresh: false)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        if Self.released, let last = UserDefaults.standard.string(forKey: "version"), version.compare(last, options: .numeric) == .orderedDescending { post("ClaudeTTY", "Updated to \(version).") }
        UserDefaults.standard.set(version, forKey: "version")
        if probe == nil, Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        window = Window(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.hidesOnDeactivate = false
        window.collectionBehavior = .fullScreenPrimary
        if predecessor != nil { window.animationBehavior = .none }
        window.contentView = layout(titlebar: window.frame.height - window.contentLayoutRect.height)
        paint()
        window.delegate = self
        if let saved = Self.saved, let screen = NSScreen.screens.first(where: { Self.display($0) == saved.display }) ?? NSScreen.screens.first {
            window.setFrame(window.constrainFrameRect(saved.frame.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY), to: screen), display: false)
        } else {
            window.center()
        }
        if let saved = Self.saved, !saved.sidebar {
            sidebarShown = false
            side.isHidden = true
            edge.isHidden = true
            sideSlide.constant = -sidebarWidth
        }
        if probe != nil { Self.saved?.fullScreen == true ? onscreen() : window.setFrameOrigin(NSPoint(x: 20_000, y: 20_000)) }
        if let frame = Self.saved?.given, let room = Self.saved?.givenIn { given = (frame, room) }
        window.layoutIfNeeded()
        for tab in restored {
            if tab.labels["sleep"] == nil {
                makeSurface(tab).setVisible(false)
            } else {
                warm(tab.name)
            }
        }
        watches = ([(statusDir, self.statusSoon), (Share.dir, self.shareCrashed),((Self.executable as NSString).deletingLastPathComponent, self.update), (zmxDir, { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: self.refresh) })] + (probe.map { [($0, { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.probeKey(); self.probeClick(); self.probeMenu(); self.probeDrop(); self.probeShot(); self.probeActive(); self.probeTrace(); self.probeFrames() } })] } ?? [])).map { Self.watch($0, $1) }
        Self.paired.keys.forEach(connect)
        if Self.released {
            checkUpdates()
            Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [unowned self] _ in checkUpdates() }.tolerance = 3600
        }
        scheduled.forEach(arm)
        armOutbox()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in mirror() }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [unowned self] _ in
            if drawing { activities.keys.forEach(redraw) }
            resumeUpdatedClaude()
        }.tolerance = 10
        Timer.scheduledTimer(withTimeInterval: Self.minute, repeats: true) { [unowned self] _ in
            checkPulls()
        }.tolerance = Self.minute / 6
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [unowned self] _ in update() }
        NSApp.mainMenu = menu()
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in ClaudeTTY.shared.showOrHide(); return noErr }, 1, &pressed, nil, nil)
        registerHotkey()
        themeWatch = NSApp.observe(\.effectiveAppearance) { [unowned self] _, _ in DispatchQueue.main.async { self.relight() } }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [unowned self] in keyHints($0) }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, Self.server, 0), .commonModes)
    }

    private func update() {
        let build = Self.build
        guard build != nil, build != running, newer == nil else { return }
        if let written = modified(Self.executable), written.timeIntervalSinceNow > -1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [unowned self] in update() }
            return
        }
        guard hidden || window.isOnActiveSpace && !window.isMiniaturized else {
            if updateWait == nil { updateWait = .scheduledTimer(withTimeInterval: probe == nil ? 600 : 1, repeats: false) { [unowned self] in
                $0.invalidate()
                menuBarIcon()
            } }
            return
        }
        running = build
        let hiding = hidden
        save(handover: State.Handover(pid: getpid(), window: window.windowNumber, hidden: hiding))
        CFMessagePortInvalidate(Self.server)
        let launcher = Self.spawn()
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(launcher, &status, 0)
            DispatchQueue.main.async {
                guard status == 0 else {
                    if Self.listen() { CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, Self.server, 0), .commonModes) }
                    return
                }
                let next = NSWorkspace.shared.runningApplications.first { $0.executableURL?.resolvingSymlinksInPath().path == Self.executable && $0.processIdentifier != getpid() }
                if NSApp.isActive, !hiding { next?.activate(from: .current) }
                NSApp.terminate(nil)
            }
        }
    }

    private func checkUpdates(manual: Bool = false) {
        URLSession.shared.dataTask(with: URL(string: Self.releases)!) { data, _, _ in
            struct Release: Decodable { struct Asset: Decodable { let name: String, browser_download_url: String }; let tag_name: String, html_url: URL, assets: [Asset] }
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async { [self] in
                let current = Bundle(path: Self.bundle)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                guard newer == nil, let release, let dmg = release.assets.first(where: { $0.name == "ClaudeTTY.dmg" }) else { return manual && newer == nil ? tell("Couldn't check for updates.") : () }
                let version = String(release.tag_name.drop { $0 == "v" })
                guard version.compare(current, options: .numeric) == .orderedDescending else { return manual ? tell("ClaudeTTY \(current) is the newest version.") : () }
                newer = (version, release.html_url, .running)
                let swap = Process()
                swap.executableURL = URL(fileURLWithPath: "/bin/zsh")
                swap.arguments = ["-c", """
                    set -e; T=$(mktemp -d); trap 'hdiutil detach -quiet -force $T/m 2>/dev/null; rm -rf $T' EXIT
                    curl -fsSL -o $T/d.dmg "$1"; hdiutil attach -quiet -nobrowse -noautoopen -readonly -mountpoint $T/m $T/d.dmg
                    R=$(codesign -d -r- "$2" 2>/dev/null | sed -n 's/^designated =>
                    rm -rf "${2:?}.new" "$2.old"; ditto $T/m/ClaudeTTY.app "$2.new"; mv "$2" "$2.old"; mv "$2.new" "$2" || { mv "$2.old" "$2"; exit 1; }; rm -rf "$2.old"
                    [[ -z $3 ]] || launchctl kickstart -k gui/$UID/$3 2>/dev/null || true
                    """, "zsh", dmg.browser_download_url, Self.bundle, probe == nil ? "dev.claudetty.keeper" : ""]   // a probe's app has no keeper
                swap.terminationHandler = { swap in DispatchQueue.main.async {
                    guard swap.terminationStatus == 0 else {
                        self.newer?.swap = .failed
                        return
                    }
                    self.newer = nil
                    self.update()
                } }
                if (try? swap.run()) == nil { newer?.swap = .failed }
            }
        }.resume()
    }

    @objc private func link(_ event: NSAppleEventDescriptor) {
        let query = URLComponents(string: event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? "")?.queryItems ?? []
        let name = query.first { $0.name == "tab" }?.value, text = String(String.UnicodeScalarView((query.first { $0.name == "text" }?.value ?? "").unicodeScalars.filter { $0.properties.generalCategory != .control }))
        guard UserDefaults.standard.bool(forKey: Self.linksKey), !text.isEmpty, let tab = tabs.first(where: { $0.name == name }) else { return NSSound.beep() }
        guard tab.labels["sleep"] == nil else {
            open(["args": [tab.group, tab.name], "focus": true])
            return retype(text, in: tab.name, after: 0)
        }
        let claude = Self.list().first { $0["name"] == name }?["pid"].flatMap(Int32.init).map(isClaude) == true
        guard let draft = claude ? Self.prompt(tab.name) : "" else { return NSSound.beep() }
        _ = try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", tab.name, claude ? "\u{1B}[200~" + (draft.isEmpty ? "" : "\n") + text + "\u{1B}[201~" : text])
        open(["args": [tab.group, tab.name], "focus": true])
    }

    @objc private func pickUpdate() {
        switch newer?.swap {
        case nil: checkUpdates(manual: true)
        case .failed: NSWorkspace.shared.open(newer!.page)
        case .running: break
        }
    }

    private func tell(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        if window.isVisible { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func probeKey() {
        guard let probe, let line = try? String(contentsOfFile: probe + "/key", encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: probe + "/key")
        let parts = line.split { $0 == " " || $0.isNewline }.map(String.init)
        guard parts.count >= 2, let code = UInt16(parts[1]) else { return }
        if parts[0] == "frame", parts.count > 2, let height = Double(parts[2]) { return window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: Double(code), height: height)), display: true) }
        if parts[0] == "onscreen" { return onscreen() }
        if parts[0] == "corner" { return window.setFrameOrigin(NSPoint(x: 1 - window.frame.width, y: 1 - window.frame.height)) }
        if parts[0] == "hotkey", parts.count > 2, let y = Double(parts[2]) { return showOrHide(at: NSPoint(x: Double(code), y: y)) }
        if parts[0] == "fullscreen" { return window.toggleFullScreen(nil) }
        if parts[0] == "minimize" { return window.miniaturize(nil) }
        if parts[0] == "close" { return window.performClose(nil) }
        if parts[0] == "activate" { return applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification)) }
        if parts[0] == "mark", let input = window.firstResponder as? NSTextInputClient {
            return parts.count > 2 ? input.setMarkedText(parts[2], selectedRange: NSRange(location: parts[2].utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) : input.unmarkText()
        }
        if parts[0] == "deactivate" { return applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification)) }
        let flags: [String: NSEvent.ModifierFlags] = ["cmd": .command, "shift": .shift, "ctrl": .control, "opt": .option]
        let modifiers = parts.dropFirst(2).reduce(into: NSEvent.ModifierFlags()) { $0.insert(flags[$1] ?? []) }
        if parts[0] == "flags" {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
            return NSApp.postEvent(NSEvent(cgEvent: event)!, atStart: false)
        }
        let characters = ["return": "\r", "esc": "\u{1b}", "delete": "\u{8}", "up": "\u{F700}", "down": "\u{F701}", "space": " ", "tab": "\t"][parts[0]] ?? parts[0]
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: (window.attachedSheet ?? window).windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        if let sheet = window.attachedSheet, let content = sheet.contentView {
            func button(_ view: NSView) -> NSButton? { (view as? NSButton).flatMap { $0.keyEquivalent == characters ? $0 : nil } ?? view.subviews.lazy.compactMap(button).first }
            if let pressed = characters == "\r" ? sheet.defaultButtonCell?.controlView as? NSButton : button(content) { return pressed.performClick(nil) }
            return sheet.firstResponder?.keyDown(with: event) ?? ()
        }
        if parts.last == "post" {
            NSApp.postEvent(event, atStart: false)
            return NSApp.postEvent(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!, atStart: false)
        }
        guard keyHints(event) != nil else { return }
        let shown = window.isVisible
        let handled = shown && window.performKeyEquivalent(with: event) || !modifiers.isDisjoint(with: [.command, .control]) && NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        if !handled && shown { window.firstResponder?.keyDown(with: event) }
    }

    private func onscreen() {
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        guide?.center()
    }

    private func probeMenu() {
        guard let probe, let line = try? String(contentsOfFile: probe + "/run", encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: probe + "/run")
        let names = line.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        var menu = NSApp.mainMenu, from = 0
        for name in names.dropLast() {
            if let submenu = menu?.items.first(where: { $0.submenu?.title == name })?.submenu { (menu, from) = (submenu, 0) }
            else if let header = menu?.items.firstIndex(where: { $0.isSectionHeader && $0.title == name }) { from = header + 1 }
            else { return }
        }
        guard let menu else { return }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        try? menu.items.map { $0.title + ($0.isEnabled ? "" : " (off)") }.joined(separator: "\n").write(toFile: probe + "/menu", atomically: true, encoding: .utf8)
        guard let index = menu.items[from...].firstIndex(where: { $0.title == names.last && $0.isEnabled }) else { return }
        menu.performActionForItem(at: index)
    }

    private func probeDrop() {
        guard let probe, let text = try? String(contentsOfFile: probe + "/drop", encoding: .utf8), let view = selected.flatMap({ surfaces[$0.name] }) else { return }
        try? FileManager.default.removeItem(atPath: probe + "/drop")
        let pasteboard = NSPasteboard(name: .init("dev.claudetty.drop." + probe))
        pasteboard.clearContents()
        pasteboard.writeObjects(text.split(separator: "\n").map { NSURL(fileURLWithPath: String($0)) })
        _ = view.drop(pasteboard)
    }

    private func probeClick() {
        guard let probe, let line = try? String(contentsOfFile: probe + "/click", encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: probe + "/click")
        var parts = line.split { $0 == " " || $0.isNewline }.map(String.init)
        let window: NSWindow = parts.first == "guide" ? guide ?? self.window : parts.first == "popover" ? popover ?? self.window : self.window
        if parts.first == "guide" || parts.first == "popover" { parts.removeFirst() }
        guard let frame = window.contentView?.superview else { return }
        func find(_ view: NSView, _ label: String, row: Bool = false) -> NSView? {
            let parts = label.split(separator: "#"), nth = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            func all(_ view: NSView) -> [NSView] { (view.accessibilityLabel() == String(parts.first ?? "") && (!row || view is Row) ? [view] : []) + view.subviews.flatMap(all) }
            return all(view).dropFirst(nth - 1).first
        }
        let moved = parts.last == "cmd-move", control = parts.last == "ctrl-cmd", command = moved || control || parts.last == "cmd", shift = parts.last == "shift", up = parts.last == "up"
        if command || shift || up { parts.removeLast() }
        let mouse = { [window] (type: NSEvent.EventType, point: NSPoint, count: Int) in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: control ? [.control, .command] : command ? .command : shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        if parts.count == 4, parts[3] == "post", let clicks = Int(parts[0]), let x = Double(parts[1]), let y = Double(parts[2]) {
            return (1...max(clicks, 1)).forEach { count in [.leftMouseDown, .leftMouseUp].forEach { NSApp.postEvent(mouse($0, NSPoint(x: x, y: y), count), atStart: false) } }
        }
        if parts.first == "hover", parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) {
            func all(_ view: NSView) -> [NSView] { (view is BarHover || view is HoverButton || view is TitleButton || view is Row || view is Arrow || view is LinkButton || view is Chat.Fact || view is Chat.Code ? [view] : []) + view.subviews.flatMap(all) }
            for view in all(frame) { view.convert(view.bounds, to: nil).contains(NSPoint(x: x, y: y)) ? view.mouseEntered(with: mouse(.mouseMoved, NSPoint(x: x, y: y), 0)) : view.mouseExited(with: mouse(.mouseMoved, NSPoint(x: x, y: y), 0)) }
            guard let surface = surfaces.values.first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: nil).contains(NSPoint(x: x, y: y)) }) else { return }
            surface.mouseEntered(with: mouse(.mouseMoved, NSPoint(x: x, y: y), 0))
            guard command || up else { return }
            surface.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: NSPoint(x: x, y: y), modifierFlags: control ? [.control, .command] : command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!)
            return surface.mouseMoved(with: mouse(.mouseMoved, NSPoint(x: x, y: y), 0))
        }
        if parts.first == "scroll", parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]) {
            let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: parts.count > 3 ? Int32(parts[3]) ?? 1 : 1, wheel2: 0, wheel3: 0)!
            wheel.location = CGPoint(x: x, y: NSScreen.screens[0].frame.height - y)
            return frame.hitTest(NSPoint(x: x, y: y))?.scrollWheel(with: NSEvent(cgEvent: wheel)!) ?? ()
        }
        if parts == ["release"] { return NSApp.postEvent(mouse(.leftMouseUp, probeDrag, 1), atStart: false) }
        if parts.count == 3, parts[0] == "to", let dx = Double(parts[1]), let dy = Double(parts[2]) {
            probeDrag = NSPoint(x: probeDrag.x + dx, y: probeDrag.y + dy)
            return NSApp.postEvent(mouse(.leftMouseDragged, probeDrag, 1), atStart: false)
        }
        let hold = parts.last == "hold"
        if parts.first == "drag", parts.count >= 4 + (hold ? 1 : 0), let dx = Double(parts[parts.count - (hold ? 3 : 2)]), let dy = Double(parts[parts.count - (hold ? 2 : 1)]) {
            let label = parts[1..<parts.count - (hold ? 3 : 2)].joined(separator: " ")
            let at = label.split(separator: " ").compactMap { Double($0) }
            guard let start = at.count == 2 ? NSPoint(x: at[0], y: at[1]) : (label.hasPrefix("bar:") ? find(tabBar, String(label.dropFirst(4)), row: true) ?? find(terminal, String(label.dropFirst(4)), row: true) : find(frame, label)).map({ $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }), let view = frame.hitTest(start) else { return }
            probeDrag = NSPoint(x: start.x + dx, y: start.y + dy)
            RunLoop.main.perform(inModes: [.default]) { [self] in
                for step in 1...10 { NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: start.x + dx * Double(step) / 10, y: start.y + dy * Double(step) / 10), 1), atStart: false) }
                if !hold { NSApp.postEvent(mouse(.leftMouseUp, probeDrag, 1), atStart: false) }
                view.mouseDown(with: mouse(.leftMouseDown, start, 1))
            }
            return
        }
        let middle = parts.last == "middle", menu = parts.last == "menu", right = parts.last == "right"
        if middle || menu || right { parts.removeLast() }
        let label = parts.dropFirst().joined(separator: " "), target = label.hasPrefix("bar:") ? find(frame, String(label.dropFirst(4)), row: true) : find(frame, label)
        if menu { _ = target?.accessibilityPerformShowMenu(); return }
        if label == "ClaudeTTY", hidden {
            let menu = NSMenu()
            menuNeedsUpdate(menu)
            popUp(menu, at: .zero, in: window.contentView!)
            return
        }
        guard let clicks = Int(parts.first ?? ""), let point = parts.count == 3 && Double(parts[1]) != nil ? NSPoint(x: Double(parts[1])!, y: Double(parts[2]) ?? 0) : target.map({ $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }) else { return }
        for count in 1...clicks {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(count - 1)) {
                guard let view = frame.hitTest(point) else { return }
                if right { return view.rightMouseDown(with: mouse(.rightMouseDown, point, count)) }
                if control { return [.leftMouseDown, .leftMouseUp].forEach { NSApp.postEvent(mouse($0, point, count), atStart: false) } }
                if !middle, !(view is SurfaceView) { NSApp.postEvent(mouse(.leftMouseUp, point, count), atStart: false) }
                let press = mouse(middle ? .otherMouseDown : .leftMouseDown, point, count)
                func commandKey(_ flags: NSEvent.ModifierFlags) {
                    view.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x37)!)
                }
                if command {
                    if moved { commandKey(.command) }
                    NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: moved ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0).map(view.mouseMoved)
                    if !moved { commandKey(.command) }
                }
                middle ? view.otherMouseDown(with: press) : view.mouseDown(with: press)
                if view is SurfaceView, !middle { view.mouseUp(with: mouse(.leftMouseUp, point, count)) }
                if command { commandKey([]) }
            }
        }
    }

    private func probeTrace() {
        guard let probe, let words = (try? String(contentsOfFile: probe + "/trace", encoding: .utf8))?.split(whereSeparator: \.isWhitespace), let seconds = words.first.flatMap({ Double($0) }) else { return }
        try? FileManager.default.removeItem(atPath: probe + "/trace")
        var log = "", frames: [CGImage] = [], tick = 0
        let crop = words.count == 6 ? NSRect(x: Double(words[2]) ?? 0, y: Double(words[3]) ?? 0, width: Double(words[4]) ?? 0, height: Double(words[5]) ?? 0) : .zero
        let start = CACurrentMediaTime()
        func sparks(_ view: NSView) -> [Spark] { (view as? Spark).map { [$0] } ?? view.subviews.flatMap(sparks) }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [unowned self] timer in
            for spark in sparks(window.contentView!.superview!) {
                let box = (spark.layer?.sublayers?.first?.presentation() as? CAShapeLayer)?.path?.boundingBox ?? .zero
                log += String(format: "%.4f\t%@\t%@\t%.2f %.2f %.2f %.2f\t%@\n", CACurrentMediaTime() - start, spark.identifier?.rawValue ?? "bar", spark.shown, box.minX, box.minY, box.width, box.height, spark.drawn)
            }
            tick += 1
            if words.count == 6, tick % 4 == 0, let root = window.contentView?.superview?.layer?.presentation(),
               let context = CGContext(data: nil, width: Int(crop.width * 2), height: Int(crop.height * 2), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.scaleBy(x: 2, y: 2)
                context.translateBy(x: -crop.minX, y: -crop.minY)
                root.render(in: context)
                context.makeImage().map { frames.append($0) }
            }
            guard CACurrentMediaTime() - start > seconds else { return }
            timer.invalidate()
            try? log.write(toFile: probe + "/trace.log", atomically: true, encoding: .utf8)
            try? FileManager.default.createDirectory(atPath: probe + "/clip", withIntermediateDirectories: true)
            for (index, frame) in frames.enumerated() { try? NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: probe + String(format: "/clip/%03d.png", index))) }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func probeFrames() {
        guard let probe, let text = try? String(contentsOfFile: probe + "/frames", encoding: .utf8), let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let layer = selected.flatMap({ surfaces[$0.name] })?.layer else { return }
        try? FileManager.default.removeItem(atPath: probe + "/frames")
        try? FileManager.default.createDirectory(atPath: probe + "/frames.d", withIntermediateDirectories: true)
        var seen: [Data: Int] = [:], last = Data(), log = ""
        let start = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                let surface = contents as! IOSurfaceRef
                IOSurfaceLock(surface, .readOnly, nil)
                let row = IOSurfaceGetBytesPerRow(surface), pixels = Data(bytes: IOSurfaceGetBaseAddress(surface), count: row * IOSurfaceGetHeight(surface))
                IOSurfaceUnlock(surface, .readOnly, nil)
                if pixels != last {
                    last = pixels
                    let n = seen[pixels] ?? seen.count
                    if seen[pixels] == nil, let image = CGImage(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                                                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                        seen[pixels] = n
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: probe + "/frames.d/\(n).png"))
                    }
                    log += String(format: "%.3f\t%d\t%@\n", Date().timeIntervalSince1970, n, String(describing: Unmanaged.passUnretained(surface).toOpaque()))
                }
            }
            guard Date().timeIntervalSince(start) > seconds else { return }
            timer.invalidate()
            try? log.write(toFile: probe + "/frames.log", atomically: true, encoding: .utf8)
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private var popover: Chat.Popover? { window.childWindows?.lazy.compactMap { $0 as? Chat.Popover }.first { $0.shown } }
    private func probeShot() {
        guard let probe, FileManager.default.fileExists(atPath: probe + "/shot"), let view = window.contentView?.superview else { return }
        try? FileManager.default.removeItem(atPath: probe + "/shot")
        for (shot, name) in [(view, "shot"), (window.attachedSheet?.contentView?.superview, "sheet"), (guide?.contentView?.superview, "guide"), (popover?.contentView?.superview, "popover")] {
            guard let shot, let rep = shot.bitmapImageRepForCachingDisplay(in: shot.bounds) else { continue }
            shot.layoutSubtreeIfNeeded()
            shot.cacheDisplay(in: shot.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: probe + "/\(name).png"))
        }
        func labels(_ view: NSView) -> [String] {
            let text = (view as? NSTextField)?.stringValue ?? (view as? Chat.Text)?.string.string.replacingOccurrences(of: "\u{fffc}\t", with: "") ?? (view as? NSButton)?.title.replacingOccurrences(of: "\u{fffc}", with: (view as? LinkButton)?.mark?.accessibilityDescription ?? "") ?? ""
            let face = view is NSButton ? view.subviews.first { $0 is NSTextField } ?? view : view
            let baseline = face.convert(NSPoint(x: 0, y: face.isFlipped ? face.firstBaselineOffsetFromTop : face.bounds.height - face.firstBaselineOffsetFromTop), to: nil).y
            let lead = (view as? Chat.Text).flatMap { $0.string.string.hasPrefix("\u{fffc}\t") ? ($0.string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.tabStops.first?.location : nil } ?? 0
            let span = view.convert(view is Chat.Text ? NSRect(x: 2 + lead, y: 0, width: view.bounds.width - 4 - lead, height: view.bounds.height) : view.bounds, to: nil)
            return (text.isEmpty || view.isHiddenOrHasHiddenAncestor ? [] : ["\(text)\t\(baseline)\t\(Int(span.minX)) \(Int(span.maxX))"]) + (view is NSButton ? [] : view.subviews.flatMap(labels))
        }
        func gauges(_ view: NSView) -> [String] {
            let box = view.convert(view.bounds, to: nil)
            return (view.accessibilityRole() == .levelIndicator && !view.isHiddenOrHasHiddenAncestor ? ["gauge\t\(view.accessibilityLabel() ?? "")\t\((view.accessibilityValue() as? String ?? "").dropLast())\t\(Int(box.minX)) \(Int(box.maxX.rounded(.up)))\t\(Int(box.minY)) \(Int(box.maxY.rounded(.up)))"] : []) + view.subviews.flatMap(gauges)
        }
        func texts(_ view: NSView) -> [String] { labels(view) + gauges(view) }
        let grids = surfaces.compactMap { name, surface in surface.surface.map { size in
            let grid = ghostty_surface_size(size)
            let top = surface.convert(NSPoint(x: 0, y: surface.isFlipped ? 0 : surface.bounds.height), to: nil)
            let body = surface.superview.map { $0.convert($0.bounds, to: nil) } ?? .zero
            return "grid \(name)\t\(surface.frame.height)\t\(surface.cellSize.height)\t\(grid.rows)\t\(surface.frame.width)\t\(surface.cellSize.width)\t\(grid.columns)\t\(top.x) \(top.y)\t\(body.minY) \(body.maxY)"
        } }
        let pathBoxes = surfaces.compactMap { name, surface in
            surface.pathBox.flatMap { $0.isHidden ? nil : "box \(name)\t" + $0.rects.map { let r = surface.convert($0, to: nil); return "\(Int(r.minX)) \(Int(r.minY)) \(Int(r.width))x\(Int(r.height))" }.joined(separator: ", ") }
        }
        func rows(_ view: NSView) -> [String] {
            let drawn = (view as? Row)?.ghost ?? view, at = drawn.convert(NSPoint(x: drawn.bounds.midX, y: drawn.bounds.midY), to: nil)
            let kind = view is Row ? "row" : view is Spark ? "spark" : view is ProgressRing ? "progress" : view is NSHostingView<ReadonlyBadge> ? "readonly" : view is Ring ? "ring" : view is Tile ? "tile" : nil
            let box = view is Row ? view.convert(view.bounds, to: nil) : nil
            return (kind != nil && !view.isHiddenOrHasHiddenAncestor ? ["\(kind!)\t\(view.accessibilityLabel() ?? "")\t\((view as? Spark)?.shown ?? (view as? ProgressRing)?.shown ?? "\(view.isAccessibilitySelected())")\t\(Int(at.x)) \(Int(at.y))\((view as? Spark)?.loopAt ?? "")" + (box.map { "\t\($0.minY) \($0.maxY)" } ?? "")] : []) + view.subviews.flatMap(rows)
        }
        let scrolled = (sidebar.enclosingScrollView.map { ["scroll\t\(Int($0.contentView.bounds.minY))"] } ?? [])
        let lane = tabBar.scroller.convert(tabBar.scroller.bounds, to: nil)
        func state(_ end: Arrow) -> String { end.isHidden ? "hidden" : !end.isEnabled ? "off" : end.ink.rest == TabStrip.amberInk ? "amber" : end.contentTintColor === end.ink.hover ? "lit" : "on" }
        let tabScroll = "tabscroll\t\(Int(tabBar.scroller.contentView.bounds.minX))\t\(Int(lane.minX)) \(Int(lane.maxX))\t" + tabBar.ends.map(state).joined(separator: " ") + "\t" + tabBar.tabs.arrangedSubviews.map { "\(Int($0.frame.minX))-\(Int($0.frame.maxX))" }.joined(separator: " ")
        let lanes = panes.values.compactMap(\.bar).map { bar in let lane = bar.scroller.convert(bar.scroller.bounds, to: nil); return "lane\t\(Int(lane.minX)) \(Int(lane.maxX))\t" + bar.ends.map(state).joined(separator: " ") + bar.tabs.arrangedSubviews.map { "\t" + ($0.accessibilityLabel() ?? "") }.joined() }
        let boxes = tabBar.crumb.map { icon in ([tabBar.views(in: .leading).first] + (icon.isHidden ? [] : [icon]) + [tabBar.arrangedSubviews.drop { $0 !== icon }.dropFirst().first { !$0.isHidden }]).map { $0.map { $0.alignmentRect(forFrame: $0.frame) } ?? .zero } }
        let crumb = boxes.map { "crumb\t\(tabBar.crumbHidden ? "hidden" : "chevron")\t" + zip($0, $0.dropFirst()).map { "\($1.minX - $0.maxX)" }.joined(separator: " ") }
        let top = NSApp.mainMenu?.items.compactMap(\.submenu) ?? [], appMenus = top + top.flatMap { $0.items.compactMap(\.submenu) }
        appMenus.forEach { $0.update() }
        let menus = appMenus.flatMap { menu in menu.items.map { item in
            "menu\t\(menu.title)\t" + (item.isSeparatorItem ? "-\t" : "\(item.title)\(item.state == .on ? " ✓" : "")\t" + Self.keys(item))
        } }
        let off = appMenus.flatMap { menu -> [String] in
            menu.items.filter { !$0.isEnabled && !$0.isSeparatorItem }.map { "menuoff\t\(menu.title)\t\($0.title)" }
        }
        let keys = pills.map { "pill\t\($0.key)\t\($0.frame.minX) \($0.frame.minY) \($0.frame.maxX) \($0.frame.maxY)\t\($0.frame.minY + KeyPill.baseline)" }
        let guided = guide?.contentView?.superview.map { (labels($0) + rows($0)).map { "guide\t" + $0 } } ?? []
        let sheet = window.attachedSheet?.contentView.map { labels($0).map { "sheet\t" + $0 } } ?? []
        let card = terminal.convert(scratch.card.frame, from: scratch), pane = terminal.bounds
        let taker = window.firstResponder === scratch.surface ? "scratch" : selected.flatMap({ chats[$0.name]?.composer.currentEditor() }).map({ $0 === window.firstResponder }) == true ? "composer" : window.firstResponder.map { responder in surfaces.first { $0.value === responder }?.key ?? "\(Swift.type(of: responder))" } ?? "none"
        let scratchGrid = scratch.surface?.surface.map { ghostty_surface_size($0) }.map { "\($0.rows)x\($0.columns)" } ?? "none"
        let rgb: [CGFloat] = scratch.ground.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] } ?? []
        let fill = rgb.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
        let backdrop = (scratch.surface?.layer?.contents).flatMap { CFGetTypeID($0 as CFTypeRef) == IOSurfaceGetTypeID() ? $0 as! IOSurfaceRef : nil }.map { drawn in
            IOSurfaceLock(drawn, .readOnly, nil)
            defer { IOSurfaceUnlock(drawn, .readOnly, nil) }
            return String(IOSurfaceGetBaseAddress(drawn).load(fromByteOffset: IOSurfaceGetBytesPerRow(drawn) * (IOSurfaceGetHeight(drawn) - 1) + IOSurfaceGetWidth(drawn) * 4 - 1, as: UInt8.self))
        } ?? "none"
        let tab = selected.flatMap { surfaces[$0.name] }.map { view in "\(view.surface.map(ghostty_surface_has_selection) == true ? "selection" : "none") \(view.scrolled)" } ?? "none"
        func box(_ rect: NSRect?) -> String { rect.map { [$0.minX, $0.minY, $0.width, $0.height].map { String(format: "%g", $0) }.joined(separator: " ") } ?? "none" }
        let chatted = selected.flatMap { tab in switches[tab.name].map { control in
            let chat = chats[tab.name]
            return "chat\t\(tab.name)\t\(chat == nil ? "Terminal" : "Chat")\tcontrol \(box(control.convert(control.bounds, to: nil)))\tbar \(box(chat.map { $0.convert($0.barFrame, to: nil) }))\tfacts \(box(chat.map { $0.convert($0.factsFrame, to: nil) }))\tside \(box(chat?.sideFrame))\ttoggle \(box(chat?.toggleFrame))\ttip \(chat?.toggle.toolTip ?? "")"
        } }
        let popped = popover.map { pop in ["popover\tframe \(box(window.convertFromScreen(pop.frame)))\ttip \(pop.tip)", pop.material] + (pop.contentView.map(texts) ?? []).map { "popover\t" + $0 } } ?? []
        let scratched = "scratch\t\(Scratch.position)\t\(scratch.open ? "shown" : "hidden")\t\(scratch.isHidden ? "out" : "in")\tcard \([card.minX, card.minY, card.width, card.height].map { String(format: "%g", $0) }.joined(separator: " "))\tpane \(String(format: "%gx%g", pane.width, pane.height))\tdim \(scratch.layer?.backgroundColor?.alpha ?? 0)\tkeys \(taker)\tgrid \(scratchGrid)\tground \(fill)\tbackdrop \(backdrop)\ttab \(tab)\tfolder \(scratch.folder.stringValue)"
        try? (selected.flatMap { chats[$0.name]?.typed } ?? []).joined(separator: "\n").write(toFile: probe + "/type", atomically: true, encoding: .utf8)
        try? (texts(view) + grids + pathBoxes + rows(view) + guided + sheet + popped + scrolled + [tabScroll] + lanes + (crumb.map { [$0] } ?? []) + keys + menus + off + (chatted.map { [$0] } ?? []) + (selected.flatMap { chats[$0.name]?.probed } ?? []) + ["titlebuttons\t" + titleButtons.arrangedSubviews.map { $0.toolTip ?? "" }.joined(separator: "\t")] + unsent.values.joined().map { "unsent\t" + $0.text } + [scratched, "spinner \(spinner != nil)", "rebuilds \(rebuilds)", "looking \(look != nil)", "badge \(NSApp.dockTile.badgeLabel ?? "")", "window \(window.isVisible ? "shown" : "hidden")", "frame \(Int(window.frame.minX)) \(Int(window.frame.minY)) \(Int(window.frame.width))x\(Int(window.frame.height))\(window.isZoomed ? " zoomed" : "")"]).joined(separator: "\n").write(toFile: probe + "/baselines", atomically: true, encoding: .utf8)
    }

    @discardableResult private func open(_ request: [String: Any]) -> String? {
        if let op = request["op"] as? [String] { return act(op) }
        var args = request["args"] as? [String] ?? []
        let cwd = request["cwd"] as? String ?? NSHomeDirectory()
        let focus = request["focus"] as? Bool ?? false
        var restarting: String?
        if args.first == "restart", args.count == 2 {
            guard selected == nil else { return restart(args[1]) }
            restarting = args[1]
            args = []
        }
        if args.first == "split" {
            guard let from = tabs.first(where: { $0.name == args[1] }) else { return "split: no tab \(args[1])" }
            if !tabs.contains(where: { $0.name == args[3] }) {
                let way = ["right", "down", "left", "up"].firstIndex(of: args[2])!
                guard let pane = newPane(beside: pane(of: from), in: from.group, across: way % 2 == 0, before: way > 1) else { return "split: couldn't save the layout" }
                insertTab(args[3], in: pane, beside: from, cwd: cwd)
            }
            args = [from.group] + args.dropFirst(3)
        }
        if let group = args.first {
            let name = args.count > 1 ? args[1] : group
            guard !name.contains("/") else { return "a tab name can't hold /" }
            let named = tabs.first { $0.group == group }?.labels["named"] ?? (name == group ? "0" : "1")
            if let tab = tabs.first(where: { $0.name == name }) {
                if args.count > 1, tab.group != group, !tabs.contains(where: { $0.group == group }) { return "\(group): no group named so; ct <group> <tab> moves a tab only into a group that exists (ct help)" }
                if args.count > 1, tab.group != group, !regroup(name, to: group, named: named) { return "couldn't move \(name) to \(group)" }
            } else {
                let opener = tabs.first { $0.name == request["from"] as? String }
                let profile = opener.map { $0.labels["profile"] } ?? shownProfile
                tabs.append(Tab(name: name, group: group, cwd: cwd, labels: ["named": named, "profile": profile, "opener": opener?.group == group ? opener?.name : nil].compactMapValues { $0 }))
            }
            let command = Array(args.dropFirst(2))
            if !command.isEmpty || commands[name] == nil { commands[name] = command.isEmpty ? [] : ["env", "PATH=" + (request["path"] as? String ?? "")] + command }
        }
        if tabs.isEmpty { tabs = [Tab(name: "main", group: "main", cwd: cwd, labels: ["named": "0"])] }
        let wanted = tabs.first { $0.name == (args.count > 1 ? args[1] : args.first) }
        guard focus || selected == nil else {
            if let wanted, surfaces[wanted.name] == nil { makeSurface(wanted).setVisible(false) }
            rebuild()
            return nil
        }
        let first = selected == nil
        select(wanted ?? selected ?? tabs.first { $0.name == Self.saved?.selected } ?? tabs[0])
        if first, let scroll = sidebar.enclosingScrollView, let saved = Self.saved {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: saved.scroll))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        hidden = hidden && !focus
        let guiding = first && predecessor == nil && Self.saved == nil && (probe == nil || FileManager.default.fileExists(atPath: probe! + "/setup"))
        hidden = hidden || guiding
        if let predecessor, !predecessor.hidden {
            window.order(.below, relativeTo: predecessor.window)
            window.makeKey()
        } else if !hidden { window.makeKeyAndOrderFront(nil) }
        if first, !hidden, Self.saved?.fullScreen == true { window.toggleFullScreen(nil) }
        menuBarIcon()
        predecessor = nil
        if guiding { openGuide(byItself: true) }
        if focus, probe == nil { NSApp.activate() }
        return restarting.flatMap { restart($0) }
    }

    private func refresh() {
        Self.lister.async { let live = Self.sessions(); DispatchQueue.main.async { self.refresh(live) } }
    }

    private static let lister = DispatchQueue(label: "zmx list", qos: .utility)

    private func refresh(_ live: [Tab]) {
        let state = { self.tabs.map { $0.labels.merging(["name": $0.name, "group": $0.group, "pid": "\($0.pid ?? 0)"]) { $1 } } + [["selected": self.selected?.name ?? ""]] }
        let before = state()
        let gone = tabs.filter { $0.pid != nil && !FileManager.default.fileExists(atPath: zmxDir + "/" + $0.name) }
        tabs.removeAll { tab in surfaces[tab.name] == nil && gone.contains(tab) }
        closed(gone.map(\.name))
        for i in tabs.indices { if let found = live.first(where: { $0 == tabs[i] }), let pid = found.pid, pid != tabs[i].ended { (tabs[i].pid, tabs[i].old) = (pid, found.old) } }
        tabs += live.filter { !tabs.contains($0) && FileManager.default.fileExists(atPath: zmxDir + "/" + $0.name) }
        for group in groups where tabs.first(where: { $0.group == group })?.labels["named"] == nil { label(group, "named", named(group) ? "1" : "0") }
        selected = selected.flatMap { old in tabs.first { $0 == old } }
        guard state() != before else { return }
        rebuild()
        saveSoon()
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        chats.values.contains { $0.composer === client as AnyObject } ? lineEditor : nil
    }
    private let lineEditor = { let editor = Chat.LineEditor(); editor.isFieldEditor = true; return editor }()
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        hidden = true
        hideHints()
        menuBarIcon()
        activityChanged()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) { activityChanged() }
    func windowDidDeminiaturize(_ notification: Notification) {
        activityChanged()
        update()
    }

    func windowWillEnterFullScreen(_ notification: Notification) { normalFrame = window.frame }
    func windowDidEnterFullScreen(_ notification: Notification) { Self.resendSizes() }
    static func resendSizes() { children(getpid()).flatMap(children).forEach { kill($0, SIGWINCH) } }
    func windowDidMove(_ notification: Notification) {
        keepPlace()
        saveSoon()
    }
    func windowDidResize(_ notification: Notification) {
        tabBar.needsLayout = true
        keepPlace()
        saveSoon()
    }
    private func keepPlace() {
        guard window.frame != fitted, !window.styleMask.contains(.fullScreen), let room = room(window.frame) else { return }
        given = (window.frame, room)
    }
    func applicationWillTerminate(_ notification: Notification) {
        save()
        Self.tellKeeper("unwatch")
    }

    private func save(handover: State.Handover? = nil) {
        saving = false
        guard let server = Self.server, CFMessagePortIsValid(server), selected != nil else { return }
        let frame = window.styleMask.contains(.fullScreen) ? normalFrame : window.frame
        scrolls = scrolls.filter { name, _ in tabs.contains { $0.name == name } }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.screens[0]
        let state = State(frame: frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), display: Self.display(screen), sidebar: sidebarShown,
                          scroll: sidebar.enclosingScrollView?.contentView.bounds.minY ?? 0, selected: selected?.name, shown: Array(shown),
                          lastTab: lastTab.mapValues(\.name), zoomed: zoomed, recent: recent, handover: handover,
                          fullScreen: window.styleMask.contains(.fullScreen), scrolled: surfaces.reduce(into: scrolls) { $0[$1.key] = $1.value.scrolled }.filter { $0.value > 0 },
                          boot: Self.boot, kept: tabs.filter { $0.labels["host"] == nil }.map { Tab(name: $0.name, group: $0.group, cwd: $0.folder, labels: $0.labels) },
                          resume: tabs.reduce(into: [:]) { ids, tab in if tab.claude != nil { ids[tab.name] = tab.session } }, sidebarWidth: sidebarWidth,
                          asleep: commands.filter { name, _ in tabs.contains { $0.name == name && ($0.labels["sleep"] != nil || $0.pid == nil) } },
                          flags: tabs.reduce(into: [:]) { all, tab in if tab.claude != nil, let front = tab.pid.flatMap(foreground) { all[tab.name] = Self.relaunch(front) } },
                          given: given?.frame, givenIn: given?.room, sidePanel: sidePanel,
                          unsent: unsent, drafts: drafts.merging(chats.compactMapValues { $0.composer.stringValue.isEmpty ? nil : $0.composer.stringValue }) { $1 })
        try? FileManager.default.createDirectory(atPath: (Self.stateFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: URL(fileURLWithPath: Self.stateFile), options: .atomic)
    }

    private func saveSoon() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in if saving { save() } }
    }

    private static func display(_ screen: NSScreen) -> UInt32 { screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0 }

    private var screens: [(frame: NSRect, room: NSRect)] {
        guard let probe else { return NSScreen.screens.map { ($0.frame, $0.visibleFrame) } }
        return ((try? String(contentsOfFile: probe + "/screens", encoding: .utf8)) ?? "").split(separator: "\n").map { line in
            let n = line.split(separator: " ").compactMap { Double($0) }
            return (NSRect(x: n[0], y: n[1], width: n[2], height: n[3]), NSRect(x: n[4], y: n[5], width: n[6], height: n[7]))
        }
    }
    private func room(_ frame: NSRect) -> NSRect? { screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }?.room }

    private static func fit(_ frame: NSRect, from room: NSRect, to target: NSRect) -> NSRect {
        guard target != room else { return frame }
        let size = NSSize(width: min(frame.width, target.width), height: min(frame.height, target.height))
        func share(_ gap: CGFloat, _ free: CGFloat) -> CGFloat { free > 0 ? min(max(gap / free, 0), 1) : 0 }
        return NSRect(x: target.minX + share(frame.minX - room.minX, room.width - frame.width) * (target.width - size.width),
                      y: target.minY + share(frame.minY - room.minY, room.height - frame.height) * (target.height - size.height), width: size.width, height: size.height)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return false
    }

    @objc private func showWindow() {
        hidden = guide != nil
        (guide ?? window).makeKeyAndOrderFront(nil)
        menuBarIcon()
        if probe == nil { NSApp.activate() }
    }

    private func menuBarIcon() {
        guard hidden || updateWait?.isValid == false else {
            statusItem.map(NSStatusBar.system.removeStatusItem)
            statusItem = nil
            iconDrawn = nil
            if let probe { try? FileManager.default.removeItem(atPath: probe + "/menubar.png") }
            return
        }
        let waiting = tabs.filter { $0.claude == "waiting" }.count
        let stopped: [String] = ["limited", "error"].filter { kind in tabs.contains { Self.marked($0) == kind } }
        guard "\(waiting) \(stopped)" != iconDrawn else { return }
        iconDrawn = "\(waiting) \(stopped)"
        let stops = stopped.compactMap { Spark.stopSymbol($0, tint: .black) }
        let text = NSMutableAttributedString(string: "✻_", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .kern: -1])
        if waiting > 0 { text.append(NSAttributedString(string: " \(waiting)", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .baselineOffset: 1])) }
        let image = NSImage(size: NSSize(width: ceil(text.size().width + stops.map { $0.size.width + 4 }.reduce(0, +)), height: ceil(text.size().height)), flipped: false) { rect in
            text.draw(at: .zero)
            var x: CGFloat = text.size().width + 4
            for stop: NSImage in stops {
                stop.draw(in: NSRect(x: x, y: (rect.height - stop.size.height) / 2, width: stop.size.width, height: stop.size.height))
                x += stop.size.width + 4
            }
            return true
        }
        image.isTemplate = true
        if let probe { return try! NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: probe + "/menubar.png")) }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.menu = NSMenu()
            statusItem?.menu?.delegate = self
            statusItem?.button?.setAccessibilityLabel("ClaudeTTY")
        }
        statusItem?.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === macs { return fillMacs(menu) }
        var rows: [(item: NSMenuItem, detail: String)] = []
        menuMarks = []
        let row = { (title: String, detail: String, action: Selector, target: String, claude: Bool, mark: String?) in
            let item = self.add(menu, title, action, target)
            item.image = mark.map { Marks.image($0, at: 0) } ?? (claude ? Self.claudeMark : nil)
            if let mark { self.menuMarks.append((item, mark)) }
            rows.append((item, detail))
        }
        if updateWait?.isValid == false {
            menu.addItem(withTitle: "Finish Update", action: #selector(showWindow), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        let waiting = tabs.filter { $0.claude == "waiting" }
        if !waiting.isEmpty {
            menu.addItem(.sectionHeader(title: "Needs you"))
            for tab in waiting { row(tab.from + tab.title, Self.cap(tab.action.map { $0.ask ?? $0.text } ?? "", 40), #selector(pickTab), tab.name, true, "blocked") }
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: "Groups"))
        for group in groups {
            let groupTabs = tabs.filter { $0.group == group }
            let activity = activity(groupTabs)
            row(groupTabs[0].from + title(group), [activity.map { Self.cap($0.what, 40) }, activity?.ago, agents(groupTabs)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  "), #selector(pickGroup), group, activity != nil, groupTabs.lazy.compactMap(\.mark).first)
        }
        let width = { (text: String, font: NSFont) in (text as NSString).size(withAttributes: [.font: font]).width }
        let column = NSMutableParagraphStyle()
        column.tabStops = [NSTextTab(textAlignment: .right, location: rows.map { width($0.item.title, .menuFont(ofSize: 0)) + ($0.detail.isEmpty ? 0 : 24 + width($0.detail, .menuFont(ofSize: 12))) }.max() ?? 0)]
        for (item, detail) in rows {
            let text = NSMutableAttributedString(string: item.title + "\t", attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: column])
            text.append(NSAttributedString(string: detail, attributes: [.font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: column]))
            item.attributedTitle = text
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Set Up ClaudeTTY…", action: #selector(setUp), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show ClaudeTTY", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit ClaudeTTY", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        let quit = menu.addItem(withTitle: "Quit ClaudeTTY", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.isHidden = true
        quit.allowsKeyEquivalentWhenHidden = true
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu == statusItem?.menu, !menuMarks.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [unowned self] _ in
            let now = CACurrentMediaTime()
            for (item, mark) in menuMarks { item.image = Marks.image(mark, at: now) }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    private func keyHints(_ event: NSEvent) -> NSEvent? {
        hideHints()
        if event.type == .keyDown, event.keyCode == 53, !picked.isEmpty || !pickedTabs.isEmpty, event.windowNumber == window.windowNumber, window.attachedSheet == nil, !(window.firstResponder is NSText) {
            unpick()
            return nil
        }
        let held = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .flagsChanged, held == .command || held == .control, window.isVisible, window.attachedSheet == nil, !(window.firstResponder is NSText) {
            hintModifier = held == .command ? "⌘" : "⌃"
            hintTimer = .scheduledTimer(withTimeInterval: 0.3, repeats: false) { [unowned self] _ in showHints() }
        }
        return event
    }

    private func hideHints() {
        hintTimer?.invalidate()
        hintTimer = nil
        pills.forEach { $0.removeFromSuperview() }
        pills = []
    }

    private func showHints() {
        hideHints()
        let root = window.contentView!
        root.layoutSubtreeIfNeeded()
        let actions = [#selector(toggleSidebar), #selector(newGroup), #selector(paneButton)]
        func buttons(_ view: NSView) -> [(String, NSView)] {
            let tip = (view as? NSButton).flatMap { button in button.action.map(actions.contains) == true ? button.toolTip : nil }
            return (tip.map { [(String($0[$0.lastIndex(of: "(")!...].dropFirst().dropLast()), view)] } ?? []) + view.subviews.flatMap(buttons)
        }
        let all = groups
        let rows = all.enumerated().compactMap { index, group in Self.digitKey(index, of: all.count).flatMap { key in groupRows[group].map { ("⌘" + key, $0 as NSView, true) } } }
        let tabKeys = paneRows.enumerated().compactMap { index, row in Self.digitKey(index, of: paneRows.count).map { ("⌃" + $0, row as NSView, false) } }
        let targets = hintModifier == "⌃" ? tabKeys : buttons(root).map { ($0, $1, false) } + rows
        func strip(_ view: NSView) -> TabStrip? { view.enclosingScrollView is Lane ? view.enclosingScrollView?.superview as? TabStrip : nil }
        let topDown = targets.filter { !$0.1.isHiddenOrHasHiddenAncestor && !$0.1.visibleRect.isEmpty && strip($0.1)?.shows($0.1 as! Row) != false }.map { key, view, corner in
            let pill = KeyPill(key), slot = corner ? nil : (view as? Row)?.closeSlot, box = view.convert(slot ?? view.bounds, to: root)
            let lane = strip(view).map { $0.scroller.convert($0.scroller.bounds, to: root) }
            let bar = sequence(first: view, next: \.superview).first { $0 is PaneBar } ?? root
            pill.edge = bar.convert(bar.bounds, to: root).maxX - 2
            let y = slot != nil ? (view as! Row).nameBaseline - KeyPill.baseline : box.midY - pill.frame.height / 2
            let x = slot == nil ? box.midX - pill.frame.width / 2 : lane.map { min(max(box.minX, $0.minX), $0.maxX - pill.frame.width) } ?? box.minX
            pill.setFrameOrigin(corner ? NSPoint(x: box.maxX - 6 - pill.frame.width, y: box.maxY - 7 - pill.frame.height) : NSPoint(x: x, y: y))
            return pill
        }.sorted { $0.frame.midY > $1.frame.midY }
        for (above, pill) in zip(topDown, topDown.dropFirst()) where above.frame.midY - pill.frame.midY < pill.frame.height / 2 {
            pill.setFrameOrigin(NSPoint(x: pill.frame.minX, y: above.frame.minY))
        }
        let placed = topDown.sorted { ($1.frame.minY, $0.frame.minX) < ($0.frame.minY, $1.frame.minX) }
        var run: [KeyPill] = [], wanted: [CGFloat] = []
        func settle() {
            let shift = zip(run, wanted).map { $0.frame.minX - $1 }.reduce(0, +) / CGFloat(max(run.count, 1))
            let over = max(0, (run.last?.frame.maxX ?? 0) - shift - (run.first?.edge ?? 0))
            for pill in run { pill.setFrameOrigin(NSPoint(x: (pill.frame.minX - shift - over).rounded(), y: pill.frame.minY)) }
        }
        for pill in placed {
            if let last = run.last, last.frame.minY == pill.frame.minY, pill.frame.minX < last.frame.maxX + 3 {
                wanted.append(pill.frame.minX)
                pill.setFrameOrigin(NSPoint(x: last.frame.maxX + 3, y: pill.frame.minY))
            } else {
                settle()
                (run, wanted) = ([], [pill.frame.minX])
            }
            run.append(pill)
        }
        settle()
        placed.forEach { root.addSubview($0) }
        pills = placed
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        for name in placed { surfaces[name]?.setVisible(drawing) }
        animate()
    }
    private var drawing: Bool { probe != nil || window.occlusionState.contains(.visible) }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let view = selected.flatMap({ surfaces[$0.name] }), view.cellSize.height > 0, !Body.unsnapped(sender, frameSize), !UserDefaults.standard.bool(forKey: Self.freeSizeKey) else { return frameSize }
        func snap(_ proposed: CGFloat, _ now: CGFloat, _ surface: CGFloat, _ padding: CGFloat, _ cell: CGFloat) -> CGFloat {
            proposed - (surface + proposed - now - padding).truncatingRemainder(dividingBy: cell)
        }
        return NSSize(width: snap(frameSize.width, sender.frame.width, view.frame.width, 2 * Self.padding.width, view.cellSize.width),
                      height: snap(frameSize.height, sender.frame.height, (view.superview ?? view).frame.height, Self.padding.height, view.cellSize.height))
    }

    private func refit() { panes.values.forEach { $0.body.fit() } }

    func applicationDidBecomeActive(_ notification: Notification) {
        app.map { ghostty_app_set_focus($0, true) }
        (window.firstResponder as? SurfaceView)?.focusDidChange(true)
        secure(true)
        if hidden { showWindow() }
        if !(window.firstResponder is NSText || window.firstResponder is SurfaceView) { selected.flatMap { chats[$0.name] }?.takeKeys() }
        window.styleMask.remove(.nonactivatingPanel)
        activityChanged()
    }

    func applicationDidResignActive(_ notification: Notification) {
        app.map { ghostty_app_set_focus($0, false) }
        (window.firstResponder as? SurfaceView)?.focusDidChange(false)
        secure(false)
        hideHints()
        window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
        activityChanged()
    }

    private func activityChanged() {
        banner()
        lookAt()
    }

    private func probeActive() {
        guard active != probeWasActive else { return }
        probeWasActive = active
        activityChanged()
    }

    private func menu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Set Up ClaudeTTY…", action: #selector(setUp), keyEquivalent: "")
        if Self.released { appMenu.addItem(withTitle: "Check for Updates", action: #selector(pickUpdate), keyEquivalent: "") }
        appMenu.addItem(.separator())
        let tabs = NSMenu(title: "New Claude Tabs")
        tabs.addItem(withTitle: "Bypass Permissions", action: #selector(toggleBypass), keyEquivalent: "")
        tabs.addItem(withTitle: "Code Mode", action: #selector(toggleCode), keyEquivalent: "")
        tabs.addItem(withTitle: "Fullscreen", action: #selector(toggleClassic), keyEquivalent: "")
        tabs.addItem(withTitle: "Share MCP Servers", action: #selector(toggleShare), keyEquivalent: "")
        appMenu.addItem(withTitle: "New Claude Tabs", action: nil, keyEquivalent: "").submenu = tabs
        let sleep = NSMenu(title: "Sleep")
        sleep.addItem(withTitle: "Sleep Idle Tabs", action: #selector(toggleSleep), keyEquivalent: "")
        sleep.addItem(.separator())
        sleep.addItem(.sectionHeader(title: "Keep Asleep Tabs Warm"))
        for title in ["Off", "1 Hour", "6 Hours"] { sleep.addItem(withTitle: title, action: #selector(pickWarm), keyEquivalent: "") }
        appMenu.addItem(withTitle: "Sleep", action: nil, keyEquivalent: "").submenu = sleep
        let hotkeys = NSMenu(title: "Show and Hide Hotkey")
        fillHotkeys(hotkeys)
        appMenu.addItem(withTitle: "Show and Hide Hotkey", action: nil, keyEquivalent: "").submenu = hotkeys
        let sounds = NSMenu(title: "Notification Sound")
        sounds.addItem(withTitle: "None", action: #selector(pickSound), keyEquivalent: "").representedObject = ""
        Self.sounds(sounds, action: #selector(pickSound))
        sounds.addItem(withTitle: "Add Sound…", action: #selector(addSound), keyEquivalent: "")
        appMenu.addItem(withTitle: "Notification Sound", action: nil, keyEquivalent: "").submenu = sounds
        macs.delegate = self
        if !Self.held { appMenu.addItem(withTitle: "Macs", action: nil, keyEquivalent: "").submenu = macs }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Rename Claude Session with Tab", action: #selector(toggleRename), keyEquivalent: "")
        appMenu.addItem(withTitle: "Focus Follows Mouse", action: #selector(toggleFollow), keyEquivalent: "")
        appMenu.addItem(withTitle: "Allow ct:// Links", action: #selector(toggleLinks), keyEquivalent: "")
        appMenu.addItem(withTitle: "Secure Keyboard Entry", action: #selector(toggleSecure), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Open Ghostty Config", action: #selector(openConfig), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Reload Ghostty Config", action: #selector(reloadConfig), keyEquivalent: ",").keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ClaudeTTY", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(SurfaceView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(SurfaceView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        for (title, action, key) in [("Find…", "start_search", "f"), ("Find Next", "navigate_search:next", "g"), ("Find Previous", "navigate_search:previous", "G"), ("Use Selection for Find", "search_selection", "e")] {
            edit.addItem(withTitle: title, action: #selector(fileAction), keyEquivalent: key).representedObject = action
        }
        edit.addItem(.separator())
        for (title, action, key) in [("Jump to Previous Prompt", "jump_to_prompt:-1", NSUpArrowFunctionKey), ("Jump to Next Prompt", "jump_to_prompt:1", NSDownArrowFunctionKey)] {
            let item = edit.addItem(withTitle: title, action: #selector(fileAction), keyEquivalent: String(UnicodeScalar(key)!))
            item.keyEquivalentModifierMask = [.command, .shift]
            item.representedObject = action
        }
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        let old = view.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        old.keyEquivalentModifierMask = [.control, .command]
        old.isHidden = true
        old.allowsKeyEquivalentWhenHidden = true
        view.addItem(withTitle: "Go to Tab…", action: #selector(goToTab), keyEquivalent: "p")
        view.addItem(withTitle: "Next Waiting Tab", action: #selector(nextWaiting), keyEquivalent: "U")
        if !Self.held {
            view.addItem(.separator())
            for (title, key) in [("Chat", "c"), ("Terminal", "t")] { view.addItem(withTitle: title, action: #selector(pickChat), keyEquivalent: key).keyEquivalentModifierMask = [.control, .command] }
            view.addItem(withTitle: "Side Panel", action: #selector(toggleSide), keyEquivalent: "i").keyEquivalentModifierMask = [.control, .command]
            let looks = NSMenu(title: "Chat")
            for (title, look) in [("Calls in Terminal Font", "B"), ("All in Terminal Font", "A")] { add(looks, title, #selector(pickChatLook), look) }
            view.addItem(withTitle: "Chat Look", action: nil, keyEquivalent: "").submenu = looks
        }
        view.addItem(.separator())
        let theme = NSMenu(title: "Theme")
        for title in ["Light", "Dark", "System"] { theme.addItem(withTitle: title, action: #selector(pickTheme), keyEquivalent: "") }
        view.addItem(withTitle: "Theme", action: nil, keyEquivalent: "").submenu = theme
        let settings: [(String, [(header: String, picks: [(String, [String: String])])])] = [
            ("Background", [("Transparency", Self.transparencies.map { ($0.title, ["background-opacity": $0.value]) }), ("Blur", Self.blurs.map { ($0.title, ["background-blur": $0.value]) })]),
            ("Padding", [("", [("Small", ["window-padding-x": "0", "window-padding-y": "0,4"]), ("Medium", ["window-padding-x": "8", "window-padding-y": "4,8"]), ("Large", ["window-padding-x": "16", "window-padding-y": "8,16"])])]),
            ("Cursor", [("", [("Block", ["cursor-style": "block"]), ("Bar", ["cursor-style": "bar"]), ("Underline", ["cursor-style": "underline"]), ("Hollow Block", ["cursor-style": "block_hollow"]), ("-", [:]), ("Blinking", ["cursor-style-blink": ""])])]),
        ]
        for (title, sections) in settings {
            let submenu = NSMenu(title: title)
            for (header, picks) in sections {
                if !header.isEmpty { submenu.addItem(.sectionHeader(title: header)) }
                for (title, pick) in picks { add(submenu, title, #selector(pickLook), pick) }
            }
            view.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
        }
        let spinner = NSMenu(title: "Icons")
        for (setting, title, value) in [("spinner", "Dots", "dots"), ("spinner", "Simple", "simple"), ("spinner", "Clawd", "clawd")] + (Spark.morph == nil ? [] : [("spinner", "Sparkle", "sparkle")])
            + [("-", "-", ""), ("sleep z", "Show Sleep Z's", "toggle"), ("-", "-", ""), ("", "Clawd Waiting on a Command", ""), ("clawd wait", "Terminal", "A"), ("clawd wait", "Hourglass", "B"), ("clawd wait", "Fishing", "C")] {
            guard !setting.isEmpty else {
                spinner.addItem(.sectionHeader(title: title))
                continue
            }
            add(spinner, title, #selector(pickSpinner), [setting, value])
        }
        view.addItem(withTitle: "Icons", action: nil, keyEquivalent: "").submenu = spinner
        view.addItem(.separator())
        view.addItem(withTitle: "Show Context Size", action: #selector(toggleContext), keyEquivalent: "")
        let panes = NSMenu(title: "Panes")
        for (header, titles, action) in [("Buttons", ["Off", "On Hover", "Always"], #selector(pickPaneButtons)), ("Motion", ["Snappy", "Natural"], #selector(pickPaneMotion))] {
            panes.addItem(.sectionHeader(title: header))
            for title in titles { panes.addItem(withTitle: title, action: action, keyEquivalent: "") }
        }
        view.addItem(withTitle: "Panes", action: nil, keyEquivalent: "").submenu = panes
        view.addItem(.separator())
        view.addItem(withTitle: "Scratch Terminal", action: #selector(toggleScratch), keyEquivalent: "j")
        let position = NSMenu(title: "Scratch Terminal Position")
        for title in ["Floating", "Drop Down", "Bottom"] { position.addItem(withTitle: title, action: #selector(pickScratch), keyEquivalent: "") }
        view.addItem(withTitle: "Scratch Terminal Position", action: nil, keyEquivalent: "").submenu = position
        view.addItem(.separator())
        view.addItem(withTitle: "Character Perfect Sizing", action: #selector(toggleFreeSize), keyEquivalent: "")
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen), keyEquivalent: "f").keyEquivalentModifierMask = [.control, .command]
        let file = NSMenu(title: "File")
        for (title, action, key, modifiers) in [("New Terminal Tab", "new_tab", "t", [.command]), ("New Claude Tab", "claude", "t", [.command, .option]), ("Reopen Closed Tab", "reopen", "T", [.command]), ("New Group", "new_window", "n", [.command]), ("-", "", "", []),
                                                ("Split Right", "new_split:right", "d", [.command]), ("Split Down", "new_split:down", "D", [.command]), ("Zoom Pane", "toggle_split_zoom", "\r", [.command, .shift]), ("-", "", "", []),
                                                ("Close Tab", "close_surface", "w", [.command]), ("Close Group", "close_window", "W", [.command])] as [(String, String, String, NSEvent.ModifierFlags)] {
            add(file, title, #selector(fileAction), action, key: key).keyEquivalentModifierMask = modifiers
        }
        file.insertItem(withTitle: "Rename Group", action: #selector(renameSelected), keyEquivalent: "R", at: 4)
        if Self.agy != nil { file.insertItem(item("New Antigravity Tab", #selector(fileAction), "agy"), at: 2) }
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        for submenu in [appMenu, file, edit, view, groupsMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }


    private func layout(titlebar: CGFloat) -> NSView {
        let root = Root()
        root.wantsLayer = true
        let side = NSVisualEffectView()
        side.material = .sidebar
        side.blendingMode = .behindWindow
        let tint = NSView(frame: side.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0, alpha: 0.18).cgColor
        side.addSubview(tint)
        sidebar.orientation = .vertical
        sidebar.alignment = .trailing
        sidebar.spacing = 4
        tabBar.spacing = 2
        tabBar.alignment = .firstBaseline
        let blank = Blank(newFolder: { [unowned self] in newFolder() }, header: { [unowned self] in Self.header(tabs) }, more: { [unowned self] in profileItems($0) }) { [unowned self] in newGroup() }
        blank.addSubview(sidebar)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = blank
        side.addSubview(scroll)
        let fit = blank.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        fit.priority = .defaultLow - 1
        func sideButtons() -> NSStackView {
            let stack = NSStackView(views: [Self.iconButton(Self.symbol("sidebar.left"), "Sidebar", "Hide or show the sidebar (⌘B)", self, #selector(toggleSidebar)), Self.iconButton(Self.symbol("plus"), "New group", "New group (⌘N)", self, #selector(newGroup))])
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            return stack
        }
        let buttons = sideButtons(), revealed = sideButtons(), zoom = window.standardWindowButton(.zoomButton)!
        let lights = zoom.frame.maxX
        zoom.superview!.addSubview(revealed)
        revealed.isHidden = true
        let buttonsLead = buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: lights + 16)
        for (name, full) in [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.willExitFullScreenNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                buttonsLead.constant = full ? 12 : lights + 16
                revealed.isHidden = !full
            }
        }
        sideSlide = side.leadingAnchor.constraint(equalTo: root.leadingAnchor)
        sideWidth = side.widthAnchor.constraint(equalToConstant: sidebarWidth)
        let fill = terminal.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        fill.priority = .init(490)
        edge.moved = { [unowned self] x, start in dragSidebar(to: x, from: start) }
        edge.ended = { [unowned self] in
            rebuild()
            saveSoon()
        }
        edge.setAccessibilityLabel("Sidebar edge")
        self.side = side
        let besideSidebar = tabBar.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 10)
        besideSidebar.priority = .init(749)
        tabBar.stop = titleButtons
        titleButtons.spacing = 10
        titleButtons.appearance = tabBar.appearance
        titleHover.views = { [unowned self] in titleButtons.arrangedSubviews.filter { !($0 is NSSegmentedControl) } }
        backing.wantsLayer = true
        header.wantsLayer = true
        for view in [backing, header, side, tabBar, terminal, scratch, buttons, titleButtons, titleHover, edge] { root.addSubview(view) }
        for view in [backing, header, side, scroll, blank, sidebar, tabBar, terminal, scratch, buttons, titleButtons, titleHover, edge] { view.translatesAutoresizingMaskIntoConstraints = false }
        scratch.dimmed = { [unowned self] in toggleScratch() }
        NSLayoutConstraint.activate([
            sideSlide,
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sideWidth,
            edge.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: 1),
            edge.widthAnchor.constraint(equalToConstant: 7),
            edge.topAnchor.constraint(equalTo: root.topAnchor, constant: titlebar),
            edge.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: side.topAnchor, constant: titlebar + 4),
            scroll.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            blank.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            blank.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            blank.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            blank.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            blank.bottomAnchor.constraint(greaterThanOrEqualTo: sidebar.bottomAnchor),
            fit,
            sidebar.topAnchor.constraint(equalTo: blank.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: blank.leadingAnchor, constant: 6),
            sidebar.trailingAnchor.constraint(equalTo: blank.trailingAnchor, constant: -6),
            buttonsLead,
            revealed.leadingAnchor.constraint(equalTo: zoom.superview!.leadingAnchor, constant: lights + 16),
            revealed.centerYAnchor.constraint(equalTo: zoom.centerYAnchor),
            buttons.centerYAnchor.constraint(equalTo: root.topAnchor, constant: titlebar / 2),
            besideSidebar,
            tabBar.leadingAnchor.constraint(greaterThanOrEqualTo: buttons.trailingAnchor, constant: 16),
            tabBar.firstBaselineAnchor.constraint(equalTo: root.topAnchor, constant: titlebar / 2 + TitleButton.font.capHeight / 2),
            tabBar.trailingAnchor.constraint(lessThanOrEqualTo: titleButtons.leadingAnchor, constant: -tabBar.gap),
            titleButtons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            titleButtons.centerYAnchor.constraint(equalTo: root.topAnchor, constant: titlebar / 2),
            titleHover.heightAnchor.constraint(equalToConstant: titlebar),
            terminal.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            fill,
            backing.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.bottomAnchor.constraint(equalTo: terminal.topAnchor),
            terminal.topAnchor.constraint(equalTo: root.topAnchor, constant: titlebar / 2 + Self.paneBar / 2),
            terminal.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scratch.leadingAnchor.constraint(equalTo: terminal.leadingAnchor),
            scratch.trailingAnchor.constraint(equalTo: terminal.trailingAnchor),
            scratch.topAnchor.constraint(equalTo: terminal.topAnchor),
            scratch.bottomAnchor.constraint(equalTo: terminal.bottomAnchor),
        ] + ([titleHover, backing, header] as [NSView]).flatMap {
            [$0.leadingAnchor.constraint(equalTo: side.trailingAnchor), $0.trailingAnchor.constraint(equalTo: root.trailingAnchor), $0.topAnchor.constraint(equalTo: root.topAnchor)]
        })
        return root
    }

    private func select(_ tab: Tab, keep: Bool = false) {
        let tab = tabs.first { $0 == tab } ?? tab
        if !keep { (picked, pickedTabs) = ([], []) }
        hideScratch()
        focus(tab)
        rebuild()
        window.makeFirstResponder(responder(tab.name))
    }

    private func focus(_ tab: Tab) {
        selected = tab
        lastTab[tab.group] = tab
        recent.removeAll { $0 == tab.name }
        recent.insert(tab.name, at: 0)
        if zoomed[tab.group] != pane(of: tab) { zoomed[tab.group] = nil }
        saveSoon()
        let pane = pane(of: tab)
        shown.subtract(tabs.filter { $0.group == tab.group && self.pane(of: $0) == pane }.map(\.name))
        shown.insert(tab.name)
    }

    private func layout(_ group: String) -> Layout {
        let groupTabs = tabs.filter { $0.group == group }
        let stored = groupTabs.first?.labels["split"].flatMap(Layout.init) ?? .pane("1")
        let used = Set(groupTabs.map { $0.labels["pane"] ?? "1" })
        return stored.panes.filter { !used.contains($0) }.reduce(Optional(stored)) { $0?.removing($1) } ?? .pane(groupTabs.first?.labels["pane"] ?? "1")
    }

    private func pane(of tab: Tab, in layout: Layout? = nil) -> String {
        let panes = (layout ?? self.layout(tab.group)).panes
        let pane = tab.labels["pane"] ?? "1"
        return panes.contains(pane) ? pane : panes[0]
    }

    private func shownTab(_ group: String, _ pane: String, in layout: Layout) -> Tab {
        let paneTabs = tabs.filter { $0.group == group && self.pane(of: $0, in: layout) == pane }
        return paneTabs.first { shown.contains($0.name) } ?? paneTabs[0]
    }

    private func arrange(_ layout: Layout) -> [String: CALayer]? {
        guard let selected else { return nil }
        let zoom = zoomedPane(selected.group, in: layout)
        var before: [String: CALayer]?
        if arranged != selected.group + "\t" + layout.text + " " + (zoom ?? "") {
            before = held ?? (arranged.hasPrefix(selected.group + "\t") ? frozen() : [:])
            held = nil
            arranged = selected.group + "\t" + layout.text + " " + (zoom ?? "")
            for view in panes.values.flatMap(\.body.subviews) { view is SurfaceView ? terminal.addSubview(view, positioned: .below, relativeTo: nil) : view.removeFromSuperview() }
            panes = [:]
            terminal.subviews.filter { !($0 is SurfaceView) }.forEach { $0.removeFromSuperview() }
            let root = zoom.map { paneView(.pane($0), split: true) } ?? paneView(layout, split: layout.panes.count > 1)
            root.frame = terminal.bounds
            root.autoresizingMask = [.width, .height]
            terminal.addSubview(root)
            terminal.layoutSubtreeIfNeeded()
            even(root)
        }
        var now: Set<String> = [], came: Set<String> = [], bodies: [String: Body] = [:]
        for (id, pane) in panes {
            let tab = shownTab(selected.group, id, in: layout)
            bodies[tab.name] = pane.body
            let view = surfaces[tab.name] ?? makeSurface(tab)
            if view.superview !== pane.body {
                pane.body.subviews.forEach(park)
                view.isHidden = false
                pane.body.addSubview(view)
                pane.body.fit()
                came.insert(tab.name)
            }
            now.insert(tab.name)
        }
        for case let view as SurfaceView in terminal.subviews where !view.isHidden { park(view) }
        let left = placed.subtracting(now), launch = placed.isEmpty
        for name in left { surfaces[name]?.setVisible(false) }
        for name in came { surfaces[name]?.setVisible(drawing) }
        placed = now
        for name in left where woken[name] != nil { woken[name]?.left = Date() }
        (launch ? Set(tabs.map(\.name)) : left.union(came)).forEach(nap)
        showChats(bodies)
        if window.firstResponder === window { window.makeFirstResponder(responder(selected.name)) }
        edges()
        return before
    }

    private func frozen(over before: [String: CALayer] = [:]) -> [String: CALayer] {
        return Dictionary(uniqueKeysWithValues: panes.compactMap { id, pane -> (String, CALayer)? in
            guard let view = pane.bar?.superview ?? pane.body as NSView?, let window else { return nil }
            let shot = CALayer()
            shot.frame = view.convert(view.bounds, to: terminal)
            shot.masksToBounds = true
            shot.isGeometryFlipped = true
            shot.backgroundColor = pane.body.layer?.backgroundColor ?? (window.isOpaque ? NSColor.windowBackgroundColor.cgColor : nil)
            func part(_ image: Any?, _ pixels: CGSize, _ rect: NSRect, scale: CGFloat, name: String? = nil) {
                guard let image else { return }
                let layer = CALayer()
                layer.name = name
                layer.contents = image
                layer.contentsScale = scale
                layer.contentsGravity = .topLeft
                layer.frame = NSRect(x: rect.minX, y: view.bounds.height - rect.maxY, width: pixels.width / scale, height: pixels.height / scale)
                shot.addSublayer(layer)
            }
            if let bar = pane.bar, let layer = bar.layer, let context = CGContext(data: nil, width: Int(bar.bounds.width * window.backingScaleFactor), height: Int(bar.bounds.height * window.backingScaleFactor),
                                                                                bitsPerComponent: 8, bytesPerRow: 0, space: window.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.scaleBy(x: window.backingScaleFactor, y: window.backingScaleFactor)
                layer.render(in: context)
                part(context.makeImage(), CGSize(width: context.width, height: context.height), bar.convert(bar.bounds, to: view), scale: window.backingScaleFactor)
            }
            for case let surface as SurfaceView in pane.body.subviews where !surface.isHidden {
                let old = before[id]?.sublayers?.first { $0.name == "terminal" }
                let picture = old == nil ? surface.picture : nil
                part(old?.contents ?? picture, old.map { CGSize(width: $0.frame.width * window.backingScaleFactor, height: $0.frame.height * window.backingScaleFactor) }
                     ?? CGSize(width: picture.map(IOSurfaceGetWidth) ?? 0, height: picture.map(IOSurfaceGetHeight) ?? 0), surface.convert(surface.bounds, to: view), scale: window.backingScaleFactor, name: "terminal")
            }
            return (id, shot)
        })
    }

    private func slide(from before: [String: CALayer]) {
        veil?.removeFromSuperlayer()
        veil = nil
        guard !before.isEmpty, let host = terminal.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        window.displayIfNeeded()
        let after = frozen(over: before)
        guard Set(after.keys) != Set(before.keys) || after.contains(where: { before[$0.key]?.frame != $0.value.frame }) else { return }
        let holder = CALayer(), live = terminal.subviews.filter { !($0 is SurfaceView) }
        holder.frame = host.bounds
        host.addSublayer(holder)
        veil = holder
        func edge(_ rect: NSRect, over: [String: CALayer], beside: [String: CALayer]) -> NSRect {
            guard let id = over.max(by: { area($0.value.frame.intersection(rect)) < area($1.value.frame.intersection(rect)) })?.key, let other = beside[id]?.frame else { return rect }
            if rect.minX >= other.maxX - 1 { return NSRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height) }
            if rect.maxX <= other.minX + 1 { return NSRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height) }
            if rect.minY >= other.maxY - 1 { return NSRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 0) }
            return NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0)
        }
        func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        func seen(_ rect: NSRect, of full: NSRect) -> NSRect {
            NSRect(x: rect.width == 0 && rect.minX == full.minX ? full.width : 0, y: rect.height == 0 && rect.minY == full.maxY ? full.height : 0, width: rect.width, height: rect.height)
        }
        var moves: [(shot: CALayer, from: NSRect, to: NSRect, full: NSRect)] = []
        for (id, shot) in after {
            moves.append((shot, before[id]?.frame ?? edge(shot.frame, over: before, beside: after), shot.frame, shot.frame))
        }
        for (id, shot) in before where after[id] == nil { moves.append((shot, shot.frame, edge(shot.frame, over: after, beside: before), shot.frame)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.forEach { $0.alphaValue = 0 }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(UserDefaults.standard.string(forKey: Self.motionKey) == "Natural" ? 0.3 : 0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1))
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, veil === holder else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            live.forEach { $0.alphaValue = 1 }
            holder.removeFromSuperlayer()
            CATransaction.commit()
            veil = nil
        }
        for move in moves {
            holder.insertSublayer(move.shot, at: move.from == move.to ? 0 : UInt32(holder.sublayers?.count ?? 0))
            let start = seen(move.from, of: move.full), end = seen(move.to, of: move.full)
            CATransaction.setDisableActions(true)
            move.shot.bounds = end
            move.shot.position = NSPoint(x: move.to.midX, y: move.to.midY)
            CATransaction.setDisableActions(false)
            for (key, value) in [("bounds", NSValue(rect: start)), ("position", NSValue(point: NSPoint(x: move.from.midX, y: move.from.midY)))] {
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = value
                move.shot.add(animation, forKey: key)
            }
        }
        CATransaction.commit()
    }

    private func responder(_ name: String) -> NSView? { chats[name]?.composer ?? surfaces[name] }

    private func chatty(_ tab: Tab) -> Bool {
        guard !Self.held, tab.labels["host"] == nil, let claude = tab.claude, claude != "asleep", let path = tab.transcript else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func showChats(_ bodies: [String: Body]) {
        func drop(_ name: String) {
            let text = chats[name]?.composer.stringValue ?? ""
            drafts[name] = text.isEmpty || chats[name]?.seen.map(Self.squeezed) == Self.squeezed(text) ? nil : text
            parked[name] = chats.removeValue(forKey: name)
            parked[name]?.removeFromSuperview()
        }
        parked = parked.filter { name, _ in tabs.contains { $0.name == name } }
        for name in chats.keys where bodies[name] == nil { drop(name) }
        for (name, body) in bodies {
            guard let tab = tabs.first(where: { $0.name == name }) else { continue }
            let path = tab.labels["chat"] != nil && chatty(tab) ? tab.transcript : nil, surface = surfaces[name]
            if let chat = chats[name], chat.path != path || chat.superview !== body { drop(name) }
            guard let path else {
                if surface?.isHidden == true {
                    surface?.isHidden = false
                    surface?.setVisible(drawing)
                }
                continue
            }
            if let chat = chats[name] { chat.refresh() } else {
                let chat = parked.removeValue(forKey: name).flatMap { $0.path == path ? $0 : nil } ?? Chat(path: path)
                chat.tab = { [unowned self] in tabs.first { $0.name == name } }
                chat.warmed = { [unowned self] tab in tab.session.map { warmed(tab, $0, Self.warmStore()) } }
                chat.keys = { [unowned self] keys in
                    if keys == "\r" || keys.first?.isNumber == true, let tab = tabs.first(where: { $0.name == name }) { Self.answered(tab) }
                    Self.type(keys, into: name)
                }
                chat.send = { [unowned self] text in say(text, to: name) }
                chat.enter = { [unowned self] text in
                    guard let tab = tabs.first(where: { $0.name == name }), let front = tab.pid.flatMap(foreground) else { return say(text, to: name) }
                    unsent[name, default: []].append(Outgoing(text: text, pid: front, session: tab.session, transcript: Self.size(tab.transcript), history: Self.size(Self.history)))
                    Self.type("\r", into: name)
                }
                chat.unsent = { [unowned self] in unsent[name] ?? [] }
                chat.takeBack = { [unowned self] in
                    let queue = unsent[name] ?? [], lines = Self.screen(name), waiting = Self.queued(lines)
                    let ours = !waiting.isEmpty && Self.prompt(lines) == "" && waiting.allSatisfy { text in queue.contains { $0.pid != nil && Self.squeezed($0.text) == text } }
                    let back = queue.filter { $0.pid == nil || ours && waiting.contains(Self.squeezed($0.text)) }
                    guard !back.isEmpty else { return "" }
                    let text = back.map(\.text).joined(separator: "\n"), left = queue.filter { !back.contains($0) }
                    if ours {
                        chats[name]?.mirror = text
                        Self.type("\u{1B}[A", into: name)
                    }
                    chats[name]?.composer.stringValue = text
                    unsent[name] = left.isEmpty ? nil : left
                    return text
                }
                chat.terminal = { [unowned self] in showChat(name, chat: false) }
                chat.link = { [unowned self] link, reveal in
                    guard target(link, from: folder(of: surfaces[name])) != nil else { return false }
                    if let reveal { open(link, from: surfaces[name], reveal: reveal) }
                    return true
                }
                chat.theme = { [unowned self] in
                    let face = surfaces[name]?.surface.flatMap { ghostty_surface_quicklook_font($0) }.map { Unmanaged<CTFont>.fromOpaque($0).takeRetainedValue() as NSFont }
                    return (Self.terminalTheme(face), face != nil)
                }
                chat.toggleSide = { [unowned self] in toggleSide() }
                chat.cycle = { [unowned self] mode in cycle(name, to: mode) }
                chat.kept = { tab in tab.session.flatMap { Self.warmStore()["deadline:" + $0] }.map { Date(timeIntervalSince1970: $0 / 1000) } }
                chat.keepWarm = { [unowned self] tab in Self.cacheTax().map { store in
                    if store["always:" + tab.name] as? Bool == true || store["always"] as? Bool == true { return "Always" }
                    guard let session = tab.session, let deadline = (store["deadline:" + session] as? Double).map({ $0 / 1000 }), deadline > Date().timeIntervalSince1970 else { return "Off" }
                    if armed[session]?.deadline != deadline { armed[session] = (deadline, deadline - Date().timeIntervalSince1970) }
                    let left = armed[session]!.left
                    return left > 3 * 3600 + 300 ? "For 6 hours" : abs(left - 90 * 60) < 300 ? "For 90 minutes" : "Until " + Self.until.string(from: Date(timeIntervalSince1970: deadline))
                } }
                chat.openWorker = { [unowned self] task in openTask(task, of: name) }
                chat.compacting = { [unowned self] on in
                    if let tab = tabs.first(where: { $0.name == name }) { label(tab.group, "compact", on ? "" : "0", tab: name) }
                }
                let draft = drafts.removeValue(forKey: name)
                chat.composer.stringValue = Self.prompt(name).flatMap { $0.isEmpty || Chat.collapsed($0) ? nil : $0 } ?? draft ?? ""
                chat.frame = body.bounds
                body.addSubview(chat)
                chats[name] = chat
                chat.refresh()
            }
            chats[name]?.alone = bodies.count == 1
            chats[name]?.showPanel = sidePanel ? nil : { [unowned self] in toggleSide() }
            chats[name]?.sideWanted = sidePanel && bodies.count == 1
            surface?.isHidden = true
            surface?.setVisible(false)
        }
    }

    @objc private func toggleSide() {
        sidePanel.toggle()
        save()
        rebuild()
    }

    private func chatSwitch(_ tab: Tab) -> [NSView] {
        guard chatty(tab) else { return [] }
        let control = NSSegmentedControl(labels: ["Chat", "Terminal"], trackingMode: .selectOne, target: self, action: #selector(pickChat))
        control.controlSize = .small
        control.selectedSegment = tab.labels["chat"] != nil ? 0 : 1
        control.identifier = .init(tab.name)
        control.toolTip = "Chat (⌃⌘C) or Terminal (⌃⌘T)"
        switches[tab.name] = control
        return [control]
    }

    @objc private func pickChat(_ sender: Any) {
        let control = sender as? NSSegmentedControl
        showChat(control?.identifier?.rawValue ?? selected?.name, chat: control.map { $0.selectedSegment == 0 } ?? ((sender as? NSMenuItem)?.title == "Chat"))
    }
    private func showChat(_ name: String?, chat: Bool) {
        guard let tab = tabs.first(where: { $0.name == name }), chatty(tab) else { return }
        label(tab.group, "chat", chat ? "1" : "", tab: tab.name)
        rebuild()
        window.makeFirstResponder(responder(tab.name))
    }

    private static let typist = DispatchQueue(label: "typist")
    static func type(_ keys: String, into name: String) { typist.async { try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", name, keys]).waitUntilExit() } }
    private func mirror() {
        let names = chats.filter { $0.value.window != nil }.map(\.key)
        guard !names.isEmpty else { return }
        DispatchQueue.global().async { [self] in
            let boxes = names.map { ($0, Self.prompt($0)) }
            DispatchQueue.main.async { [self] in for (name, box) in boxes { chats[name]?.held(box) } }
        }
    }

    private func say(_ text: String, to name: String) {
        unsent[name, default: []].append(Outgoing(text: text))
        deliver()
    }
    private func armOutbox() {
        if unsent.isEmpty {
            outbox?.invalidate()
            outbox = nil
        } else if outbox == nil {
            outbox = .scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in deliver() }
        }
    }
    private func deliver() {
        for (name, sent) in unsent {
            guard let tab = tabs.first(where: { $0.name == name }), let front = tab.pid.flatMap(foreground) else { continue }
            var queue = sent.filter { $0.pid == nil || !arrived($0, in: tab) }
            for index in queue.indices where queue[index].pid != nil && (queue[index].pid != front || tab.session != nil && queue[index].session != tab.session) { queue[index].pid = nil }
            if let next = queue.firstIndex(where: { $0.pid == nil }), tab.session != nil, case let lines = Self.screen(name), Self.prompt(lines) == "" {
                let text = Self.squeezed(queue[next].text), pasted = queue.filter { $0.pid != nil && Self.squeezed($0.text) == text }.count
                let held = Self.queued(lines).filter { $0 == text }.count
                (queue[next].pid, queue[next].session, queue[next].at, queue[next].transcript, queue[next].history) = (front, tab.session, Date(), Self.size(tab.transcript), Self.size(Self.history))
                queue[next].answer = tab.claude == "waiting"
                if held <= pasted { _ = try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", name, "\u{1B}[200~" + queue[next].text + "\u{1B}[201~"]) { _ in usleep(300_000); _ = try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", name, "\r"]) } }
            }
            if queue != sent { unsent[name] = queue.isEmpty ? nil : queue }
        }
    }
    private func arrived(_ sent: Outgoing, in tab: Tab) -> Bool {
        let rows = Self.rows(tab.transcript, from: sent.transcript)
        return sent.answer && tab.claude != "waiting"
            || rows.contains { Chat.entries($0).contains { $0.kind == .user && $0.text == sent.text } }
            || !rows.contains { $0["operation"] as? String == "enqueue" && $0["content"] as? String == sent.text } && Self.rows(Self.history, from: sent.history).contains { Self.typed($0) == sent.text }
    }
    static let history = NSHomeDirectory() + "/.claude/history.jsonl"
    private static func size(_ path: String?) -> UInt64 { path.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? UInt64 } ?? 0 }
    static func rows(_ path: String?, from offset: UInt64) -> [[String: Any]] {
        guard let path, let file = FileHandle(forReadingAtPath: path), let end = try? file.seekToEnd() else { return [] }
        defer { try? file.close() }
        try? file.seek(toOffset: end < offset ? 0 : offset)
        return ((try? file.readToEnd()) ?? Data()).split(separator: 0x0A).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    static func typed(_ row: [String: Any]) -> String {
        (row["pastedContents"] as? [String: [String: Any]] ?? [:]).reduce(row["display"] as? String ?? "") { text, paste in
            text.replacingOccurrences(of: "\\[Pasted text #\(paste.key)( [^\\]]*)?\\]", with: NSRegularExpression.escapedTemplate(for: paste.value["content"] as? String ?? ""), options: .regularExpression)
        }
    }

    private func cycle(_ name: String, to mode: String) {
        DispatchQueue.global().async { [self] in
            for step in 0..<5 {
                guard let now = Self.mode(name) else { break }
                if now == mode { return }
                guard step < 4 else { break }
                try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", name, "\u{1B}[Z"]).waitUntilExit()
                usleep(400_000)
            }
            DispatchQueue.main.async { [self] in showChat(name, chat: false) }
        }
    }

    private func park(_ view: NSView) {
        guard view is SurfaceView else { return view.removeFromSuperview() }
        view.isHidden = true
        view.frame = terminal.bounds
        terminal.addSubview(view, positioned: .below, relativeTo: nil)
    }

    private func zoomedPane(_ group: String, in layout: Layout) -> String? {
        zoomed[group].flatMap { layout.panes.count > 1 && layout.panes.contains($0) ? $0 : nil }
    }

    @objc private func toggleZoom(_ item: NSMenuItem? = nil) {
        if let name = item?.representedObject as? String, let tab = tabs.first(where: { $0.name == name }) { focus(tab) }
        guard let selected else { return }
        let layout = layout(selected.group)
        guard layout.panes.count > 1 else { return }
        zoomed[selected.group] = zoomedPane(selected.group, in: layout) == nil ? pane(of: selected, in: layout) : nil
        rebuild()
        window.makeFirstResponder(responder(selected.name))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let typing = (window.firstResponder as? NSText).map { !sequence(first: $0 as NSView, next: \.superview).contains { $0 is FindBar } } ?? false
        let finding = (item.representedObject as? String).map(Chat.searches) == true && selected.flatMap({ chats[$0.name] }) != nil
        let asking = window.attachedSheet != nil || typing && !finding || guide != nil
        let composing = typing && (window.firstResponder as? NSView).map { sequence(first: $0, next: \.superview).contains { $0 is Chat } } == true
        let chatKey = composing && (item.action == #selector(goToTab) || ["new_tab", "claude", "agy"].contains(item.representedObject as? String))
        let groups = item.action == #selector(pickGroup) || item.action == #selector(pickTab)
        if item.action == #selector(toggleSecure) { item.state = UserDefaults.standard.bool(forKey: Self.secureKey) ? .on : .off }
        if item.action == #selector(toggleLinks) { item.state = UserDefaults.standard.bool(forKey: Self.linksKey) ? .on : .off }
        if item.action == #selector(toggleRename) { item.state = UserDefaults.standard.bool(forKey: Self.renameKey) ? .on : .off }
        if item.action == #selector(toggleFollow) { item.state = UserDefaults.standard.bool(forKey: Self.followKey) ? .on : .off }
        if item.action == #selector(pickHotkey) { item.state = item.title == UserDefaults.standard.string(forKey: Self.hotkeyKey) ?? "Off" ? .on : .off }
        if item.action == #selector(pickSound) { item.state = item.representedObject as? String == UserDefaults.standard.string(forKey: Self.soundKey) ?? "Glass" ? .on : .off }
        if item.action == #selector(pickChatLook) { item.state = item.representedObject as? String == Chat.look ? .on : .off }
        if item.action == #selector(pickSpinner), let pick = item.representedObject as? [String] {
            item.state = (pick[1] == "toggle" ? Spark.settings[pick[0]] != "off" : Spark.settings[pick[0]] == pick[1]) ? .on : .off
            if pick[0] == "sleep z" { return ["dots", "clawd"].contains(Spark.style) }
            if pick[0] != "spinner" { return Spark.style == "clawd" }
        }
        if item.action == #selector(pickTheme) { item.state = item.title == ["light": "Light", "dark": "Dark"][UserDefaults.standard.string(forKey: Self.themeKey) ?? ""] ?? "System" ? .on : .off }
        if item.action == #selector(pickPaneMotion) {
            item.state = item.title == UserDefaults.standard.string(forKey: Self.motionKey) ?? "Snappy" ? .on : .off
            return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
        if item.action == #selector(pickPaneButtons) { item.state = item.title == Self.paneButtons ? .on : .off }
        if item.action == #selector(pickScratch) { item.state = item.title == Scratch.position ? .on : .off }
        if item.action == #selector(pickLook), let pick = item.representedObject as? [String: String] {
            item.state = pick.allSatisfy { Self.look[$0] == $1 } ? .on : .off
            if pick["background-blur"] != nil, Self.look["background-opacity"] == "1" { return false }
        }
        if item.action == #selector(toggleBypass) { item.state = UserDefaults.standard.bool(forKey: Self.askKey) ? .off : .on }
        if item.action == #selector(toggleCode) { item.state = UserDefaults.standard.bool(forKey: Self.codeKey) ? .on : .off }
        if item.action == #selector(toggleClassic) { item.state = UserDefaults.standard.bool(forKey: Self.classicKey) ? .off : .on }
        if item.action == #selector(pickUpdate) {
            item.title = switch newer?.swap {
            case nil: "Check for Updates"
            case .running: "Updating to \(newer!.version)…"
            case .failed: "Update to \(newer!.version)…"
            }
            return newer?.swap != .running
        }
        if item.action == #selector(toggleSleep) { item.state = UserDefaults.standard.bool(forKey: Self.wakeKey) ? .off : .on }
        if item.action == #selector(toggleShare) { item.state = UserDefaults.standard.bool(forKey: Share.offKey) ? .off : .on }
        if item.action == #selector(pickWarm) { item.state = Self.hours(item.title) == UserDefaults.standard.double(forKey: Self.warmKey) ? .on : .off }
        if item.action == #selector(toggleContext) { item.state = UserDefaults.standard.bool(forKey: Self.contextKey) ? .off : .on }
        if item.action == #selector(pickChat) { item.state = (selected.flatMap { chats[$0.name] } != nil) == (item.title == "Chat") ? .on : .off }
        if item.action == #selector(toggleSide) { item.state = sidePanel ? .on : .off }
        if item.action == #selector(toggleFreeSize) { item.state = UserDefaults.standard.bool(forKey: Self.freeSizeKey) ? .off : .on }
        if item.menu?.supermenu === NSApp.mainMenu, unseen && !groups || asking && !chatKey && (groups || item.action == #selector(fileAction) || item.action == #selector(goToTab) || item.action == #selector(toggleScratch)) { return false }
        if item.action == #selector(nextWaiting) { return longestWaiting != nil }
        if item.action == #selector(pickChat) { return selected.map(chatty) == true }
        if item.action == #selector(toggleSide) { return selected.flatMap { chats[$0.name] } != nil && selected.map { let split = layout($0.group); return split.panes.count == 1 || zoomedPane($0.group, in: split) != nil } == true }
        let zoom = item.action == #selector(toggleZoom) || item.action == #selector(fileAction) && item.representedObject as? String == "toggle_split_zoom"
        return !zoom || selected.map { layout($0.group).panes.count > 1 } == true
    }

    private func paneView(_ layout: Layout, split: Bool) -> NSView {
        guard case .pane(let id) = layout else {
            guard case .split(let across, let parts) = layout else { fatalError() }
            let view = SplitView()
            view.isVertical = across
            view.dividerStyle = .thin
            parts.forEach { view.addArrangedSubview(paneView($0, split: true)) }
            return view
        }
        let body = Body()
        guard split else {
            panes[id] = (nil, body)
            return body
        }
        let bar = PaneBar()
        bar.wantsLayer = true
        bar.doubleClick = { [unowned self] in newTab(pane: id) }
        bar.spacing = 2
        bar.setHuggingPriority(.init(249), for: .horizontal)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
        let pane = NSView()
        for view in [bar, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: pane.topAnchor),
            bar.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.paneBar),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        panes[id] = (bar, body)
        return pane
    }

    private func even(_ view: NSView) {
        guard let split = view as? NSSplitView else { return }
        let count = CGFloat(split.arrangedSubviews.count)
        let length = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness * (count - 1)
        for index in 0..<split.arrangedSubviews.count - 1 {
            split.setPosition(length * CGFloat(index + 1) / count + split.dividerThickness * CGFloat(index), ofDividerAt: index)
        }
        split.layoutSubtreeIfNeeded()
        split.arrangedSubviews.forEach(even)
    }

    private func makeSurface(_ tab: Tab) -> SurfaceView {
        var tab = tab
        if let index = tabs.firstIndex(of: tab), tabs[index].labels.removeValue(forKey: "sleep") != nil {
            tabs[index].labels["freed"] = nil
            tab = tabs[index]
            woken[tab.name] = (Date(), tab.transcript, tab.transcript.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? UInt64 } ?? 0)
        }
        let labels = (["group=" + Self.encoded(tab.group)] + tab.labels.map { $0.key + "=" + Self.encoded($0.value) }).joined(separator: " ")
        let command = (tab.labels["host"].map { Self.ssh($0, ["attach", tab.onHost]) } ?? ["env", "ZMX_NO_DETACH_KEY=1"] + [Self.executable, "--attach"] + ["--labels", labels, tab.name] + (commands[tab.name] ?? []))
            .map(Self.quoted).joined(separator: " ")
        let view = SurfaceView(app: app!, command: command, cwd: tab.cwd)
        surfaces[tab.name] = view
        if let rows = scrolls[tab.name] { view.restore(rows) }
        if tab.labels["readonly"] != nil { view.binding("toggle_readonly") }
        view.onFocus = { [unowned self] in
            guard let tab = tabs.first(where: { $0.name == tab.name }), tab != selected else { return }
            focus(tab)
            rebuild()
        }
        view.onDrop = { [unowned self] in Self.dropTexts($0, claude: tabs.first { $0.name == tab.name }?.claude != nil) }
        view.onAnswer = { [unowned self] in tabs.first { $0.name == tab.name }.map(Self.answered) }
        view.tabItems = { [unowned self] in
            guard let tab = tabs.first(where: { $0.name == tab.name }) else { return (false, nil, []) }
            let layout = layout(tab.group)
            let zoom = layout.panes.count > 1 ? [item(zoomedPane(tab.group, in: layout) == nil ? "Zoom Pane" : "Unzoom Pane", #selector(toggleZoom), tab.name)] : []
            return (tab.claude != nil, Self.summary(tab), (tab.labels["host"] == nil ? scheduleItems(tab) + [.separator()] : []) + tabControls(tab) + [.separator()] + zoom + [item("Close Tab", #selector(closeTabs), [tab.name])])
        }
        view.frame = terminal.bounds
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        terminal.addSubview(view, positioned: .below, relativeTo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.redrawClaude(tab.name) }
        return view
    }

    private func newTab(pane: String? = nil, claude: Bool = false, beside: Tab? = nil, named base: String? = nil, command: [String]? = nil) {
        guard let selected = beside ?? selected else { return }
        zoomed[selected.group] = nil
        let pane = pane ?? self.pane(of: selected)
        if let host = selected.labels["host"] {
            guard !claude, command == nil else { return NSSound.beep() }
            let taken = Set(tabs.filter { $0.labels["host"] == host }.map(\.onHost))
            let name = (2...).lazy.map { "\(selected.group.dropFirst(host.count + 1))-\($0)" }.first { !taken.contains($0) }!
            arriving[host] = host + "/" + name
            return op(host, ["new", (tabs.first { $0.group == selected.group && self.pane(of: $0) == pane } ?? selected).onHost, name]) { [unowned self] in if !$0 { arriving[host] = nil } }
        }
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: zmxDir)) ?? []) + tabs.map(\.name))
        let name = base.flatMap { taken.contains($0) ? nil : $0 } ?? (2...).lazy.map { (base ?? selected.group) + "-\($0)" }.first { !taken.contains($0) }!
        commands[name] = command ?? (claude ? Self.claude(Self.bypass) : nil)
        select(insertTab(name, in: pane, beside: selected, cwd: selected.folder))
    }

    private static var bypass: String { UserDefaults.standard.bool(forKey: askKey) ? "" : "--dangerously-skip-permissions" }
    private static let program = probe.flatMap { FileManager.default.isExecutableFile(atPath: $0 + "/claude") ? $0 + "/claude" : nil } ?? "claude"
    private static let agy = (probe.map { [$0 + "/agy"] } ?? ["/opt/homebrew/bin/agy", "/usr/local/bin/agy"]).first(where: FileManager.default.isExecutableFile)
    private static func claude(_ args: String, program: String = program, env: String = "") -> [String] { ["zsh", "-lic", "exec env BUN_OPTIONS=--smol " + env + (UserDefaults.standard.bool(forKey: classicKey) ? "" : "CLAUDE_CODE_NO_FLICKER=1 ") + program + share(args) + (light ? " --settings " + quoted(lightTheme) + " " : " ") + args] }
    private static let lightTheme = #"{"theme":"light"}"#
    private static func share(_ args: String) -> String { args.contains("--mcp-config") || args.contains("--strict-mcp-config") ? "" : " $(" + quoted(executable) + " --share-flag)" }
    private static func quoted(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func resume(_ tab: Tab, _ session: String) -> String {
        tab.transcript.map { (try? Data(contentsOf: URL(fileURLWithPath: $0), options: .alwaysMapped))?.range(of: Data(#""type":"user""#.utf8)) != nil } == false ? "" : " --resume " + quoted(session)
    }
    private static func codeMode(_ transcript: String?) -> String {
        transcript.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0), options: .alwaysMapped) }?.range(of: Data(#""replMode":true"#.utf8)) == nil ? "" : "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE=1 "
    }
    private static func projects(_ folder: String) -> String { projectsDir + "/" + folder.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression) }
    private static let boot: Int = {
        var time = timeval(), size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &time, &size, nil, 0)
        return time.tv_sec
    }()

    @discardableResult private func insertTab(_ name: String, in pane: String, beside from: Tab, cwd: String) -> Tab {
        var labels = tabs.first { $0.group == from.group }!.labels
        labels["pane"] = pane
        labels["title"] = nil
        labels["viewer"] = nil
        labels["chat"] = nil
        labels["rank"] = nil
        let tab = Tab(name: name, group: from.group, cwd: cwd, labels: labels)
        let layout = layout(from.group)
        tabs.insert(tab, at: (tabs.lastIndex { $0.group == from.group && self.pane(of: $0, in: layout) == pane } ?? tabs.lastIndex { $0.group == from.group }!) + 1)
        return tab
    }

    private func split(_ pane: String, across: Bool, before: Bool = false) {
        guard let selected, let new = newPane(beside: pane, in: selected.group, across: across, before: before) else { return NSSound.beep() }
        newTab(pane: new)
    }

    private func newPane(beside pane: String, in group: String, across: Bool, before: Bool) -> String? {
        let layout = layout(group)
        let new = String((layout.panes.compactMap { Int($0) }.max() ?? 0) + 1)
        return label(group, "split", layout.splitting(pane, with: new, across: across, before: before).text, queued: true) ? new : nil
    }

    @objc private func fileAction(_ item: NSMenuItem) {
        guard let action = item.representedObject as? String else { return }
        if scratch.open, action == "close_surface" { return toggleScratch() }
        if action == "new_tab", let selected, !subTabs(tabs.filter { $0.group == selected.group }).isEmpty { return toggleScratch() }
        if action == "reopen" { return reopenTab() }
        if Chat.searches(action), let chat = selected.flatMap({ chats[$0.name] }) { return chat.find(action) }
        if action == "close_surface", let selected, !picked.isEmpty || !pickedTabs.isEmpty {
            return closing(picked.isEmpty ? chosen(selected.name) : tabs.filter { picked.contains($0.group) }.map(\.name), title: picked.isEmpty ? "Close tabs?" : "Close \(picked.count) groups?", ask: true)
        }
        guard let surface = selected.flatMap({ surfaces[$0.name]?.surface }) else { return }
        if action == "claude" { return newTab(claude: true) }
        if action == "agy", let agy = Self.agy { return newTab(command: ["zsh", "-lic", "exec " + Self.quoted(agy)]) }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @objc private func toggleSecure() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.secureKey), forKey: Self.secureKey)
        secure(NSApp.isActive)
    }

    @objc private func pickHotkey(_ item: NSMenuItem) {
        UserDefaults.standard.set(item.title == "Off" ? nil : item.title, forKey: Self.hotkeyKey)
        if !registerHotkey() { NSSound.beep() }
    }

    private func fillHotkeys(_ menu: NSMenu) {
        menu.removeAllItems()
        for title in ["Off"] + Self.keys.map(\.0) { menu.addItem(withTitle: title, action: #selector(pickHotkey), keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Record Shortcut…", action: #selector(recordHotkey), keyEquivalent: "")
    }

    @objc private func recordHotkey(_ item: NSMenuItem) {
        hotkey.map { _ = UnregisterEventHotKey($0) }
        hotkey = nil
        let alert = NSAlert()
        alert.messageText = "Type a Shortcut"
        alert.informativeText = "Hold ⌘, ⌥ or ⌃ with the key."
        Self.keyed(alert.addButton(withTitle: "Cancel"), "⎋")
        alert.buttons[0].keyEquivalent = "\u{1b}"
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned self] event in
            let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
            if event.keyCode == kVK_Escape && mods.isEmpty { return event }
            guard !mods.isDisjoint(with: [.control, .option, .command]) else { if probe == nil { NSSound.beep() }; return nil }
            let base = event.characters(byApplyingModifiers: []) ?? "", scalar = base.unicodeScalars.first?.value ?? 0
            let name = event.keyCode == kVK_Space ? "Space" : (NSF1FunctionKey...NSF20FunctionKey).contains(Int(scalar)) ? "F\(Int(scalar) - NSF1FunctionKey + 1)" : base.uppercased()
            let title = zip([NSEvent.ModifierFlags.control, .option, .shift, .command], ["⌃", "⌥", "⇧", "⌘"]).filter { mods.contains($0.0) }.map(\.1).joined() + name
            let carbon = zip([NSEvent.ModifierFlags.control, .option, .shift, .command], [controlKey, optionKey, shiftKey, cmdKey]).filter { mods.contains($0.0) }.reduce(0) { $0 | $1.1 }
            UserDefaults.standard.set([title, "\(event.keyCode)", "\(carbon)"], forKey: Self.recordedKey)
            UserDefaults.standard.set(title, forKey: Self.hotkeyKey)
            alert.window.sheetParent.map { $0.endSheet(alert.window, returnCode: .OK) } ?? NSApp.stopModal(withCode: .OK)
            return nil
        }
        let answer = { [unowned self] (response: NSApplication.ModalResponse) in
            monitor.map(NSEvent.removeMonitor)
            if response == .OK, let menu = item.menu { fillHotkeys(menu) }
            if !registerHotkey() { NSSound.beep() }
        }
        window.isVisible ? alert.beginSheetModal(for: window, completionHandler: answer) : answer(alert.runModal())
    }

    @discardableResult private func registerHotkey() -> Bool {
        hotkey.map { _ = UnregisterEventHotKey($0) }
        hotkey = nil
        guard probe == nil, let key = Self.keys.first(where: { $0.0 == UserDefaults.standard.string(forKey: Self.hotkeyKey) }) else { return true }
        guard RegisterEventHotKey(UInt32(key.1), UInt32(key.2), EventHotKeyID(signature: 0x43545459, id: 1), GetApplicationEventTarget(), 0, &hotkey) == noErr else {
            UserDefaults.standard.removeObject(forKey: Self.hotkeyKey)
            return false
        }
        return true
    }

    private func showOrHide(at pointer: NSPoint = NSEvent.mouseLocation) {
        if NSApp.isActive && !unseen { return NSApp.hide(nil) }
        if !window.styleMask.contains(.fullScreen), guide == nil, !window.isOnActiveSpace { summon() }
        if !window.styleMask.contains(.fullScreen), let now = room(window.frame), let to = screens.first(where: { $0.frame.contains(pointer) })?.room, to != now {
            let from = given ?? (window.frame, now)
            let frame = Self.fit(from.frame, from: from.room, to: to)
            fitted = frame
            window.setFrame(frame, display: false)
        }
        showWindow()
    }

    private func summon() {
        window.orderOut(nil)
        window.styleMask.insert(.nonactivatingPanel)
        window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    @objc private func pickSound(_ item: NSMenuItem) {
        let sound = item.representedObject as? String ?? ""
        UserDefaults.standard.set(sound, forKey: Self.soundKey)
        NSSound(named: sound)?.play()
    }

    private static func sounds(_ menu: NSMenu, action: Selector?) {
        for folder in ["/System/Library/Sounds", userSounds] {
            menu.addItem(.separator())
            for file in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() where !file.hasPrefix(".") {
                menu.addItem(withTitle: (file as NSString).deletingPathExtension, action: action, keyEquivalent: "").representedObject = (file as NSString).deletingPathExtension
            }
        }
        menu.addItem(.separator())
    }

    private static let userSounds = probe.map { $0 + "/sounds" } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Sounds").path

    @objc private func addSound(_ item: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        guard let url = probe.map({ URL(fileURLWithPath: (try? String(contentsOfFile: $0 + "/open", encoding: .utf8))?.trimmingCharacters(in: .newlines) ?? "") }) ?? (panel.runModal() == .OK ? panel.url : nil), let menu = item.menu else { return }
        let target = URL(fileURLWithPath: Self.userSounds).appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(atPath: Self.userSounds, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: url, to: target) }
        } catch { return tell("Couldn't add \(url.lastPathComponent).") }
        let name = url.deletingPathExtension().lastPathComponent
        let picked = menu.items.last { $0.representedObject as? String == name } ?? menu.insertItem(withTitle: name, action: #selector(pickSound), keyEquivalent: "", at: menu.index(of: item))
        picked.representedObject = name
        pickSound(picked)
    }

    @objc private func pickSpinner(_ item: NSMenuItem) {
        guard let pick = item.representedObject as? [String] else { return }
        let value = pick[1] != "toggle" ? pick[1] : Spark.settings[pick[0]] == "off" ? "on" : "off"
        Spark.settings[pick[0]] = value
        UserDefaults.standard.set(value, forKey: pick[0] + " " + zmxDir)
        rebuild()
        animate()
    }

    private func secure(_ active: Bool) {
        let on = active && UserDefaults.standard.bool(forKey: Self.secureKey)
        guard on != securing else { return }
        securing = on
        _ = on ? EnableSecureEventInput() : DisableSecureEventInput()
    }

    @objc private func toggleSort(_ sender: NSButton) {
        sender.enclosingMenuItem?.menu?.cancelTracking()
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.sortKey), forKey: Self.sortKey)
        rebuild()
    }

    private static var paneButtons: String { UserDefaults.standard.bool(forKey: buttonsKey) ? "Off" : BarHover.always ? "Always" : "On Hover" }

    @objc private func pickPaneButtons(_ item: NSMenuItem) {
        UserDefaults.standard.set(item.title == "Off", forKey: Self.buttonsKey)
        UserDefaults.standard.set(item.title == "On Hover", forKey: BarHover.hoverKey)
        rebuild()
    }

    @objc private func pickPaneMotion(_ item: NSMenuItem) { UserDefaults.standard.set(item.title, forKey: Self.motionKey) }

    @objc private func toggleScratch() {
        let shown = !scratch.open
        if shown, scratch.surface == nil {
            let folder = selected?.folder ?? NSHomeDirectory()
            let command = ["env", "ZMX_NO_DETACH_KEY=1", Self.executable, "--attach", "--labels", "", Scratch.name].map(Self.quoted).joined(separator: " ")
            scratch.start(SurfaceView(app: app!, command: command, cwd: folder), in: folder)
            paintScratch()
            Self.lister.async { [self] in
                guard let kept = Self.list().first(where: { $0["name"] == Scratch.name })?["cwd"].flatMap({ URL(string: $0)?.path }) else { return }
                DispatchQueue.main.async { self.scratch.place(kept) }
            }
        }
        scratch.show(shown)
        if !shown, let chat = selected.flatMap({ chats[$0.name] }) { return chat.takeKeys() }
        window.makeFirstResponder(shown ? scratch.surface : selected.flatMap { surfaces[$0.name] })
    }

    private func hideScratch() { if scratch.open { toggleScratch() } }

    @objc private func pickScratch(_ item: NSMenuItem) {
        UserDefaults.standard.set(item.title == "Floating" ? nil : item.title, forKey: Scratch.positionKey)
        scratch.needsLayout = true
    }

    @objc private func pickChatLook(_ item: NSMenuItem) {
        guard let look = item.representedObject as? String, look != Chat.look else { return }
        Chat.look = look
        UserDefaults.standard.set(look, forKey: Chat.lookKey)
        chats.values.forEach { $0.relook() }
    }

    @objc private func pickTheme(_ item: NSMenuItem) {
        UserDefaults.standard.set(item.title == "System" ? nil : item.title.lowercased(), forKey: Self.themeKey)
        theme()
    }

    private func theme() { NSApp.appearance = ["light": NSAppearance(named: .aqua), "dark": NSAppearance(named: .darkAqua)][UserDefaults.standard.string(forKey: Self.themeKey) ?? ""] ?? nil }

    private var lit: Bool?
    private func relight() {
        guard lit != Self.light, app != nil else { return }
        lit = Self.light
        relook()
        rebuild()
    }

    @objc private func pickLook(_ item: NSMenuItem) {
        guard var pick = item.representedObject as? [String: String] else { return }
        if pick.allSatisfy({ Self.look[$0] == $1 }), pick["cursor-style-blink"] != nil { pick = ["cursor-style-blink": "false"] }
        UserDefaults.standard.set((UserDefaults.standard.dictionary(forKey: Self.lookKey) ?? [:]).merging(pick) { $1 }, forKey: Self.lookKey)
        relook()
        refit()
    }

    private func relook() {
        guard let app, let config = Self.config() else { return }
        ghostty_app_update_config(app, config)
        ghostty_config_free(config)
        paint()
    }

    @objc private func openConfig() {
        let path = ghostty_config_open_path()
        defer { ghostty_string_free(path) }
        guard let start = path.ptr, path.len > 0 else { return }
        let file = URL(fileURLWithPath: String(decoding: UnsafeRawBufferPointer(start: start, count: Int(path.len)), as: UTF8.self))
        if let probe { return try! file.path.write(toFile: probe + "/opened", atomically: true, encoding: .utf8) }
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) else { return }
        NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func reloadConfig() {
        relook()
        refit()
    }

    @objc private func toggleLinks() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.linksKey), forKey: Self.linksKey) }
    @objc private func toggleRename() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.renameKey), forKey: Self.renameKey) }
    @objc private func toggleFollow() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.followKey), forKey: Self.followKey) }
    @objc private func toggleBypass() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.askKey), forKey: Self.askKey) }
    @objc private func toggleCode() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.codeKey), forKey: Self.codeKey) }
    @objc private func toggleClassic() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.classicKey), forKey: Self.classicKey) }
    private static func tabEnv() {
        _ = UserDefaults.standard.bool(forKey: classicKey) ? unsetenv("CLAUDE_CODE_NO_FLICKER") : setenv("CLAUDE_CODE_NO_FLICKER", "1", 1)
        _ = UserDefaults.standard.bool(forKey: codeKey) ? setenv("CLAUDE_CODE_EXPERIMENTAL_CODE_MODE", "1", 1) : unsetenv("CLAUDE_CODE_EXPERIMENTAL_CODE_MODE")
    }

    @objc private func toggleSleep() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.wakeKey), forKey: Self.wakeKey)
        tabs.map(\.name).forEach(nap)
    }

    private static func hours(_ title: String) -> Double { Double(title.prefix { $0.isNumber }) ?? 0 }

    @objc private func pickWarm(_ item: NSMenuItem) {
        UserDefaults.standard.set(Self.hours(item.title), forKey: Self.warmKey)
        tabs.map(\.name).forEach(warm)
    }

    @objc private func toggleShare() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Share.offKey), forKey: Share.offKey)
        resumeUpdatedClaude()
    }

    private func shareCrashed() {
        let names = Share.crashed(since: max(crashesSeen, Date().timeIntervalSince1970 - Share.crashes.within))
        guard names.count >= Share.crashes.count, !UserDefaults.standard.bool(forKey: Share.offKey) else { return }
        crashesSeen = Date().timeIntervalSince1970
        let list = ListFormatter.localizedString(byJoining: Set(names).sorted().map { $0 == "bridge" ? "the MCP bridge" : $0 })
        let alert = NSAlert()
        alert.messageText = "Shared MCP servers keep crashing"
        alert.informativeText = (list.hasPrefix("the") ? "T" + list.dropFirst() : list) + " crashed \(names.count) times in the last 10 minutes. With sharing off, each tab runs its own copy."
        for (title, key) in [("Turn Off Sharing", "↩"), ("Keep Sharing", "⎋")] { Self.keyed(alert.addButton(withTitle: title), key) }
        alert.buttons[1].keyEquivalent = "\u{1b}"
        let answer = { [unowned self] (response: NSApplication.ModalResponse) in if response == .alertFirstButtonReturn { toggleShare() } }
        window.isVisible ? alert.beginSheetModal(for: window, completionHandler: answer) : answer(alert.runModal())
    }
    private var crashesSeen = 0.0

    @objc private func toggleFreeSize() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.freeSizeKey), forKey: Self.freeSizeKey) }

    @objc private func toggleContext() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.contextKey), forKey: Self.contextKey)
        rebuild()
    }

    static func cap(_ text: String, _ limit: Int) -> String { text.count > limit ? text.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" : text }
    static func model(_ id: String) -> String {
        let parts = id.split(separator: "-").dropFirst().filter { $0.count < 8 } as [Substring]
        guard let family = parts.first, parts.dropFirst().allSatisfy({ Int($0) != nil }) else { return String(id.trimmingPrefix("claude-")) }
        return ([family.capitalized] + [parts.dropFirst().joined(separator: ".")]).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func tokens(_ count: Int) -> String { count < 1000 ? "\(count)" : count < 999_500 ? "\(Int((Double(count) / 1000).rounded()))k" : String(format: "%gM", (Double(count) / 100_000).rounded() / 10) }
    static func header(_ tabs: [Tab]) -> String {
        let saved = tabs.reduce(sharing(tabs)) { $0 + ($1.labels["sleep"] == nil ? 0 : Int64($1.labels["freed"] ?? "") ?? 0) }
        let active = tabs.count { $0.claude == "working" }
        return (tabs.count == 1 ? "1 tab" : "\(tabs.count) tabs") + (active > 0 ? ", \(active) active" : "") + (saved > 0 ? ", " + ByteCountFormatter.string(fromByteCount: saved, countStyle: .memory) + " saved" : "")
    }

    private static func sharing(_ tabs: [Tab]) -> Int64 {
        guard FileManager.default.fileExists(atPath: Share.dir + "/port") else { return 0 }
        let claudes = Share.users(), shells = Set(tabs.compactMap(\.pid))
        let counts = claudes.values.flatMap { $0 }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let sizes = Dictionary(uniqueKeysWithValues: counts.keys.filter { counts[$0]! > 1 }.compactMap { key in Share.server(key).map { (key, Double(footprint($0))) } })
        var saved = 0.0
        for (pid, keys) in claudes where sequence(first: pid, next: { info($0).map { Int32($0.pbi_ppid) }.flatMap { $0 > 1 ? $0 : nil } }).prefix(8).contains(where: shells.contains) {
            for key in keys { saved += (sizes[key] ?? 0) * Double(counts[key]! - 1) / Double(counts[key]!) }
        }
        return Int64(saved)
    }
    static func brief(_ tab: Tab) -> String? {
        guard let context = tab.context, let reply = tab.reply, let model = (reply["message"] as? [String: Any])?["model"] as? String else { return nil }
        let effort = (reply["effort"] as? String).flatMap { ["low": "(L)", "medium": "(M)", "high": "(H)", "xhigh": "(XH)", "max": "(Max)"][$0] }
        return [Self.model(model), effort, tokens(context) + "/" + tokens(window(reply))].compactMap { $0 }.joined(separator: " ")
    }
    static func window(_ reply: [String: Any]) -> Int {
        let name = model((reply["message"] as? [String: Any])?["model"] as? String ?? ""), version = Double(name.split(separator: " ").last ?? "") ?? 0
        return (reply["requestedModel"] as? String)?.hasSuffix("[1m]") == true || version >= 5 || name.hasPrefix("Opus") && version >= 4.7 ? 1_000_000 : 200_000
    }

    private static func summary(_ tab: Tab) -> String? {
        let memory = tab.pid.map { shell in footprint(info(shell).map { Int32($0.pbi_ppid) }.flatMap { $0 > 1 ? $0 : nil } ?? shell) } ?? 0
        let parts = [brief(tab), memory > 0 ? ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory) : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func meter(_ field: NSTextField, _ tab: Tab) {
        field.stringValue = tab.context.map(Self.tokens) ?? ""
        field.isHidden = field.stringValue.isEmpty
    }

    @objc private func paneButton(_ sender: NSButton) {
        let pane = sender.identifier!.rawValue
        switch sender.tag {
        case 0, 1: newTab(pane: pane, claude: sender.tag == 0)
        default: split(pane, across: sender.tag == 2)
        }
    }

    private static let paneIcons = [(clawd(nil), "New Claude tab", "New Claude tab (⌥⌘T)", clawd(Spark.orange)), (symbol("terminal"), "New terminal", "New terminal (⌘T)", nil), (symbol("square.split.2x1"), "Split right", "Split right (⌘D)", nil), (symbol("square.split.1x2"), "Split down", "Split down (⇧⌘D)", nil)]
    private func paneButtons(_ pane: String, shown: Bool) -> [NSView] {
        if UserDefaults.standard.bool(forKey: Self.buttonsKey) { return [] }
        return Self.paneIcons.enumerated().map { index, button in
            let view = Self.iconButton(button.0, button.1, button.2, self, #selector(paneButton), size: 12, lit: button.3 ?? button.0)
            view.alphaValue = shown || BarHover.always ? 1 : 0
            view.tag = index
            view.identifier = .init(pane)
            return view
        }
    }

    static func symbol(_ name: String) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: nil)! }

    static func iconButton(_ image: NSImage, _ label: String, _ tip: String, _ target: AnyObject, _ action: Selector, size: CGFloat = 13, lit: NSImage? = nil) -> NSButton {
        image.accessibilityDescription = label
        let button = lit.map { HoverButton(lit: $0, size: size) } ?? NSButton()
        button.image = image
        button.title = ""
        button.imagePosition = .imageOnly
        button.target = target
        button.action = action
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: size, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        return button
    }

    private func goTo(split target: ghostty_action_goto_split_e) {
        guard let selected else { return }
        if zoomed[selected.group] != nil {
            zoomed[selected.group] = nil
            rebuild()
            terminal.layoutSubtreeIfNeeded()
        }
        let layout = layout(selected.group), ids = layout.panes, from = pane(of: selected, in: layout)
        let step: (CGFloat, CGFloat)? = [GHOSTTY_GOTO_SPLIT_LEFT: (-1, 0), GHOSTTY_GOTO_SPLIT_RIGHT: (1, 0), GHOSTTY_GOTO_SPLIT_UP: (0, 1), GHOSTTY_GOTO_SPLIT_DOWN: (0, -1)][target]
        let to = step.map { neighbor(from, $0, in: ids) } ?? ids[(ids.firstIndex(of: from)! + (target == GHOSTTY_GOTO_SPLIT_NEXT ? 1 : ids.count - 1)) % ids.count]
        to.map { select(shownTab(selected.group, $0, in: layout)) }
    }

    private func neighbor(_ from: String, _ step: (CGFloat, CGFloat), in ids: [String]) -> String? {
        let center = { (id: String) in self.panes[id].map { $0.body.convert(NSPoint(x: $0.body.bounds.midX, y: $0.body.bounds.midY), to: nil) } ?? .zero }
        let origin = center(from)
        return ids.filter { id in (center(id).x - origin.x) * step.0 + (center(id).y - origin.y) * step.1 > 0 }
            .min { hypot(center($0).x - origin.x, center($0).y - origin.y) < hypot(center($1).x - origin.x, center($1).y - origin.y) }
    }

    @objc private func newGroup() { makeGroup(in: nil) }

    private func newFolder() {
        let name = Self.unused("FOLDER", Set(tabs.compactMap { $0.labels["folder"] }))
        makeGroup(in: name)
        rebuild()
        rename(folder: name)
    }

    private func makeGroup(in folder: String?, profile: String? = nil, at cwd: String? = nil, claude: Bool = false) {
        let cwd = cwd ?? selected?.folder ?? NSHomeDirectory()
        let base = (cwd as NSString).lastPathComponent.replacingOccurrences(of: " ", with: "-")
        let name = Self.unused(base, takenNames())
        let tab = Tab(name: name, group: name, cwd: cwd, labels: ["named": "0", "folder": folder, "profile": profile ?? shownProfile].compactMapValues { $0 })
        tabs.append(tab)
        commands[name] = claude ? Self.claude(Self.bypass) : nil
        select(tab)
    }

    @objc func newTabHere(_ board: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let folder = (board.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.resolvingSymlinksInPath().path else { return }
        let claude = userData == "claude"
        if let tab = tabs.first(where: { URL(fileURLWithPath: $0.folder).resolvingSymlinksInPath().path == folder }) {
            newTab(claude: claude, beside: tab)
        } else {
            makeGroup(in: nil, at: folder, claude: claude)
        }
        showWindow()
    }

    private func takenNames() -> Set<String> { Set(Self.list().compactMap { $0["name"] } + tabs.flatMap { [$0.name, $0.group] }) }

    private static func unused(_ base: String, _ taken: Set<String>) -> String { (1...).lazy.map { $0 == 1 ? base : base + "-\($0)" }.first { !taken.contains($0) }! }

    private func title(_ group: String) -> String {
        let first = tabs.first { $0.group == group }!
        return named(group) ? String(group.dropFirst(first.labels["host"].map { $0.count + 1 } ?? 0)) : first.title
    }

    private func named(_ group: String) -> Bool { tabs.first { $0.group == group }?.labels["named"].map { $0 == "1" } ?? !tabs.contains { $0.group == group && $0.name == group } }

    @objc private func toggleSidebar() {
        sidebarShown.toggle()
        saveSoon()
        toggles += 1
        rebuild()
        let show = sidebarShown, toggle = toggles, root = window.contentView!, moving: [NSView] = [side, edge, tabBar, terminal]
        let from = moving.map { $0.frame.minX + ($0.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0) }
        side.isHidden = false
        edge.isHidden = !show
        if show { sideWidth.constant = sidebarWidth }
        sideSlide.constant = show ? 0 : -sideWidth.constant
        root.layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1))
        CATransaction.setCompletionBlock { [unowned self] in if toggle == toggles, !show { side.isHidden = true } }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            root.layer?.add(CATransition(), forKey: "fade")
        } else {
            for (view, x) in zip(moving, from) where x != view.frame.minX {
                let slide = CABasicAnimation(keyPath: "transform.translation.x")
                slide.fromValue = x - view.frame.minX
                slide.toValue = 0
                view.layer?.add(slide, forKey: "slide")
            }
        }
        CATransaction.commit()
    }

    private func dragSidebar(to x: CGFloat, from start: CGFloat) {
        if (x >= Self.sidebarWidths.lowerBound / 2) != sidebarShown {
            sidebarWidth = sidebarShown ? start : max(x, Self.sidebarWidths.lowerBound)
            return toggleSidebar()
        }
        guard sidebarShown else { return }
        sidebarWidth = min(max(x, Self.sidebarWidths.lowerBound), Self.sidebarWidths.upperBound)
        sideWidth.constant = sidebarWidth
    }

    private func goTo(_ target: ghostty_action_goto_tab_e) {
        guard let selected else { return }
        if target == GHOSTTY_GOTO_TAB_NEXT || target == GHOSTTY_GOTO_TAB_PREVIOUS {
            let layout = layout(selected.group), pane = pane(of: selected, in: layout)
            let paneTabs = tabs.filter { $0.group == selected.group && self.pane(of: $0, in: layout) == pane }
            let index = paneTabs.firstIndex(of: selected)! + (target == GHOSTTY_GOTO_TAB_NEXT ? 1 : paneTabs.count - 1)
            return select(paneTabs[index % paneTabs.count])
        }
        let index = target == GHOSTTY_GOTO_TAB_LAST ? groups.count : Int(target.rawValue)
        guard (1...groups.count).contains(index) else { return }
        select(group: groups[index - 1])
    }

    private func select(group: String, keep: Bool = false) {
        let members = tabs.filter { $0.group == group }, awake = members.filter { $0.claude != "asleep" }
        let left = members.first { $0 == lastTab[group] } ?? members[0]
        select(left.claude != "asleep" || awake.isEmpty ? left : recent.lazy.compactMap { name in awake.first { $0.name == name } }.first ?? awake[0], keep: keep)
    }

    private var longestWaiting: Tab? {
        tabs.filter { $0 != selected && $0.claude == "waiting" }
            .map { (modified(statusDir + "/" + $0.name) ?? .distantFuture, $0) }
            .min { $0.0 < $1.0 }?.1
    }

    @objc private func nextWaiting() { longestWaiting.map { select($0) } }

    @objc private func goToTab() {
        guard let selected else { return }
        hideScratch()
        let ranked = tabs.map { tab in (tab == selected ? Int.max : recent.firstIndex(of: tab.name) ?? Int.max - 1, tab) }.sorted { $0.0 < $1.0 }.map(\.1)
        let counts = Dictionary(tabs.map { ($0.group, 1) }, uniquingKeysWith: +)
        let menus = (NSApp.mainMenu?.items.compactMap(\.submenu).filter { $0 !== groupsMenu } ?? []) + [tabRows[selected.name]?.contextMenu?()].compactMap { $0 }
        GoTo(ranked.map { tab in (tab, tab.from + (counts[tab.group]! > 1 ? "\(title(tab.group)) › \(tab.title)" : title(tab.group)), place(tab.frontFolder), colors.first { $0.name == tab.labels["color"] }?.color, Self.marked(tab)) }, commands: Self.commands(menus), in: terminal) { [unowned self] in select($0) }
    }

    private static func commands(_ menus: [NSMenu]) -> [GoTo.Command] {
        var seen: Set<String> = []
        func walk(_ menu: NSMenu, _ path: String, _ place: String) -> [GoTo.Command] {
            menu.update()
            return menu.items.flatMap { item -> [GoTo.Command] in
                let title = path.isEmpty ? item.title : path + " › " + item.title
                if let submenu = item.submenu { return walk(submenu, title, place) }
                guard !item.isHidden, !item.isSeparatorItem, !item.isSectionHeader, item.isEnabled, let action = item.action, action != #selector(goToTab), action != #selector(NSWindow.makeKeyAndOrderFront), seen.insert(title).inserted else { return [] }
                return [(item, title, place)]
            }
        }
        return menus.flatMap { walk($0, "", $0.title.isEmpty ? $0 === NSApp.mainMenu?.items.first?.submenu ? "ClaudeTTY" : "Tab" : $0.title) }
    }

    static func keys(_ item: NSMenuItem) -> String {
        let glyphs: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let key = item.keyEquivalent, names = ["\r": "↩", String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑", String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"]
        return key.isEmpty ? "" : glyphs.filter { item.keyEquivalentModifierMask.union(key == key.lowercased() ? [] : .shift).contains($0.0) }.map(\.1).joined() + (names[key] ?? key.uppercased())
    }

    @objc private func switchGroup(_ sender: NSButton) {
        let menu = NSMenu()
        let all = groups
        for (index, group) in all.enumerated() {
            let groupTabs = tabs.filter { $0.group == group }
            let item = groupItem(group, at: index, of: all.count, in: menu)
            item.view = GroupEntry(item, state: status(groupTabs).map { ([$0] + [agents(groupTabs)].compactMap { $0 }).joined(separator: "  ") }, place: place(groupTabs[0].frontFolder),
                                   bar: colors.first { $0.name == groupTabs[0].labels["color"] }?.color)
        }
        let width = menu.items.compactMap { $0.view?.frame.width }.max() ?? 0
        for item in menu.items { item.view?.frame.size.width = width }
        popUp(menu, at: NSPoint(x: 0, y: sender.bounds.maxY + 6), in: sender)
    }

    @discardableResult private func groupItem(_ group: String, at index: Int, of count: Int, in menu: NSMenu) -> NSMenuItem {
        let item = add(menu, title(group), #selector(pickGroup), group, key: Self.digitKey(index, of: count) ?? "")
        item.state = group == selected?.group ? .on : .off
        return item
    }

    private static func digitKey(_ index: Int, of count: Int) -> String? { index < 8 ? "\(index + 1)" : index == count - 1 ? "9" : nil }

    @objc private func pickGroup(_ item: NSMenuItem) {
        select(group: item.representedObject as! String)
        showWindow()
    }

    private static let sidebarWidths: ClosedRange<CGFloat> = 140...400
    private static let paneBar: CGFloat = 28
    private static let claudeMark = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
        let rays = NSBezierPath()
        for (index, length) in [6.5, 5, 6, 4.5, 6.5, 5.5, 4.5, 6, 5, 6.5, 4.5, 5.5].enumerated() {
            let angle = Double(index) * .pi / 6 + 0.2
            rays.move(to: NSPoint(x: rect.midX + cos(angle) * 1.5, y: rect.midY + sin(angle) * 1.5))
            rays.line(to: NSPoint(x: rect.midX + cos(angle) * length, y: rect.midY + sin(angle) * length))
        }
        rays.lineWidth = 1.6
        rays.lineCapStyle = .round
        Spark.orange.setStroke()
        rays.stroke()
        return true
    }
    private static func clawd(_ color: NSColor?) -> NSImage {
        let image = NSImage(size: NSSize(width: 17, height: 10), flipped: true) { _ in
            (color ?? .black).setFill()
            for (row, runs) in [[2...14], [2...3, 5...11, 13...14], [0...16], [2...14], [2...2, 4...4, 12...12, 14...14]].enumerated() {
                for run in runs { NSRect(x: run.lowerBound, y: row * 2, width: run.count, height: 2).fill() }
            }
            return true
        }
        image.isTemplate = color == nil
        return image
    }

    private var shownProfile: String? { selected?.labels["profile"] }

    private var profiles: [String?] { tabs.reduce(into: [String?]()) { if !$0.contains($1.labels["profile"]) { $0.append($1.labels["profile"]) } }.sorted { ($0 ?? "").localizedStandardCompare($1 ?? "") == .orderedAscending } }

    private static func title(profile: String?) -> String { profile ?? "Profile 1" }

    private func latest(in profile: String?) -> Tab? {
        let members = tabs.filter { $0.labels["profile"] == profile }
        return recent.lazy.compactMap { name in members.first { $0.name == name } }.first ?? members.first
    }

    private var items: [(key: String, pinned: Bool, groups: [String])] {
        let profile = shownProfile, firsts = tabs.reduce(into: [Tab]()) { found, tab in if tab.labels["profile"] == profile, !found.contains(where: { $0.group == tab.group }) { found.append(tab) } }
        var states: [String: Int] = [:]
        if UserDefaults.standard.bool(forKey: Self.sortKey) {
            for tab in tabs { states[tab.group] = min(states[tab.group] ?? 2, ["waiting": 0, "working": 1][tab.claude ?? ""] ?? 2) }
        }
        for tab in firsts { if let name = tab.labels["folder"] { states["\t" + name] = min(states["\t" + name] ?? 2, states[tab.group] ?? 2) } }
        func ranked(_ entries: [(key: String, pinned: String?, order: String?)]) -> [String] {
            entries.map { ($0.pinned == nil ? 1 : 0, states[$0.key] ?? 2, Int($0.order ?? "") ?? .max, $0.key) }.sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }.map(\.3)
        }
        let inside = ranked(firsts.map { ($0.group, $0.labels["pinned"], $0.labels["order"]) })
        let tops = firsts.reduce(into: [(key: String, pinned: String?, order: String?)]()) { found, tab in
            let name = tab.labels["folder"], key = name.map { "\t" + $0 } ?? tab.group
            if !found.contains(where: { $0.key == key }) { found.append(name == nil ? (key, tab.labels["pinned"], tab.labels["order"]) : (key, tab.labels["folderpinned"], tab.labels["folderorder"])) }
        }
        let pins = Dictionary(uniqueKeysWithValues: tops.map { ($0.key, $0.pinned != nil) })
        return ranked(tops).map { key in (key, pins[key]!, key.hasPrefix("\t") ? inside.filter { "\t" + (folder($0) ?? "") == key } : [key]) }
    }

    private var groups: [String] { items.flatMap(\.groups) }

    private func peers(_ key: String) -> [String] {
        let pinned = { (group: String) in self.tabs.first { $0.group == group }?.labels["pinned"] != nil }
        if let name = key.hasPrefix("\t") ? nil : folder(key) { return items.first { $0.key == "\t" + name }!.groups.filter { pinned($0) == pinned(key) } }
        let pin = items.first { $0.key == key }!.pinned
        return items.filter { $0.pinned == pin }.map(\.key)
    }

    private func label(folder name: String, _ key: String, _ value: String) {
        for group in groups where folder(group) == name && tabs.first(where: { $0.group == group })?.labels[key] != (value.isEmpty ? nil : value) { label(group, key, value) }
    }

    private func folder(_ group: String) -> String? { tabs.first { $0.group == group }?.labels["folder"] }

    private func shown(_ group: String) -> Bool {
        guard let folder = folder(group), collapsed.contains(folder) else { return true }
        return group == selected?.group || tabs.contains { $0.group == group && $0.claude == "waiting" }
    }

    private var picked: Set<String> = []
    private var pickedTabs: Set<String> = []
    private var pickAnchor: String?

    private func pick(_ key: String, range: Bool, tab: Bool = false) {
        guard let selected else { return }
        let current = tab ? selected.name : selected.group
        let rows = tab ? barTabs(selected.group) : groups.filter(shown)
        var chosen = tab ? pickedTabs : picked
        if chosen.isEmpty { pickAnchor = nil }
        if range, let from = rows.firstIndex(of: pickAnchor ?? current), let to = rows.firstIndex(of: key) {
            chosen = Set(rows[min(from, to)...max(from, to)])
        } else if key != current {
            if chosen.isEmpty { chosen = [current] }
            if chosen.remove(key) == nil { chosen.insert(key) }
            pickAnchor = key
        }
        chosen.insert(current)
        (picked, pickedTabs) = chosen.count < 2 ? ([], []) : tab ? ([], chosen) : (chosen, [])
        rebuild()
    }

    private func unpick() {
        guard !picked.isEmpty || !pickedTabs.isEmpty else { return }
        (picked, pickedTabs) = ([], [])
        rebuild()
    }

    private func barTabs(_ group: String) -> [String] {
        let layout = layout(group)
        return layout.panes.flatMap { id in tabs.filter { $0.group == group && pane(of: $0, in: layout) == id }.map(\.name) }
    }

    private func chosen(_ name: String) -> [String] { pickedTabs.contains(name) ? barTabs(selected!.group).filter(pickedTabs.contains) : [name] }

    private var collapsed: Set<String> {
        get { Set((UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []).map { $0.uppercased() }) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.collapsedKey) }
    }

    private func rebuild() {
        guard let selected, editing == nil, Row.lifted == nil else { return }
        rebuilds += 1
        fronts = front
        for tab in tabs where tab.claude != nil {
            guard let front = tab.pid.flatMap(foreground), claudeExits[front] == nil else { continue }
            claudeExits[front] = Self.onExit(front) { [unowned self] in
                claudeExits[front] = nil
                rebuild()
            }
        }
        activities = [:]
        tabSparks = [:]
        tabRings = [:]
        meters = [:]
        tabRows = [:]
        let shownPills = folderBadges.compactMapValues(\.pill)
        folderBadges = [:]
        groupRows = [:]
        folderRows = [:]
        picked.formIntersection(groups)
        pickedTabs.formIntersection(tabs.filter { $0.group == selected.group }.map(\.name))
        if picked.count < 2 { picked = [] }
        if pickedTabs.count < 2 { pickedTabs = [] }
        let closed = collapsed
        sidebar.setViews(items.flatMap { item -> [NSView] in
            let head = item.key.hasPrefix("\t") ? folderRow(String(item.key.dropFirst()), open: !closed.contains(String(item.key.dropFirst())), pinned: item.pinned, was: shownPills[String(item.key.dropFirst())]) : nil
            let rows = item.groups.filter(shown).map { group -> Row in
                let folder = folder(group)
                let groupTabs = tabs.filter { $0.group == group }
                let pinned = groupTabs[0].labels["pinned"] != nil
                let sparks = activity(groupTabs).map { activity in
                    let view = ActivityView(selected: group == selected.group, single: activity.sparks.count == 1, width: sidebarWidth - 36 - (folder == nil ? 0 : Self.folderIndent), open: { [unowned self] name in tabs.first { $0.name == name }.map { select($0) } }) { [unowned self] in agentsMenu(groupTabs) }
                    view.openWorker = { [unowned self] worker in
                        if let tab = tabs.first(where: { worker.task == ["tab", $0.name] }) { select(tab) } else { openTask(worker.task, of: worker.owner) }
                    }
                    view.show(activity)
                    activities[group] = view
                    return view
                }
                let row = Row(title(group), icon: pinned ? NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned") : nil, activity: sparks, detail:place(groupTabs[0].frontFolder), pull: pullLabel(groupTabs[0], selected: group == selected.group || picked.contains(group)) + changesLabel(groupTabs[0], selected: group == selected.group || picked.contains(group)), bar: colors.first { $0.name == groupTabs[0].labels["color"] }?.color, selected: group == selected.group || picked.contains(group), fill: group == selected.group ? .controlAccentColor : .controlAccentColor.withAlphaComponent(0.45),
                              close: { [unowned self] in closing(group: group) }) { [unowned self] in
                    select(group: group, keep: picked.contains(group))
                }
                row.clicked = { [unowned self] in unpick() }
                row.contextMenu = { [unowned self] in picked.contains(group) ? pickedMenu() : groupMenu(group, pinned: pinned) }
                row.picking = { [unowned self] range in pick(group, range: range) }
                row.rename = { [unowned self] in rename(group) }
                row.lane = folder.flatMap(closed.contains) == true ? nil : (pinned ? "pinned" : "groups") + (folder.map { " in " + $0 } ?? "")
                row.dropped = { [unowned self] to in reorder(group, to: to) }
                row.aim = { [unowned self] point in home(at: point, for: group).flatMap { folderRows[$0] } }
                row.carried = { [unowned self] point in
                    guard let name = home(at: point, for: group) else { return false }
                    refolder(picked.contains(group) ? groups.filter(picked.contains) : [group], to: name)
                    return true
                }
                groupRows[group] = row
                if groupTabs[0].labels["host"].flatMap({ unreachable[$0] }) != nil { row.alphaValue = 0.45 }
                return row
            }
            head?.block = rows
            return [head].compactMap { $0 } + rows
        }, in: .top)
        let nested = Set(groupRows.filter { folder($0.key) != nil }.values.map(ObjectIdentifier.init))
        for row in sidebar.views { row.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: nested.contains(ObjectIdentifier(row)) ? -Self.folderIndent : 0).isActive = true }
        if let reason = selected.labels["host"].flatMap({ unreachable[$0] }) {
            let caption = NSTextField(wrappingLabelWithString: reason)
            caption.font = .systemFont(ofSize: 12)
            caption.textColor = .secondaryLabelColor
            let line = NSStackView(views: [caption])
            line.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 0, right: 12)
            sidebar.addView(line, in: .top)
            line.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
        Row.space(sidebar)
        if folderIcon?.folder != selected.folder {
            let icon = NSWorkspace.shared.icon(forFile: selected.folder)
            folderIcon = (selected.folder, NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16)); return true })
        }
        window.title = title(selected.group)
        let named = named(selected.group) || tabs.count(where: { $0.group == selected.group }) > 1
        let title = TitleButton(title: window.title, target: self, action: #selector(switchGroup))
        title.image = folderIcon?.image
        title.imagePosition = .imageLeading
        title.isBordered = false
        title.font = TitleButton.font
        title.contentTintColor = .labelColor
        title.toolTip = "Switch group (⌘1-9)"
        title.cell?.lineBreakMode = .byClipping
        let layout = layout(selected.group), focused = pane(of: selected, in: layout)
        let before = arrange(layout)
        let rows = { [unowned self] (pane: String) -> [NSView] in
            let paneTabs = tabs.filter { $0.group == selected.group && self.pane(of: $0, in: layout) == pane }
            let pick = shownTab(selected.group, pane, in: layout)
            if pane == focused { paneRows = [] }
            return paneTabs.map { tab in
                let lone = paneTabs.count == 1
                let spark = Self.marked(tab).map { Spark($0, phase: 0, selected: false, key: tab.name, mark: tab.mark) }
                spark?.cold = activities[tab.group]?.cold(tab.name) ?? false
                tabSparks[tab.name] = spark
                let meter = tab.claude != nil && !UserDefaults.standard.bool(forKey: Self.contextKey) ? NSTextField(labelWithString: "") : nil
                meter.map { self.meter($0, tab) }
                meters[tab.name] = meter
                let ring = progresses[tab.name].map { ProgressRing($0.report) }
                tabRings[tab.name] = ring
                let extra = pickedTabs.contains(tab.name) && tab != selected
                let row = Row(named ? tab.title : "", icon: tab.claude != nil || !named || ring != nil ? nil : NSImage(systemSymbolName: "apple.terminal.fill", accessibilityDescription: "Shell"), spark: spark ?? ring, meter: meter, selected: lone || tab == pick || extra, fill: extra ? .controlAccentColor.withAlphaComponent(0.2) : lone ? .clear : pane == focused ? Row.pickFill : Row.hoverFill,
                              close: lone && layout.panes.count == 1 ? nil : { [unowned self] in closing([tab.name]) }) { [unowned self] in select(tab, keep: pickedTabs.contains(tab.name)) }
                row.picking = { [unowned self] range in self.pick(tab.name, range: range, tab: true) }
                row.clicked = { [unowned self] in unpick() }
                row.contextMenu = { [unowned self] in tabMenu(tab, paneTabs.map(\.name), layout) }
                tabRows[tab.name] = row
                if pane == focused { paneRows.append(row) }
                row.rename = { [unowned self, unowned row] in rename(tab: tab.name, in: row) }
                row.lane = "tabs"
                row.dropped = { [unowned self] to in
                    let names = chosen(tab.name)
                    for name in names where !paneTabs.contains(where: { $0.name == name }) { label(tab.group, "pane", pane, tab: name) }
                    reorder(Self.placed(names, dragged: tab.name, in: paneTabs.map(\.name), to: to))
                    rebuild()
                }
                row.carried = { [unowned self] point in carry(chosen(tab.name), dragged: tab.name, to: point) }
                row.aim = { [unowned self] point in groupRows.first { $0.key != tab.group && under($0.value, point) }?.value }
                return row
            }
        }
        let single = layout.panes.count == 1
        let crumb = BarIcon()
        tabBar.setViews([title] + (single && named ? [crumb] : []) + (single ? rows(focused) : []), in: .leading)
        tabBar.setCustomSpacing(6, after: title)
        tabBar.crumb = single && named ? crumb : nil
        switches = [:]
        titleButtons.setViews(single ? chatSwitch(shownTab(selected.group, focused, in: layout)) + paneButtons(focused, shown: titleHover.inside) : [], in: .leading)
        for (id, pane) in panes {
            pane.bar?.setViews(rows(id), in: .leading)
            pane.bar.map { $0.setViews(chatSwitch(shownTab(selected.group, id, in: layout)) + paneButtons(id, shown: $0.hover.inside), in: .trailing) }
        }
        before.map(slide)
        animate()
        marks()
        lookAt()
        if hidden { menuBarIcon() }
        groupsMenu.removeAllItems()
        let all = groups
        for (index, group) in all.enumerated() { groupItem(group, at: index, of: all.count, in: groupsMenu) }
        groupsMenu.addItem(.separator())
        let paneTabs = tabs.filter { $0.group == selected.group && pane(of: $0, in: layout) == focused }
        for (index, tab) in paneTabs.enumerated() {
            let item = add(groupsMenu, tab.title, #selector(pickTab), tab.name, key: Self.digitKey(index, of: paneTabs.count) ?? "")
            item.keyEquivalentModifierMask = .control
            item.state = tab == selected ? .on : .off
        }
        if paneTabs.count < 9, let last = groupsMenu.items.last?.copy() as? NSMenuItem {
            last.keyEquivalent = "9"
            last.isHidden = true
            last.allowsKeyEquivalentWhenHidden = true
            groupsMenu.addItem(last)
        }
        if !pills.isEmpty { showHints() }
    }

    private func place(_ folder: String) -> String {
        [(folder as NSString).abbreviatingWithTildeInPath, Self.branch(folder)].compactMap { $0 }.joined(separator: "  ")
    }

    private func status(_ groupTabs: [Tab]) -> String? {
        let states = groupTabs.map(\.claude)
        guard let state = (["waiting", "working", "background", "idle"] as [String]).first(where: { states.contains($0) }) else { return nil }
        let names = zip(groupTabs, states).filter { $0.1 == state }.map(\.0.name)
        return groupTabs.count < 2 || state == "idle" ? state : state + ": " + names.joined(separator: ", ")
    }

    private func subTabs(_ groupTabs: [Tab]) -> [Tab] { groupTabs.filter { tab in groupTabs.contains { $0.name == tab.labels["opener"] } } }

    private func agents(_ groupTabs: [Tab]) -> String? {
        let count = groupTabs.map { $0.tasks.filter { $0[0] == "agent" }.count }.reduce(0, +)
        return count == 0 ? nil : count == 1 ? "1 sub" : "\(count) subs"
    }

    private func activity(_ groupTabs: [Tab]) -> Activity? {
        let claudes = groupTabs.compactMap { tab in tab.claude.map { (tab: tab, state: $0) } }
        guard !claudes.isEmpty else { return nil }
        let line = claudes.compactMap { tab, state -> (name: String, who: String, what: String, ask: Bool, at: Date, ago: String, thinking: Bool)? in
            if state == "background", let shell = tab.tasks.filter({ $0[0] == "shell" }).max(by: { Double($0[2]) ?? 0 < Double($1[2]) ?? 0 }) {
                let start = Date(timeIntervalSince1970: Double(shell[2]) ?? 0)
                return (tab.name, tab.title, "Waiting on " + shell[3], false, start, Self.ago(start), false)
            }
            return state == "idle" || state == "asleep" ? nil : tab.action.map { (tab.name, tab.title, state == "waiting" ? $0.ask ?? $0.text : $0.text == "Thinking" ? verb(tab, $0.at) : $0.text, state == "waiting", $0.at, "", state == "working" && ["Thinking", "Writing"].contains($0.text)) }
        }.filter { !$0.what.isEmpty }.max { ($0.ask ? 1 : 0, $0.ask ? $1.at : $0.at) < ($1.ask ? 1 : 0, $1.ask ? $0.at : $1.at) }
        let stop = line?.ask == true ? nil : claudes.filter { $0.state == "idle" }.compactMap { tab, _ in Self.stopped(tab).map { (tab: tab, words: $0.words, until: $0.until, limit: !$0.until.isEmpty, at: $0.at) } }.max { $0.at < $1.at }
        let done = line == nil && stop == nil ? claudes.filter { $0.state == "idle" }.compactMap { tab, _ in reply(tab).map { (name: tab.name, who: tab.title, what: $0.text, at: $0.at) } }.max { $0.at < $1.at } : nil
        lazy var store = Self.warmStore()
        let subTabs = subTabs(groupTabs).map {
            Worker(task: ["tab", $0.name], owner: $0.name, folder: $0.folder, name: $0.title, doing: $0.action?.text ?? "", ask: nil, working: $0.claude == "working")
        }
        return Activity(sparks: claudes.map { .init(name: $0.tab.name, title: $0.tab.title, state: Self.marked($0.tab) ?? $0.state, mark: $0.tab.mark, cold: cold($0.tab, store)) }, name: stop?.tab.name ?? line?.name ?? done?.name ?? "", who: stop?.tab.title ?? line?.who ?? done?.who ?? "", what: stop?.words ?? line?.what ?? done?.what ?? "", ask: stop.map { !$0.limit } ?? line?.ask ?? false,
                        ago: stop.map { $0.limit ? $0.until : Self.ago($0.at) } ?? line?.ago ?? done.map { Self.ago($0.at) } ?? "", agents: subTabs.isEmpty ? agents(groupTabs) : nil, workers: subTabs.isEmpty ? [] : groupTabs.flatMap(\.workers) + subTabs, thinking: line?.thinking ?? false)
    }

    private func verb(_ tab: Tab, _ at: Date) -> String {
        if let cached = verbs[tab.name], cached.at == at { return (cached.verb ?? "Thinking") + "…" }
        let screen = String(decoding: Self.zmxOutput("history", tab.name) ?? Data(), as: UTF8.self).split(separator: "\n").suffix(12)
        let verb = screen.reversed().lazy.compactMap { $0.firstMatch(of: #/^\S ([\p{L} ]+)… \(/#)?.1 }.first.map(String.init)
        verbs[tab.name] = (at, verb)
        if verb == nil, tails[tab.name] == nil {
            let tail = Process(), pipe = Pipe()
            tail.executableURL = URL(fileURLWithPath: zmx)
            tail.arguments = ["tail", tab.name]
            tail.standardOutput = pipe
            pipe.fileHandleForReading.readabilityHandler = { [unowned self] handle in
                handle.readabilityHandler = nil
                DispatchQueue.main.async { [unowned self] in
                    tails.removeValue(forKey: tab.name)?.terminate()
                    guard verbs[tab.name]?.at == at else { return }
                    verbs[tab.name] = nil
                    redraw(tab.group)
                }
            }
            if (try? tail.run()) != nil { tails[tab.name] = tail }
        }
        return (verb ?? "Thinking") + "…"
    }

    static func marked(_ tab: Tab) -> String? {
        guard tab.claude == "idle", let stop = stopped(tab) else { return tab.claude }
        return stop.until.isEmpty ? "error" : "limited"
    }

    static func stopped(_ tab: Tab) -> (words: String, until: String, at: Date)? {
        guard let path = tab.transcript, let last = lastMessages(path).first(where: { $0["type"] as? String == "assistant" }), last["isApiErrorMessage"] as? Bool == true,
              let text = (((last["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String), let at = modified(path) else { return nil }
        if let hit = text.firstMatch(of: #/hit your \w+ limit . resets (.+?)(?: \(|$)/#) { return ("Limited", "until " + hit.1, at) }
        let words = text.localizedCaseInsensitiveContains("overloaded") ? "Overloaded" : text.contains("ENOTFOUND") || text.contains("Connection") ? "No connection" : text.contains("authenticate") ? "Signed out" : text.contains("output token") ? "Reply too long" : "API error"
        return (words, "", at)
    }

    private func reply(_ tab: Tab) -> (text: String, at: Date)? {
        guard let path = tab.transcript, let stamp = modified(path) else { return nil }
        if let cached = replies[path], cached.stamp == stamp { return cached.reply }
        let found = lastMessages(path).lazy.compactMap { message -> (text: String, at: Date)? in
            guard message["type"] as? String == "assistant", let block = ((message["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first, block["type"] as? String == "text",
                  let first = (block["text"] as? String)?.split(whereSeparator: \.isNewline).lazy.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*-`> ")) }).first(where: { !$0.isEmpty }),
                  let at = (message["timestamp"] as? String).flatMap(stamps.date) else { return nil }
            return (first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: ""), at)
        }.first
        replies[path] = (stamp, found)
        return found
    }

    static func ago(_ at: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(at) / 60)
        return minutes < 1 ? "now" : minutes < 60 ? "\(minutes)m" : minutes < 1440 ? "\(minutes / 60)h" : "\(minutes / 1440)d"
    }

    private func statusSoon() {
        guard !statusPending else { return }
        statusPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [unowned self] in
            statusPending = false
            statusChanged()
            resumeUpdatedClaude()
            tabs.map(\.name).forEach(nap)
        }
    }
    private var statusPending = false

    private func statusChanged() {
        readNotices()
        watchTranscripts()
        guard front == fronts else { return rebuild() }
        if hidden { menuBarIcon() }
        activities.keys.forEach(redraw)
        for tab in tabs {
            tabSparks[tab.name]?.kind = Self.marked(tab) ?? ""
            tabSparks[tab.name]?.mark = tab.mark
            meters[tab.name].map { meter($0, tab) }
        }
        animate()
    }

    private var front: [String] {
        let all = groups
        return tabs.map { ($0.claude == nil ? "" : "✻ ") + $0.folder } + all + all.filter(shown)
    }

    private func redraw(_ group: String) {
        for tab in tabs where tab.group == group { chats[tab.name]?.refresh() }
        let activity = activity(tabs.filter { $0.group == group })
        activity.map { activities[group]?.show($0) }
        for tab in tabs where tab.group == group {
            let spark = activity?.sparks.first { $0.name == tab.name }
            tabSparks[tab.name]?.kind = spark?.state ?? ""
            tabSparks[tab.name]?.mark = spark?.mark
            tabSparks[tab.name]?.cold = spark?.cold ?? false
        }
    }

    private func watchTranscripts() {
        let paths = Dictionary(uniqueKeysWithValues: tabs.filter { $0.claude != nil }.compactMap { tab in tab.transcript.map { (tab.name, $0) } })
        if paths.contains(where: { transcripts[$0.key]?.path != $0.value }) { saveSoon() }
        for (name, old) in transcripts where paths[name] != old.path {
            old.watch.cancel()
            transcripts[name] = nil
        }
        for (name, path) in paths where transcripts[name] == nil {
            let file = Darwin.open(path, O_EVTONLY)
            guard file >= 0 else { continue }
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: file, eventMask: .write, queue: .main)
            watch.setEventHandler { [unowned self] in
                tabs.first { $0.name == name }.map { redraw($0.group) }
                animate()
                nap(name)
            }
            watch.setCancelHandler { Darwin.close(file) }
            watch.resume()
            transcripts[name] = (path, watch)
        }
    }

    private func animate() {
        let live = Spark.style == "simple" && drawing && (sidebarShown && activities.values.contains { $0.moving } || tabSparks.values.contains { $0.moving })
        guard live != (spinner != nil) else { return }
        spinner?.invalidate()
        spinner = live ? Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [unowned self] _ in
            let held = { (key: String) in self.unreachable.keys.contains { key.hasPrefix($0 + "/") } }
            for (group, view) in activities where !held(group) { view.spin() }
            turn += 1
            for (name, spark) in tabSparks where !held(name) { spark.spin(turn) }
        } : nil
    }


    private func readNotices(fresh: Bool = true) {
        var read: [String: Notice] = [:]
        for tab in tabs {
            let path = statusDir + "/" + tab.name + ".notice", host = tab.labels["host"] != nil
            guard let at = host ? tab.labels["noticed"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) : modified(path), dismissed[tab.name] != at else { continue }
            if let old = notices[tab.name], old.at == at {
                read[tab.name] = old
            } else if fresh && (tab.labels["notify"] == "0" || tab == selected && !away) {
                dismissed[tab.name] = at
                try? FileManager.default.removeItem(atPath: path)
            } else if let text = host ? tab.labels["notice"] : try? String(contentsOfFile: path, encoding: .utf8) {
                read[tab.name] = Notice(text: text, at: at, bannered: !fresh)
            }
        }
        guard read != notices else { return }
        withdraw(notices.keys.filter { read[$0] == nil })
        notices = read
        banner()
        marks()
        lookAt()
    }

    private var unseen: Bool { !window.isVisible }
    private var away: Bool { !active || unseen || probe == nil && CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!) > 120 }
    private var active: Bool { probe.map { FileManager.default.fileExists(atPath: $0 + "/active") } ?? NSApp.isActive }

    private func banner() {
        guard let newest = notices.filter({ !$0.value.bannered }).max(by: { $0.value.at < $1.value.at }) else { return }
        let wait = 2 - Date().timeIntervalSince(lastBanner)
        guard wait <= 0 else {
            retryBanner = retryBanner ?? Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [unowned self] _ in
                retryBanner = nil
                banner()
            }
            return
        }
        for name in notices.keys { notices[name]?.bannered = true }
        lastBanner = Date()
        post(tabs.first { $0.name == newest.key }.map { $0.from + $0.title } ?? newest.key, newest.value.text, tab: newest.key)
    }

    private func post(_ title: String, _ text: String, tab: String? = nil) {
        let sound = tab == nil ? "" : UserDefaults.standard.string(forKey: Self.soundKey) ?? "Glass"
        if let probe {
            let posted = (try? String(contentsOfFile: probe + "/banner", encoding: .utf8)) ?? ""
            try? (posted + title + "\t" + text + "\t" + sound + "\n").write(toFile: probe + "/banner", atomically: true, encoding: .utf8)
            return
        }
        NSSound(named: sound)?.play()
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = text
            content.userInfo = tab.map { ["tab": $0] } ?? [:]
            center.add(UNNotificationRequest(identifier: tab ?? "update", content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let name = response.notification.request.content.userInfo["tab"] as? String
        DispatchQueue.main.async { [self] in
            tabs.first { $0.name == name }.map { select($0) }
            showWindow()
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) { done(.banner) }

    private func marks() {
        NSApp.dockTile.badgeLabel = notices.isEmpty ? nil : String(notices.count)
        for (folder, dot) in folderBadges { dot.isHidden = !unread(folder) }
        guard let selected else { return }
        let layout = layout(selected.group)
        for (id, pane) in panes {
            pane.body.subviews.filter { $0 is Ring }.forEach { $0.removeFromSuperview() }
            let names = tabs.filter { $0.group == selected.group && notices[$0.name] != nil && self.pane(of: $0, in: layout) == id }.map(\.name)
            guard !names.isEmpty else { continue }
            let ring = Ring(frame: pane.body.bounds)
            ring.setAccessibilityLabel(names.joined(separator: ", "))
            pane.body.addSubview(ring)
        }
    }

    private func lookAt() {
        guard active, let name = selected?.name, notices[name] != nil else {
            look?.timer.invalidate()
            look = nil
            return
        }
        guard look?.tab != name else { return }
        look?.timer.invalidate()
        look = (name, Date(), Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [unowned self] _ in
            guard let since = look?.since else { return }
            if away { look?.since = Date() } else if Date().timeIntervalSince(since) >= 1 { clear(name) }
        })
    }

    private static func answered(_ tab: Tab) {
        guard tab.claude == "waiting" else { return }
        let call = tab.transcript.map(lastMessages)?.lazy.compactMap { (($0["message"] as? [String: Any])?["content"] as? [[String: Any]])?.last { $0["type"] as? String == "tool_use" }?["name"] as? String }.first
        guard !["AskUserQuestion", "ExitPlanMode"].contains(call ?? "") else { return }
        let path = statusDir + "/" + tab.name
        if (try? FileManager.default.removeItem(atPath: path + ".asked")) != nil { try? FileManager.default.removeItem(atPath: path + ".notice") }
        try? "working".write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func clear(_ name: String) {
        guard let notice = notices.removeValue(forKey: name) else { return }
        dismissed[name] = notice.at
        try? FileManager.default.removeItem(atPath: statusDir + "/" + name + ".notice")
        withdraw([name])
        marks()
        lookAt()
    }

    private func withdraw(_ names: [String]) {
        if probe == nil, Bundle.main.bundleIdentifier != nil, !names.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: names) }
    }

    @objc private func sleepTab(_ item: NSMenuItem) { (item.representedObject as! [String]).forEach(sleep) }

    @objc private func forkTab(_ item: NSMenuItem) {
        guard let tab = tabs.first(where: { $0.name == item.representedObject as? String }), let session = tab.session, let front = tab.pid.flatMap(foreground) else { return }
        let base = tab.name.replacingOccurrences(of: "-[0-9]+$", with: "", options: .regularExpression)
        let resume = Self.resume(tab, session)
        newTab(beside: tab, named: base, command: Self.claude(Self.flags(Self.arguments(front)) + resume + (resume.isEmpty ? "" : " --fork-session"), env: Self.codeMode(tab.transcript)))
    }

    private func resumeItem(_ tab: Tab) -> NSMenuItem {
        let dir = Self.projects(tab.folder)
        let open = Set(tabs.compactMap(\.session)), clock = Date.FormatStyle(date: .abbreviated, time: .shortened), menu = NSMenu()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") && !open.contains(String($0.dropLast(6))) }
        for (file, date) in files.compactMap({ file in modified(dir + "/" + file).map { (file, $0) } }).sorted(by: { $0.1 > $1.1 }) where menu.items.count < 15 {
            guard let named = Self.named(dir + "/" + file), let name = named.title ?? named.prompt else { continue }
            let item = add(menu, Self.cap(name, 50) + " (\(date.formatted(clock)))", #selector(resumeSession), (tab.name, dir + "/" + file, name))
            item.subtitle = named.title == nil ? nil : named.prompt.map { Self.cap($0, 60) }
            item.toolTip = named.prompt
        }
        let resume = item("Resume Session", nil)
        resume.submenu = menu.items.isEmpty ? nil : menu
        return resume
    }

    private static func named(_ path: String) -> (title: String?, prompt: String?)? {
        guard let file = FileHandle(forReadingAtPath: path), let end = try? file.seekToEnd() else { return nil }
        defer { try? file.close() }
        try? file.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        var title: String?, prompt: String?
        for line in (try? file.readToEnd())?.split(separator: UInt8(ascii: "\n")) ?? [] {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if (row["entrypoint"] as? String)?.hasPrefix("sdk") == true { return nil }
            title = row["customTitle"] as? String ?? title
            prompt = row["lastPrompt"] as? String ?? prompt
        }
        return (title, prompt)
    }

    @objc private func resumeSession(_ item: NSMenuItem) {
        let (name, path, title) = item.representedObject as! (String, String, String), id = String((path as NSString).lastPathComponent.dropLast(6))
        guard let tab = tabs.first(where: { $0.name == name }) else { return }
        let base = title.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(3).joined(separator: "-")
        newTab(beside: tab, named: base.isEmpty ? nil : base, command: Self.claude(Self.bypass + " --resume " + Self.quoted(id), env: Self.codeMode(path)))
    }

    private func awake(_ tab: Tab) -> Bool { tab.labels["awake"] != nil || groupAwake(tab.group) }
    private func groupAwake(_ group: String) -> Bool { tabs.first { $0.group == group }?.labels["groupawake"] != nil }

    @objc private func keepAwake(_ item: NSMenuItem) {
        let (group, names, key) = item.representedObject as! (String, [String], String)
        let on = names.isEmpty ? !groupAwake(group) : !tabs.filter { names.contains($0.name) }.allSatisfy { $0.labels[key] != nil }
        for tab in names.isEmpty ? [nil] : names.map(Optional.some) { label(group, key, on ? "1" : "", tab: tab) }
        for each in tabs where each.group == group { nap(each.name) }
        rebuild()
    }

    private func nap(_ name: String) {
        let tab = tabs.first { $0.name == name }, claude = tab?.claude
        if let tab, let wake = woken[name], asked(tab, since: tab.transcript == wake.path ? wake.from : 0) { woken[name] = nil }
        guard let tab, !UserDefaults.standard.bool(forKey: Self.wakeKey), !awake(tab), !(tab.pid.flatMap(foreground).map(Self.bridged) ?? false), !placed.isEmpty, !placed.contains(name), claude == "idle", tab.listed.isEmpty,
              let due = woken[name].map({ $0.left + minute / 2 }) ?? tab.transcript.flatMap(modified).map({ $0 + 20 * minute }) else {
            naps.removeValue(forKey: name)?.invalidate()
            return
        }
        guard due > Date() else {
            naps[name] = nil
            if emptyPrompt(name) { sleep(name) }
            return
        }
        guard naps[name]?.fireDate != due else { return }
        naps[name]?.invalidate()
        naps[name] = Timer(fire: due, interval: 0, repeats: false) { [unowned self] _ in nap(name) }
        RunLoop.main.add(naps[name]!, forMode: .common)
    }
    private var naps: [String: Timer] = [:]
    private var woken: [String: (left: Date, path: String?, from: UInt64)] = [:]

    private func asked(_ tab: Tab, since offset: UInt64) -> Bool {
        guard let path = tab.transcript, let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        try? file.seek(toOffset: offset)
        guard let tail = try? file.readToEnd() else { return false }
        return tail.range(of: Data(#""type":"user""#.utf8)) != nil || tail.range(of: Data(#""operation":"enqueue""#.utf8)) != nil
    }

    private func sleep(_ name: String) {
        if let tab = tabs.first(where: { $0.name == name }), let host = tab.labels["host"] { return op(host, ["sleep", tab.onHost]) }
        guard let index = tabs.firstIndex(where: { $0.name == name }), let session = tabs[index].session, let front = tabs[index].pid.flatMap(foreground) else { return }
        let tab = tabs[index], words = Self.arguments(front)
        woken[name] = nil
        commands[tab.name] = Self.claude(Self.relaunch(front) + Self.resume(tab, session), program: Self.quoted(words[0]), env: Self.codeMode(tab.transcript))
        let peer = json(NSHomeDirectory() + "/.claude/sessions/\(front).json")?["name"] as? String
        let freed = tab.pid.map { Self.footprint($0) } ?? 0
        tabs[index] = Tab(name: tab.name, group: tab.group, cwd: tab.folder, labels: tab.labels.merging(["sleep": peer ?? "1", "freed": "\(freed)"]) { $1 }, ended: tab.pid)
        try? "asleep".write(toFile: statusDir + "/" + tab.name, atomically: true, encoding: .utf8)
        save()
        Self.end(tab.name, shell: tab.pid)
        surfaces.removeValue(forKey: tab.name)?.removeFromSuperview()
        rebuild()
        saveSoon()
        warm(name)
    }

    private func warm(_ name: String) {
        warms.removeValue(forKey: name)?.invalidate()
        let store = Self.warmStore(), hours = UserDefaults.standard.double(forKey: Self.warmKey)
        let slept = modified(statusDir + "/" + name)
        guard let tab = tabs.first(where: { $0.name == name }), tab.labels["sleep"] != nil, let session = tab.session,
              let deadline = store["deadline:" + session].map({ Date(timeIntervalSince1970: $0 / 1000) }) ?? slept.flatMap({ hours > 0 ? $0 + hours * 60 * minute : nil }) else { return }
        let last = warmed(tab, session, store), due = last + 49 * minute
        guard last + 60 * minute > Date(), due < deadline else { return }
        warms[name] = Timer(fire: max(due, Date()), interval: 0, repeats: false) { [unowned self] _ in
            warms[name] = nil
            guard let tab = tabs.first(where: { $0.name == name }), tab.labels["sleep"] != nil, tab.session == session else { return }
            ping(tab, session)
        }
        RunLoop.main.add(warms[name]!, forMode: .common)
    }
    private let minute = probe == nil ? 60.0 : 0.1

    private func warmed(_ tab: Tab, _ session: String, _ store: [String: Double]) -> Date {
        let message = (tab.reply?["timestamp"] as? String).flatMap(stamps.date) ?? .distantPast
        return [store["last:" + session].map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast, message, warmedAt[tab.name] ?? .distantPast].max()!
    }

    private func cold(_ tab: Tab, _ store: @autoclosure () -> [String: Double]) -> Bool {
        guard ["idle", "asleep"].contains(tab.claude), let session = tab.session else { return false }
        let written = ((tab.reply?["message"] as? [String: Any])?["usage"] as? [String: Any])?["cache_creation"] as? [String: Int] ?? [:]
        let lifetime = written["ephemeral_5m_input_tokens", default: 0] > 0 && written["ephemeral_1h_input_tokens", default: 0] == 0 ? 5.0 : 60
        return warmed(tab, session, store()) + lifetime * minute < Date()
    }
    private var warms: [String: Timer] = [:]
    private var warmedAt: [String: Date] = [:]

    private func ping(_ tab: Tab, _ session: String) {
        let reply = tab.reply, message = reply?["message"] as? [String: Any], model = message?["model"] as? String, effort = reply?["effort"] as? String
        let prefix = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + ((message?["usage"] as? [String: Any])?[$1] as? Int ?? 0) }
        let args = ["-p", "--resume", session, "--fork-session", "--no-session-persistence", "--max-turns", "1", "--settings", #"{"disableAllHooks":true}"#, "--output-format", "json"]
            + (model.map { ["--model", $0] } ?? []) + (effort.map { ["--effort", $0] } ?? []) + ["Reply with the single word: warm"]
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "exec env BUN_OPTIONS=--smol " + Self.program + Self.share("") + " \"$@\" </dev/null", "zsh"] + args
        process.currentDirectoryURL = URL(fileURLWithPath: reply?["cwd"] as? String ?? tab.folder)
        process.environment = ProcessInfo.processInfo.environment.filter { !["CLAUDE_PID", "CLAUDE_CODE_CHILD_SESSION", "ZMX_SESSION"].contains($0.key) }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            let usage = ((try? JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile())) as? [String: Any])?["usage"] as? [String: Any]
            let read = usage?["cache_read_input_tokens"] as? Int ?? 0
            DispatchQueue.main.async { [unowned self] in
                let ok = prefix > 0 && Double(read) >= 0.9 * Double(prefix)
                let line = "\(stamps.string(from: Date())) \(tab.name) \(session) \(model ?? "default") \(effort ?? "") read \(read) of \(prefix) \(ok ? "warm" : "failed")\n"
                if let log = FileHandle(forWritingAtPath: Self.warmLog) ?? (FileManager.default.createFile(atPath: Self.warmLog, contents: nil) ? FileHandle(forWritingAtPath: Self.warmLog) : nil) {
                    log.seekToEndOfFile()
                    log.write(Data(line.utf8))
                    try? log.close()
                }
                guard ok else { return }
                warmedAt[tab.name] = Date()
                saveSoon()
                warm(tab.name)
            }
        }
        try? process.run()
    }
    static let warmLog = (statusDir as NSString).deletingLastPathComponent + "/warm.log"

    private static func cacheTax() -> [String: Any]? { cacheTaxFile().flatMap { reread($0, json) } }
    private static func cacheTaxFile() -> String? { reread(storeDir) { try? FileManager.default.contentsOfDirectory(atPath: $0) }?.first { $0.hasPrefix("cache-tax_") && $0.hasSuffix(".json") }.map { storeDir + "/" + $0 } }
    private var armed: [String: (deadline: Double, left: TimeInterval)] = [:]
    private static let until = { let format = DateFormatter(); format.setLocalizedDateFormatFromTemplate("hmm"); return format }()
    private static func warmStore() -> [String: Double] { cacheTax()?.compactMapValues { $0 as? Double } ?? [:] }

    @objc private func toggleReadonly(_ item: NSMenuItem) {
        let chosen = tabs.filter { (item.representedObject as! [String]).contains($0.name) }, on = !chosen.allSatisfy { $0.labels["readonly"] != nil }
        for tab in chosen where (tab.labels["readonly"] != nil) != on {
            if let view = surfaces[tab.name] { view.binding("toggle_readonly") } else { label(tab.group, "readonly", on ? "1" : "", tab: tab.name) }
        }
    }

    @objc private func mute(_ item: NSMenuItem) {
        let chosen = tabs.filter { (item.representedObject as! [String]).contains($0.name) }, muted = chosen.allSatisfy { $0.labels["notify"] == "0" }
        for tab in chosen { label(tab.group, "notify", muted ? "" : "0", tab: tab.name) }
    }

    private func agentsMenu(_ groupTabs: [Tab]) -> NSMenu {
        let menu = NSMenu()
        let clock = Date.FormatStyle(date: .omitted, time: .shortened)
        let item = { [unowned self] (title: String, task: [String], tab: Tab, detail: String) in
            let item = add(menu, Self.cap(title, 60), #selector(openTask(_:)), (tab.name, task))
            item.toolTip = title
            item.subtitle = [Date(timeIntervalSince1970: Double(task[2]) ?? 0).formatted(clock), Self.cap(detail, 60)].filter { !$0.isEmpty }.joined(separator: "  ")
        }
        var shells: [(Tab, [String])] = []
        for tab in groupTabs {
            let tasks = tab.tasks
            shells += tasks.filter { $0[0] == "shell" }.map { (tab, $0) }
            let agents = tasks.filter { $0[0] == "agent" }
            guard !agents.isEmpty else { continue }
            menu.addItem(.sectionHeader(title: [tab.name, tab.context.map(Self.tokens)].compactMap { $0 }.joined(separator: "  ")))
            for agent in agents {
                let meta = Self.meta(agent), rows = lastMessages(agent[3]), finished = meta["finished"] as? Bool == true
                let reply = rows.first { (($0["message"] as? [String: Any])?["model"] as? String)?.hasPrefix("claude") == true }, message = reply?["message"] as? [String: Any]
                let usage = message?["usage"] as? [String: Any]
                let context = usage.map { usage in ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) } }
                let tool = rows.lazy.compactMap { (($0["message"] as? [String: Any])?["content"] as? [[String: Any]])?.last { $0["type"] as? String == "tool_use" }?["name"] as? String }.first
                let stopped = tab.claude == "asleep" || tab.session.map { !agent[3].contains("/\($0)/") } == true
                let moved = modified(agent[3]) ?? Date()
                let state = finished ? "done" : stopped ? "stopped" : moved.timeIntervalSinceNow > -60 ? "active" : "quiet " + Self.ago(moved)
                let model = [(message?["model"] as? String).map(Self.model), reply?["effort"] as? String].compactMap { $0 }.joined(separator: " ")
                item([meta["agentType"] as? String, meta["description"] as? String ?? agent[1]].compactMap { $0 }.joined(separator: "  "), agent, tab,
                     [model, context.map(Self.tokens) ?? "", finished || stopped ? "" : tool ?? "", state].filter { !$0.isEmpty }.joined(separator: "  "))
            }
        }
        if !shells.isEmpty {
            menu.addItem(.sectionHeader(title: "shells"))
            for (tab, shell) in shells { item(shell[3], shell, tab, "") }
        }
        return menu
    }

    @objc private func openTask(_ item: NSMenuItem) {
        if let (owner, task) = item.representedObject as? (String, [String]) { openTask(task, of: owner) }
    }
    private func openTask(_ task: [String], of owner: String) {
        guard let tab = tabs.first(where: { $0.name == owner }) else { return }
        let name = owner + "-" + task[1].prefix(8)
        select(tab)
        if let open = tabs.first(where: { $0.name == name }) { return select(open) }
        guard let pane = newPane(beside: pane(of: tab), in: tab.group, across: true, before: false) else { return NSSound.beep() }
        commands[name] = task[0] == "agent" ? ["sh", "-c", "tail -n +1 -F \"$0\" | /usr/bin/jq --unbuffered -rR \"$1\"", task[3], Self.transcriptView]
            : ["sh", "-c", "f=$(ls /private/tmp/claude-$(id -u)/*/*/tasks/\"$0\".output 2>/dev/null | head -1); [ -n \"$f\" ] && exec tail -n +1 -F \"$f\"; echo No output yet.", task[1]]
        insertTab(name, in: pane, beside: tab, cwd: tab.folder)
        let index = tabs.firstIndex { $0.name == name }!
        tabs[index].labels["title"] = task[0] == "agent" ? Self.meta(task)["agentType"] as? String ?? "agent" : "shell"
        tabs[index].labels["viewer"] = "1"
        select(tabs[index])
    }
    private static let transcriptView = #"""
        fromjson? | select(.type == "user" or .type == "assistant") | .message.content
        | if type == "string" then "\u001b[2m> \(.)\u001b[0m\n" else .[]
          | if .type == "text" then .text + "\n"
            elif .type == "tool_use" then "\u001b[32m●\u001b[0m \(.name)(\(.input | .file_path
            elif .type == "tool_result" then "  \u001b[2m⎿ \(.content | if type == "array" then map(.text?
            else empty end end
        """#

    @objc private func pickTab(_ item: NSMenuItem) {
        if let tab = tabs.first(where: { $0.name == item.representedObject as? String }) { select(tab) }
        showWindow()
    }

    private func item(_ title: String, _ action: Selector?, _ object: Any? = nil, key: String = "") -> NSMenuItem {
        let item = title == "-" ? NSMenuItem.separator() : NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = object
        return item
    }

    @discardableResult private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ object: Any? = nil, key: String = "") -> NSMenuItem {
        let made = item(title, action, object, key: key)
        menu.addItem(made)
        return made
    }

    private func groupMenu(_ group: String, pinned: Bool) -> NSMenu {
        let menu = NSMenu(), groupTabs = tabs.filter { $0.group == group }
        menu.addItem(.sectionHeader(title: Self.header(groupTabs)))
        let paired = remote(group)
        let awake = !paired && groupTabs.contains { $0.claude != nil } ? groupAwake(group) : nil
        let pullShown = groupTabs[0].labels["pr"] == nil, pullable = !paired && (!pullShown || Self.gh != nil && Self.pullBranch(groupTabs[0].frontFolder) != nil)
        let checked = awake == true || pullable && pullShown
        let rows = { [unowned self] (rowTabs: ArraySlice<Tab>, into: NSMenu) in
            for tab in rowTabs {
                let row = add(into, Self.cap(tab.title, 48), #selector(pickTab), tab.name)
                if let info = Self.brief(tab) { row.view = InfoRow(row.title, info: info, inset: checked ? 30 : 16) }
            }
        }
        rows(groupTabs.prefix(15), menu)
        if groupTabs.count > 15 {
            let more = NSMenu()
            rows(groupTabs.dropFirst(15), more)
            menu.addItem(withTitle: "\(groupTabs.count - 15) More", action: nil, keyEquivalent: "").submenu = more
        }
        menu.addItem(.separator())
        addOwn(menu, group, inset: checked ? 27 : 13, pinned: pinned, color: groupTabs.first?.labels["color"]) {
            if let awake { add(menu, "Keep Awake", #selector(keepAwake), (group, [String](), "groupawake")).state = awake ? .on : .off }
            if pullable { add(menu, "PR Status", #selector(setLabel), ([group], "pr", pullShown ? "off" : "")).state = pullShown ? .on : .off }
            if !paired { folderMenu(menu, [group]) }
            profileMenu(menu, [group])
        }
        let others = tabs.contains { $0.group != group && $0.labels["pinned"] == nil && $0.labels["profile"] == shownProfile }
        for (title, action) in [("-", nil), ("Close Group", #selector(closeGroup)), ("Close Other Groups", others ? #selector(closeOthers) : nil)] {
            add(menu, title, action, group)
        }
        return menu
    }

    private func pickedMenu() -> NSMenu {
        let menu = NSMenu(), chosen = groups.filter(picked.contains), pinned = chosen.allSatisfy { group in tabs.first { $0.group == group }?.labels["pinned"] != nil }
        add(menu, pinned ? "Unpin Groups" : "Pin Groups", #selector(setLabel), (chosen, "pinned", pinned ? "" : "1"))
        if !chosen.contains(where: remote) { folderMenu(menu, chosen) }
        profileMenu(menu, chosen)
        menu.addItem(.separator())
        let colored = Set(chosen.map { group in tabs.first { $0.group == group }?.labels["color"] })
        addColors(menu, chosen, current: colored.count == 1 ? colored.first! : nil, inset: 13)
        menu.addItem(.separator())
        add(menu, "Close \(chosen.count) Groups", #selector(closeGroups), chosen)
        return menu
    }

    private func folderMenu(_ menu: NSMenu, _ chosen: [String]) {
        let homes = Set(chosen.map(folder)), shared = homes.count == 1 ? homes.first! : nil
        let folders = groups.compactMap(folder).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let submenu = NSMenu()
        for (title, target) in folders.filter { $0 != shared }.map({ ($0, Optional($0)) }) + [("New Folder", nil)] + (homes == [nil] ? [] : [(shared.map { "Out of \($0)" } ?? "Out of Folders", Optional(""))]) {
            add(submenu, title, #selector(moveToFolder), (chosen, target))
        }
        menu.addItem(withTitle: "Move to Folder", action: nil, keyEquivalent: "").submenu = submenu
    }

    private func profileMenu(_ menu: NSMenu, _ chosen: [String]) {
        guard !chosen.contains(where: remote) else { return }
        let submenu = NSMenu(), shown = shownProfile
        for profile in profiles where !tabs.contains(where: { $0.labels["profile"] == profile && $0.labels["host"] != nil }) {
            let item = add(submenu, Self.title(profile: profile), profile == shown ? nil : #selector(moveToProfile), (chosen, Optional(profile ?? "")))
            item.state = profile == shown ? .on : .off
        }
        add(submenu, "New Profile", #selector(moveToProfile), (chosen, String?.none))
        menu.addItem(withTitle: "Move to Profile", action: nil, keyEquivalent: "").submenu = submenu
    }

    @objc private func moveToProfile(_ item: NSMenuItem) {
        let (chosen, target) = item.representedObject as! ([String], String?)
        let shown = shownProfile, name = target ?? (2...).lazy.map { "Profile \($0)" }.first { name in !self.profiles.contains(name) }!
        for group in chosen { label(group, "profile", name) }
        picked = []
        if let selected, chosen.contains(selected.group) { select(latest(in: shown) ?? selected) } else { rebuild() }
    }

    private func profileItems(_ menu: NSMenu) {
        menu.addItem(withTitle: "New Profile", action: #selector(newProfile), keyEquivalent: "").target = self
        if !Self.held { menu.addItem(withTitle: "Add Mac…", action: #selector(addMac), keyEquivalent: "").target = self }
        let all = profiles
        guard all.count > 1 else { return }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Profiles"))
        for profile in all {
            let item = add(menu, Self.title(profile: profile), #selector(showProfile), profile ?? "")
            item.state = profile == shownProfile ? .on : .off
            item.image = tabs.contains { $0.labels["profile"] == profile && $0.claude == "waiting" } ? TabStrip.waitingDot : nil
            if let profile, let hop = unreachable[profile] {
                let text = NSMutableAttributedString(string: item.title + "    ", attributes: [.font: NSFont.menuFont(ofSize: 0)])
                text.append(NSAttributedString(string: hop.replacingOccurrences(of: " on " + profile, with: "").replacingOccurrences(of: profile + " ", with: ""), attributes: [.font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
                item.attributedTitle = text
            }
        }
    }

    @objc private func newProfile() { makeGroup(in: nil, profile: (2...).lazy.map { "Profile \($0)" }.first { name in !self.profiles.contains(name) }!) }

    @objc private func showProfile(_ item: NSMenuItem) {
        let profile = item.representedObject as! String
        latest(in: profile.isEmpty ? nil : profile).map { select($0) }
    }


    private static let pairedKey = "paired macs " + zmxDir
    private static var paired: [String: [String]] { UserDefaults.standard.dictionary(forKey: pairedKey) as? [String: [String]] ?? [:] }

    static func ssh(_ host: String, _ words: [String]) -> [String] {
        let socket = NSTemporaryDirectory() + "ct-" + SHA256.hash(data: Data(([host] + (paired[host] ?? [])).joined(separator: "\0").utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
        return ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ControlMaster=auto", "-o", "ControlPersist=60", "-o", "ControlPath=" + socket] + (words.first == "attach" ? ["-tt", "-q"] : []) + (paired[host] ?? []) + words.map(encoded)
    }

    @discardableResult private static func run(_ host: String, _ words: [String], output: Pipe? = nil, errors: Pipe? = nil, then: ((Process) -> Void)? = nil) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Array(ssh(host, words).dropFirst())
        (process.standardInput, process.standardOutput, process.standardError) = (FileHandle.nullDevice, output.map { $0 as Any } ?? FileHandle.nullDevice, errors.map { $0 as Any } ?? FileHandle.nullDevice)
        process.terminationHandler = then
        return (try? process.run()).map { process }
    }

    private func remote(_ group: String) -> Bool { tabs.first { $0.group == group }?.labels["host"] != nil }

    private var links: [String: Process] = [:]
    private var listing: [String: Bool] = [:]
    private var arriving: [String: String] = [:]
    private var unreachable: [String: String] = [:]

    static func hop(_ host: String, _ said: String) -> String {
        let address = paired[host]?.last ?? host
        let hops = [("could not resolve", "Can't find \(address)"), ("refused", "Remote Login is off on \(host)"), ("permission denied", "\(host) no longer lets this Mac in"), ("identification has changed", "\(host) is not the Mac this one paired with"), ("not found", "ClaudeTTY isn't on \(host)")]
        return hops.first { said.lowercased().contains($0.0) }?.1 ?? "\(host) is asleep or off the network"
    }

    private func connect(_ host: String) {
        let pipe = Pipe()
        pipe.fileHandleForReading.readabilityHandler = { [unowned self] handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil } else { DispatchQueue.main.async { self.relist(host) } }
        }
        let errors = Pipe()
        links[host] = Self.run(host, ["watch"], output: pipe, errors: errors) { [unowned self] process in
            let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async { [self] in
                guard links[host] === process else { return }
                let hop = Self.hop(host, said)
                if unreachable.updateValue(hop, forKey: host) != hop { rebuild() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in if links[host] === process { connect(host) } }
            }
        }
    }

    private static let support = probe ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/ClaudeTTY").path
    private static let authorizedKeys = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/authorized_keys").path
    private static let served = "restrict,pty,command=\"~/.local/bin/claudetty-serve --serve claudetty:"

    static func guests() -> [(id: String, name: String)] {
        ((try? String(contentsOfFile: authorizedKeys, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            guard line.hasPrefix(served), let end = line.dropFirst(served.count).firstIndex(of: "\"") else { return nil }
            let fields = line[end...].split(separator: " ", maxSplits: 3)
            return (String(line[line.index(line.startIndex, offsetBy: served.count)..<end]), fields.count == 4 ? String(fields[3]) : "")
        }
    }

    static func revoke(_ id: String) -> String? {
        let file = URL(fileURLWithPath: authorizedKeys).resolvingSymlinksInPath().path, draft = file + ".claudetty"
        guard id.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil else { return "has no Mac \(id)" }
        guard let old = FileManager.default.contents(atPath: file) else { return nil }
        let tag = Data((served + id + "\" ").utf8)
        let new = Data(old.split(separator: 10, omittingEmptySubsequences: false).filter { !$0.starts(with: tag) }.joined(separator: [10]))
        guard new != old else { return nil }
        let mode = (try? FileManager.default.attributesOfItem(atPath: file))?[.posixPermissions] ?? 0o600
        guard FileManager.default.createFile(atPath: draft, contents: new, attributes: [.posixPermissions: mode]), FileManager.default.contents(atPath: draft) == new, Darwin.rename(draft, file) == 0 else {
            try? FileManager.default.removeItem(atPath: draft)
            return "couldn't rewrite \(file)"
        }
        return nil
    }

    private func pair(_ address: String, user: String, password: String, then: @escaping (String?) -> Void) {
        let key = Self.support + "/remote", known = Self.support + "/known_hosts"
        let parts = address.split(separator: ":"), host = String(parts.first ?? ""), reached = ["-o", "UserKnownHostsFile=" + known, "-l", user] + (parts.count == 2 ? ["-p", String(parts[1])] : []) + [host]
        DispatchQueue.global(qos: .userInitiated).async { [unowned self] in
            func run(_ tool: String, _ args: [String], input: String = "", env: [String: String] = [:]) -> (status: Int32, out: String, said: String) {
                let process = Process(), output = Pipe(), errors = Pipe(), feed = Pipe()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = args
                process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
                (process.standardInput, process.standardOutput, process.standardError) = (feed, output, errors)
                guard (try? process.run()) != nil else { return (127, "", "") }
                feed.fileHandleForWriting.write(Data(input.utf8))
                try? feed.fileHandleForWriting.close()
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                return (process.terminationStatus, out, said)
            }
            if !FileManager.default.fileExists(atPath: key) { _ = run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "", "-f", key]) }
            let pub = ((try? String(contentsOfFile: key + ".pub", encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).prefix(2).joined(separator: " ")
            let id = SHA256.hash(data: Data(pub.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let script = """
            read -r line; f=~/.ssh/authorized_keys
            [ -x ~/.local/bin/claudetty-serve ] || { echo "claudetty-serve: not found" >&2; exit 3; }
            [ -d ~/.ssh ] || mkdir -m 700 ~/.ssh
            grep -qxF "$line" "$f" 2>/dev/null || { if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then echo >> "$f"; fi; printf "%s\\n" "$line" >> "$f"; }
            grep -qxF "$line" "$f" && scutil --get ComputerName
            """
            let line = Self.served + id + "\" " + pub + " " + (Host.current().localizedName ?? "Mac")
            let done = pub.isEmpty ? (status: 1, out: "", said: "") : run("/usr/bin/ssh", ["-o", "StrictHostKeyChecking=accept-new", "-o", "NumberOfPasswordPrompts=1", "-o", "ConnectTimeout=10"] + reached + ["/bin/sh -c '" + script + "'"],
                                                       input: line + "\n", env: ["SSH_ASKPASS": Self.executable, "SSH_ASKPASS_REQUIRE": "force", "CLAUDETTY_ASKPASS": password])
            let name = done.out.split(separator: "\n").last.map(String.init) ?? ""
            DispatchQueue.main.async { [self] in
                guard done.status == 0, !name.isEmpty else {
                    let said = done.said.lowercased()
                    return then(said.contains("permission denied") ? "That password didn't work for \(user) on \(host)." : Self.hop(host, said) + (said.contains("refused") ? ". Turn it on in its System Settings > General > Sharing." : "."))
                }
                var all = UserDefaults.standard.dictionary(forKey: Self.pairedKey) ?? [:]
                all[name] = ["-i", key, "-o", "IdentitiesOnly=yes"] + reached
                UserDefaults.standard.set(all, forKey: Self.pairedKey)
                links.removeValue(forKey: name)?.terminate()
                connect(name)
                then(nil)
            }
        }
    }

    private var adding: (alert: NSAlert, fields: [NSTextField], problem: NSTextField)?

    @objc private func addMac(_ sender: Any?) {
        let fields = [NSTextField(string: ""), NSTextField(string: NSUserName()), NSSecureTextField(string: "")]
        fields[0].placeholderString = "Name or address"
        let grid = NSGridView(views: zip(["Mac", "User", "Password"], fields).map { title, field in
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
            return [label, field]
        })
        (grid.rowSpacing, grid.columnSpacing, grid.rowAlignment) = (8, 8, .firstBaseline)
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.font = .systemFont(ofSize: 11)
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = grid.fittingSize.width
        problem.isHidden = true
        let form = NSStackView(views: [grid, problem])
        (form.orientation, form.alignment, form.spacing) = (.vertical, .leading, 8)
        form.frame.size = form.fittingSize
        let alert = NSAlert()
        alert.messageText = "Add Mac"
        alert.informativeText = "That Mac's tabs, shells included, open on this one."
        alert.accessoryView = form
        for (title, key) in [("Add Mac", "↩"), ("Cancel", "⎋")] { Self.keyed(alert.addButton(withTitle: title), key) }
        alert.buttons[1].keyEquivalent = "\u{1b}"
        (alert.buttons[0].target, alert.buttons[0].action) = (self, #selector(addingMac))
        adding = (alert, fields, problem)
        alert.beginSheetModal(for: window) { [unowned self] _ in adding = nil }
        alert.window.makeFirstResponder(fields[0])
    }

    @objc private func addingMac(_ button: NSButton) {
        guard let sheet = adding else { return }
        let (alert, fields, problem) = sheet
        let address = fields[0].stringValue.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return NSSound.beep() }
        button.isEnabled = false
        pair(address, user: fields[1].stringValue, password: fields[2].stringValue) { [unowned self] failure in
            button.isEnabled = true
            guard let failure else { return window.endSheet(alert.window) }
            problem.stringValue = failure
            problem.isHidden = false
            alert.accessoryView?.frame.size = alert.accessoryView?.fittingSize ?? .zero
            alert.layout()
        }
    }

    private let macs = NSMenu(title: "Macs")

    private func fillMacs(_ menu: NSMenu) {
        menu.addItem(withTitle: "Add Mac…", action: #selector(addMac), keyEquivalent: "").target = self
        let shown = Self.paired.keys.sorted(), guests = Self.guests()
        if !shown.isEmpty || !guests.isEmpty { menu.addItem(.separator()) }
        if !shown.isEmpty { menu.addItem(.sectionHeader(title: "Shown Here")) }
        for host in shown { add(menu, "Remove \u{201C}\(host)\u{201D}…", #selector(removeMac), host) }
        if !guests.isEmpty { menu.addItem(.sectionHeader(title: "Opens This Mac")) }
        for guest in guests { add(menu, "Remove \u{201C}\(guest.name)\u{201D}…", #selector(removeGuest), guest) }
    }

    @objc private func removeMac(_ item: NSMenuItem) {
        let host = item.representedObject as! String
        confirm("Remove \u{201C}\(host)\u{201D}?", nil, "Remove", info: "Its tabs keep running on \(host).") { [unowned self] in if $0 { unpair(host) } }
    }

    @objc private func removeGuest(_ item: NSMenuItem) {
        let (id, name) = item.representedObject as! (id: String, name: String)
        confirm("Remove \u{201C}\(name)\u{201D}?", nil, "Remove", info: "It can no longer open this Mac's tabs.") { [unowned self] in
            guard $0 else { return }
            if let problem = Self.revoke(id) { return tell("ClaudeTTY \(problem)") }
            Self.disconnect(id)
        }
    }

    private static func disconnect(_ id: String) {
        let ps = Process(), output = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-x", "-o", "pid=,ppid=,command="]
        ps.standardOutput = output
        guard (try? ps.run()) != nil else { return }
        let rows = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { line -> (pid: pid_t, parent: pid_t, command: String)? in
            let fields = line.split(separator: " ")
            guard fields.count > 2, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { return nil }
            return (pid, parent, fields.dropFirst(2).joined(separator: " "))
        }
        let byPid = Dictionary(rows.map { ($0.pid, $0) }) { first, _ in first }
        for row in rows where row.command.contains("--serve claudetty:" + id) {
            var up = byPid[row.parent]
            while let next = up, !next.command.hasPrefix("sshd") { up = byPid[next.parent] }
            if let sshd = up { kill(sshd.pid, SIGTERM) }
        }
    }

    private func unpair(_ host: String) {
        Self.run(host, ["unpair"])
        var all = UserDefaults.standard.dictionary(forKey: Self.pairedKey) ?? [:]
        all[host] = nil
        UserDefaults.standard.set(all, forKey: Self.pairedKey)
        links.removeValue(forKey: host)?.terminate()
        unreachable[host] = nil
        closed(tabs.filter { $0.labels["host"] == host }.map(\.name))
    }

    private func relist(_ host: String) {
        guard listing[host] == nil else { listing[host] = true; return }
        listing[host] = false
        let pipe = Pipe()
        guard let process = Self.run(host, ["list", "--json"], output: pipe) else { listing[host] = nil; return }
        DispatchQueue.global().async { [unowned self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            DispatchQueue.main.async {
                let again = self.listing.removeValue(forKey: host) == true
                if process.terminationStatus == 0, let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { self.merge(host, rows) }
                if again { self.relist(host) }
            }
        }
    }

    private func merge(_ host: String, _ rows: [[String: Any]]) {
        if unreachable.removeValue(forKey: host) != nil { rebuild() }
        let found = rows.compactMap { row -> Tab? in
            guard let name = row["tab"] as? String, let group = row["group"] as? String else { return nil }
            let labels = (row["labels"] as? [String: String] ?? [:]).filter { !["sleep", "freed", "profile"].contains($0.key) }
            return Tab(name: host + "/" + name, group: host + "/" + group, cwd: row["folder"] as? String ?? "/", labels: labels.merging(["host": host, "profile": host, "state": row["state"] as? String ?? "shell", "mark": row["mark"] as? String ?? "", "notice": row["notice"] as? String ?? "", "noticed": row["noticed"] as? String ?? ""]) { $1 }, topic: row["title"] as? String)
        }
        let before = tabs
        for tab in found { if let index = tabs.firstIndex(of: tab) { tabs[index] = tab } else { tabs.append(tab) } }
        for tab in found where tab.labels["state"] == "asleep" && !shown.contains(tab.name) { surfaces.removeValue(forKey: tab.name)?.removeFromSuperview() }
        closed(tabs.filter { $0.labels["host"] == host && !found.contains($0) }.map(\.name))
        guard tabs.count != before.count || zip(tabs, before).contains(where: { $0.labels != $1.labels || $0.title != $1.title }) else { return }
        rebuild()
        readNotices()
        if let tab = tabs.first(where: { $0.name == arriving[host] }) {
            arriving[host] = nil
            select(tab)
        }
    }

    private func op(_ host: String, _ words: [String], then: @escaping (Bool) -> Void = { _ in }) {
        let done = { [unowned self] (took: Bool) in
            if !took {
                NSSound.beep()
                relist(host)
            }
            then(took)
        }
        if Self.run(host, words, then: { process in DispatchQueue.main.async { done(process.terminationStatus == 0) } }) == nil { done(false) }
    }

    private func end(_ names: [String], on host: String) {
        for name in names { op(host, ["end", String(name.dropFirst(host.count + 1))]) { [unowned self] in if $0 { closed([name]) } } }
    }

    private func act(_ op: [String]) -> String? {
        guard op.count > 1, let tab = tabs.first(where: { $0.name == op[1] }) else { return "no such tab" }
        switch (op[0], op.count) {
        case ("sleep", 2):
            guard tab.claude == "idle", tab.listed.isEmpty, !shown.contains(tab.name) else { return "\(tab.name) can't sleep now" }
            sleep(tab.name)
            if tabs.first(where: { $0 == tab })?.labels["sleep"] == nil { return "\(tab.name) didn't sleep" }
        case ("wake", 2):
            guard tab.labels["sleep"] != nil else { return "\(tab.name) isn't asleep" }
            makeSurface(tab).setVisible(false)
        case ("end", 2): end([tab.name], Self.list().filter { $0["name"] == tab.name })
        case ("new", 3):
            guard !takenNames().contains(op[2]) else { return "\(op[2]) is taken" }
            commands[op[2]] = nil
            makeSurface(insertTab(op[2], in: pane(of: tab), beside: tab, cwd: tab.folder)).setVisible(false)
        case ("label", 4) where Self.pairedLabels.contains(op[2]) && (op[2] != "group" || !op[3].isEmpty):
            guard label(tab.group, op[2], op[3], tab: tab.name) else { return "couldn't label \(tab.name)" }
        default: return "can't \(op[0])"
        }
        rebuild()
        return nil
    }

    private func unread(_ folder: String) -> Bool { tabs.contains { $0.labels["folder"] == folder && notices[$0.name] != nil } }

    private func folderRow(_ name: String, open: Bool, pinned: Bool, was: CountPill?) -> Row {
        let toggle = { [unowned self] in
            if open { collapsed.insert(name) } else { collapsed.remove(name) }
            rebuild()
        }
        let badge = Ping(), count = CountPill(labelWithString: "\(Set(tabs.filter { $0.labels["folder"] == name }.map(\.group)).count)")
        badge.pill = count
        badge.isHidden = !unread(name)
        folderBadges[name] = badge
        let row = Row(name, icon: NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: open ? "Close folder" : "Open folder"), badge: badge, meter: count, head: true, pin: pinned, tint: colors.first { $0.name == tabs.first { $0.labels["folder"] == name }?.labels["foldercolor"] }?.color, selected: false, fill: .clear, action: toggle)
        row.contextMenu = { [unowned self] in
            let menu = NSMenu(), key = "\t" + name
            addOwn(menu, key, inset: 13, pinned: items.first { $0.key == key }?.pinned == true, color: tabs.first { $0.labels["folder"] == name }?.labels["foldercolor"]) {
                add(menu, "Remove Folder, Keep Groups", #selector(removeFolder), name)
            }
            return menu
        }
        row.rename = { [unowned self] in
            toggle()
            rename(folder: name)
        }
        row.lane = pinned ? "pinned" : "groups"
        row.dropped = { [unowned self] to in reorder("\t" + name, to: to) }
        folderRows[name] = row
        if let was, let old = Int(was.stringValue.trimmingCharacters(in: .whitespaces)), let number = Int(count.stringValue.trimmingCharacters(in: .whitespaces)), old != number, let before = was.inkImage {
            let ink = count.textColor
            DispatchQueue.main.async { count.roll(from: before, span: count.bounds.width, up: number > old) { count.textColor = $0 ? .clear : ink } }
        }
        return row
    }

    @objc private func moveToFolder(_ item: NSMenuItem) {
        let (chosen, target) = item.representedObject as! ([String], String?)
        refolder(chosen, to: target)
    }

    private func refolder(_ chosen: [String], to target: String?) {
        let name = target ?? Self.unused("FOLDER", Set(tabs.compactMap { $0.labels["folder"] }))
        let member = tabs.first { $0.labels["folder"] == name && !chosen.contains($0.group) }
        for group in chosen {
            for key in ["folderpinned", "folderorder", "foldercolor"] where tabs.first(where: { $0.group == group })?.labels[key] != member?.labels[key] { label(group, key, member?.labels[key] ?? "") }
            label(group, "folder", name)
        }
        picked = []
        rebuild()
        if target == nil { rename(folder: name) }
    }

    @objc private func renameFolder(_ item: NSMenuItem) { rename(folder: item.representedObject as! String) }

    @objc private func removeFolder(_ item: NSMenuItem) {
        let name = item.representedObject as! String
        if let row = editing, row === folderRows[name] { row.finish(nil) }
        for group in groups where folder(group) == name {
            for key in ["folder", "folderpinned", "folderorder", "foldercolor"] where tabs.first(where: { $0.group == group })?.labels[key] != nil { label(group, key, "") }
        }
        collapsed.remove(name)
        rebuild()
    }

    private func rename(folder name: String) {
        guard let row = folderRows[name] else { return }
        let taken = Set(tabs.compactMap { $0.labels["folder"] }).subtracting([name])
        edit(row, { text in
            let typed = Self.trimmed(text)
            return typed.isEmpty ? "A folder needs a name." : taken.contains(typed) ? "Another folder is named \(typed)." : nil
        }) { [unowned self] text in
            if let typed = text.map(Self.trimmed), typed != name {
                for group in groups where folder(group) == name { label(group, "folder", typed) }
                if collapsed.remove(name) != nil { collapsed.insert(typed) }
            }
        }
    }

    private func edit(_ row: Row, _ problem: @escaping (String) -> String?, done: @escaping (String?) -> Void) {
        editing = row
        row.edit(problem) { [unowned self] text in
            editing = nil
            done(text)
            rebuild()
            window.makeFirstResponder(selected.flatMap { surfaces[$0.name] })
        }
    }

    @objc private func closeGroup(_ item: NSMenuItem) { closing(group: item.representedObject as! String) }

    @objc private func closeGroups(_ item: NSMenuItem) {
        let chosen = item.representedObject as! [String]
        closing(tabs.filter { chosen.contains($0.group) }.map(\.name), title: "Close \(chosen.count) groups?", ask: true)
    }

    @objc private func closeOthers(_ item: NSMenuItem) {
        closing(tabs.filter { $0.group != item.representedObject as! String && $0.labels["pinned"] == nil && $0.labels["profile"] == shownProfile }.map(\.name), title: "Close other groups?", ask: true)
    }

    private func addOwn(_ menu: NSMenu, _ key: String, inset: CGFloat, pinned: Bool, color: String?, between: () -> Void) {
        let folder = key.hasPrefix("\t")
        addMoves(menu, key, inset: inset, pinned: pinned)
        menu.addItem(.separator())
        add(menu, folder ? "Rename Folder" : "Rename Group", folder ? #selector(renameFolder) : #selector(renameGroup), folder ? String(key.dropFirst()) : key, key: folder ? "" : "R")
        between()
        menu.addItem(.separator())
        addColors(menu, [key], current: color, inset: inset)
    }

    private func addMoves(_ menu: NSMenu, _ key: String, inset: CGFloat, pinned: Bool) {
        let sorting = UserDefaults.standard.bool(forKey: Self.sortKey), order = peers(key), index = order.firstIndex(of: key)!
        let button = { [unowned self] (symbol: String, title: String, action: Selector, on: Bool) in
            let made = Self.iconButton(Self.symbol(symbol), title, title, self, action, lit: Self.symbol(symbol))
            made.widthAnchor.constraint(equalToConstant: 26).isActive = true
            made.state = on ? .on : .off
            if on { made.contentTintColor = .controlAccentColor }
            return made
        }
        let arrows = NSStackView()
        let pin = button(pinned ? "pin.fill" : "pin", (pinned ? "Unpin " : "Pin ") + (key.hasPrefix("\t") ? "Folder" : "Group"), #selector(pinRow), pinned)
        pin.tag = pinned ? 0 : 1
        arrows.addView(pin, in: .leading)
        if !key.hasPrefix("\t") { arrows.addView(button("line.3.horizontal.decrease", "Sort by State", #selector(toggleSort), sorting), in: .leading) }
        for (symbol, title, to) in [("arrow.up", "Move Up", index - 1), ("arrow.down", "Move Down", index + 1), ("arrow.up.to.line", "Move to Top", 0)] {
            let arrow = button(symbol, title, #selector(move), false)
            arrow.tag = to
            arrow.isEnabled = !sorting && to != index && order.indices.contains(to)
            arrows.addView(arrow, in: .trailing)
        }
        arrows.spacing = 0
        arrows.autoresizingMask = [.width]
        arrows.edgeInsets = NSEdgeInsets(top: 0, left: inset - 4, bottom: 0, right: 14)
        arrows.heightAnchor.constraint(equalToConstant: 24).isActive = true
        arrows.setFrameSize(arrows.fittingSize)
        let item = menu.addItem(withTitle: "Move", action: nil, keyEquivalent: "")
        item.view = arrows
        item.representedObject = key
    }

    @objc private func pinRow(_ sender: NSButton) {
        let item = sender.enclosingMenuItem!, key = item.representedObject as! String, value = sender.tag == 1 ? "1" : ""
        item.menu?.cancelTracking()
        if key.hasPrefix("\t") { label(folder: String(key.dropFirst()), "folderpinned", value) } else { label(key, "pinned", value) }
        rebuild()
    }

    @objc private func move(_ sender: NSButton) {
        let item = sender.enclosingMenuItem!
        item.menu?.cancelTracking()
        reorder(item.representedObject as! String, to: sender.tag)
    }

    private func reorder(_ key: String, to: Int) {
        let keys = picked.contains(key) ? peers(key).filter(picked.contains) : [key]
        for (index, item) in Self.placed(keys, dragged: key, in: peers(key), to: to).enumerated() {
            if item.hasPrefix("\t") { label(folder: String(item.dropFirst()), "folderorder", String(index)) } else if tabs.first(where: { $0.group == item })?.labels["order"] != String(index) { label(item, "order", String(index)) }
        }
        rebuild()
    }

    private static func placed(_ moved: [String], dragged: String, in order: [String], to: Int) -> [String] {
        var rest = order.filter { !moved.contains($0) }
        rest.insert(contentsOf: moved, at: order.filter { $0 != dragged }.prefix(to).filter { !moved.contains($0) }.count)
        return rest
    }

    private func reorder(_ order: [String]) {
        let old = Dictionary(uniqueKeysWithValues: tabs.map { ($0.name, $0) })
        var next = order.makeIterator()
        tabs = tabs.map { order.contains($0.name) ? old[next.next()!]! : $0 }
        let group = old[order[0]]!.group
        for (index, tab) in tabs.filter({ $0.group == group }).enumerated() where tab.labels["rank"] != String(index) { label(group, "rank", String(index), tab: tab.name) }
    }

    private func tabControls(_ tab: Tab) -> [NSMenuItem] {
        [item("Rename Tab", #selector(renameTab), tab.name)] + (tab.labels["title"] == nil ? [] : [item("Remove Custom Tab Name", #selector(retitle), [tab.name])])
            + [item(tab.labels["notify"] == "0" ? "Unmute Notifications" : "Mute Notifications", #selector(mute), [tab.name])] + (tab.labels["host"] == nil ? [readonlyItem([tab.name])] : [])
    }

    private func readonlyItem(_ names: [String]) -> NSMenuItem {
        let made = item("Read-only", #selector(toggleReadonly), names)
        made.state = tabs.filter { names.contains($0.name) }.allSatisfy { $0.labels["readonly"] != nil } ? .on : .off
        return made
    }

    private func pickedTabsMenu(_ names: [String]) -> NSMenu {
        let menu = NSMenu(), chosen = tabs.filter { names.contains($0.name) }, group = chosen[0].group
        let titled = chosen.filter { $0.labels["title"] != nil }.map(\.name), muted = chosen.allSatisfy { $0.labels["notify"] == "0" }
        if !titled.isEmpty { add(menu, titled.count == 1 ? "Remove Custom Tab Name" : "Remove \(titled.count) Custom Tab Names", #selector(retitle), titled) }
        add(menu, "\(muted ? "Unmute" : "Mute") Notifications for \(names.count) Tabs", #selector(mute), names)
        let paired = chosen[0].labels["host"] != nil
        if !paired { menu.addItem(readonlyItem(names)) }
        let claudes = chosen.filter { $0.claude != nil }
        if !claudes.isEmpty {
            let sleepy = claudes.filter { $0.claude == "idle" && $0.listed.isEmpty && !shown.contains($0.name) }.map(\.name), count = sleepy.isEmpty ? claudes.count : sleepy.count
            add(menu, count == 1 ? "Sleep Tab" : "Sleep \(count) Tabs", sleepy.isEmpty ? nil : #selector(sleepTab), sleepy)
            if !paired { add(menu, claudes.count == 1 ? "Keep Awake" : "Keep \(claudes.count) Tabs Awake", groupAwake(group) ? nil : #selector(keepAwake), (group, claudes.map(\.name), "awake")).state = claudes.allSatisfy(awake) ? .on : .off }
        }
        menu.addItem(.separator())
        add(menu, "Close \(names.count) Tabs", #selector(closeTabs), names)
        return menu
    }

    private func tabMenu(_ tab: Tab, _ paneTabs: [String], _ layout: Layout) -> NSMenu {
        if chosen(tab.name).count > 1 { return pickedTabsMenu(chosen(tab.name)) }
        let menu = NSMenu()
        let add = { (title: String, action: Selector?, object: Any?) in self.add(menu, title, action, object) }
        if let summary = Self.summary(tab) { menu.addItem(.sectionHeader(title: summary)) }
        let paired = tab.labels["host"] != nil
        menu.items += tabControls(tab)
        if tab.claude != nil {
            add("Sleep Tab", tab.claude == "idle" && tab.listed.isEmpty && !shown.contains(tab.name) ? #selector(sleepTab) : nil, [tab.name])
            if !paired {
                self.add(menu, "Keep Awake", groupAwake(tab.group) ? nil : #selector(keepAwake), (tab.group, [tab.name], "awake")).state = awake(tab) ? .on : .off
                add("Fork Tab", tab.session != nil && tab.pid.flatMap(foreground) != nil ? #selector(forkTab) : nil, tab.name)
            }
        }
        if !paired { menu.addItem(resumeItem(tab)) }
        add("-", nil, nil)
        let index = paneTabs.firstIndex(of: tab.name)!
        let left = Array(paneTabs[..<index]), right = Array(paneTabs[(index + 1)...])
        for (title, names) in [("Close Tab", [tab.name]), ("Close Tabs to Left", left), ("Close Tabs to Right", right), ("Close Other Tabs", left + right)] {
            add(title, names.isEmpty ? nil : #selector(closeTabs), names)
        }
        let ids = layout.panes, from = pane(of: tab, in: layout)
        if ids.count > 1 {
            add("-", nil, nil)
            add(zoomedPane(tab.group, in: layout) == nil ? "Zoom Pane" : "Unzoom Pane", #selector(toggleZoom), tab.name)
        }
        let moves: [(String, (CGFloat, CGFloat))] = [("Move to Left Pane", (-1, 0)), ("Move to Right Pane", (1, 0)), ("Move to Upper Pane", (0, 1)), ("Move to Lower Pane", (0, -1))]
        for (index, (title, step)) in moves.enumerated() where !paired && zoomedPane(tab.group, in: layout) == nil && ids.contains(where: { neighbor($0, step, in: ids) != nil }) {
            if index == 0 || index == 2 { add("-", nil, nil) }
            let to = neighbor(from, step, in: ids)
            add(title, to == nil ? nil : #selector(moveTab), (tab.name, to ?? ""))
        }
        return menu
    }

    private func scheduleItems(_ tab: Tab) -> [NSMenuItem] {
        let clock = Date.FormatStyle(date: .abbreviated, time: .shortened)
        let lines = [("Schedule Message…", #selector(schedule), tab as Any)] + scheduled.filter { $0[0] == tab.name }.map { entry in
            ("Cancel \u{201C}\(Self.cap(entry[2], 30))\u{201D} (\(Date(timeIntervalSince1970: Double(entry[1])!).formatted(clock)))", #selector(unschedule), entry as Any)
        }
        return lines.map { item($0, $1, $2) }
    }

    private var scheduled: [[String]] {
        get { UserDefaults.standard.array(forKey: Self.scheduledKey) as? [[String]] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.scheduledKey) }
    }

    private func arm(_ entry: [String]) {
        let timer = Timer(fire: Date(timeIntervalSince1970: Double(entry[1])!), interval: 0, repeats: false) { [unowned self] _ in
            guard scheduled.contains(entry) else { return }
            scheduled.removeAll { $0 == entry }
            type(entry[2], to: entry[0])
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func type(_ text: String, to name: String) {
        if let tab = tabs.first(where: { $0.name == name }), tab.labels["sleep"] != nil {
            makeSurface(tab).setVisible(false)
            return awake(name) { [unowned self] in type(text, to: name) }
        }
        _ = try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", name, text]) { _ in usleep(300_000); _ = try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", name, "\r"]) }
    }

    private func awake(_ name: String, tries: Int = 120, then: @escaping () -> Void) {
        guard tries > 0, let tab = tabs.first(where: { $0.name == name }) else { return }
        if tab.claude == "idle", emptyPrompt(name) { return then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [unowned self] in awake(name, tries: tries - 1, then: then) }
    }

    @objc private func schedule(_ item: NSMenuItem) {
        let tab = item.representedObject as! Tab
        let text = NSTextField(string: "")
        text.placeholderString = "Message or command"
        let picker = NSDatePicker()
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = Date(timeIntervalSinceNow: 3600)
        picker.minDate = Date()
        let fields = NSStackView(views: [text, picker])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.frame.size = NSSize(width: 260, height: 54)
        text.widthAnchor.constraint(equalToConstant: 260).isActive = true
        confirm("Schedule a message to \u{201C}\(tab.title)\u{201D}", fields, "Schedule") { [unowned self] in
            guard $0, !text.stringValue.isEmpty else { return }
            let entry = [tab.name, String(Int(picker.dateValue.timeIntervalSince1970)), text.stringValue]
            scheduled.append(entry)
            arm(entry)
        }
        text.window?.makeFirstResponder(text)
    }

    @objc private func unschedule(_ item: NSMenuItem) {
        let entry = item.representedObject as! [String]
        scheduled.removeAll { $0 == entry }
    }

    @objc private func renameTab(_ item: NSMenuItem) {
        let name = item.representedObject as! String
        tabRows[name].map { rename(tab: name, in: $0) }
    }

    private func rename(tab name: String, in row: Row) {
        edit(row, { _ in nil }) { [unowned self] text in
            if let text, let tab = tabs.first(where: { $0.name == name }) {
                let title = Self.trimmed(text)
                if !label(tab.group, "title", title, tab: name) { return NSSound.beep() }
                guard UserDefaults.standard.bool(forKey: Self.renameKey), tab.claude != nil, tab.labels["sleep"] == nil, tab.labels["host"] == nil, !title.isEmpty else { return }
                awake(name, tries: 3600) { [unowned self] in
                    if tabs.first(where: { $0.name == name })?.labels["title"] == title { type("/rename " + title, to: name) }
                }
            }
        }
    }

    @objc private func retitle(_ item: NSMenuItem) {
        for tab in tabs where (item.representedObject as! [String]).contains(tab.name) { label(tab.group, "title", "", tab: tab.name) }
        rebuild()
    }

    @objc private func closeTabs(_ item: NSMenuItem) {
        let names = item.representedObject as! [String]
        closing(names, title: names.count == 1 ? "Close tab?" : "Close tabs?", ask: names.count > 1)
    }

    @objc private func moveTab(_ item: NSMenuItem) {
        let (name, pane) = item.representedObject as! (String, String)
        guard let tab = tabs.first(where: { $0.name == name }), label(tab.group, "pane", pane, tab: name) else { return NSSound.beep() }
        select(tabs.first { $0 == tab }!)
    }

    private func carry(_ names: [String], dragged name: String, to point: NSPoint) -> Bool {
        guard let tab = tabs.first(where: { $0.name == name }), let scroll = sidebar.enclosingScrollView else { return false }
        let under = { (view: NSView) in self.under(view, point) }
        if case let (pane, bar)? = panes.lazy.compactMap({ id, pane in pane.bar.flatMap { under($0) ? (id, $0) : nil } }).first {
            guard pane != self.pane(of: tab) else { return false }
            let layout = layout(tab.group), there = tabs.filter { $0.group == tab.group && self.pane(of: $0, in: layout) == pane }.map(\.name)
            guard names.filter({ !label(tab.group, "pane", pane, tab: $0) }).isEmpty else { NSSound.beep(); return false }
            let left = bar.arrangedSubviews.filter { $0 is Row && $0.convert(NSPoint(x: $0.bounds.midX, y: 0), to: nil).x < point.x }.count
            reorder(Self.placed(names, dragged: name, in: there, to: left))
            select(tabs.first { $0 == tab }!)
            return true
        }
        guard under(scroll) else { return false }
        let group = groupRows.first { under($0.value) }?.key
            ?? (tabs.contains { $0.group == tab.group && !names.contains($0.name) } ? Self.unused(name, takenNames().subtracting([name]).union(groups)) : nil)
        guard let group, group != tab.group, names.map({ regroup($0, to: group) }).contains(true) else { return false }
        select(tabs.first { $0 == tab }!)
        return true
    }

    private func under(_ view: NSView, _ point: NSPoint) -> Bool { !view.isHiddenOrHasHiddenAncestor && view.bounds.contains(view.convert(point, from: nil)) }

    private func home(at point: NSPoint, for group: String) -> String? {
        let name = folderRows.first { under($0.value, point) }?.key ?? groupRows.first { under($0.value, point) }.flatMap { folder($0.key) }
        return name == folder(group) ? nil : name
    }

    private static let groupKeys = ["color", "pinned", "groupawake", "order", "split", "named", "folder", "folderpinned", "folderorder", "foldercolor", "pr", "profile"]

    private func regroup(_ name: String, to group: String, named: String = "0") -> Bool {
        let tab = tabs.first { $0.name == name }!, source = tab.group, target = tabs.first { $0.group == group }
        var wanted = (target?.labels ?? tab.labels.filter { $0.key == "profile" }.merging(["named": named]) { $1 }).filter { Self.groupKeys.contains($0.key) }
        wanted["pane"] = target.map { pane(of: tabs.first { $0 == lastTab[group] } ?? $0) }
        wanted["title"] = tab.labels["title"]
        guard label(source, "group", group, tab: name) else { NSSound.beep(); return false }
        for key in Set(wanted.keys).union(tab.labels.keys) where wanted[key] != tab.labels[key] && !label(group, key, wanted[key] ?? "", tab: name) { NSSound.beep() }
        let index = tabs.firstIndex(of: tab)!
        let moved = tabs.remove(at: index)
        if let next = tabs.firstIndex(where: { $0.group == source }), next > index { tabs.insert(tabs.remove(at: next), at: index) }
        tabs.insert(moved, at: (tabs.lastIndex { $0.group == group } ?? tabs.count - 1) + 1)
        lastTab = lastTab.filter { $0.value.name != name }
        selected = selected.flatMap { old in tabs.first { $0 == old } }
        return true
    }

    private func addColors(_ menu: NSMenu, _ keys: [String], current: String?, inset: CGFloat) {
        let circles = NSStackView(views: ([("none", nil)] + colors.map { ($0.name, Optional($0.color)) }).enumerated().map { index, choice in
            let button = NSButton(image: Self.dot(choice.1, ringed: current == (choice.1 == nil ? nil : choice.0)), target: self, action: #selector(pickColor))
            button.isBordered = false
            button.tag = index
            button.toolTip = choice.0.capitalized
            button.setAccessibilityLabel(choice.0.capitalized)
            return button
        })
        circles.spacing = 2
        circles.edgeInsets = NSEdgeInsets(top: 2, left: inset, bottom: 2, right: 14)
        circles.setFrameSize(circles.fittingSize)
        let colorItem = menu.addItem(withTitle: "Color", action: nil, keyEquivalent: "")
        colorItem.view = circles
        colorItem.representedObject = keys
    }

    @objc private func pickColor(_ sender: NSButton) {
        let item = sender.enclosingMenuItem!, keys = item.representedObject as! [String]
        item.menu?.cancelTracking()
        let value = sender.tag == 0 ? "" : colors[sender.tag - 1].name
        for key in keys {
            if key.hasPrefix("\t") {
                label(folder: String(key.dropFirst()), "foldercolor", value)
            } else {
                label(key, "color", value)
            }
        }
        rebuild()
    }

    private static func dot(_ color: NSColor?, ringed: Bool) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
            if let color {
                color.setFill()
                circle.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                circle.lineWidth = 1
                circle.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 6, y: 6))
                slash.line(to: NSPoint(x: 14, y: 14))
                slash.stroke()
            }
            if ringed {
                NSColor.labelColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
    }

    @objc private func setLabel(_ item: NSMenuItem) {
        let (groups, key, value) = item.representedObject as! ([String], String, String)
        for group in groups { label(group, key, value) }
        rebuild()
    }

    @discardableResult private func label(_ group: String, _ key: String, _ value: String, tab: String? = nil, queued: Bool = false) -> Bool {
        var all = true
        for index in tabs.indices where tabs[index].group == group && (tab == nil || tabs[index].name == tab) {
            let host = tabs[index].labels["host"]
            if key == "group", host.map({ !value.hasPrefix($0 + "/") }) ?? remote(value) {
                all = false
                continue
            }
            if let host {
                guard Self.pairedLabels.contains(key) else {
                    all = false
                    continue
                }
                op(host, ["label", tabs[index].onHost, key, key == "group" ? String(value.dropFirst(host.count + 1)) : value])
            } else if queued, tabs[index].labels["sleep"] == nil {
                let name = tabs[index].name
                Self.lister.async { _ = Self.zmxOutput("set", name, key + "=" + Self.encoded(value)) }
            } else if tabs[index].labels["sleep"] == nil, Self.zmxOutput("set", tabs[index].name, key + "=" + Self.encoded(value)) == nil {
                all = false
                continue
            }
            if key == "group" { tabs[index].group = value } else { tabs[index].labels[key] = value.isEmpty ? nil : value }
        }
        return all
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.")
    private static func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: plain)!.replacingOccurrences(of: "%", with: "_") }

    private static func decoded(_ value: String) -> String { value.replacingOccurrences(of: "_", with: "%").removingPercentEncoding ?? value }

    private static func legacy(_ value: String) -> String { value.replacingOccurrences(of: "_([0-9A-Fa-f]{2})", with: "%$1", options: .regularExpression).removingPercentEncoding ?? value }

    @objc private func renameGroup(_ item: NSMenuItem) { rename(item.representedObject as! String) }

    @objc private func renameSelected() {
        guard let selected else { return }
        if !sidebarShown { toggleSidebar() }
        rename(selected.group)
    }

    private func rename(_ group: String) {
        guard let row = groupRows[group] else { return }
        let mac = tabs.first { $0.group == group }?.labels["host"].map { $0 + "/" } ?? ""
        edit(row, { [unowned self] text in
            let name = Self.trimmed(text)
            return name.isEmpty ? "A group needs a name." : mac + name != group && groups.contains(mac + name) ? "Another group is named \(name)." : nil
        }) { [unowned self] text in
            if let name = text.map({ mac + Self.trimmed($0) }) {
                if label(group, "group", name) {
                    label(name, "named", "1")
                } else {
                    label(name, "group", group)
                    NSSound.beep()
                }
                selected = selected.flatMap { old in tabs.first { $0.name == old.name } }
                lastTab = Dictionary(lastTab.values.compactMap { old in tabs.first { $0.name == old.name } }.map { ($0.group, $0) }, uniquingKeysWith: { first, _ in first })
            }
        }
    }

    private static func branch(_ path: String) -> String? { repo(path)?.branch }

    private static func repo(_ path: String) -> (git: String, branch: String?)? {
        var dir = URL(fileURLWithPath: path)
        while dir.path != "/" {
            let dotGit = dir.appending(path: ".git")
            let git = (try? String(contentsOf: dotGit, encoding: .utf8)).map { String($0.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? dotGit.path
            if let head = try? String(contentsOfFile: git + "/HEAD", encoding: .utf8) {
                return (git, head.hasPrefix("ref: refs/heads/") ? String(head.dropFirst(16)).trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    private static func pullBranch(_ folder: String) -> (key: String, branch: String)? {
        guard let repo = repo(folder), let branch = repo.branch else { return nil }
        let common = (try? String(contentsOfFile: repo.git + "/commondir", encoding: .utf8)).map { URL(fileURLWithPath: repo.git).appending(path: $0.trimmingCharacters(in: .whitespacesAndNewlines)).standardized.path } ?? repo.git
        guard let config = try? String(contentsOfFile: common + "/config", encoding: .utf8), let remote = config.firstMatch(of: #/\[remote "([^"]+)"\][^\[]*url\s*=\s*\S*github\.com[:/]/#)?.1 else { return nil }
        let refs = common + "/refs/remotes/\(remote)/", packed = (try? String(contentsOfFile: common + "/packed-refs", encoding: .utf8)) ?? ""
        let head = (try? String(contentsOfFile: refs + "HEAD", encoding: .utf8))?.split(separator: "/").last?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ![head, "main", "master"].contains(branch), FileManager.default.fileExists(atPath: refs + branch) || packed.contains(" refs/remotes/\(remote)/\(branch)\n") else { return nil }
        return (repo.git + "\t" + branch, branch)
    }

    private static var gh: String? {
        let env = ProcessInfo.processInfo.environment, config = env["GH_CONFIG_DIR"] ?? (env["XDG_CONFIG_HOME"] ?? (env["HOME"] ?? NSHomeDirectory()) + "/.config") + "/gh"
        guard FileManager.default.fileExists(atPath: config + "/hosts.yml") else { return nil }
        return loginPath?.split(separator: ":").map { $0 + "/gh" }.first(where: FileManager.default.isExecutableFile)
    }
    private static let minute: TimeInterval = probe == nil || FileManager.default.fileExists(atPath: probe! + "/realtime") ? 60 : 1

    private func checkPulls() {
        guard !away, sidebarShown, let gh = Self.gh else { return }
        for tab in groupRows.keys.compactMap({ group in tabs.first { $0.group == group } }) where tab.labels["pr"] == nil {
            let folder = tab.frontFolder
            guard let (key, branch) = Self.pullBranch(folder), pulls[key]?.pull?.open != false,
                  Date().timeIntervalSince(pulls[key]?.asked ?? .distantPast) > (pulls[key]?.pull == nil ? 4.5 : 0.9) * Self.minute else { continue }
            pulls[key] = (pulls[key]?.pull, Date())
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["pr", "view", branch, "--json", "number,state,url,statusCheckRollup,additions,deletions"]
            process.currentDirectoryURL = URL(fileURLWithPath: folder)
            process.environment = ProcessInfo.processInfo.environment.merging(["PATH": Self.loginPath ?? "", "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1"]) { $1 }
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            DispatchQueue.global(qos: .utility).async {
                let json = (try? JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile())) as? [String: Any]
                DispatchQueue.main.async { [unowned self] in
                    guard let json, let number = json["number"] as? Int, let url = json["url"] as? String, let state = json["state"] as? String else { return }
                    let checks = (json["statusCheckRollup"] as? [[String: Any]] ?? []).map { ($0["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? $0["state"] as? String ?? "PENDING" }
                    let failed = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]
                    let glyph = state == "MERGED" ? "◆" : state == "CLOSED" ? "⊘" : checks.isEmpty ? nil : checks.contains(where: failed.contains) ? "✗" : checks.contains { $0 == "PENDING" || $0 == "EXPECTED" } ? "●" : "✓"
                    let pull = Pull(number: number, open: state == "OPEN", glyph: glyph, url: url, added: json["additions"] as? Int ?? 0, removed: json["deletions"] as? Int ?? 0), changed = pulls[key]?.pull != pull
                    pulls[key] = (pull, Date())
                    if changed { rebuild() }
                }
            }
        }
    }

    private func shownPull(_ tab: Tab) -> Pull? {
        guard !pulls.isEmpty, tab.labels["pr"] == nil, let repo = Self.repo(tab.frontFolder) else { return nil }
        return pulls[repo.git + "\t" + (repo.branch ?? "")]?.pull
    }

    private func pullLabel(_ tab: Tab, selected: Bool) -> [NSView] {
        guard let pull = shownPull(tab) else { return [] }
        let label = LinkButton(title: "", target: self, action: #selector(openPull))
        label.isBordered = false
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.ink = selected ? (NSColor(white: 1, alpha: 0.8), .white) : (.secondaryLabelColor, .secondaryLabelColor)
        label.text = "#\(pull.number)"
        label.toolTip = pull.url
        let height = label.fittingSize.height
        let look: (symbol: String, hue: NSColor?)? = pull.glyph.flatMap { ["✓": ("checkmark.circle.fill", .systemGreen), "✗": ("xmark.circle.fill", .systemRed), "●": ("ellipsis.circle.fill", NSColor(cgColor: Marks.amber)!), "◆": ("diamond.fill", nil), "⊘": ("slash.circle", nil)][$0] }
        if let look {
            let grey = selected ? NSColor.white : .secondaryLabelColor
            let colors = look.hue.map { [selected ? .controlAccentColor : .white, selected ? .white : TabStrip.markInk($0, 0.2)] } ?? [grey]
            label.mark = NSImage(systemSymbolName: look.symbol, accessibilityDescription: pull.glyph)!.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold).applying(.init(paletteColors: colors)))!
        }
        let tint = selected ? NSColor.white : look?.hue ?? .gray
        label.fill = (tint.withAlphaComponent(0.16), tint.withAlphaComponent(0.32))
        label.wantsLayer = true
        label.layer?.cornerRadius = height / 2
        label.heightAnchor.constraint(equalToConstant: height).isActive = true
        label.widthAnchor.constraint(equalToConstant: ceil(label.attributedTitle.size().width) + 2 * (look == nil ? 3.5 : 1)).isActive = true
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return [label]
    }

    private func changesLabel(_ tab: Tab, selected: Bool) -> [NSView] {
        guard let pull = shownPull(tab), pull.added + pull.removed > 0 else { return [] }
        let text = NSMutableAttributedString()
        for (count, sign, hue, shade) in [(pull.added, "+", NSColor.systemGreen, 0.62), (pull.removed, "\u{2212}", .systemRed, 0.4)] where count > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: " ")) }
            text.append(NSAttributedString(string: sign + String(count), attributes: [.foregroundColor: selected ? NSColor(white: 1, alpha: 0.8) : TabStrip.markInk(hue, shade)]))
        }
        text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), range: NSRange(location: 0, length: text.length))
        let label = NSTextField(labelWithAttributedString: text)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setAccessibilityLabel("\(pull.added) lines added, \(pull.removed) removed")
        return [label]
    }

    @objc private func openPull(_ sender: NSButton) {
        guard let url = sender.toolTip.flatMap(URL.init) else { return }
        if let probe { return try! url.absoluteString.write(toFile: probe + "/opened", atomically: true, encoding: .utf8) }
        NSWorkspace.shared.open(url)
    }

    private func closing(_ names: [String], title: String = "Close tab?", ask: Bool = false) {
        if let tab = tabs.first(where: { $0.name == names.first }), let host = tab.labels["host"] {
            return confirm(names.count == 1 && title == "Close tab?" ? "Close \u{201C}\(tab.title)\u{201D}?" : title, nil, "Detach", other: ("End on \(host)", { [unowned self] in end(names, on: host) })) { [unowned self] in
                if $0 { closed(names, detached: true) }
            }
        }
        let sessions = Self.list().filter { names.contains($0["name"] ?? "") }
        let doomed = names.compactMap { name in sessions.first { $0["name"] == name } }.compactMap { session -> (tab: String, jobs: [Job])? in
            let tab = tabs.first { $0.name == session["name"] }
            let jobs = tab?.labels["viewer"] != nil ? [] : Self.jobs(session, tab)
            return jobs.isEmpty ? nil : (tab?.title ?? session["name"]!, jobs)
        }
        guard !doomed.isEmpty || ask else { return end(names, sessions) }
        confirm(doomed.count == 1 && title == "Close tab?" ? "Close \u{201C}\(doomed[0].tab)\u{201D}?" : title, Self.doomedList(doomed), "Close") { [unowned self] in if $0 { end(names, sessions) } }
    }

    private func end(_ names: [String], _ sessions: [[String: String]]) {
        closedTabs = Array((closedTabs + sessions.compactMap(closedTab)).suffix(10))
        for session in sessions { Self.end(session["name"]!, shell: session["pid"].flatMap(Int32.init)) }
        closed(names)
    }

    private func confirm(_ message: String, _ accessory: NSView?, _ action: String, info: String = "", other: (title: String, run: () -> Void)? = nil, then: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.accessoryView = accessory
        for (title, key) in [(action, "↩")] + (other.map { [($0.title, "⌘⌫")] } ?? []) + [("Cancel", "⎋")] { Self.keyed(alert.addButton(withTitle: title), key) }
        alert.buttons.last!.keyEquivalent = "\u{1b}"
        if other != nil { (alert.buttons[1].keyEquivalent, alert.buttons[1].keyEquivalentModifierMask) = ("\u{8}", .command) }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn, let other { return other.run() }
            then(response == .alertFirstButtonReturn)
        }
    }

    static func keyed(_ button: NSButton, _ key: String) {
        button.setAccessibilityLabel(button.title)
        let color = key == "↩" ? NSColor.alternateSelectedControlTextColor : .controlTextColor
        let label = NSMutableAttributedString(string: button.title + "  ", attributes: [.font: button.font!, .foregroundColor: color])
        let lit = NSColor(name: nil) { [weak button] _ in button?.window?.isKeyWindow == true ? color.withAlphaComponent(0.55) : .secondaryLabelColor }
        label.append(NSAttributedString(string: key, attributes: [.font: button.font!, .foregroundColor: key == "↩" ? lit : NSColor.secondaryLabelColor]))
        button.attributedTitle = label
    }

    private func closing(group: String) {
        let groupTabs = tabs.filter { $0.group == group }
        let pinned = groupTabs.first?.labels["pinned"] != nil
        closing(groupTabs.map(\.name), title: (pinned ? "Close pinned group \u{201C}" : "Close group \u{201C}") + title(group) + "\u{201D}?", ask: pinned)
    }

    private func closedTab(_ session: [String: String]) -> (tab: Tab, index: Int, command: [String]?, history: Data?)? {
        guard let name = session["name"], let index = tabs.firstIndex(where: { $0.name == name }) else { return nil }
        var tab = tabs[index]
        tab.pid = session["pid"].flatMap(Int32.init)
        let kept = Tab(name: name, group: tab.group, cwd: tab.folder, labels: tab.labels)
        if tab.claude != nil, let session = tab.session, let front = tab.pid.flatMap(foreground) { return (kept, index, Self.claude(Self.relaunch(front) + Self.resume(tab, session), env: Self.codeMode(tab.transcript)), nil) }
        if tab.labels["replay"] == nil, let command = commands[name] { return (kept, index, command, nil) }
        guard let history = Self.zmxOutput("history", name, "--vt") else { return (kept, index, nil, nil) }
        return (kept, index, nil, history.lastIndex(of: 10).map { history.prefix(through: $0) })
    }

    @discardableResult private static func onExit(_ pid: Int32, _ then: @escaping () -> Void) -> DispatchSourceProcess {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            source.cancel()
            then()
        }
        source.resume()
        return source
    }

    private static func zmxOutput(_ arguments: String...) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return process.terminationStatus == 0 ? output : nil
    }

    private func emptyPrompt(_ name: String) -> Bool { Self.prompt(name) == "" }

    private static func prompt(_ name: String) -> String? { prompt(screen(name)) }
    private static func prompt(_ lines: [Substring]) -> String? {
        let rules = lines.indices.filter { lines[$0].hasPrefix("────") }
        guard rules.count >= 2 else { return nil }
        let box = lines[rules[rules.count - 2] + 1 ..< rules[rules.count - 1]].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard box.first?.hasPrefix("❯") == true else { return nil }
        let width = lines[rules[rules.count - 1]].count - 3
        return box.dropFirst().reduce(box[0].dropFirst().trimmingCharacters(in: .whitespaces)) { text, row in
            let last = text.split(separator: "\n", omittingEmptySubsequences: false).last?.count ?? 0, word = row.prefix { !$0.isWhitespace }.count
            return text + (last >= width ? "" : last + 1 + word > width ? " " : "\n") + row
        }.trimmingCharacters(in: .whitespaces)
    }
    private static func mode(_ name: String) -> String? {
        let lines = screen(name)
        guard prompt(lines) != nil, let rule = lines.lastIndex(where: { $0.hasPrefix("────") }) else { return nil }
        let below = lines[(rule + 1)...].joined(separator: " ")
        return [("accept edits on", "acceptEdits"), ("plan mode on", "plan"), ("bypass permissions on", "bypassPermissions"), ("auto mode on", "auto")].first { below.contains($0.0) }?.1 ?? "default"
    }
    private static func queued(_ lines: [Substring]) -> [String] {
        let rules = lines.indices.filter { lines[$0].hasPrefix("────") }
        guard rules.count >= 2 else { return [] }
        var out: [String] = [], block: [String] = []
        for line in lines[max(0, rules[rules.count - 2] - 60) ..< rules[rules.count - 2]] {
            let row = line.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("⎿") && row.contains("Queued") {
                out += block
                block = []
            } else if row.hasPrefix("❯") {
                block.append(squeezed(String(row.dropFirst())))
            } else if row.isEmpty {
                block = []
            } else if !block.isEmpty {
                block[block.count - 1] += squeezed(row)
            }
        }
        return out
    }
    static func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private static func screen(_ name: String) -> [Substring] {
        var text = String(decoding: zmxOutput("history", name, "--vt") ?? Data(), as: UTF8.self)
        for match in try! NSRegularExpression(pattern: "\u{1B}\\[([0-9]*)C").matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            text.replaceSubrange(Range(match.range, in: text)!, with: String(repeating: " ", count: Int(text[Range(match.range(at: 1), in: text)!]) ?? 1))
        }
        return text
            .replacingOccurrences(of: "\u{1B}\\[2m(?:[^\u{1B}]|\u{1B}\\[(?!0m)[0-9;]*m)*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]|\r", with: "", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
    }

    private static let switches: Set = ["--dangerously-skip-permissions", "--verbose", "--ide", "--strict-mcp-config", "--chrome"]
    private static func takesValue(_ word: String) -> Bool { word.hasPrefix("-") && !word.contains("=") && !switches.contains(word) }
    private static func prompted(_ argv: [String]) -> Bool { argv.indices.dropFirst().contains { !argv[$0].hasPrefix("-") && !takesValue(argv[$0 - 1]) } }
    private static func relaunch(_ front: Int32) -> String {
        let words = arguments(front)
        return flags(words) + (bridged(front) && !words.contains { $0 == "--remote-control" || $0.hasPrefix("--remote-control=") } ? " --remote-control" : "")
    }
    private static func bridged(_ front: Int32) -> Bool { json(NSHomeDirectory() + "/.claude/sessions/\(front).json")?["bridgeSessionId"] != nil }
    private static func flags(_ argv: [String]) -> String {
        var kept: [String] = [], index = 1
        while index < argv.count {
            let word = argv[index]
            index += 1
            if word == "--" { break }
            if ["--resume", "-r", "--session-id"].contains(word) {
                if index < argv.count, !argv[index].hasPrefix("-") { index += 1 }
                continue
            }
            if word == "--settings", index < argv.count, argv[index] == lightTheme {
                index += 1
                continue
            }
            let value = kept.last.map(takesValue) ?? false
            guard word.hasPrefix("-") ? !["--continue", "-c", "--fork-session"].contains(word) && !word.hasPrefix("--resume=") && !word.hasPrefix("--session-id=") && !(word.hasPrefix("--mcp-config=") && word.contains(Share.marker)) : value else { continue }
            kept.append(word)
        }
        return kept.map(quoted).joined(separator: " ")
    }

    private func reopenTab() {
        guard let (old, index, command, history) = closedTabs.popLast() else { return NSSound.beep() }
        let taken = Set(Self.list().compactMap { $0["name"] } + tabs.map(\.name))
        let name = taken.contains(old.name) ? Self.unused(old.group, taken) : old.name
        var tab = Tab(name: name, group: old.group, cwd: old.cwd, labels: old.labels)
        if let peer = tabs.first(where: { $0.group == old.group }) {
            let layout = layout(old.group)
            for key in Self.groupKeys { tab.labels[key] = peer.labels[key] }
            if !layout.panes.contains(old.labels["pane"] ?? "") { tab.labels["pane"] = pane(of: peer, in: layout) }
        } else {
            tab.labels["split"] = nil
            tab.labels["pane"] = nil
        }
        tab.labels["replay"] = history.map { _ in "1" }
        commands[name] = history.map(Self.replay) ?? command
        tabs.insert(tab, at: min(index, tabs.count))
        for (rank, peer) in tabs.filter({ $0.group == tab.group }).enumerated() where peer.labels["rank"] != String(rank) {
            if peer == tab { tabs[tabs.firstIndex(of: tab)!].labels["rank"] = String(rank) } else { label(tab.group, "rank", String(rank), tab: peer.name) }
        }
        select(tab)
    }

    private func resumeUpdatedClaude() {
        guard Date() >= nextResume, selected != nil else { return }
        let keyed = NSApp.isActive ? selected?.name : nil
        lazy var store = Self.warmStore()
        for tab in tabs where tab.name != keyed && tab.claude == "idle" && tab.listed.isEmpty && unsent[tab.name] == nil {
            guard let session = tab.session, let shell = tab.pid, let front = foreground(shell), let link = started(front)?.strings.first, FileManager.default.fileExists(atPath: link),
                  tab.old || inode(link) != inode(binary(front))
                  || tab.name != selected?.name && Self.footprint(front, deep: false) > bloated || Share.stale(front), emptyPrompt(tab.name),
                  !(Self.resume(tab, session).isEmpty && Self.prompted(Self.arguments(front))),
                  tab.reply == nil || !cold(tab, store) else { continue }
            nextResume = Date() + 5
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [unowned self] in resumeUpdatedClaude() }
            return restart(tab, session: session, shell: shell, front: front, draft: "")
        }
        for tab in tabs where tab.old && tab.name != keyed && tab.claude == nil {
            guard let shell = tab.pid, foreground(shell) == shell, Self.children(shell).isEmpty, Self.shells.contains(binary(shell)) else { continue }
            nextResume = Date() + 5
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [unowned self] in resumeUpdatedClaude() }
            let history = Self.zmxOutput("history", tab.name, "--vt").flatMap { all in all.lastIndex(of: 10).map { all.prefix(through: $0) } }
            var kept = tab
            kept.labels["replay"] = history.map { _ in "1" }
            return replace(kept, shell: shell, command: history.map(Self.replay) ?? [])
        }
    }
    private static let shells = Set(((try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))

    private static func replay(_ history: Data) -> [String] {
        let path = NSTemporaryDirectory() + "claudetty-" + UUID().uuidString
        FileManager.default.createFile(atPath: path, contents: history)
        return ["sh", "-c", "cat \"$0\"; rm -f \"$0\"; exec \"$SHELL\" -l", path]
    }

    private func restart(_ name: String) -> String? {
        guard let tab = tabs.first(where: { $0.name == name }) else { return "restart: no tab \(name)" }
        guard let session = tab.session, let shell = tab.pid, let front = foreground(shell), let state = tab.claude, state != "asleep" else { return "restart: \(name) runs no Claude" }
        guard state != "working" else { return "restart: \(name) is working; `ct wait \(name) idle` first" }
        restart(tab, session: session, shell: shell, front: front, draft: Self.prompt(name) ?? "")
        return nil
    }

    private func restart(_ tab: Tab, session: String, shell: Int32, front: Int32, draft: String) {
        let words = Self.arguments(front), name = tab.name
        let args = Self.relaunch(front) + Self.resume(tab, session)
        guard front == shell || tab.old else {
            let codeMode = Self.codeMode(tab.transcript)
            Self.onExit(front) { [unowned self] in
                let env = (UserDefaults.standard.bool(forKey: Self.classicKey) ? "env -u CLAUDE_CODE_NO_FLICKER " : "env CLAUDE_CODE_NO_FLICKER=1 ") + codeMode
                _ = try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", name, env + Self.quoted(words[0]) + " " + args + "\r"])
                retype(draft, in: name, after: shell)
            }
            kill(front, SIGTERM)
            return
        }
        replace(tab, shell: shell, command: Self.claude(args, program: Self.quoted(words[0]), env: Self.codeMode(tab.transcript))) { [unowned self] in retype(draft, in: name, after: shell) }
    }

    private func replace(_ tab: Tab, shell: Int32, command: [String], then: @escaping () -> Void = {}) {
        let name = tab.name
        tabs[tabs.firstIndex(of: tab)!] = Tab(name: name, group: tab.group, cwd: tab.folder, labels: tab.labels, ended: shell)
        commands[name] = command
        save()
        func attach(_ tries: Int) {
            guard let tab = tabs.first(where: { $0.name == name }) else { return }
            if tries > 0, FileManager.default.fileExists(atPath: zmxDir + "/" + name) { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attach(tries - 1) } }
            surfaces[name]?.removeFromSuperview()
            makeSurface(tab).setVisible(false)
            rebuild()
            then()
        }
        Self.end(name, shell: shell) { attach(30) }
    }

    private func retype(_ draft: String, in name: String, after shell: Int32, tries: Int = 120) {
        guard !draft.isEmpty, tries > 0, let tab = tabs.first(where: { $0.name == name }) else { return }
        guard let pid = tab.pid, pid != shell || tab.claude != nil, Self.prompt(name) == "" else {
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [unowned self] in retype(draft, in: name, after: shell, tries: tries - 1) }
        }
        _ = try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", name, "\u{1B}[200~" + draft + "\u{1B}[201~"])
    }
    private var nextResume = Date.distantPast
    private let bloated: UInt64 = probe == nil ? 400 << 20 : 1

    private static func jobs(_ session: [String: String], _ tab: Tab?) -> [Job] {
        guard let shell = session["pid"].flatMap(Int32.init), let front = foreground(shell), let own = info(shell)?.pbi_pgid else { return [] }
        let claude = isClaude(shell)
        var found: [proc_bsdinfo] = []
        let command = session["cmd"] != nil && session["replay"] == nil
        var queue = command ? [shell] : children(shell)
        while let pid = queue.popLast() {
            guard !(claude && pid == front), let process = info(pid) else { continue }
            if process.pbi_pgid != own || command { found.append(process) }
            queue += children(pid)
        }
        let leaders = Dictionary(grouping: found, by: \.pbi_pgid).values.map { group in group.min { ($0.pbi_pid != $0.pbi_pgid ? 1 : 0, $0.pbi_start_tvsec) < ($1.pbi_pid != $1.pbi_pgid ? 1 : 0, $1.pbi_start_tvsec) }! }
        let since = { (seconds: UInt64) in Date(timeIntervalSince1970: Double(seconds)) }
        var jobs = leaders.sorted { ($0.pbi_pgid != UInt32(front) ? 1 : 0, $0.pbi_start_tvsec) < ($1.pbi_pgid != UInt32(front) ? 1 : 0, $1.pbi_start_tvsec) }.map { process in
            let words = arguments(Int32(process.pbi_pid), launcher: process.pbi_ppid == UInt32(shell))
            return Job(name: words.first.map { ($0 as NSString).lastPathComponent } ?? withUnsafeBytes(of: process.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }, detail: words.dropFirst().joined(separator: " "), since: since(process.pbi_start_tvsec))
        }
        if claude, let tab {
            jobs.insert(contentsOf: [Job(name: "Claude", detail: tab.claude?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", since: since(info(front)?.pbi_start_tvsec ?? 0))] + tab.tasks.map { task in
                let meta = task[0] == "agent" ? Self.meta(task) : nil
                let words = task[3].split(separator: " ", maxSplits: 1).map(String.init)
                return Job(name: meta.map { $0["agentType"] as? String ?? "agent" } ?? words[0], detail: meta.map { $0["description"] as? String ?? task[1] } ?? words.dropFirst().joined(), since: since(UInt64(task[2]) ?? 0), claudes: true)
            }, at: 0)
        }
        return jobs
    }

    private static func doomedList(_ doomed: [(tab: String, jobs: [Job])]) -> NSView {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        var rows: [NSView] = []
        for (tab, jobs) in doomed {
            if doomed.count > 1 {
                let label = NSTextField(labelWithString: tab)
                label.font = .boldSystemFont(ofSize: font.pointSize)
                label.textColor = .secondaryLabelColor
                rows.append(label)
            }
            rows += jobs.map { job in
                let text = NSMutableAttributedString(string: job.name, attributes: [.font: NSFont.systemFont(ofSize: font.pointSize, weight: .semibold), .foregroundColor: NSColor.labelColor])
                text.append(NSAttributedString(string: "  " + job.detail, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
                let line = NSTextField(labelWithAttributedString: text)
                line.lineBreakMode = .byTruncatingTail
                line.maximumNumberOfLines = 1
                line.cell?.truncatesLastVisibleLine = true
                line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                line.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let time = NSTextField(labelWithString: ago(job.since))
                time.font = .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
                time.textColor = .tertiaryLabelColor
                let row = NSStackView(views: [line, time])
                row.distribution = .fill
                row.edgeInsets.left = job.claudes ? 14 : 0
                return row
            }
        }
        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        for (index, row) in rows.enumerated() where index > 0 && row is NSTextField { list.setCustomSpacing(10, after: rows[index - 1]) }
        for row in rows { row.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -12).isActive = true }
        list.widthAnchor.constraint(equalToConstant: 300).isActive = true
        list.frame.size = list.fittingSize
        return list
    }

    static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 { return info }
        var process = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size, mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &process, &size, nil, 0) == 0, size > 0 else { return nil }
        (info.pbi_pid, info.pbi_ppid, info.pbi_pgid, info.pbi_start_tvsec) = (UInt32(pid), UInt32(process.kp_eproc.e_ppid), UInt32(process.kp_eproc.e_pgid), UInt64(process.kp_proc.p_starttime.tv_sec))
        info.pbi_comm = withUnsafeBytes(of: process.kp_proc.p_comm) { $0.load(as: Swift.type(of: info.pbi_comm)) }
        return info
    }

    private static func end(_ name: String, shell: Int32?, then: @escaping () -> Void = {}) {
        let stuck = shell == nil ? zmxes(name) : []
        var tree: [(pid: Int32, start: UInt64)] = [], next = shell.map { [$0] } ?? stuck
        let front = shell.flatMap(foreground).map(UInt32.init)
        while let pid = next.popLast() {
            guard let found = info(pid) else { continue }
            if found.pbi_pgid != front { tree.append((pid, found.pbi_start_tvsec)) }
            next += children(pid)
        }
        let killing = stuck.isEmpty ? try? Process.run(URL(fileURLWithPath: zmx), arguments: ["kill", name]) { _ in DispatchQueue.main.async(execute: then) } : nil
        if killing == nil { then() }
        let signal = { (number: Int32) in for process in tree where info(process.pid)?.pbi_start_tvsec == process.start { kill(process.pid, number) } }
        signal(SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { signal(SIGKILL) }
    }

    private static func zmxes(_ name: String) -> [Int32] {
        var pids = [Int32](repeating: 0, count: Int(max(proc_listallpids(nil, 0), 0)) + 64)
        let found = Int(max(proc_listallpids(&pids, Int32(pids.count * 4)), 0))
        return pids.prefix(found).filter { pid in
            guard let (count, all) = started(pid), all.count > count, count > 2, (all[1] as NSString).lastPathComponent == "zmx", ["attach", "run"].contains(all[2]) else { return false }
            let at = count > 4 && all[3] == "--labels" ? 5 : 3
            return count > at - 1 && all[at] == name && all[(count + 1)...].first { $0.hasPrefix("ZMX_DIR=") } == ProcessInfo.processInfo.environment["ZMX_DIR"].map { "ZMX_DIR=" + $0 }
        }
    }

    private static func footprint(_ pid: Int32, deep: Bool = true) -> UInt64 {
        var usage = rusage_info_v2()
        let read = withUnsafeMutablePointer(to: &usage) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) } }
        return (deep ? children(pid) : []).reduce(read == 0 ? usage.ri_phys_footprint : 0) { $0 + footprint($1) }
    }

    static func children(_ pid: Int32) -> [Int32] {
        var pids = [Int32](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, Int32(pids.count * 4))
        return Array(pids.prefix(Int(max(bytes, 0)) / 4))
    }

    static func meta(_ agent: [String], read: (String) -> [String: Any]? = json) -> [String: Any] {
        read(String(agent[3].dropLast(5)) + "meta.json") ?? [:]
    }
    static func hue(_ name: String, in folder: String) -> NSColor {
        let file = [folder + "/.claude/agents", NSHomeDirectory() + "/.claude/agents"].lazy.compactMap { try? String(contentsOfFile: $0 + "/\(name).md", encoding: .utf8) }.first
        let named = file?.split(separator: "\n").first { $0.hasPrefix("color:") }.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
        return named.flatMap { hues.firstIndex(of: $0) }.map { hueColors[$0] } ?? hueColors[Int(name.utf8.reduce(UInt32(0)) { $0 &* 31 &+ UInt32($1) } % 8)]
    }
    private static let hues = ["red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan"]
    private static let hueColors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemYellow, .systemPurple, .systemOrange, .systemPink, .systemTeal]

    static func arguments(_ pid: Int32, launcher: Bool = false) -> [String] {
        guard let (count, all) = started(pid) else { return [] }
        let strings = all.dropFirst()
        var words = Array(strings.prefix(count))
        if launcher, !words.isEmpty, let ran = strings.dropFirst(count).first(where: { $0.hasPrefix("_=") }) { words[0] = String(ran.dropFirst(2)) }
        return words
    }

    private static func topic(_ title: String) -> String? {
        guard let glyph = title.first, !glyph.isLetter, !glyph.isNumber, title.dropFirst().first == " " else { return nil }
        let topic = title.dropFirst(2).components(separatedBy: .controlCharacters).joined(separator: " ")
        return topic == "Claude Code" ? "" : topic
    }

    private func name(_ view: SurfaceView?) -> String? { surfaces.first { $0.value === view }?.key }

    private func closed(_ names: [String], detached: Bool = false) {
        guard tabs.contains(where: { names.contains($0.name) }) else { return }
        let all = tabs
        defer {
            if detached {
                tabs = all + tabs.filter { tab in !all.contains { $0.name == tab.name } }
                rebuild()
            }
        }
        if panes.count > 1 { held = frozen() }
        for name in names {
            if !detached { clear(name) }
            surfaces.removeValue(forKey: name)?.removeFromSuperview()
            try? FileManager.default.removeItem(atPath: statusDir + "/" + name + ".topic")
        }
        scheduled.removeAll { names.contains($0[0]) }
        let index = groups.firstIndex(of: selected?.group ?? "") ?? 0
        let pane = selected.map { pane(of: $0) }
        tabs.removeAll { names.contains($0.name) }
        lastTab = lastTab.filter { !names.contains($0.value.name) }
        shown.subtract(names)
        saveSoon()
        guard !tabs.isEmpty else {
            guard names.allSatisfy({ $0.contains("/") }) else { return NSApp.terminate(nil) }
            tabs = [Tab(name: Self.unused("main", takenNames()), group: "main", cwd: NSHomeDirectory(), labels: ["named": "0"])]
            return select(tabs[0])
        }
        guard let group = selected?.group, let name = selected?.name, names.contains(name) else { return rebuild() }
        if let sibling = tabs.first(where: { $0.group == group && self.pane(of: $0) == pane }) { return select(sibling) }
        let left = groups
        guard !left.isEmpty else { return select(latest(in: tabs.first { $0.name == recent.first { name in tabs.contains { $0.name == name } } }?.labels["profile"] ?? tabs[0].labels["profile"])!) }
        select(group: left.contains(group) ? group : left[min(index, left.count - 1)])
    }

    private static func sessions() -> [Tab] {
        let all = list()
        let misread = Dictionary(all.flatMap { [$0["group"], $0["folder"]].compactMap { $0 } }.map { (legacy($0), decoded($0)) }.filter { $0.0 != $0.1 }) { first, _ in first }
        func read(_ label: String) -> String { misread[decoded(label)] ?? decoded(label) }
        let found = all.compactMap { fields -> (Int, Tab)? in
            guard let name = fields["name"], let group = fields["group"] else { return nil }
            var labels = fields.filter { ["color", "pinned", "groupawake", "order", "split", "pane", "title", "rank", "notify", "awake", "named", "replay", "folder", "folderpinned", "folderorder", "foldercolor", "readonly", "pr", "profile", "chat", "opener"].contains($0.key) }.mapValues(decoded)
            labels["folder"] = fields["folder"].map(read)?.uppercased()
            return (Int(fields["created"] ?? "") ?? 0, Tab(name: name, group: read(group), cwd: URL(string: fields["cwd"] ?? "")?.path ?? NSHomeDirectory(), labels: labels, pid: fields["pid"].flatMap(Int32.init), old: fields["zmx"] == "0.8", topic: try? String(contentsOfFile: statusDir + "/" + name + ".topic", encoding: .utf8)))
        }.sorted { $0.0 < $1.0 }.map(\.1)
        let first = Dictionary(found.enumerated().map { ($1.group, $0) }, uniquingKeysWith: { first, _ in first })
        return found.map { (first[$0.group]!, Int($0.labels["rank"] ?? "") ?? .max, $0) }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    private static func redrawClaude(_ name: String) {
        guard let pid = list().first(where: { $0["name"] == name })?["pid"].flatMap(Int32.init), isClaude(pid) else { return }
        _ = try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", name, "\u{0c}"])
    }

    private static func list() -> [[String: String]] {
        let output = String(decoding: zmxOutput("list") ?? Data(), as: UTF8.self)
        return output.split(separator: "\n").map { line in
            Dictionary(line.split(separator: "\t").compactMap { field -> (String, String)? in
                let pair = field.trimmingCharacters(in: .whitespaces.union(["→"])).split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }, uniquingKeysWith: { first, _ in first })
        }
    }


    private static func view(_ userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
        userdata.map { Unmanaged<SurfaceView>.fromOpaque($0).takeUnretainedValue() }
    }

    private func perform(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        let view = target.tag == GHOSTTY_TARGET_SURFACE ? Self.view(target.target.surface.flatMap(ghostty_surface_userdata)) : nil
        switch action.tag {
        case GHOSTTY_ACTION_CELL_SIZE:
            let backing = NSSize(width: Double(action.action.cell_size.width), height: Double(action.action.cell_size.height))
            view?.cellSize = view?.convertFromBacking(backing) ?? .zero
            refit()
        case GHOSTTY_ACTION_OPEN_URL:
            let link = String(decoding: UnsafeRawBufferPointer(start: action.action.open_url.url, count: Int(action.action.open_url.len)), as: UTF8.self)
            DispatchQueue.main.async { self.open(link, from: view) }
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = action.action.desktop_notification
            let parts = [note.title, note.body].map { String(cString: $0) }.filter { !$0.isEmpty }
            guard parts.first != "Claude Code" else { return true }
            return notice(parts.joined(separator: ": "), from: view)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED where view != nil && view === scratch.surface:
            DispatchQueue.main.async { [self] in
                if scratch.open { window.makeFirstResponder(selected.flatMap { surfaces[$0.name] }) }
                scratch.end()
            }
        case GHOSTTY_ACTION_RING_BELL:
            guard tabs.first(where: { $0.name == name(view) })?.claude == nil else { return true }
            return notice("Rang the bell", from: view)
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            guard let name = name(view), tabs.first(where: { $0.name == name })?.claude == nil else { return true }
            let report = action.action.progress_report, at = Date()
            progresses[name] = report.state == GHOSTTY_PROGRESS_STATE_REMOVE ? nil : (report, at)
            if let ring = tabRings[name], progresses[name] != nil {
                ring.report = report
            } else if tabs.contains(where: { $0.name == name && $0.group == selected?.group }) {
                rebuild()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, progresses[name]?.at == at else { return }
                progresses[name] = nil
                if tabRings[name] != nil { rebuild() }
            }
        case GHOSTTY_ACTION_READONLY:
            let on = action.action.readonly == GHOSTTY_READONLY_ON
            view?.readonly = on
            guard let tab = tabs.first(where: { $0.name == name(view) }), (tab.labels["readonly"] != nil) != on else { return true }
            label(tab.group, "readonly", on ? "1" : "", tab: tab.name)
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let finished = action.action.command_finished
            guard finished.duration >= 5_000_000_000 else { return true }
            let took = Duration.nanoseconds(Int64(finished.duration)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
            return notice(finished.exit_code > 0 ? "Failed with code \(finished.exit_code) after \(took)" : "Finished in \(took)", from: view)
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let over = action.action.mouse_over_link
            let link = String(decoding: UnsafeRawBufferPointer(start: over.url, count: Int(over.len)), as: UTF8.self)
            let url = link.isEmpty ? nil : self.target(link, from: folder(of: view))?.url
            view?.box(url?.isFileURL == true ? over : nil)
            return url != nil
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            (action.action.mouse_shape == GHOSTTY_MOUSE_SHAPE_POINTER ? NSCursor.pointingHand : action.action.mouse_shape == GHOSTTY_MOUSE_SHAPE_TEXT ? .iBeam : .arrow).set()
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
        case GHOSTTY_ACTION_OPEN_CONFIG:
            openConfig()
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            reloadConfig()
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
        case GHOSTTY_ACTION_NEW_TAB:
            newTab()
        case GHOSTTY_ACTION_NEW_SPLIT:
            let direction = action.action.new_split
            selected.map { split(pane(of: $0), across: direction == GHOSTTY_SPLIT_DIRECTION_RIGHT || direction == GHOSTTY_SPLIT_DIRECTION_LEFT, before: direction == GHOSTTY_SPLIT_DIRECTION_LEFT || direction == GHOSTTY_SPLIT_DIRECTION_UP) }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            goTo(split: action.action.goto_split)
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            toggleZoom()
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            terminal.subviews.first.map(even)
        case GHOSTTY_ACTION_NEW_WINDOW:
            newGroup()
        case GHOSTTY_ACTION_CLOSE_WINDOW:
            selected.map { closing(group: $0.group) }
        case GHOSTTY_ACTION_GOTO_TAB:
            goTo(action.action.goto_tab)
        case GHOSTTY_ACTION_START_SEARCH:
            guard let view else { return false }
            (view.find ?? FindBar(view)).open(String(cString: action.action.start_search.needle))
        case GHOSTTY_ACTION_END_SEARCH:
            view?.find?.close()
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            view?.find?.total = action.action.search_total.total < 0 ? nil : action.action.search_total.total
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            view?.find?.selected = action.action.search_selected.selected < 0 ? nil : action.action.search_selected.selected
        case GHOSTTY_ACTION_SCROLLBAR:
            view?.scrollbar(action.action.scrollbar)
        case GHOSTTY_ACTION_SET_TITLE:
            if front != fronts { rebuild() }
            if let name = name(view), let tab = tabs.first(where: { $0.name == name }), let topic = Self.topic(String(cString: action.action.set_title.title)), topic != tab.topic ?? "", tab.claude != nil {
                let path = statusDir + "/" + name + ".topic"
                _ = topic.isEmpty ? try? FileManager.default.removeItem(atPath: path) : try? topic.write(toFile: path, atomically: true, encoding: .utf8)
                tabs[tabs.firstIndex(of: tab)!].topic = topic.isEmpty ? nil : topic
                rebuild()
            }
        case GHOSTTY_ACTION_COLOR_CHANGE:
            let change = action.action.color_change
            guard let view, change.kind == GHOSTTY_ACTION_COLOR_KIND_EDGE || change.kind == GHOSTTY_ACTION_COLOR_KIND_EDGE_DEFAULT else { return false }
            view.edge = (NSColor(srgbRed: CGFloat(change.r) / 255, green: CGFloat(change.g) / 255, blue: CGFloat(change.b) / 255, alpha: 1), change.kind == GHOSTTY_ACTION_COLOR_KIND_EDGE)
            edges()
        default:
            return false
        }
        return true
    }

    private func notice(_ text: String, from view: SurfaceView?) -> Bool {
        guard let name = name(view), !text.isEmpty else { return false }
        return (try? text.write(toFile: statusDir + "/" + name + ".notice", atomically: true, encoding: .utf8)) != nil
    }

    private func open(_ link: String, from view: SurfaceView?, reveal: Bool = false) {
        let start = folder(of: view)
        guard case (var url, let line)? = target(link, from: start) else { return }
        if reveal || view?.revealing == true, url.isFileURL {
            if let probe { return try! (link + " → reveal " + url.path).write(toFile: probe + "/opened", atomically: true, encoding: .utf8) }
            return NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        let script = (probe.map { $0 + "/config" } ?? NSHomeDirectory() + "/.config/claudetty") + "/open"
        if FileManager.default.isExecutableFile(atPath: script) {
            let arguments = [url.isFileURL ? url.path + (line.map { ":\($0.row):\($0.column)" } ?? "") : url.absoluteString, start.path]
            if let probe { return try! (link + " → " + ([script] + arguments).joined(separator: " ")).write(toFile: probe + "/opened", atomically: true, encoding: .utf8) }
            _ = try? Process.run(URL(fileURLWithPath: script), arguments: arguments)
            return
        }
        let tool = url.isFileURL ? Self.isText(url) ? "ttt" : nil : url.scheme == "http" || url.scheme == "https" ? "terminal-browser" : nil
        if let tool, let path = Self.loginPath, let from = tabs.first(where: { surfaces[$0.name] === view }), let found = path.split(separator: ":").map({ $0 + "/" + tool }).first(where: FileManager.default.isExecutableFile) {
            let open = tabs.first { $0.group == from.group && commands[$0.name]?.contains(found) == true }
            guard let pane = open.map({ pane(of: $0) }) ?? newPane(beside: pane(of: from), in: from.group, across: true, before: false) else { return NSSound.beep() }
            let arguments = url.isFileURL ? [url.path + (line.map { ":\($0.row):\($0.column)" } ?? "")] : ["open", url.absoluteString]
            return newTab(pane: pane, beside: from, named: tool == "ttt" ? "ttt" : "browser", command: ["env", "PATH=" + path, found] + arguments)
        }
        var xed: [String]?
        if let line, let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            let opener = Bundle(url: app)?.bundleIdentifier
            if opener == "com.apple.dt.Xcode" { xed = ["--line", String(line.row), url.path] }
            else if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil { url = URL(string: "vscode://file")!.appending(path: url.path + ":\(line.row):\(line.column)") }
        }
        if let probe { return try! (link + " → " + (xed.map { "xed " + $0.joined(separator: " ") } ?? url.absoluteString)).write(toFile: probe + "/opened", atomically: true, encoding: .utf8) }
        if let xed {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/xed"), arguments: xed)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func folder(of view: SurfaceView?) -> URL { URL(fileURLWithPath: tabs.first { surfaces[$0.name] === view }?.folder ?? NSHomeDirectory(), isDirectory: true) }

    private func target(_ link: String, from start: URL) -> (url: URL, line: (row: Int, column: Int)?)? {
        let path = (link as NSString).expandingTildeInPath
        let names = [path] + path.indices.filter { path[$0] == " " }.reversed().map { String(path[..<$0]) }
        let tries: [(String, (row: Int, column: Int)?)] = names.flatMap { name in
            let bare = name.replacing(#/[.,;:)'"”’]+$/#, with: "")   // a sentence's "see notes.md." or "(at app.js:12)", tried after the name as written
            let numbered = bare.wholeMatch(of: #/(.+?):(\d+)(?::(\d+))?/#)
            return [(name, nil), (bare, nil)] + (numbered.map { [(String($0.1), (Int($0.2)!, $0.3.flatMap { Int($0) } ?? 1))] } ?? [])
        }
        var url: URL? = link.contains("://") || link.hasPrefix("mailto:") ? URL(string: link) : nil
        var line: (row: Int, column: Int)?
        folders: for folder in sequence(first: start, next: { $0.path == "/" ? nil : $0.deletingLastPathComponent() }) where url == nil {
            for (candidate, at) in tries where !candidate.isEmpty && FileManager.default.fileExists(atPath: URL(fileURLWithPath: candidate, relativeTo: folder).path) {
                url = URL(fileURLWithPath: candidate, relativeTo: folder).standardizedFileURL
                line = at
                break folders
            }
        }
        if url == nil, link.wholeMatch(of: #/localhost(:\d+)?(\/.*)?/#) != nil { url = URL(string: "http://" + link) }
        return (url ?? Self.links.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)).flatMap { $0.range.length == link.utf16.count ? $0.url : nil }).map { ($0, line) }
    }

    private static let mimes: [String: NSPasteboard.PasteboardType] = ["text/plain": .string, "text/html": .html, "image/png": .png]
    private static let links = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static func isText(_ url: URL) -> Bool { (try? FileHandle(forReadingFrom: url).read(upToCount: 8000))?.contains(0) == false }
    static var loginPath: String?
    private static func shellPath() -> String {
        let shell = Process(), file = NSTemporaryDirectory() + "claudetty-path-\(getpid())"
        shell.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        shell.arguments = ["-lic", "printf %s \"$PATH\" > \"$CLAUDETTY_PATH_FILE\""]
        shell.environment = ProcessInfo.processInfo.environment.merging(["CLAUDETTY_PATH_FILE": file]) { $1 }
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if shell.isRunning { kill(shell.processIdentifier, SIGKILL) } }
        shell.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: file) }
        return (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
    }

    static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        guard location == GHOSTTY_CLIPBOARD_STANDARD else { return nil }
        return probe == nil ? .general : NSPasteboard(name: .init("dev.claudetty.probe." + probe!))
    }

    private static func pasteText(_ pasteboard: NSPasteboard) -> String? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return files.map { escape($0.path) }.joined(separator: " ") }
        if let text = pasteboard.string(forType: .string) { return text }
        guard let png = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "claudetty-paste")
        let file = folder.appending(path: "\(Int(Date().timeIntervalSince1970 * 1000)).png")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil, (try? png.write(to: file)) != nil else { return nil }
        return escape(file.path)
    }

    private static func dropTexts(_ pasteboard: NSPasteboard, claude: Bool) -> [String] {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard claude, !files.isEmpty else { return pasteText(pasteboard).map { [$0] } ?? [] }
        let images = files.filter { ["png", "jpg", "jpeg", "gif", "webp"].contains($0.pathExtension.lowercased()) }
        let others = files.filter { !images.contains($0) }.map { "@\"\($0.path)\"" }
        return [images.map { escape($0.path) }.joined(separator: " "), others.isEmpty ? "" : (images.isEmpty ? "" : " ") + others.joined(separator: " ") + " "].filter { !$0.isEmpty }
    }

    private static func escape(_ path: String) -> String {
        path.reduce(into: "") { escaped, char in
            if "\\ ()[]{}<>\"'`!#$&;|*?\t".contains(char) { escaped.append("\\") }
            escaped.append(char)
        }
    }

    private static func readClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer) -> ghostty_clipboard_read_result_e {
        guard let surface = view(userdata)?.surface, let pasteboard = pasteboard(location) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        guard let text = pasteText(pasteboard) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, text, state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private func pasting(_ text: String, _ view: SurfaceView, _ state: UnsafeMutableRawPointer) {
        let lines = text.split(whereSeparator: \.isNewline)
        let indent = NSMutableParagraphStyle()
        indent.firstLineHeadIndent = 6
        indent.headIndent = 6
        indent.lineBreakMode = .byTruncatingTail
        let preview = NSTextField(labelWithAttributedString: NSAttributedString(string: lines.prefix(6).joined(separator: "\n") + (lines.count > 6 ? "\n…" : ""), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: indent]))
        preview.frame.size = NSSize(width: 300, height: preview.fittingSize.height)
        confirm(lines.count > 1 ? "Paste \(lines.count) lines?" : "Paste this text?", preview, "Paste") { paste in
            guard let surface = view.surface else { return }
            paste ? Self.complete(surface, text, state, confirmed: true) : ghostty_surface_deny_clipboard_request(surface, state)
        }
    }

    private static func complete(_ surface: ghostty_surface_t, _ text: String, _ state: UnsafeMutableRawPointer, confirmed: Bool) {
        "text/plain".withCString { mime in
            text.withCString { data in
                withUnsafePointer(to: ghostty_clipboard_content_s(mime: mime, data: data, len: text.utf8.count)) { content in
                    var complete = ghostty_clipboard_complete_s(contents: content, contents_len: 1, available: nil, available_len: 0, confirmed: confirmed, remember: false)
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }
    }

    private static func writeClipboard(_ location: ghostty_clipboard_e, _ content: UnsafePointer<ghostty_clipboard_content_s>, _ count: Int) {
        guard let pasteboard = pasteboard(location) else { return }
        let items = (0..<count).compactMap { index -> (NSPasteboard.PasteboardType, Data)? in
            let item = content[index]
            guard let type = Self.mimes[String(cString: item.mime)] else { return nil }
            return (type, Data(bytes: item.data, count: item.len))
        }
        guard !items.isEmpty else { return }
        pasteboard.declareTypes(items.map(\.0), owner: nil)
        for (type, data) in items {
            pasteboard.setData(data, forType: type)
        }
    }
}

final class Window: NSPanel {
    override var canBecomeMain: Bool { true }
    override var title: String { didSet { if isVisible || isMiniaturized { NSApp.changeWindowsItem(self, title: title, filename: false) } } }
    override func order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        super.order(place, relativeTo: other)
        if place != .out { NSApp.addWindowsItem(self, title: title, filename: false) }
    }
    override func doCommand(by selector: Selector) {
        selector == #selector(cancelOperation(_:)) ? cancelOperation(nil) : super.doCommand(by: selector)
    }
    override func cancelOperation(_ sender: Any?) {
        let pick = #selector(cancelOperation(_:))
        unsafeBitCast(class_getMethodImplementation(NSWindow.self, pick), to: (@convention(c) (NSWindow, Selector, Any?) -> Void).self)(self, pick, sender)
    }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { probe == nil ? super.constrainFrameRect(frameRect, to: screen) : frameRect }
}

final class Root: NSView {
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window?.performMiniaturize(nil)
        case "None", "Do Nothing": break
        default: window?.performZoom(nil)
        }
    }
}

final class Body: NSView {
    static func unsnapped(_ window: NSWindow, _ size: NSSize) -> Bool { size == window.screen?.visibleFrame.size || window.styleMask.contains(.fullScreen) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        fit()
    }
    func fit() {
        for case let view as SurfaceView in subviews {
            let left = view.cellSize.height > 0 ? (bounds.height - ClaudeTTY.padding.height).truncatingRemainder(dividingBy: view.cellSize.height) : 0
            view.frame = NSRect(x: 0, y: -left.rounded(.down), width: bounds.width, height: bounds.height)
        }
    }
}

struct Outgoing: Codable, Equatable { var text: String, at = Date(), pid: Int32? = nil, session: String? = nil, transcript: UInt64 = 0, history: UInt64 = 0, answer = false }

final class Chat: NSView, NSTextFieldDelegate {
    struct Entry {
        enum Kind { case user, reply, tool, divider, seen, pasted, notice, compaction, summary, output }
        var kind: Kind, text: String, name = "", id = "", at: Date
        var images: [Data] = []
        var status = "", result = ""
        var mode: String? = nil
        var ask = Ask()
        var figure: String? = nil
        var failed = false, old = "", new = ""
    }
    static let lookKey = "chat look " + zmxDir
    static var look = UserDefaults.standard.string(forKey: lookKey) ?? "B"
    struct Theme { var ink: NSColor, palette: [NSColor], font: NSFont }
    struct Call: Equatable { var name = "", id = "", line = "", body = "", output = "", status = "", old = "", new = "", open = false, more = false }
    var theme: () -> (Theme, Bool) = { (Theme(ink: .white, palette: [], font: .monospacedSystemFont(ofSize: 13, weight: .regular)), false) }
    private var themed: (theme: Theme, real: Bool)?
    struct Ask: Equatable { var detail = "", body = "", options: [String] = [], pick = false }
    enum Item: Equatable { case user(String), unsent(String), reply(String), divider(String), fold(id: String, text: String, time: String, open: Bool), call(Call), live(line: String, at: Date), ask(name: String, head: String, ask: Ask), images([Data], pasted: Bool), notice(id: String, kind: String, title: String, status: String, result: String, open: Bool), figure(String), sendNow, compaction(id: String, title: String, before: Int, after: Int, summary: String, open: Bool, since: Date?) }

    static let compacted = "arrow.down.right.and.arrow.up.left"
    static let bar: CGFloat = 36, slot: CGFloat = 36 + 5 + 16 + 10
    private static let chunk: UInt64 = 262_144
    private static let words = ["Bash": ("Ran", "command"), "Agent": ("Started", "agent"), "Read": ("Read", "file"), "Edit": ("Edited", "file"), "WebFetch": ("Fetched", "page")]
    private static let icons = ["Bash": "terminal", "Agent": "person.2", "Read": "doc.text", "Edit": "pencil", "WebFetch": "globe"]

    let path: String
    var tab: () -> Tab? = { nil }
    var warmed: (Tab) -> Date? = { _ in nil }
    var keys: (String) -> Void = { _ in }
    var send: (String) -> Void = { _ in }
    var enter: (String) -> Void = { _ in }
    var mirror: String?
    private(set) var seen: String?
    private var settled: String?, edited = Date.distantPast
    var unsent: () -> [Outgoing] = { [] }
    var takeBack: () -> String = { "" }
    var terminal: () -> Void = {}
    var cycle: (String) -> Void = { _ in }
    var kept: (Tab) -> Date? = { _ in nil }
    var keepWarm: (Tab) -> String? = { _ in nil }
    var compacting: (Bool) -> Void = { _ in }
    var openWorker: ([String]) -> Void = { _ in }
    var link: (String, _ reveal: Bool?) -> Bool = { _, _ in false }
    private var hover: Any?, hot: Text?
    var showPanel: (() -> Void)? { didSet { needsLayout = true } }
    private let workersRow = Flip()
    private var above: CGFloat = 0, workersDrawn: [String] = []
    private var grown: CGFloat = 0
    var sideWanted = false { didSet { fitSide() } }
    var alone = false { didSet { fitSide() } }
    var toggleSide: () -> Void = {}
    private var sideShown = false { didSet { if sideShown != oldValue { showSide() } } }
    private static let minLane: CGFloat = 360
    private func fitSide() {
        let fits = bounds.width - Self.sideWidth >= Self.minLane
        sideShown = sideWanted && fits
        toggle.isHidden = !(alone && fits)
    }
    private(set) lazy var toggle = ClaudeTTY.iconButton(ClaudeTTY.symbol("sidebar.right"), "Side Panel", "Side panel (⌃⌘I)", self, #selector(toggled), size: 12, lit: ClaudeTTY.symbol("sidebar.right"))
    @objc private func toggled() { toggleSide() }
    var toggleFrame: NSRect? { toggle.isHidden ? nil : convert(toggle.frame, to: nil) }
    let composer = NSTextField(string: "")
    private let glass = NSGlassEffectView(), barContent = Flip(), placeholder = Text(NSAttributedString(), width: 0), round = Press(""), factsRow = Flip()
    private var facts: [Fact] = []
    private let viewport = Flip(), scroll = NSScrollView(), doc = Doc(), fade = CAGradientLayer()
    private var entries: [Entry] = [], start: UInt64 = 0, end: UInt64 = 0
    private var rows: [(item: Item, view: NSView, gap: CGFloat)] = []
    private var open: Set<String> = []
    private var column: CGFloat = 0, dark = true, stuck = true
    private var paging = false, swiping = false, clock: (text: Text, at: Date)?, ticker: Timer?, minutes: Timer?, shownFacts: [String] = []
    private var popover: Popover?
    private weak var contextFact: Fact?
    private let side = Flip(), sideScroll = NSScrollView(), sideDoc = Flip()
    private var sideDrawn: [String] = []
    private var sideParts: [(shows: String, views: [NSView], top: CGFloat, foot: CGFloat)] = []
    static let sideWidth: CGFloat = 272
    private weak var allow: NSButton?
    private weak var numbered: NSView?
    private var caret: NSRange?
    private var recall: (prompts: [String], at: Int)?
    private var finder: FindBar?
    private var needle = "", hits: [Int] = [], hit = 0
    private var preview: Preview?
    private var previewKeys: Any?

    final class Flip: NSView { override var isFlipped: Bool { true } }
    final class Press: NSButton {
        var run: () -> Void = {}
        convenience init(_ title: String = "", run: @escaping () -> Void = {}) {
            self.init(frame: .zero)
            self.title = title
            self.run = run
            (target, action) = (self, #selector(fire))
        }
        @objc private func fire() { run() }
    }
    final class Code: NSView {
        private let copy: NSView
        private var lit = false {
            didSet {
                guard lit != oldValue else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.timingFunction = .init(name: .easeOut)
                    copy.animator().alphaValue = lit ? 1 : 0
                }
            }
        }
        init(frame: NSRect, copy: NSView) {
            self.copy = copy
            super.init(frame: frame)
            wantsLayer = true
            copy.alphaValue = 0
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override func mouseEntered(with event: NSEvent) { lit = true }
        override func mouseExited(with event: NSEvent) { lit = false }
        override func mouseMoved(with event: NSEvent) { lit = true }
    }
    final class Fact: NSView {
        private let lit = Flip()
        let click: ((Fact) -> Void)?
        init(_ parts: [NSView], lit glowing: [NSView], halo: NSColor?, click: ((Fact) -> Void)?, tall: Bool = false) {
            self.click = click
            super.init(frame: .zero)
            clipsToBounds = false
            let shadow = halo.map { halo in
                let shadow = NSShadow()
                shadow.shadowColor = halo
                shadow.shadowBlurRadius = 7
                return shadow
            }
            var x: CGFloat = -2
            for (part, glow) in zip(parts, glowing) {
                part.frame.origin = NSPoint(x: x, y: tall ? 0 : (part as? Text).map { Chat.capCentered($0, in: 16) } ?? ((16 - part.frame.height) / 2).rounded())
                glow.frame = part.frame
                addSubview(part)
                if glow is Text || glow is NSImageView { lit.addSubview(glow) }
                if glow is Text, let shadow {
                    glow.shadow = shadow
                    glow.clipsToBounds = false
                }
                x = part.frame.maxX + (part is Text ? 3 : 4)
            }
            frame.size = NSSize(width: x - 3, height: tall ? parts.map(\.frame.maxY).max() ?? 16 : 16)
            lit.frame = bounds
            lit.clipsToBounds = false
            lit.wantsLayer = true
            lit.shadow = halo.map { halo in let bloom = NSShadow(); bloom.shadowColor = halo.withAlphaComponent(halo.alphaComponent * 0.6); bloom.shadowBlurRadius = 14; return bloom }
            lit.isHidden = true
            lit.alphaValue = 0
            addSubview(lit)
            if click != nil { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)) }
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override func resetCursorRects() { if click != nil { addCursorRect(bounds, cursor: .pointingHand) } }
        override func hitTest(_ point: NSPoint) -> NSView? { click != nil && frame.contains(point) ? self : nil }
        override func mouseDown(with event: NSEvent) { click?(self) }
        override func mouseEntered(with event: NSEvent) { glow(true) }
        override func mouseExited(with event: NSEvent) { glow(false) }
        private func glow(_ on: Bool) {
            guard click != nil else { return }
            lit.isHidden = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = on ? 0.12 : 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                self.lit.animator().alphaValue = on ? 1 : 0
            }, completionHandler: { [weak self] in if let self, lit.alphaValue == 0 { lit.isHidden = true } })
        }
    }
    final class Doc: NSView {
        override var isFlipped: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard let chat = enclosingScrollView?.superview?.superview as? Chat else { return }
            chat.unpick()
            window?.makeFirstResponder(chat)
        }
    }
    final class Fold: NSView {
        var toggle: () -> Void = {}
        override var isFlipped: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if let lane = enclosingScrollView { window?.makeFirstResponder(lane.superview?.superview) }
            toggle()
        }
    }
    class Mark: NSImageView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    final class Fill: Mark {
        override var wantsUpdateLayer: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            guard let image else { return }
            let scale = max(bounds.width / max(image.size.width, 1), bounds.height / max(image.size.height, 1))
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        }
    }
    final class Preview: NSPanel {
        let images: [NSImage]
        private(set) var index: Int
        private let view = NSImageView()
        init(_ images: [NSImage], at index: Int, over parent: NSWindow) {
            self.images = images
            self.index = index
            let room = (parent.screen ?? NSScreen.main).map { $0.visibleFrame.size } ?? NSSize(width: 1200, height: 800)
            let size = images.reduce(NSSize.zero) { most, image in
                let pixels = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
                let scale = min(0.5, room.width * 0.8 / max(pixels.width, 1), room.height * 0.8 / max(pixels.height, 1))
                return NSSize(width: max(most.width, pixels.width * scale), height: max(most.height, pixels.height * scale))
            }
            let content = NSRect(x: 0, y: 0, width: max(320, size.width.rounded()), height: max(240, size.height.rounded()))
            super.init(contentRect: content, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
            hidesOnDeactivate = probe == nil
            view.imageScaling = .scaleProportionallyUpOrDown
            view.autoresizingMask = [.width, .height]
            view.frame = content
            contentView?.addSubview(view)
            show()
            setFrameOrigin(probe == nil ? NSPoint(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2) : NSPoint(x: -20_000, y: -20_000))
        }
        private func show() {
            view.image = images[index]
            title = images.count > 1 ? "\(index + 1) of \(images.count)" : ""
        }
        func handle(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 123: index = max(0, index - 1)
            case 124: index = min(images.count - 1, index + 1)
            case 53, 49: close()
            default: return false
            }
            show()
            return true
        }
        var closed: () -> Void = {}
        override func keyDown(with event: NSEvent) { if !handle(event) { super.keyDown(with: event) } }
        override func cancelOperation(_ sender: Any?) { close() }
        override func close() {
            super.close()
            closed()
        }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { probe == nil ? super.constrainFrameRect(frameRect, to: screen) : frameRect }
    }
    final class Text: NSView {
        var string: NSAttributedString
        init(_ string: NSAttributedString, width: CGFloat) {
            self.string = string
            super.init(frame: .zero)
            clipsToBounds = true
            fit(width)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { true }
        override var firstBaselineOffsetFromTop: CGFloat {
            let font = string.length > 0 ? string.attribute(.font, at: string.length - 1, effectiveRange: nil) as? NSFont : nil
            return ((string.length > 0 ? string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil)?.minimumLineHeight ?? 18) + (font ?? .systemFont(ofSize: 13)).descender
        }
        var inkInset: (top: CGFloat, bottom: CGFloat) {
            guard string.length > 0, let font = string.attribute(.font, at: string.length - 1, effectiveRange: nil) as? NSFont else { return (0, 0) }
            let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(string), .useGlyphPathBounds)
            return (firstBaselineOffsetFromTop - ink.maxY, ink.minY - font.descender)
        }
        func centered(in height: CGFloat) -> CGFloat { (height - frame.height + inkInset.bottom - inkInset.top).rounded() / 2 }
        func fit(_ width: CGFloat) {
            let size = string.boundingRect(with: NSSize(width: floor(width), height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
            frame.size = NSSize(width: ceil(size.width) + 4, height: ceil(size.height))
            needsDisplay = true
        }
        var found: [NSRange] = [], current = false
        var hot: NSRange? { didSet { if hot != oldValue { needsDisplay = true } } }
        var picked: NSRange? { didSet { if picked != oldValue { needsDisplay = true } } }
        override func draw(_ dirty: NSRect) {
            var shown = string
            if !found.isEmpty || hot != nil || picked != nil {
                let lit = NSMutableAttributedString(attributedString: string)
                let color = current ? NSColor(srgbRed: 0xF2 / 255, green: 0xA5 / 255, blue: 0x7E / 255, alpha: 1) : NSColor(srgbRed: 1, green: 0xE0 / 255, blue: 0x82 / 255, alpha: 1)
                for range in found { lit.addAttributes([.backgroundColor: color, .foregroundColor: NSColor.black], range: range) }
                if let hot { lit.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: hot) }
                if let picked { lit.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, range: picked) }
                shown = lit
            }
            shown.draw(with: bounds.insetBy(dx: 2, dy: 0), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
        func word(at point: NSPoint) -> (word: String, range: NSRange, drawn: Bool)? {
            let (storage, layout, box, spot) = laid(point)
            defer { withExtendedLifetime(storage) {} }
            let glyph = layout.glyphIndex(for: spot, in: box)
            guard string.length > 0, layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: box).contains(spot) else { return nil }
            let index = layout.characterIndexForGlyph(at: glyph), text = string.string as NSString
            var linked = NSRange()
            if let link = string.attribute(.link, at: index, effectiveRange: &linked) { return ((link as? URL)?.absoluteString ?? String(describing: link), linked, true) }
            let back = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards, range: NSRange(location: 0, length: index))
            let ahead = text.rangeOfCharacter(from: .whitespacesAndNewlines, range: NSRange(location: index, length: text.length - index))
            let start = back.location == NSNotFound ? 0 : NSMaxRange(back), end = ahead.location == NSNotFound ? text.length : ahead.location
            let marks = CharacterSet(charactersIn: "()[]{}<>\"'`“”‘’*")
            var range = NSRange(location: start, length: max(end - start, 0))
            while range.length > 0, marks.contains(UnicodeScalar(text.character(at: range.location)) ?? " ") { range = NSRange(location: range.location + 1, length: range.length - 1) }
            while range.length > 0, marks.contains(UnicodeScalar(text.character(at: NSMaxRange(range) - 1)) ?? " ") { range.length -= 1 }
            return range.length > 0 ? (text.substring(with: range), range, false) : nil
        }
        func index(at point: NSPoint) -> Int {
            let (storage, layout, box, spot) = laid(point)
            defer { withExtendedLifetime(storage) {} }
            var fraction: CGFloat = 0
            let index = layout.characterIndex(for: spot, in: box, fractionOfDistanceBetweenInsertionPoints: &fraction)
            return min(string.length, index + (fraction > 0.5 ? 1 : 0))
        }
        private func laid(_ point: NSPoint) -> (NSTextStorage, NSLayoutManager, NSTextContainer, NSPoint) {
            let storage = NSTextStorage(attributedString: string), layout = NSLayoutManager(), box = NSTextContainer(size: NSSize(width: bounds.width - 4, height: 100_000))
            box.lineFragmentPadding = 0
            layout.addTextContainer(box)
            storage.addLayoutManager(layout)
            return (storage, layout, box, convert(point, from: nil).applying(CGAffineTransform(translationX: -2, y: 0)))
        }
        override func mouseDown(with event: NSEvent) {
            guard let chat = enclosingChat, chat.clicked(self, event) || chat.select(from: self, event) else { return super.mouseDown(with: event) }
        }
        private var enclosingChat: Chat? { sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? Chat }.first }
    }
    private func clicked(_ text: Text, _ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        guard text.isDescendant(of: doc), let found = text.word(at: event.locationInWindow), command || found.drawn else { return false }
        return link(found.word, command && event.modifierFlags.contains(.control))
    }
    private var picks: [Text] = []
    private func select(from text: Text, _ event: NSEvent) -> Bool {
        guard text.isDescendant(of: doc), let window else { return false }
        func all(_ view: NSView) -> [Text] { view.subviews.flatMap { ($0 as? Text).map { [$0] } ?? all($0) } }
        let texts = all(doc).map { ($0, $0.convert($0.bounds, to: doc)) }.sorted { ($0.1.minY, $0.1.minX) < ($1.1.minY, $1.1.minX) }.map(\.0)
        let anchor = (text, text.index(at: event.locationInWindow))
        var head = anchor, dragged = false
        unpick()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            dragged = dragged || hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) > 3
            guard dragged else { continue }
            doc.autoscroll(with: next)
            if let over = lane(next) { head = (over, over.index(at: next.locationInWindow)) }
            guard let a = texts.firstIndex(where: { $0 === anchor.0 }), let h = texts.firstIndex(where: { $0 === head.0 }) else { continue }
            let (from, to) = (a, anchor.1) <= (h, head.1) ? ((a, anchor.1), (h, head.1)) : ((h, head.1), (a, anchor.1))
            unpick()
            picks = Array(texts[from.0...to.0])
            for (index, text) in picks.enumerated() {
                let start = index == 0 ? from.1 : 0, end = index == picks.count - 1 ? to.1 : text.string.length
                text.picked = NSRange(location: start, length: end - start)
            }
        }
        if dragged { window.makeFirstResponder(self) }
        return dragged
    }
    private func unpick() {
        picks.forEach { $0.picked = nil }
        picks = []
    }
    @objc func copy(_ sender: Any?) {
        let text = picks.compactMap { text in text.picked.map { (text.string.string as NSString).substring(with: $0) } }.joined(separator: "\n").replacingOccurrences(of: "\u{FFFC}\t", with: "")
        guard !text.isEmpty, let board = ClaudeTTY.pasteboard(GHOSTTY_CLIPBOARD_STANDARD) else { return }
        board.clearContents()
        board.setString(text, forType: .string)
    }
    final class LineEditor: NSTextView {
        override func keyDown(with event: NSEvent) {
            guard [36, 76].contains(event.keyCode), event.modifierFlags.contains(.shift) else { return super.keyDown(with: event) }
            insertNewlineIgnoringFieldEditor(nil)
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !picks.isEmpty, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "c" else { return super.performKeyEquivalent(with: event) }
        copy(nil)
        return true
    }
    private func lane(_ event: NSEvent, at point: NSPoint? = nil) -> Text? {
        guard let window, event.window === window, !isHiddenOrHasHiddenAncestor, let host = doc.superview else { return nil }
        return doc.hitTest(host.convert(point ?? event.locationInWindow, from: nil)) as? Text
    }
    private func hovered(_ event: NSEvent) {
        let point = window?.mouseLocationOutsideOfEventStream ?? .zero
        let text = event.modifierFlags.contains(.command) ? lane(event, at: point) : nil
        let found = text.flatMap { $0.word(at: point) }.flatMap { link($0.word, nil) ? $0.range : nil }
        let was = hot != nil
        if hot !== text || hot?.hot != found { hot?.hot = nil }
        hot = found == nil ? nil : text
        hot?.hot = found
        if found != nil { NSCursor.pointingHand.set() } else if was { NSCursor.arrow.set() }
    }

    init(path: String) {
        self.path = path
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
        viewport.autoresizingMask = [.width, .height]
        viewport.wantsLayer = true
        viewport.layer?.mask = fade
        for (view, document) in [(scroll, doc), (sideScroll, sideDoc)] {
            view.autoresizingMask = [.width, .height]
            view.drawsBackground = false
            view.contentView.drawsBackground = false
            view.hasVerticalScroller = true
            view.autohidesScrollers = true
            view.scrollerStyle = .overlay
            view.documentView = document
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: nil) { [weak self] _ in self?.swiping = true }
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: nil) { [weak self] _ in
            self?.swiping = false
            self?.place()
        }
        viewport.addSubview(scroll)
        addSubview(viewport)
        glass.cornerRadius = Self.bar / 2
        glass.contentView = barContent
        composer.isBordered = false
        composer.drawsBackground = false
        composer.focusRingType = .none
        composer.font = Self.body
        composer.cell?.wraps = true
        composer.lineBreakMode = .byWordWrapping
        composer.delegate = self
        composer.sizeToFit()
        round.isBordered = false
        round.imagePosition = .imageOnly
        round.wantsLayer = true
        round.layer?.cornerRadius = 13
        round.run = { [unowned self] in ["working", "waiting"].contains(tab()?.claude) ? keys("\u{1b}") : submit() }
        for view in [placeholder, composer, round] { barContent.addSubview(view) }
        factsRow.clipsToBounds = false
        addSubview(glass)
        addSubview(factsRow)
        addSubview(workersRow)
        side.isHidden = true
        side.addSubview(sideScroll)
        addSubview(side)
        toggle.isHidden = true
        addSubview(toggle)
        tail()
        hover = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .flagsChanged, .leftMouseDown]) { [weak self] event in
            guard let self, event.type == .leftMouseDown else {
                self?.hovered(event)
                return event
            }
            return event.modifierFlags.isSuperset(of: [.control, .command]) && lane(event).map { self.clicked($0, event) } == true ? nil : event
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        hover.map(NSEvent.removeMonitor)
        ticker?.invalidate()
        minutes?.invalidate()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var barFrame: NSRect { NSRect(x: ((lane - column) / 2).rounded() - 4, y: bounds.height - Self.slot - grown, width: column + 8, height: Self.bar + grown) }
    private var lane: CGFloat { bounds.width - (sideShown ? Self.sideWidth : 0) }
    private var under: CGFloat { max(0, window.map { convert(NSPoint(x: 0, y: $0.contentLayoutRect.maxY), from: nil).y } ?? 0) }
    var sideFrame: NSRect? { sideShown ? convert(side.frame, to: nil) : nil }
    var factsFrame: NSRect { NSRect(x: barFrame.minX, y: bounds.height - 26, width: barFrame.width, height: 16) }

    override func keyDown(with event: NSEvent) {
        if let preview, preview.isVisible, previewKeys != nil, preview.handle(event) { return }
        if event.keyCode == 53, let popover { return popover.dismiss() }
        if event.keyCode == 53, finder != nil { return find("end_search") }
        let clip = scroll.contentView, page = clip.bounds.height - 40
        let by: CGFloat? = switch event.specialKey {
        case .upArrow?: -40
        case .downArrow?: 40
        case .pageUp?: -page
        case .pageDown?: page
        case .home?: -doc.frame.height
        case .end?: doc.frame.height
        default: nil
        }
        guard let by else {
            let enter = (event.characters == "\r" || event.characters == "\u{3}") && !blank
            guard event.modifierFlags.isDisjoint(with: [.command, .control]), let typed = event.characters, !typed.isEmpty,
                  enter || typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) else { return }
            takeKeys()
            return composer.currentEditor()?.keyDown(with: event) ?? ()
        }
        clip.scroll(to: NSPoint(x: 0, y: max(0, min(doc.frame.height - clip.bounds.height, clip.bounds.minY + by))))
        scroll.reflectScrolledClipView(clip)
    }

    private func inBar(_ point: NSPoint) -> Bool { NSBezierPath(roundedRect: glass.frame, xRadius: Self.bar / 2, yRadius: Self.bar / 2).contains(point) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        let local = convert(point, from: superview)
        guard inBar(local) else { return hit }
        if hit?.isDescendant(of: composer) == true { return hit }
        if hit === round, NSBezierPath(ovalIn: round.bounds).contains(round.convert(local, from: self)) { return hit }
        return self
    }
    override func mouseDown(with event: NSEvent) {
        guard inBar(convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        takeKeys()
    }
    override func scrollWheel(with event: NSEvent) { scroll.scrollWheel(with: event) }

    private var blank: Bool { composer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    override func viewDidChangeEffectiveAppearance() { needsLayout = true }
    override func setFrameSize(_ size: NSSize) {
        if size != frame.size { popover?.dismiss() }
        super.setFrameSize(size)
        fitSide()
    }
    override func viewDidMoveToWindow() {
        if window == nil { popover?.dismiss() }
        tick()
        minutes?.invalidate()
        minutes = window == nil ? nil : Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.fill() }
    }

    override func layout() {
        super.layout()
        let lane = lane
        viewport.frame = NSRect(x: 0, y: 0, width: lane, height: bounds.height)
        scroll.frame = viewport.bounds
        side.frame = NSRect(x: lane, y: under, width: Self.sideWidth, height: bounds.height - under)
        toggle.frame = NSRect(x: bounds.width - 12 - 17, y: under + 8, width: 17, height: 17)
        let row = toggle.frame.maxY - under
        sideScroll.frame = NSRect(x: 0, y: row, width: Self.sideWidth, height: max(0, side.frame.height - row))
        let height = max(bounds.height, 1), top = bounds.height - Self.slot - grown - above
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = viewport.bounds
        fade.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, 6 / height, 34 / height, top / height, (top + Self.bar) / height, 1].map { NSNumber(value: Double($0)) }
        CATransaction.commit()
        let width = max(min(960, lane - 80), lane / 2), isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard width != column || isDark != dark else {
            let shift = ((lane - column) / 2).rounded() - ((doc.frame.width - column) / 2).rounded()
            if shift != 0 { rows.forEach { $0.view.frame.origin.x += shift } }
            (glass.frame, factsRow.frame) = (barFrame, factsFrame)
            workersRow.frame = NSRect(x: barFrame.minX, y: barFrame.minY - above, width: barFrame.width, height: above)
            return place()
        }
        let clip = scroll.contentView, anchor = stuck ? nil : rows.firstIndex { $0.view.frame.maxY > clip.bounds.minY }.map { ($0, clip.bounds.minY - rows[$0].view.frame.minY) }
        (column, dark) = (width, isDark)
        (glass.frame, factsRow.frame) = (barFrame, factsFrame)
        workersRow.frame = NSRect(x: barFrame.minX, y: barFrame.minY - above, width: barFrame.width, height: above)
        round.frame = NSRect(x: glass.frame.width - 31, y: 5 + grown, width: 26, height: 26)
        composer.frame.size.width = round.frame.minX - 8 - 16
        grow()
        rows.forEach { $0.view.removeFromSuperview() }
        rows = []
        themed = nil
        shownFacts = []
        show()
        if let (index, offset) = anchor, index < rows.count {
            clip.scroll(to: NSPoint(x: 0, y: max(0, min(doc.frame.height - clip.bounds.height, rows[index].view.frame.minY + min(offset, rows[index].view.frame.height)))))
            scroll.reflectScrolledClipView(clip)
        }
        fill()
    }

    private func fill() {
        guard column > 0 else { return }
        let tab = tab(), working = ["working", "waiting"].contains(tab?.claude)
        let font = prose(read)
        if composer.font != font {
            composer.font = font
            composer.frame.size.height = composer.cell!.cellSize.height
            grown = 0
            grow()
        }
        placeholder.string = plain(working ? "Tell Claude what to do instead" : "Message Claude", font: font, color: faint)
        placeholder.fit(column)
        placeholder.frame.origin = NSPoint(x: 16, y: Self.capCentered(placeholder, in: Self.bar))
        placeholder.isHidden = !composer.stringValue.isEmpty
        composer.textColor = ink
        composer.frame.origin = NSPoint(x: 16, y: placeholder.frame.minY + placeholder.firstBaselineOffsetFromTop - composer.firstBaselineOffsetFromTop)
        round.image = NSImage(systemSymbolName: working ? "stop.fill" : "arrow.up", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: working ? 9 : 12, weight: .bold))
        round.contentTintColor = working ? (dark ? .black : .white) : faint
        round.layer?.backgroundColor = (working ? ink : dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)).cgColor
        round.setAccessibilityLabel(working ? "Stop" : "Send")
        let reply = tab?.reply, model = (reply?["message"] as? [String: Any])?["model"] as? String
        let effort = (Self.file("settings.json")?["effortLevel"] as? String) ?? reply?["effort"] as? String
        let mode = entries.last { $0.mode != nil }?.mode
        let warm = tab.flatMap { tab in reply.flatMap { _ in warmed(tab) } }.map { Int(($0.addingTimeInterval(3600).timeIntervalSinceNow / 60).rounded(.down)) }
        let claude = Self.file("scripts/.usage-cache.json").map(limits), agy = agyLimits(), levels = ((claude?.rows ?? []) + (agy?.rows ?? [])).map { (name: $0.name, used: Int($0.used.rounded())) }
        let context = tab?.context, window = reply.map(ClaudeTTY.window) ?? 1
        let locked = (Self.file("keybindings.json")?["bindings"] as? [[String: Any]] ?? []).contains { $0["context"] as? String == "Chat" && ($0["bindings"] as? [String: Any])?["shift+tab"] is NSNull }
        let left = [model.map { ClaudeTTY.model($0) + (effort.map { " " + (["xhigh": "Extra High"][$0] ?? $0.capitalized) } ?? "") }, mode.map { ["bypassPermissions": "Bypass", "acceptEdits": "Accept Edits", "default": "Ask", "plan": "Plan"][$0] ?? $0.capitalized }]
        let right = [warm.map { $0 >= 0 ? "Warm \(max(1, $0))m" : "Cold" }, context.map(ClaudeTTY.tokens)]
        let workers = tab?.workers ?? [], crew = sideShown ? [] : workers
        fillSide(tab, workers: workers, limits: claude, agy: agy, context: context, of: window, model: model)
        fillWorkers(crew)
        let shown = (left + right).map { $0 ?? "" } + [dark ? "dark" : "light", "\(column)", "\(context.map { $0 * 100 / window } ?? 0)", "\(locked)", "\(showPanel == nil)", "\(crew.map { [$0.name, "\($0.working)"] })", "\(levels.map { [$0.name, "\($0.used)"] })"]
        guard shown != shownFacts else { return }
        shownFacts = shown
        let opened = facts.firstIndex { $0 === popover?.fact }, count = facts.count
        facts.forEach { $0.removeFromSuperview() }
        let menus: [((Fact) -> Void)?] = [
            { [unowned self] in pick($0, [("Default", "default"), ("Opus", "opus"), ("Fable", "fable"), ("Sonnet", "sonnet"), ("Haiku", "haiku")], current: model.map { id in ClaudeTTY.model(id).split(separator: " ").first.map(String.init) ?? id }) { [unowned self] in _ = send("/model " + $0) } },
            locked ? nil : { [unowned self] in pick($0, [("Ask", "default"), ("Accept Edits", "acceptEdits"), ("Plan", "plan"), ("Bypass", "bypassPermissions"), ("Auto", "auto")], current: left[1]) { [unowned self] in cycle($0) } },
        ]
        facts = (crew.isEmpty ? [] : [workersFact(crew)]) + zip(left, menus).compactMap { text, menu in text.map { text in fact(menu) { [small(text, $0)] + (menu == nil ? [] : [mark("chevron.down", $0, size: 8, width: 9)]) } } }
        var x: CGFloat = 18
        for fact in facts {
            fact.frame.origin.x = x
            x = fact.frame.maxX + 14
        }
        let counted = { [unowned self] (bars: Bool) in context.map { count in fact({ [unowned self] in showContext($0, count, of: window, in: tab?.frontFolder, model: model) }) { [ring(Double(count) / Double(window)), small(ClaudeTTY.tokens(count), $0)] + (bars ? levels.map { gauge($0.used, name: $0.name) } : []) } } }
        let ends: [Fact?] = [
            counted(true),
            warm.map { left in fact({ [unowned self] in pop($0, cachePanel(left, kept: tab.flatMap(kept), usage: (reply?["message"] as? [String: Any])?["usage"] as? [String: Any], warmed: tab.flatMap(warmed))) }) { [mark("cube.fill", left >= 0 ? .systemGreen : $0, size: 10), small(left >= 0 ? "Warm \(max(1, left))m" : "Cold", $0)] } },
        ]
        let bare = levels.isEmpty ? nil : counted(false)
        let start = x
        x = round.frame.maxX - 5
        for whole in ends.compactMap({ $0 }) {
            guard let fact = [whole, whole === ends[0] ? bare : nil].compactMap({ $0 }).first(where: { x - $0.frame.width >= start }) else { continue }
            fact.frame.origin.x = x - fact.frame.width
            x = fact.frame.minX - 14
            facts.append(fact)
        }
        contextFact = ends[0]
        for fact in facts { factsRow.addSubview(fact) }
        if let opened, facts.count == count, let popover {
            if contextOpen?.fact === popover.fact { contextOpen?.fact = facts[opened] }
            popover.fact = facts[opened]
        }
    }
    private static func file(_ name: String) -> [String: Any]? { reread(NSHomeDirectory() + "/.claude/" + name, json) }
    private func fact(_ click: ((Fact) -> Void)?, _ parts: (NSColor) -> [NSView]) -> Fact { Fact(parts(dim), lit: parts(ink), halo: halo, click: click) }
    private var halo: NSColor { dark ? NSColor(white: 1, alpha: 0.95) : NSColor(white: 0, alpha: 0.5) }
    private func small(_ text: String, _ color: NSColor) -> Text { Text(plain(text, font: .systemFont(ofSize: 12), color: color), width: 300) }
    private func mark(_ name: String, _ color: NSColor, size: CGFloat, width: CGFloat = 14) -> NSImageView {
        let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: size, weight: .medium))!)
        view.contentTintColor = color
        view.imageAlignment = .alignCenter
        view.frame.size = NSSize(width: width, height: 14)
        return view
    }
    private func ring(_ used: Double) -> NSView {
        let view = Flip(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        view.wantsLayer = true
        for (end, color) in [(1.0, dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.14)), (min(used, 1), NSColor.controlAccentColor)] {
            let arc = CAShapeLayer()
            arc.path = CGPath(ellipseIn: CGRect(x: 1.5, y: 1.5, width: 11, height: 11), transform: nil)
            arc.fillColor = nil
            arc.strokeColor = color.cgColor
            arc.lineWidth = 2.2
            arc.lineCap = .round
            arc.strokeEnd = end
            arc.frame = view.bounds
            arc.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
            view.layer!.addSublayer(arc)
        }
        return view
    }
    private func gauge(_ used: Int, name: String, width: CGFloat = 26, height: CGFloat = 4, tick: Double? = nil) -> NSView {
        let track = rounded(NSRect(x: 0, y: 0, width: width, height: height), fill: dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.12), radius: height / 2)
        track.setAccessibilityElement(true)
        track.setAccessibilityRole(.levelIndicator)
        track.setAccessibilityLabel(name)
        track.setAccessibilityValue("\(used)%")
        track.layer!.masksToBounds = true
        track.addSubview(rounded(NSRect(x: 0, y: 0, width: (width * CGFloat(min(used, 100)) / 100).rounded(), height: height), fill: used <= 50 ? .systemGreen : used <= 80 ? .systemOrange : .systemRed, radius: 0))
        if let tick { track.addSubview(rounded(NSRect(x: (width * tick / 100).rounded(), y: 0, width: 1.5, height: height), fill: ink, radius: 0)) }
        return track
    }


    private func pick(_ fact: Fact, _ items: [(title: String, value: String)], current: String?, run: @escaping (String) -> Void) {
        popover?.dismiss()
        let menu = NSMenu()
        for (title, value) in items {
            let item = menu.addItem(withTitle: title, action: #selector(picked), keyEquivalent: "")
            item.target = self
            item.state = title == current ? .on : .off
            item.representedObject = { run(value) }
        }
        popUp(menu, at: NSPoint(x: -12, y: fact.bounds.maxY + 4), in: fact)
    }
    @objc private func picked(_ item: NSMenuItem) { (item.representedObject as? () -> Void)?() }

    private func pop(_ fact: Fact, _ panel: @autoclosure () -> NSView) {
        let open = popover?.fact
        popover?.dismiss()
        guard open !== fact, let window else { return }
        let bar = convert(barFrame, to: nil), tip = fact.convert(NSPoint(x: fact.bounds.midX, y: 0), to: nil).x
        let closing = window.childWindows?.lazy.compactMap { $0 as? Popover }.first { $0.fact === fact }
        let opened = closing ?? Popover(fact: fact, dark: dark)
        opened.closed = { [weak self] in self?.popover = nil }
        opened.open(panel(), tip: NSPoint(x: tip, y: bar.maxY), right: bar.maxX, in: window)
        popover = opened
    }

    private func panel(_ width: CGFloat, _ title: String, _ aside: String) -> Flip {
        let panel = Flip(frame: NSRect(x: 0, y: 0, width: width, height: 0)), head = Text(plain(title, font: .systemFont(ofSize: 13, weight: .semibold)), width: 120), side = Text(plain(aside, color: dim), width: 200)
        head.frame.origin = NSPoint(x: 14, y: 12)
        side.frame.origin = NSPoint(x: width - 14 - side.frame.width, y: 12)
        panel.addSubview(head)
        panel.addSubview(side)
        return panel
    }
    private func row(_ panel: NSView, _ name: String, _ value: String, y: CGFloat, color: NSColor) {
        let left = Text(plain(name, font: .systemFont(ofSize: 12), color: color), width: 180), right = Text(plain(value, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: color), width: 120)
        left.frame.origin = NSPoint(x: 14, y: y)
        right.frame.origin = NSPoint(x: panel.frame.width - 14 - right.frame.width, y: y)
        panel.addSubview(left)
        panel.addSubview(right)
    }

    private static var setups: [String: [(name: String, tokens: Int)]] = ((try? Data(contentsOf: URL(fileURLWithPath: setupsFile))).flatMap { try? JSONDecoder().decode([String: [[String]]].self, from: $0) } ?? [:]).mapValues { $0.compactMap { pair in Int(pair.last ?? "").map { (pair[0], $0) } } }
    private static let setupsFile = (ClaudeTTY.stateFile as NSString).deletingLastPathComponent + "/context.json"
    private static var asked: Set<String> = []
    private static var failed: Set<String> = []
    private var contextOpen: (fact: Fact, used: Int, window: Int)?
    private func showContext(_ fact: Fact, _ used: Int, of window: Int, in cwd: String?, model: String?) {
        contextOpen = (fact, used, window)
        pop(fact, contextPanel(used, of: window, setup: setup(in: cwd, model: model, retry: true)))
    }
    private func setup(in cwd: String?, model: String?, retry: Bool = false) -> [(name: String, tokens: Int)] {
        let key = (cwd ?? "") + "\n" + (model ?? "")
        if retry, Self.failed.remove(key) != nil { Self.asked.remove(key) }
        if let cwd, let model, Self.asked.insert(key).inserted, let claude = ClaudeTTY.loginPath?.split(separator: ":").map({ $0 + "/claude" }).first(where: FileManager.default.isExecutableFile) {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: claude)
            process.arguments = ["-p", "/context", "--output-format", "json", "--model", model]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.environment = ProcessInfo.processInfo.environment.filter { !["CLAUDECODE", "ZMX_SESSION", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PID"].contains($0.key) }.merging(["PATH": ClaudeTTY.loginPath ?? ""]) { $1 }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) == nil { Self.failed.insert(key) } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let rows = Self.categories((try? JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any])?["result"] as? String ?? "")
                    DispatchQueue.main.async { [weak self] in
                        guard !rows.isEmpty else { return _ = Self.failed.insert(key) }
                        Self.setups[key] = rows
                        try? JSONEncoder().encode(Self.setups.mapValues { $0.map { [$0.name, String($0.tokens)] } }).write(to: URL(fileURLWithPath: Self.setupsFile), options: .atomic)
                        guard let self else { return }
                        if let open = contextOpen, let popover, popover.fact === open.fact, let parent = popover.parent { popover.show(contextPanel(open.used, of: open.window, setup: rows), in: parent) }
                        fill()
                    }
                }
            }
        }
        return Self.setups[key] ?? []
    }
    static func categories(_ markdown: String) -> [(name: String, tokens: Int)] {
        let table = markdown.components(separatedBy: "### Estimated usage by category").dropFirst().first?.components(separatedBy: "###").first ?? ""
        return table.split(separator: "\n").compactMap { line in
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2, let number = Double(cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "kM"))) else { return nil }
            return (cells[0], Int(number * (cells[1].hasSuffix("M") ? 1_000_000 : cells[1].hasSuffix("k") ? 1000 : 1)))
        }
    }

    private func contextPanel(_ used: Int, of window: Int, setup: [(name: String, tokens: Int)]) -> NSView {
        let (rows, buffer) = Self.contextRows(used, of: window, setup: setup)
        let width: CGFloat = 280, panel = panel(width, "Context", ClaudeTTY.tokens(used) + " of " + ClaudeTTY.tokens(window))
        let track = contextTrack(used, of: window, buffer: buffer, width: width - 28)
        track.frame.origin = NSPoint(x: 14, y: 38)
        panel.addSubview(track)
        for (index, (name, tokens)) in rows.enumerated() { row(panel, name, Self.k(tokens), y: 54 + 20 * CGFloat(index), color: ["Used", "Messages"].contains(name) ? ink : dim) }
        let compact = compactButton()
        compact.frame.origin = NSPoint(x: width - 10 - compact.frame.width, y: 54 + 20 * CGFloat(rows.count) + 8)
        panel.addSubview(compact)
        panel.frame.size.height = compact.frame.maxY + 10
        limitRows(Self.file("scripts/.usage-cache.json").map(limits), agyLimits(), in: panel)
        return panel
    }
    private func limitRows(_ claude: Limits?, _ agy: Limits?, in panel: NSView) {
        let sections = Self.sections(claude, agy)
        guard !sections.isEmpty else { return }
        let width = panel.frame.width
        var top = panel.frame.height
        panel.addSubview(rounded(NSRect(x: 14, y: top, width: width - 28, height: 1 / (window?.backingScaleFactor ?? 2)), fill: NSColor(white: dark ? 1 : 0, alpha: 0.12), radius: 0))
        top += 12
        for (index, (title, limits)) in sections.enumerated() {
            if index > 0 { top += 4 }
            let head = Text(plain(title, font: .systemFont(ofSize: index == 0 ? 13 : 12, weight: .semibold), color: index == 0 ? ink : dim), width: 120), side = Text(plain(limits.reset, color: dim), width: 200)
            head.frame.origin = NSPoint(x: 14, y: top)
            side.frame.origin = NSPoint(x: width - 14 - side.frame.width, y: top)
            panel.addSubview(head)
            panel.addSubview(side)
            top += index == 0 ? 30 : 26
            for (name, used, tick, _) in limits.rows {
                row(panel, name, "\(Int(used.rounded()))%", y: top, color: ink)
                let bar = gauge(Int(used.rounded()), name: name, width: width - 28, height: 6, tick: tick)
                bar.frame.origin = NSPoint(x: 14, y: top + 22)
                panel.addSubview(bar)
                top = bar.frame.maxY + 12
            }
        }
        panel.frame.size.height = top + 2
    }
    private static func contextRows(_ used: Int, of window: Int, setup: [(name: String, tokens: Int)]) -> (rows: [(name: String, tokens: Int)], buffer: Int) {
        let buffer = setup.first { $0.name == "Autocompact buffer" }?.tokens ?? 33_000
        let kinds = setup.filter { !["Messages", "Free space", "Autocompact buffer"].contains($0.name) && !$0.name.contains("(deferred)") }
        return ((kinds.isEmpty ? [("Used", used)] : kinds + [("Messages", max(0, used - kinds.map(\.tokens).reduce(0, +)))]) + [("Free space", max(0, window - used - buffer)), ("Autocompact buffer", buffer)], buffer)
    }
    private func contextTrack(_ used: Int, of window: Int, buffer: Int, width: CGFloat) -> NSView {
        let track = rounded(NSRect(x: 0, y: 0, width: width, height: 6), fill: dark ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.06), radius: 3)
        track.layer!.masksToBounds = true
        let span = { (tokens: Int) in (width * CGFloat(tokens) / CGFloat(window)).rounded() }
        track.addSubview(rounded(NSRect(x: 0, y: 0, width: min(span(used), width), height: 6), fill: .controlAccentColor, radius: 0))
        track.addSubview(rounded(NSRect(x: width - span(buffer), y: 0, width: span(buffer), height: 6), fill: faint, radius: 0))
        return track
    }
    private func compactButton() -> Press {
        let compact = Press("Compact") { [unowned self] in
            popover?.dismiss()
            send("/compact")
        }
        compact.bezelStyle = .push
        compact.controlSize = .small
        compact.sizeToFit()
        return compact
    }
    private static func k(_ tokens: Int) -> String { tokens < 10_000 ? String(format: "%.1fk", Double(tokens) / 1000).replacingOccurrences(of: ".0k", with: "k") : ClaudeTTY.tokens(tokens) }

    typealias Limits = (reset: String, rows: [(name: String, used: Double, tick: Double?, note: String)])
    private func limits(_ usage: [String: Any]) -> Limits {
        let date = { (text: Any?) in (text as? String).flatMap { Self.iso.date(from: $0.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)) } }
        let week = usage["seven_day"] as? [String: Any], reset = date(week?["resets_at"])
        let five = usage["five_hour"] as? [String: Any], capped = (usage["limits"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "weekly_scoped" }
        let rows: [(name: String, used: Double, pace: (tick: Double?, note: String))] = [
            (five?["utilization"] as? Double).map { ("5-hour", $0, Self.pace($0, 5 * 3600, date(five?["resets_at"]))) },
            (week?["utilization"] as? Double).map { ("Week", $0, Self.pace($0, 7 * 86400, reset)) },
        ].compactMap { $0 } + capped.compactMap { limit in
            guard let name = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String, let used = (limit["percent"] as? NSNumber)?.doubleValue else { return nil }
            return (name, used, (nil, ""))
        }
        return (reset.map { "Resets " + Self.weekday.string(from: $0) } ?? "", rows.map { ($0.name, $0.used, $0.pace.tick, $0.pace.note) })
    }
    private static func sections(_ claude: Limits?, _ agy: Limits?) -> [(title: String, limits: Limits)] { [("Limits", claude), ("Antigravity", agy)].compactMap { title, limits in limits.flatMap { $0.rows.isEmpty ? nil : (title, $0) } } }
    private static func pace(_ used: Double, _ window: TimeInterval, _ ends: Date?) -> (tick: Double?, note: String) {
        guard let ends else { return (nil, "") }
        let gone = max(0, min(1, 1 - ends.timeIntervalSinceNow / window)), out = Date().addingTimeInterval((100 - used) / max(used, 0.1) * gone * window)
        return (gone * 100, used >= 100 ? "Resets " + weekday.string(from: ends) : gone > 0 && out < ends ? "Runs out \(dayName.string(from: out))" : "")
    }
    private func agyLimits() -> Limits? {
        let path = statusDir + "/agy-quota.json"
        guard let quota = reread(path, json) as? [String: [String: Any]], let read = modified(path) else { return nil }
        let reset = { (id: String) in (quota[id]?["reset_time"] as? String).flatMap(Self.iso.date) }
        let buckets: [(id: String, name: String, window: TimeInterval)] = [("gemini-5h", "Gemini 5-hour", 5 * 3600), ("gemini-weekly", "Gemini week", 7 * 86400), ("3p-5h", "Claude and GPT 5-hour", 5 * 3600), ("3p-weekly", "Claude and GPT week", 7 * 86400)]
        let rows: [(name: String, used: Double, tick: Double?, note: String)] = buckets.compactMap { bucket in
            guard quota[bucket.id]?["disabled"] as? Bool != true, let left = (quota[bucket.id]?["remaining_fraction"] as? NSNumber)?.doubleValue else { return nil }
            let used = (1 - left) * 100, pace = Self.pace(used, bucket.window, reset(bucket.id))
            return (bucket.name, used, pace.tick, pace.note)
        }
        return (-read.timeIntervalSinceNow > 1800 ? "As of " + Self.clock.string(from: read) : reset("gemini-weekly").map { "Resets " + Self.weekday.string(from: $0) } ?? "", rows)
    }
    private static let iso = ISO8601DateFormatter(), weekday = { let format = DateFormatter(); format.setLocalizedDateFormatFromTemplate("EEEhmm"); return format }()
    private static let dayName = { let format = DateFormatter(); format.setLocalizedDateFormatFromTemplate("EEE"); return format }()
    private static let clock = { let format = DateFormatter(); format.setLocalizedDateFormatFromTemplate("hmm"); return format }()

    private func cachePanel(_ left: Int, kept: Date?, usage: [String: Any]?, warmed: Date?) -> NSView {
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate(kept.map { Calendar.current.isDateInToday($0) } ?? true ? "hmm" : "EEEhmm")
        let panel = panel(240, "Cache", left >= 0 ? "Warm" : "Cold")
        let read = usage?["cache_read_input_tokens"] as? Int, wrote = usage?["cache_creation_input_tokens"] as? Int
        let rows = [left >= 0 ? ("Time left", "\(max(1, left))m") : nil,
                    left >= 0 ? read.map { ("Holds", ClaudeTTY.tokens($0 + (wrote ?? 0))) } : nil,
                    read.map { ("Last turn read", ClaudeTTY.tokens($0)) }, wrote.map { ("Last turn wrote", ClaudeTTY.tokens($0)) },
                    warmed.map { ("Last warmed", Self.clock.string(from: $0)) },
                    kept.flatMap { $0 > Date() ? ("Kept warm until", day.string(from: $0)) : nil }].compactMap { $0 }
        for (index, (name, value)) in rows.enumerated() { row(panel, name, value, y: 42 + 20 * CGFloat(index), color: dim) }
        panel.frame.size.height = 42 + 20 * CGFloat(rows.count) + (rows.isEmpty ? 0 : 10)
        return panel
    }


    private var soft: NSColor { dark ? NSColor(white: 1, alpha: 0.66) : NSColor(white: 0, alpha: 0.64) }
    private static let warmPicks = [("For 6 hours", "6h"), ("For 90 minutes", "90m"), ("Always", "always"), ("Off", "off")]

    private func showSide() {
        needsLayout = true
        side.isHidden = false
        if sideShown {
            side.alphaValue = 0
            sideDrawn = []
        }
        fill()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            side.animator().alphaValue = sideShown ? 1 : 0
        } completionHandler: { [weak self] in
            if let self, !sideShown { side.isHidden = true }
        }
    }

    private func fillSide(_ tab: Tab?, workers: [Worker], limits: Limits?, agy: Limits?, context: Int?, of size: Int, model: String?) {
        guard sideShown else { return }
        let setup = context == nil ? [] : setup(in: tab?.frontFolder, model: model, retry: sideDrawn.isEmpty), warm = tab.flatMap(keepWarm), compacts = tab?.labels["compact"] != "0"
        let pad: CGFloat = 16, inner = Self.sideWidth - 2 * pad
        if sideDrawn != [dark ? "dark" : "light"] {
            sideDrawn = [dark ? "dark" : "light"]
            sideParts = []
            (side.subviews.filter { $0 !== sideScroll } + sideDoc.subviews).forEach { $0.removeFromSuperview() }
            let edge = rounded(NSRect(x: 0, y: 0, width: 1 / (window?.backingScaleFactor ?? 2), height: side.bounds.height), fill: NSColor(white: dark ? 1 : 0, alpha: 0.12), radius: 0)
            edge.autoresizingMask = .height
            side.addSubview(edge)
        }
        var top: CGFloat = 8
        var drawn: [NSView] = []
        func add(_ view: NSView) {
            sideDoc.addSubview(view)
            drawn.append(view)
        }
        func put(_ view: NSView, x: CGFloat = pad, gap: CGFloat = 0) {
            view.frame.origin = NSPoint(x: x, y: top + gap)
            add(view)
            top = view.frame.maxY
        }
        func right(_ view: NSView, on row: NSView) {
            view.frame.origin = NSPoint(x: Self.sideWidth - pad - view.frame.width + 2, y: row.frame.minY + ((row.frame.height - view.frame.height) / 2).rounded())
            add(view)
        }
        func head(_ title: String, note: String = "") {
            let text = Text(plain(title, font: .systemFont(ofSize: 11, weight: .semibold), color: soft, lineHeight: 14), width: inner)
            put(text, x: pad - 2)
            if !note.isEmpty { right(Text(plain(note, font: .systemFont(ofSize: 11), color: soft, lineHeight: 14), width: inner), on: text) }
            top += 8
        }
        func row(_ name: String, _ value: String, color: NSColor, lineHeight: CGFloat) {
            let text = Text(plain(name, font: .systemFont(ofSize: 12), color: color, lineHeight: lineHeight), width: inner - 60)
            put(text, x: pad - 2)
            right(Text(plain(value, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: color, lineHeight: lineHeight), width: 80), on: text)
        }
        func setting(_ title: String, _ control: NSControl) {
            let text = Text(plain(title, font: .systemFont(ofSize: 12), lineHeight: 16), width: inner - control.frame.width - 8)
            put(text, x: pad - 2)
            right(control, on: text)
            top = max(text.frame.maxY, control.frame.maxY) + 9
        }
        let shownLimits = Self.sections(limits, agy), limitsShown = shownLimits.flatMap { title, limits in [title, limits.reset] + limits.rows.map { "\($0.name) \(Int($0.used.rounded())) \($0.tick.map { (inner * $0 / 100).rounded() } ?? -1) \($0.note)" } }
        let sections: [(shows: String, draw: () -> Void)] = [
            ("\(workers.map { $0.task + [$0.folder, $0.name, $0.doing, $0.ask ?? ""] })", { [self] in
                guard !workers.isEmpty else { return }
                head("Workers")
                let asks = askInk
                for worker in workers {
                    let row = Fold(frame: NSRect(x: pad, y: top + 2, width: inner, height: 16)), disc = NSImageView(image: avatar(worker.name, color: ClaudeTTY.hue(worker.name, in: worker.folder), side: 16))
                    disc.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
                    let text = Text(named(worker.name, worker.ask ?? worker.doing, color: worker.ask == nil ? soft : asks, wrap: worker.ask != nil), width: inner - 24)
                    text.frame.size.width = min(text.frame.width, inner - 22)
                    text.frame.origin = NSPoint(x: 22, y: Self.capCentered(Text(named(worker.name, "", color: soft), width: inner), in: 16))
                    row.frame.size.height = max(16, text.frame.maxY)
                    row.addSubview(disc)
                    row.addSubview(text)
                    row.toggle = { [unowned self] in openWorker(worker.task) }
                    put(row, gap: 2)
                    top += 8
                    if worker.ask != nil {
                        let allow = pill("Allow", strong: true, at: NSPoint(x: pad + 22, y: top - 2), in: sideDoc) { [unowned self] in keys("\r") }
                        let deny = pill("Deny", strong: false, at: NSPoint(x: allow.frame.maxX + 6, y: top - 2), in: sideDoc) { [unowned self] in keys("\u{1b}") }
                        drawn += [allow, deny]
                        top = allow.frame.maxY + 8
                    }
                }
                top += 14
            }),
            ("\(context ?? -1) \(size) \(setup)", { [self] in
                guard let context else { return }
                let (rows, buffer) = Self.contextRows(context, of: size, setup: setup)
                head("Context", note: ClaudeTTY.tokens(context) + " of " + ClaudeTTY.tokens(size))
                put(contextTrack(context, of: size, buffer: buffer, width: inner))
                top += 6
                for (name, tokens) in rows { row(name, Self.k(tokens), color: ["Used", "Messages"].contains(name) ? ink : soft, lineHeight: 17) }
                let compact = compactButton()
                compact.frame.origin = NSPoint(x: Self.sideWidth - pad - compact.frame.width + 4, y: top + 4)
                add(compact)
                top = compact.frame.maxY + 18
            }),
            ("\(limitsShown)", { [self] in
                guard !shownLimits.isEmpty else { return }
                for (index, (title, limits)) in shownLimits.enumerated() {
                    if index > 0 { top += 4 }
                    head(title, note: limits.reset)
                    for (name, used, tick, note) in limits.rows {
                        row(name, "\(Int(used.rounded()))%", color: ink, lineHeight: 16)
                        put(gauge(Int(used.rounded()), name: name, width: inner, height: 6, tick: tick), gap: 5)
                        if !note.isEmpty { put(Text(plain(note, font: .systemFont(ofSize: 11), color: soft, lineHeight: 15), width: inner), x: pad - 2, gap: 5) }
                        top += 10
                    }
                }
                top += 8
            }),
            ("\(warm ?? "") \(compacts)", { [self] in
                head("Settings")
                if let warm {
                    let picks = Pick(Self.warmPicks.map(\.0), picked: warm) { [unowned self] index in
                        send("/keepwarm " + Self.warmPicks[index].1)
                        return true
                    }
                    picks.controlSize = .small
                    picks.font = .systemFont(ofSize: 11)
                    picks.isBordered = false
                    picks.alignment = .right
                    picks.fit()
                    setting("Keep the cache warm", picks)
                }
                let compacting = NSSwitch()
                compacting.controlSize = .mini
                compacting.state = compacts ? .on : .off
                (compacting.target, compacting.action) = (self, #selector(compactSwitched))
                compacting.setAccessibilityLabel("Compact before it goes cold")
                compacting.sizeToFit()
                setting("Compact before it goes cold", compacting)
            }),
        ]
        for (index, section) in sections.enumerated() {
            if index < sideParts.count, sideParts[index].shows == section.shows {
                let part = sideParts[index], shift = top - part.top
                if shift != 0 { part.views.forEach { $0.frame.origin.y += shift } }
                sideParts[index].top = top
                sideParts[index].foot = part.foot + shift
                top = part.foot + shift
                continue
            }
            let start = top
            drawn = []
            section.draw()
            if index < sideParts.count {
                sideParts[index].views.forEach { $0.removeFromSuperview() }
                sideParts[index] = (section.shows, drawn, start, top)
            } else {
                sideParts.append((section.shows, drawn, start, top))
            }
        }
        sideDoc.frame = NSRect(x: 0, y: 0, width: Self.sideWidth, height: top - 9 + pad)
    }
    @objc private func compactSwitched(_ sender: NSSwitch) { compacting(sender.state == .on) }
    private var askInk: NSColor { dark ? .systemOrange : NSColor(srgbRed: 0.6, green: 0.26, blue: 0, alpha: 1) }
    private func named(_ name: String, _ rest: String, color: NSColor, wrap: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: plain(name + ": ", font: .systemFont(ofSize: 12, weight: .semibold), lineHeight: 16)), style = para(16)
        out.append(plain(rest, font: .systemFont(ofSize: 12), color: color, lineHeight: 16))
        style.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }
    private func pill(_ title: String, strong: Bool, at origin: NSPoint, in parent: NSView, run: @escaping () -> Void) -> Fold {
        let text = Text(plain(title, font: .systemFont(ofSize: 12, weight: .medium), color: strong ? ink : soft), width: 80)
        let pill = Fold(frame: NSRect(origin: origin, size: NSSize(width: text.frame.width + 16, height: 22)))
        let fill = rounded(pill.bounds, fill: strong ? NSColor(white: dark ? 1 : 0, alpha: dark ? 0.16 : 0.1) : NSColor(white: dark ? 1 : 0, alpha: dark ? 0.11 : 0.06), radius: 11)
        text.frame.origin = NSPoint(x: 6, y: Self.capCentered(text, in: 22))
        fill.addSubview(text)
        pill.addSubview(fill)
        pill.toggle = run
        parent.addSubview(pill)
        return pill
    }


    private func fillWorkers(_ workers: [Worker]) {
        let asking = workers.first { $0.ask != nil }
        let drawn = [dark ? "dark" : "light", "\(column)", asking.map { [$0.name, $0.ask ?? "", "\($0.working)"].joined(separator: "\t") } ?? ""]
        guard drawn != workersDrawn else { return }
        workersDrawn = drawn
        workersRow.subviews.forEach { $0.removeFromSuperview() }
        above = asking == nil ? 0 : 22 + 8
        if let asking, let ask = asking.ask {
            let disc = WorkerDiscs([asking], side: 16) { [unowned self] in openWorker($0.task) }
            disc.frame.origin = NSPoint(x: 16, y: 3)
            workersRow.addSubview(disc)
            let text = Text(named(asking.name, ask, color: askInk), width: barFrame.width - 38 - 16 - 120)
            text.frame.origin = NSPoint(x: 36, y: Self.capCentered(Text(named(asking.name, "", color: askInk), width: 300), in: 22))
            workersRow.addSubview(text)
            let allow = pill("Allow", strong: true, at: NSPoint(x: text.frame.maxX + 8, y: 0), in: workersRow) { [unowned self] in keys("\r") }
            _ = pill("Deny", strong: false, at: NSPoint(x: allow.frame.maxX + 6, y: 0), in: workersRow) { [unowned self] in keys("\u{1b}") }
        }
        needsLayout = true
    }
    private func workersFact(_ workers: [Worker]) -> Fact {
        let working = workers.filter(\.working).count, extra = workers.count - WorkerDiscs.limit
        return fact(showPanel.map { show in { _ in show() } }) { [unowned self] color in
            [WorkerDiscs(workers, open: nil)] + (extra > 0 ? [small("+\(extra)", color)] : []) + [small(working > 0 ? "\(working) working" : "\(workers.count) idle", color)]
        }
    }

    final class Pick: NSPopUpButton {
        private var run: (Int) -> Bool = { _ in true }
        convenience init(_ titles: [String], picked: String, run: @escaping (Int) -> Bool) {
            self.init(frame: .zero, pullsDown: false)
            addItems(withTitles: titles)
            if !titles.contains(picked) {
                addItem(withTitle: picked)
                lastItem?.isHidden = true
            }
            selectItem(withTitle: picked)
            (cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
            for item in itemArray { (item.target, item.action) = (self, #selector(chose)) }
            self.run = run
        }
        override func mouseDown(with event: NSEvent) {
            guard probe != nil, let menu else { return super.mouseDown(with: event) }
            popUp(menu, at: NSPoint(x: 0, y: bounds.maxY), in: self)
        }
        @objc private func chose(_ item: NSMenuItem) {
            guard run(index(of: item)) else { return }
            select(item)
            fit()
        }
        func fit() {
            let right = frame.maxX
            sizeToFit()
            frame.size.width = ceil(attributedTitle.size().width) + 22
            frame.origin.x = right - frame.width
        }
    }

    final class Popover: NSPanel {
        weak var fact: Fact?
        var closed: () -> Void = {}
        private(set) var tip: CGFloat = 0
        private(set) var shown = false
        private var monitor: Any?, sampler: Timer?, moves = 0
        private var at = NSPoint.zero, right: CGFloat = 0, foot: CGFloat = 0
        private let ground = NSView(), glass = NSGlassEffectView(), holder = NSView(), edge = Edge()
        init(fact: Fact, dark: Bool) {
            self.fact = fact
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            edge.color = NSColor(white: dark ? 1 : 0, alpha: 0.1)
            glass.contentView = holder
            ground.wantsLayer = true
            ground.layer?.mask = CAShapeLayer()
            ground.addSubview(glass)
            ground.addSubview(edge)
            contentView = NSView()
            contentView?.addSubview(ground)
        }
        func open(_ panel: NSView, tip: NSPoint, right: CGFloat, in parent: NSWindow) {
            (at, self.right, self.tip) = (tip, right, tip.x)
            show(panel, in: parent)
            if self.parent == nil {
                ground.layer?.transform = away
                ground.layer?.opacity = 0
                appearance = parent.effectiveAppearance
                parent.addChildWindow(self, ordered: .above)
            }
            monitor = monitor ?? NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, event.window !== self, event.window?.contentView?.superview?.hitTest(event.locationInWindow) !== self.fact else { return event }
                dismiss()
                return event
            }
            move(true)
        }
        func show(_ panel: NSView, in parent: NSWindow) {
            let arrow: CGFloat = 7.5, size = panel.frame.size, x = min(right - size.width, at.x - 22)
            foot = at.x - x
            setFrame(parent.convertToScreen(NSRect(x: x, y: at.y + 2.5, width: size.width, height: size.height + arrow)), display: false)
            let outline = { [foot] (inset: CGFloat) in
                let path = NSBezierPath(), w = size.width - inset, h = size.height + arrow - inset
                path.move(to: NSPoint(x: foot, y: inset))
                path.line(to: NSPoint(x: foot + 8, y: arrow))
                path.appendArc(from: NSPoint(x: w, y: arrow), to: NSPoint(x: w, y: h), radius: 10)
                path.appendArc(from: NSPoint(x: w, y: h), to: NSPoint(x: inset, y: h), radius: 10)
                path.appendArc(from: NSPoint(x: inset, y: h), to: NSPoint(x: inset, y: arrow), radius: 10)
                path.appendArc(from: NSPoint(x: inset, y: arrow), to: NSPoint(x: foot - 8, y: arrow), radius: 10)
                path.line(to: NSPoint(x: foot - 8, y: arrow))
                path.close()
                return path
            }
            ground.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height + arrow)
            (ground.layer?.mask as? CAShapeLayer)?.path = outline(0).cgPath
            glass.frame = ground.bounds
            edge.frame = ground.bounds
            edge.shape = outline(0.25)
            edge.needsDisplay = true
            holder.subviews.forEach { $0.removeFromSuperview() }
            panel.frame.origin = NSPoint(x: 0, y: arrow)
            holder.addSubview(panel)
            invalidateShadow()
        }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        func dismiss() {
            guard shown else { return }
            monitor.map(NSEvent.removeMonitor)
            monitor = nil
            move(false)
            closed()
        }
        private var away: CATransform3D {
            let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || probe.map { FileManager.default.fileExists(atPath: $0 + "/reducemotion") } == true
            return still ? CATransform3DIdentity : CATransform3DScale(CATransform3DMakeTranslation(foot * 0.04, 0, 0), 0.96, 0.96, 1)
        }
        private func move(_ shown: Bool) {
            self.shown = shown
            moves += 1
            let move = moves, layer = ground.layer!, drawn = layer.presentation() ?? layer
            let from: [(String, Any)] = [("opacity", drawn.opacity), ("transform", drawn.transform)]
            layer.opacity = shown ? 1 : 0
            layer.transform = shown ? CATransform3DIdentity : away
            CATransaction.begin()
            CATransaction.setAnimationDuration(shown ? 0.16 : 0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1))
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, move == moves, !shown else { return }
                parent?.removeChildWindow(self)
                orderOut(nil)
            }
            for (key, value) in from {
                let animation = CABasicAnimation(keyPath: key)
                animation.fromValue = value
                layer.add(animation, forKey: key)
            }
            CATransaction.commit()
            sample(shown ? "open" : "close")
        }
        private func sample(_ way: String) {
            guard let probe else { return }
            let now = ProcessInfo.processInfo.systemUptime, event = NSApp.currentEvent?.timestamp ?? now, start = now - event < 0.5 ? event : now
            sampler?.invalidate()
            sampler = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self, layer = ground.layer!] timer in
                let drawn = layer.presentation() ?? layer, alpha = self?.alphaValue ?? 1, scale = drawn.transform.m11, opacity = drawn.opacity
                let line = "\(way)\t\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))\talpha \(String(format: "%g", alpha))\tscale \(String(format: "%g", scale))\topacity \(String(format: "%g", opacity))\n"
                if let file = FileHandle(forWritingAtPath: probe + "/popmotion") ?? (FileManager.default.createFile(atPath: probe + "/popmotion", contents: nil) ? FileHandle(forWritingAtPath: probe + "/popmotion") : nil) {
                    file.seekToEndOfFile()
                    file.write(Data(line.utf8))
                    file.closeFile()
                }
                if way == "open" ? alpha == 1 && scale == 1 && opacity == 1 : alpha == 0 || opacity == 0 { timer.invalidate() }
            }
            RunLoop.main.add(sampler!, forMode: .common)
        }
        var material: String {
            let half = glass.bounds.width * glass.bounds.height / 2
            func fills(_ view: NSView) -> [CGFloat] { (view.frame.width * view.frame.height >= half ? [view.layer?.backgroundColor?.alpha ?? 0] : []) + view.subviews.flatMap(fills) }
            return "popover\tmaterial \(type(of: glass))\tfill \(String(format: "%g", (fills(holder) + fills(edge)).max() ?? 0))"
        }
        final class Edge: NSView {
            var shape = NSBezierPath(), color = NSColor.clear
            override func draw(_ dirty: NSRect) {
                color.setStroke()
                shape.lineWidth = 0.5
                shape.stroke()
            }
        }
    }
    static func capCentered(_ text: Text, in height: CGFloat) -> CGFloat {
        let font = text.string.length > 0 ? text.string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? body : body
        return ((height / 2 + font.capHeight / 2 - text.frame.height - font.descender) * 2).rounded() / 2
    }


    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if let popover { popover.dismiss() } else if ["working", "waiting"].contains(tab()?.claude) { keys("\u{1b}") }
            return true
        }
        let walking = recall.map { $0.at >= 0 && composer.stringValue == $0.prompts[$0.at] } ?? false
        if selector == #selector(NSResponder.moveUp(_:)), blank || walking {
            let text = walking ? "" : takeBack()
            if !text.isEmpty { return compose(text) }
            if !walking { recall = (prompts(), -1) }
            guard let recall, recall.at + 1 < recall.prompts.count else { return walking }
            self.recall!.at += 1
            return compose(recall.prompts[recall.at + 1])
        }
        if selector == #selector(NSResponder.moveDown(_:)), walking, let recall {
            self.recall!.at -= 1
            return compose(recall.at > 0 ? recall.prompts[recall.at - 1] : "")
        }
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if blank, let allow, allow.window != nil { allow.performClick(nil) } else { submit() }
        return true
    }
    private func compose(_ text: String) -> Bool {
        composer.stringValue = text
        composer.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        placeholder.isHidden = !text.isEmpty
        grow()
        forward()
        return true
    }
    func grow() {
        let line = NSLayoutManager().defaultLineHeight(for: composer.font!)
        _ = composer.stringValue
        let lines = min(8, max(1, (composer.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: composer.frame.width, height: .greatestFiniteMagnitude)).height / line).rounded()))
        guard (lines - 1) * line != grown else { return }
        composer.frame.size.height += (lines - 1) * line - grown
        grown = (lines - 1) * line
        round.frame.origin.y = 5 + grown
        needsLayout = true
    }
    private func prompts() -> [String] {
        guard let tab = tab() else { return [] }
        let folder = (tab.cwd as NSString).resolvingSymlinksInPath, session = tab.session
        let rows = ClaudeTTY.rows(ClaudeTTY.history, from: 0).filter { ($0["project"] as? String).map { ($0 as NSString).resolvingSymlinksInPath } == folder }.reversed()
        let ordered = rows.filter { $0["sessionId"] as? String == session } + rows.filter { $0["sessionId"] as? String != session }
        return ordered.map(ClaudeTTY.typed).reduce(into: []) { list, text in if list.last != text { list.append(text) } }
    }
    func controlTextDidChange(_ note: Notification) {
        if numbered?.window != nil, let digit = composer.stringValue.first, composer.stringValue.count == 1, ("1"..."9").contains(digit) {
            composer.stringValue = ""
            return keys(String(digit))
        }
        placeholder.isHidden = !composer.stringValue.isEmpty
        grow()
        forward()
    }
    private func forward() {
        guard let held = mirror, tab()?.claude != "waiting" else { return }
        let text = composer.stringValue, old = Array(held), new = Array(text)
        guard text != held else { return }
        let same = zip(old, new).prefix { $0 == $1 }.count
        let tail = zip(old[same...].reversed(), new[same...].reversed()).prefix { $0 == $1 }.count
        let put = String(new[same ..< new.count - tail])
        keys(String(repeating: "\u{1B}[D", count: tail) + String(repeating: "\u{7F}", count: old.count - same - tail) + (put.isEmpty ? "" : "\u{1B}[200~" + put + "\u{1B}[201~") + String(repeating: "\u{1B}[C", count: tail))
        mirror = text
        edited = Date()
    }
    static func collapsed(_ box: String) -> Bool { box.contains("[Pasted text #") || box.contains("[Image #") }
    func held(_ box: String?) {
        defer { seen = box }
        guard let box else { return (mirror, settled) = (nil, nil) }
        guard box == seen, box != settled, Date().timeIntervalSince(edited) > 2 else { return }
        settled = box
        let text = composer.stringValue
        guard !Self.collapsed(box), mirror.map({ ClaudeTTY.squeezed($0) }) != ClaudeTTY.squeezed(box) else { return }
        if ClaudeTTY.squeezed(text) == ClaudeTTY.squeezed(box) { mirror = text }
        else if mirror.map({ text != $0 }) ?? !text.isEmpty { (mirror, edited) = (box, .distantPast); forward() }
        else { mirror = box; _ = compose(box) }
    }
    func controlTextDidEndEditing(_ note: Notification) { caret = (note.userInfo?["NSFieldEditor"] as? NSTextView)?.selectedRange }
    func takeKeys() {
        guard composer.currentEditor() == nil, window?.makeFirstResponder(composer) == true, let editor = composer.currentEditor() else { return }
        let length = (composer.stringValue as NSString).length
        editor.selectedRange = caret.flatMap { NSMaxRange($0) <= length ? $0 : nil } ?? NSRange(location: length, length: 0)
    }
    private func submit() {
        let text = composer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        forward()
        let boxed = mirror != nil && tab()?.claude != "waiting"
        composer.stringValue = ""
        placeholder.isHidden = false
        grow()
        if boxed { (mirror, edited) = ("", Date()) }
        boxed ? enter(text) : send(text)
        stuck = true
        show()
    }

    func refresh() {
        var info = stat()
        let size = stat(path, &info) == 0 ? UInt64(info.st_size) : 0
        if size < end { return tail() }
        if size > end {
            let read = lines(end, size, cut: false)
            entries += read.flatMap(\.entries)
            end = read.last?.end ?? end
        }
        show()
        fill()
    }


    static func searches(_ action: String) -> Bool { action == "start_search" || action.hasPrefix("navigate_search") }

    func find(_ action: String) {
        switch action {
        case "start_search":
            if finder == nil {
                if start > 0 {
                    while start > 0 { older() }
                    show(prepended: true)
                }
                finder = FindBar(over: viewport, top: under + 8, stays: false, act: { [unowned self] in find($0) }, back: { [unowned self] in takeKeys() })
            }
            finder?.open(nil)
        case "navigate_search:next", "navigate_search:previous":
            guard !hits.isEmpty else { return }
            hit = (hit + (action.hasSuffix("next") ? 1 : hits.count - 1)) % hits.count
            lit(reveal: true)
        case "end_search":
            finder?.close()
            finder = nil
            needle = ""
            lit(reveal: false)
        default:
            needle = String(action.dropFirst("search:".count))
            hit = 0
            lit(reveal: true)
        }
    }

    private func lit(reveal: Bool) {
        hits = []
        for index in rows.indices.reversed() {
            let texts = said(index)
            let found = texts.map { text in
                let string = text.string.string as NSString
                var found: [NSRange] = [], from = 0
                while !needle.isEmpty, case let range = string.range(of: needle, options: .caseInsensitive, range: NSRange(location: from, length: string.length - from)), range.location != NSNotFound {
                    found.append(range)
                    from = NSMaxRange(range)
                }
                return found
            }
            if found.contains(where: { !$0.isEmpty }) { hits.append(index) }
            for (text, ranges) in zip(texts, found) {
                (text.found, text.current) = (ranges, !ranges.isEmpty && hits.count - 1 == hit)
                text.needsDisplay = true
            }
        }
        finder?.total = needle.isEmpty ? nil : hits.count
        finder?.selected = hits.isEmpty ? nil : hit
        guard reveal, hits.indices.contains(hit) else { return }
        let clip = scroll.contentView, middle = (under + bounds.height - Self.slot) / 2
        let to = NSPoint(x: 0, y: max(0, min(doc.frame.height - clip.bounds.height, rows[hits[hit]].view.frame.midY - middle)))
        let from = clip.bounds.minY
        clip.scroll(to: to)
        scroll.reflectScrolledClipView(clip)
        guard from != to.y, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let glide = CABasicAnimation(keyPath: "bounds.origin.y")
        glide.fromValue = from - to.y
        glide.toValue = 0
        glide.isAdditive = true
        glide.duration = 0.25
        glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        clip.layer?.add(glide, forKey: nil)
    }

    private func said(_ index: Int) -> [Text] {
        func texts(_ view: NSView) -> [Text] { (view as? Text).map { [$0] } ?? view.subviews.flatMap(texts) }
        switch rows[index].item {
        case .user, .unsent, .reply: return texts(rows[index].view)
        default: return []
        }
    }


    private func tail() {
        var info = stat()
        (entries, start, end) = ([], 0, 0)
        guard stat(path, &info) == 0 else { return show() }
        start = UInt64(info.st_size)
        older(first: true)
        show()
    }

    private func older(first: Bool = false) {
        var chunk = Self.chunk
        while start > 0 {
            let from = start > chunk ? start - chunk : 0, read = lines(from, start, cut: from > 0)
            if first { end = read.last?.end ?? from }
            guard let turn = from == 0 ? 0 : read.firstIndex(where: { $0.entries.first.map { $0.kind == .user || $0.kind == .divider || $0.kind == .compaction } == true }) else {
                chunk *= 4
                continue
            }
            entries.insert(contentsOf: read[turn...].flatMap(\.entries), at: 0)
            start = from == 0 ? 0 : read[turn].start
            return
        }
    }

    private func lines(_ from: UInt64, _ to: UInt64, cut: Bool) -> [(start: UInt64, end: UInt64, entries: [Entry])] {
        guard to > from, let file = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? file.close() }
        try? file.seek(toOffset: from)
        let data = (try? file.read(upToCount: Int(to - from))) ?? Data()
        var out: [(start: UInt64, end: UInt64, entries: [Entry])] = [], at = data.startIndex, skip = cut
        while let newline = data[at...].firstIndex(of: 0x0A) {
            if !skip, let json = try? JSONSerialization.jsonObject(with: data[at..<newline]) as? [String: Any] {
                out.append((from + UInt64(at - data.startIndex), from + UInt64(newline + 1 - data.startIndex), Self.entries(json)))
            }
            skip = false
            at = newline + 1
        }
        return out
    }

    static func entries(_ json: [String: Any]) -> [Entry] {
        let peer = (json["origin"] as? [String: Any])?["kind"] as? String == "peer"
        guard json["isSidechain"] as? Bool != true, json["isMeta"] as? Bool != true || peer else { return [] }
        let at = (json["timestamp"] as? String).flatMap(stamps.date) ?? .distantPast, content = (json["message"] as? [String: Any])?["content"]
        if json["isCompactSummary"] as? Bool == true { return [Entry(kind: .summary, text: summary(content as? String ?? ""), at: at)] }
        switch json["type"] as? String {
        case "system":
            guard json["subtype"] as? String == "compact_boundary" else { return [] }
            let meta = json["compactMetadata"] as? [String: Any] ?? [:]
            return [Entry(kind: .compaction, text: meta["trigger"] as? String == "auto" ? "Auto-compacted" : "Compacted", id: json["uuid"] as? String ?? "\(at.timeIntervalSince1970)", at: at, status: "\(meta["preTokens"] as? Int ?? 0) \(meta["postTokens"] as? Int ?? 0)")]
        case "attachment":
            let queued = json["attachment"] as? [String: Any], said = (queued?["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if said.hasPrefix("<task-notification>") { return notice(said, at: at) }
            if let message = message(said, at: at, peer: (queued?["origin"] as? [String: Any])?["kind"] as? String == "peer") { return [message] }
            return queued?["type"] as? String == "queued_command" && !said.isEmpty ? [Entry(kind: .user, text: said, at: at)] : []
        case "user":
            let text = (content as? String) ?? (content as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n") ?? ""
            if let command = tag("command-name", text) {
                return [command == "/clear" ? Entry(kind: .divider, text: "Cleared", at: at) : Entry(kind: .user, text: ([command] + [tag("command-args", text)].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " "), at: at, mode: json["permissionMode"] as? String)]
            }
            var said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.hasPrefix("<task-notification>") { return notice(said, at: at) }
            if let message = message(said, at: at, peer: peer) { return [message] }
            let blocks = content as? [[String: Any]] ?? []
            func pictures(_ list: [[String: Any]]) -> [Data] { list.compactMap { $0["type"] as? String == "image" ? ((($0["source"] as? [String: Any])?["data"] as? String).flatMap { Data(base64Encoded: $0) }) : nil } }
            let read = blocks.flatMap { $0["type"] as? String == "tool_result" ? pictures($0["content"] as? [[String: Any]] ?? []) : [] }, pasted = pictures(blocks)
            let outputs = blocks.compactMap { block -> Entry? in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                let output = (block["content"] as? String) ?? (block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
                return Entry(kind: .output, text: output, id: id, at: at, failed: block["is_error"] as? Bool == true)
            }
            if !outputs.isEmpty { return outputs + (read.isEmpty ? [] : [Entry(kind: .seen, text: "", at: at, images: read)]) }
            if !read.isEmpty { return [Entry(kind: .seen, text: "", at: at, images: read)] }
            if !pasted.isEmpty {
                said = said.replacingOccurrences(of: #"\[Image #\d+\]\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                return [Entry(kind: .pasted, text: "", at: at, images: pasted)] + (said.isEmpty ? [] : [Entry(kind: .user, text: said, at: at, mode: json["permissionMode"] as? String)])
            }
            return said.isEmpty || said.hasPrefix("<") || said.hasPrefix("[Request interrupted") || said.hasPrefix("Caveat:") ? [] : [Entry(kind: .user, text: said, at: at, mode: json["permissionMode"] as? String)]
        case "assistant":
            return (content as? [[String: Any]] ?? []).compactMap { block -> Entry? in
                if block["type"] as? String == "tool_use" {
                    let input = block["input"] as? [String: Any] ?? [:], name = block["name"] as? String ?? "", questions = input["questions"] as? [[String: Any]] ?? []
                    let ask = name == "AskUserQuestion" ? Ask(detail: questions.first?["question"] as? String ?? "", options: (questions.first?["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }, pick: questions.count == 1 && questions[0]["multiSelect"] as? Bool != true)
                        : Ask(detail: name == "Bash" || name == "REPL" ? input["description"] as? String ?? "" : "", body: ["command", "code", "file_path", "url"].lazy.compactMap { input[$0] as? String }.first ?? "")
                    let svg = (input["files"] as? [String])?.first { $0.hasSuffix(".svg") }
                    let figure = name == "mcp__easel__chart" ? (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } : svg.map { ([$0] + [input["caption"] as? String].compactMap { $0 }).joined(separator: "\n") }
                    return Entry(kind: .tool, text: line(input), name: name, id: block["id"] as? String ?? UUID().uuidString, at: at, ask: ask, figure: figure, old: input["old_string"] as? String ?? "", new: input["new_string"] as? String ?? "")
                }
                let text = block["type"] as? String == "text" ? (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
                return text.isEmpty ? nil : Entry(kind: .reply, text: text, at: at)
            }
        default: return []
        }
    }

    private static func summary(_ text: String) -> String {
        let body = text.range(of: "Summary:\n").map { String(text[$0.upperBound...]) } ?? text
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false), end = lines.firstIndex { $0.hasPrefix("If you need specific details from before compaction") || $0.hasPrefix("Continue the conversation from where it left off") } ?? lines.endIndex
        return lines[..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func notice(_ text: String, at: Date) -> [Entry] {
        let summary = tag("summary", text) ?? "", status = tag("status", text) ?? "", quoted = summary.split(separator: "\"", omittingEmptySubsequences: false)
        guard let kind = summary.hasPrefix("Agent") ? "agent" : summary.hasPrefix("Background command") ? "shell" : nil else { return [] }
        let exit = summary.range(of: #"exit code \d+"#, options: .regularExpression).map { String(summary[$0].dropFirst(10)) }
        let shown = status == "failed" ? "Failed" : status == "killed" ? "Stopped" : exit.map { $0 == "0" ? "Done" : "Exit \($0)" } ?? "Finished"
        return [Entry(kind: .notice, text: quoted.count >= 3 ? String(quoted[1]) : summary, name: kind, id: (tag("task-id", text) ?? summary) + "\(at.timeIntervalSince1970)", at: at, status: shown, result: tag("result", text) ?? "")]
    }

    private static func message(_ text: String, at: Date, peer: Bool) -> Entry? {
        guard peer || text.hasPrefix("<cross-session-message"), let open = text.range(of: "<cross-session-message"), let head = text.range(of: ">", range: open.upperBound..<text.endIndex) else { return nil }
        let attributes = String(text[open.upperBound..<head.lowerBound]), name = attributes.range(of: #"from-name="[^"]*""#, options: .regularExpression).map { String(attributes[$0].dropFirst(11).dropLast()) } ?? "Another session"
        let close = text.range(of: "</cross-session-message>", range: head.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        var body = text[head.upperBound..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("[\(name)] ") { body.removeFirst(name.count + 3) }
        return Entry(kind: .notice, text: name, name: "peer", id: "peer\(at.timeIntervalSince1970)", at: at, result: body)
    }

    private static func tag(_ name: String, _ text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func line(_ input: [String: Any]) -> String {
        for key in ["description", "file_path", "url", "pattern", "command", "prompt", "query"] {
            guard let text = input[key] as? String, !text.isEmpty else { continue }
            return String((key == "file_path" ? (text as NSString).lastPathComponent : text).split(separator: "\n").first ?? "")
        }
        return ""
    }

    private static func summary(_ names: [String]) -> String {
        let keys = names.map { words[$0] == nil ? "" : $0 }
        return keys.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.map { key in
            let count = keys.filter { $0 == key }.count, (verb, noun) = words[key] ?? ("Used", "tool")
            return "\(verb) \(count) \(noun)\(count > 1 ? "s" : "")"
        }.joined(separator: ", ")
    }


    private func items() -> [Item] {
        let tab = tab(), state = tab?.claude
        var out: [Item] = [], run: [Entry] = [], seen: [Data] = [], held: Entry?, summary = ""
        func compaction() {
            guard let compacted = held else { return }
            let tokens = compacted.status.split(separator: " ").compactMap { Int($0) }
            out.append(.compaction(id: compacted.id, title: compacted.text, before: tokens.first ?? 0, after: tokens.last ?? 0, summary: summary, open: open.contains(compacted.id), since: nil))
            (held, summary) = (nil, "")
        }
        let outputs = Dictionary(entries.filter { $0.kind == .output }.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        func call(_ entry: Entry) -> Item {
            let result = outputs[entry.id]
            var output = result?.text ?? "", status = ""
            if let exit = output.firstMatch(of: #/^Exit code (\d+)\n?/#) {
                status = "exit \(exit.1)"
                output = String(output[exit.range.upperBound...])
            } else if result?.failed == true {
                status = "error"
            }
            output = output.replacingOccurrences(of: #"</?tool_use_error>"#, with: "", options: .regularExpression).trimmingCharacters(in: .newlines)
            return .call(Call(name: entry.name, id: entry.id, line: entry.text, body: entry.ask.body, output: output, status: status, old: entry.old, new: entry.new, open: open.contains("out " + entry.id), more: open.contains("more " + entry.id)))
        }
        func flush(_ ending: Date?) {
            defer {
                if !seen.isEmpty { out.append(.images(seen, pasted: false)) }
                seen = []
            }
            guard let first = run.first else { return }
            let running = ending == nil && (state == "working" || state == "waiting"), asked = ending == nil && state == "waiting" && tab?.action?.worker == nil ? run.last : nil
            let shown = running ? Array(run.dropLast(asked == nil ? 0 : 1).suffix(asked == nil ? 3 : 2)) : [], folded = run.dropLast(shown.count + (asked == nil ? 0 : 1)).filter { $0.name != "REPL" }
            if !folded.isEmpty {
                let opened = open.contains(first.id)
                out.append(.fold(id: first.id, text: Self.summary(folded.map(\.name)), time: running ? "" : Self.duration((ending ?? run.last!.at).timeIntervalSince(first.at)), open: opened))
                if opened { out += folded.map(call) }
            }
            for (index, step) in shown.enumerated() { out.append(state == "working" && index == shown.count - 1 ? .live(line: step.text, at: step.at) : call(step)) }
            if let asked {
                let head = ["Bash": "Allow this command?", "AskUserQuestion": asked.ask.detail, "ExitPlanMode": "Approve the plan?"][asked.name] ?? tab?.action?.ask ?? "Allow \(asked.name)?"
                var ask = asked.ask
                if asked.name == "AskUserQuestion" { ask.detail = "" }
                out.append(.ask(name: asked.name, head: head, ask: ask))
            }
            run = []
        }
        for (index, entry) in entries.enumerated() where entry.kind != .output {
            if entry.kind == .summary {
                summary = entry.text
                continue
            }
            if held != nil, entry.kind != .user || !entry.text.hasPrefix("/compact") { compaction() }
            if entry.kind == .seen {
                seen += entry.images
                continue
            }
            guard entry.kind != .tool else {
                run.append(entry)
                let next = index + 1 < entries.count ? entries[index + 1].at : nil
                if let figure = entry.figure, next != nil || !["working", "waiting"].contains(state) {
                    flush(next)
                    out.append(.figure(figure))
                }
                continue
            }
            flush(entry.at)
            switch entry.kind {
            case .pasted: out.append(.images(entry.images, pasted: true))
            case .notice: out.append(.notice(id: entry.id, kind: entry.name, title: entry.text, status: entry.status, result: entry.result, open: open.contains(entry.id) != (entry.name == "peer")))
            case .user: out.append(.user(entry.text))
            case .reply: out.append(.reply(entry.text))
            case .compaction: held = entry
            default: out.append(.divider(entry.text))
            }
            if entry.kind == .user && entry.text.hasPrefix("/compact") { compaction() }
        }
        compaction()
        flush(nil)
        if let name = tab?.name, let began = (try? FileManager.default.attributesOfItem(atPath: statusDir + "/." + name + ".compact"))?[.modificationDate] as? Date { out.append(.compaction(id: "compacting", title: "Compacting", before: 0, after: 0, summary: "", open: false, since: began)) }
        let waiting = unsent().filter { sent in !entries.contains { $0.kind == .user && $0.text == sent.text && $0.at >= sent.at } }
        return out + waiting.map { .unsent($0.text) } + (state == "working" && waiting.contains { $0.pid != nil } ? [.sendNow] : [])
    }

    private func show(prepended: Bool = false) {
        guard column > 0 else { return }
        let items = items(), keep = prepended ? 0 : zip(rows, items).prefix { $0.item == $1 }.count
        rows[keep...].forEach { $0.view.removeFromSuperview() }
        rows.removeSubrange(keep...)
        if keep == 0 || !rows.contains(where: { if case .live = $0.item { true } else if case .compaction(_, _, _, _, _, _, .some) = $0.item { true } else { false } }) { clock = nil }
        for item in items[keep...] {
            let row = make(item)
            doc.addSubview(row.view)
            rows.append(row)
        }
        place(prepended: prepended)
        tick()
        if finder != nil { lit(reveal: false) }
    }

    private func place(prepended: Bool = false) {
        let clip = scroll.contentView, before = doc.frame.height, top = clip.bounds.minY
        var y: CGFloat = 28
        for row in rows {
            row.view.frame.origin.y = y + row.gap
            y = row.view.frame.maxY
        }
        let content = y + 24 + Self.slot + grown + above, height = max(content, clip.bounds.height)
        for row in rows { row.view.frame.origin.y += height - content }
        doc.frame = NSRect(x: 0, y: 0, width: clip.bounds.width, height: height)
        if stuck && swiping { return }
        let to = stuck ? height - clip.bounds.height : prepended ? top + height - before : top
        clip.scroll(to: NSPoint(x: 0, y: max(0, to)))
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func scrolled() {
        let clip = scroll.contentView
        stuck = clip.bounds.maxY >= doc.frame.height - 2
        guard !paging, start > 0, clip.bounds.minY < clip.bounds.height / 2 else { return }
        paging = true
        older()
        show(prepended: true)
        paging = false
    }

    private func tick() {
        guard clock != nil, window != nil else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let clock else { return }
            clock.text.string = plain(Self.duration(Date().timeIntervalSince(clock.at)), color: dim)
            clock.text.fit(60)
        }
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }


    private var ink: NSColor { dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.88) }
    private var dim: NSColor { dark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.56) }
    private var faint: NSColor { NSColor(white: dark ? 1 : 0, alpha: 0.32) }
    private static let body = NSFont.systemFont(ofSize: 13)
    private static let read: CGFloat = 15, lead: CGFloat = 23

    private func para(_ lineHeight: CGFloat = 18) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakStrategy = .standard
        return style
    }
    private func plain(_ text: String, font: NSFont = body, color: NSColor? = nil, lineHeight: CGFloat = 18) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color ?? ink, .paragraphStyle: para(lineHeight)])
    }
    private func blocks(_ text: String) -> NSView {
        enum Piece { case prose(NSMutableAttributedString), code(String, String), table(Int, [[NSAttributedString]]), rule }
        let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full))) ?? AttributedString(text)
        var pieces: [Piece] = [], lastItem: Int?, lastRow: Int?
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let kinds = intent?.components ?? [], slice = AttributedString(parsed[range])
            if kinds.contains(where: { $0.kind == .thematicBreak }) {
                pieces.append(.rule)
                continue
            }
            if case .codeBlock(let hint)? = kinds.first(where: { if case .codeBlock = $0.kind { true } else { false } })?.kind {
                pieces.append(.code(hint ?? "", String(slice.characters).trimmingCharacters(in: .newlines)))
                continue
            }
            if let table = kinds.first(where: { if case .table = $0.kind { true } else { false } }) {
                let row = kinds.first { if case .tableRow = $0.kind { true } else { $0.kind == .tableHeaderRow } }?.identity
                let cell = inline(slice, size: read)
                if case .table(let id, var rows)? = pieces.last, id == table.identity {
                    if row == lastRow { rows[rows.count - 1].append(cell) } else { rows.append([cell]) }
                    pieces[pieces.count - 1] = .table(id, rows)
                } else {
                    pieces.append(.table(table.identity, [[cell]]))
                }
                lastRow = row
                continue
            }
            let level = kinds.lazy.compactMap { kind -> Int? in
                guard case .header(let level) = kind.kind else { return nil }
                return level
            }.first
            let size: CGFloat = level.map { read * ([2, 1.5, 1.17, 1, 0.83, 0.67] as [CGFloat])[min($0, 6) - 1] } ?? read
            let line = inline(slice, size: size, weight: level == nil ? .regular : .bold, color: kinds.contains { $0.kind == .blockQuote } ? dim : ink)
            let style = para(level == nil ? lead : ceil(size * 1.3))
            let depth = CGFloat(kinds.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count)
            var continued = false
            if let item = kinds.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }), case .listItem(let ordinal) = kinds[item].kind {
                (style.headIndent, style.firstLineHeadIndent) = (depth * 27.5, (depth - 1) * 27.5)
                style.tabStops = [NSTextTab(textAlignment: .left, location: depth * 27.5)]
                if kinds[item].identity != lastItem {
                    let ordered = item + 1 < kinds.count && kinds[item + 1].kind == .orderedList
                    line.insert(plain((ordered ? "\(ordinal)." : "•") + "\t", font: prose(read), color: ordered ? ink : dim), at: 0)
                    continued = lastItem != nil
                } else {
                    style.firstLineHeadIndent = depth * 27.5
                }
                lastItem = kinds[item].identity
            } else {
                lastItem = nil
            }
            if kinds.contains(where: { $0.kind == .blockQuote }) { (style.headIndent, style.firstLineHeadIndent) = (14, 14) }
            if case .prose(let prose)? = pieces.last {
                style.paragraphSpacingBefore = continued ? 6 : level.map { 9 + [0.14, 0.09, 0.04, 0, 0, 0][min($0, 6) - 1] * size } ?? 12
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                prose.append(NSAttributedString(string: "\n", attributes: prose.attributes(at: prose.length - 1, effectiveRange: nil)))
                prose.append(line)
            } else {
                line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
                pieces.append(.prose(line))
            }
        }
        let box = Flip(frame: NSRect(x: 0, y: 0, width: column, height: 0))
        var y: CGFloat = 0
        for piece in pieces {
            let view: NSView
            switch piece {
            case .prose(let prose): view = Text(prose, width: column)
            case .code(let hint, let code): view = codeBlock(hint, code)
            case .table(_, let rows): view = table(rows)
            case .rule: view = rounded(NSRect(x: 0, y: 0, width: column, height: 1), fill: NSColor(white: dark ? 1 : 0, alpha: 0.1), radius: 0)
            }
            view.frame.origin.y = y + (y == 0 ? 0 : 16)
            box.addSubview(view)
            y = view.frame.maxY
        }
        box.frame.size.height = y
        return box
    }
    private func inline(_ slice: AttributedString, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for run in slice.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = prose(size, weight: intent.contains(.stronglyEmphasized) && weight == .regular ? .semibold : weight)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? (Self.look == "A" ? term.ink : ink), .paragraphStyle: para()]
            if intent.contains(.code) {
                attributes[.font] = Self.look == "A" ? prose(size) : NSFont.monospacedSystemFont(ofSize: (size * 0.85).rounded(), weight: .regular)
                attributes[.backgroundColor] = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.08 : 0.05)
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.controlAccentColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = NSColor.controlAccentColor.withAlphaComponent(0.4)
            }
            out.append(NSAttributedString(string: String(slice[run.range].characters), attributes: attributes))
        }
        return out
    }
    private func codeBlock(_ hint: String, _ code: String) -> NSView {
        let field = Text(plain(code, font: .monospacedSystemFont(ofSize: 12.5, weight: .regular), lineHeight: 19), width: column - 24)
        field.frame.origin = NSPoint(x: 12, y: 8)
        let copy = copyButton(code, "Copy code", at: NSPoint(x: column - 8 - 24, y: 4))
        let block = Code(frame: NSRect(x: 0, y: 0, width: column, height: field.frame.height + 16), copy: copy)
        block.layer!.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: 0.04).cgColor
        [field, copy].forEach(block.addSubview)
        if !hint.isEmpty {
            let label = Text(plain(hint, font: .systemFont(ofSize: 11), color: dim, lineHeight: 16), width: column)
            label.frame.origin = NSPoint(x: copy.frame.minX - 4 - label.frame.width, y: 6)
            block.addSubview(label)
        }
        return block
    }
    private func copyButton(_ string: String, _ label: String, at origin: NSPoint) -> Press {
        let copy = Press {
            let board = ClaudeTTY.pasteboard(GHOSTTY_CLIPBOARD_STANDARD)!
            board.clearContents()
            board.setString(string, forType: .string)
        }
        copy.isBordered = false
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 10, weight: .regular).applying(.init(paletteColors: [dim])))
        copy.setAccessibilityLabel(label)
        copy.frame = NSRect(origin: origin, size: NSSize(width: 24, height: 20))
        copy.wantsLayer = true
        copy.layer!.backgroundColor = NSColor(white: dark ? 1 : 0, alpha: 0.06).cgColor
        copy.layer!.cornerRadius = 6
        return copy
    }
    private func table(_ rows: [[NSAttributedString]]) -> NSView {
        let cells = rows.enumerated().map { index, row in row.map { cell in
            let text = NSMutableAttributedString(attributedString: cell)
            if index == 0 { text.addAttribute(.font, value: prose(read, weight: .bold), range: NSRange(location: 0, length: text.length)) }
            return text as NSAttributedString
        } }
        let count = cells.map(\.count).max() ?? 0
        let natural = (0..<count).map { col in cells.map { $0.count > col ? ceil($0[col].size().width) + 4 : 0 }.max() ?? 0 }
        let room = column - CGFloat(count) * 25 - 1, sum = natural.reduce(0, +)
        let widths = sum > room ? natural.map { ($0 * room / sum).rounded(.down) } : natural
        let left = widths.indices.map { col in widths[..<col].reduce(0, +) + CGFloat(col) * 25 + 1 }
        let width = (left.last ?? 0) + (widths.last ?? 0) + 25
        let box = Flip(frame: NSRect(x: 0, y: 0, width: width, height: 0)), line = NSColor(white: dark ? 1 : 0, alpha: 0.18)
        var y: CGFloat = 1, tops: [CGFloat] = []
        for row in cells {
            tops.append(y)
            let fields = row.enumerated().map { col, cell in Text(cell, width: widths[col]) }
            let height = (fields.map(\.frame.height).max() ?? 18) + 12
            for (col, field) in fields.enumerated() {
                field.frame.origin = NSPoint(x: left[col] + 10, y: y + 6)
                box.addSubview(field)
            }
            y += height + 1
        }
        box.frame.size.height = y
        for top in tops + [y] { box.addSubview(rounded(NSRect(x: 0, y: top - 1, width: width, height: 1), fill: line, radius: 0)) }
        for x in left.map({ $0 - 1 }) + [width - 1] { box.addSubview(rounded(NSRect(x: x, y: 0, width: 1, height: y), fill: line, radius: 0)) }
        return box
    }
    private func figure(_ spec: String) -> NSView {
        let lines = spec.components(separatedBy: "\n")
        if lines[0].hasSuffix(".svg") {
            guard let image = NSImage(contentsOfFile: lines[0]), image.size.width > 0 else { return Text(plain("Couldn't read " + (lines[0] as NSString).lastPathComponent, color: dim), width: column) }
            let scale = min(1, column / image.size.width, 360 / image.size.height)
            let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
            let box = Flip(frame: NSRect(origin: .zero, size: size)), picture = NSImageView(frame: NSRect(origin: .zero, size: size))
            picture.image = image
            picture.imageScaling = .scaleProportionallyUpOrDown
            box.addSubview(picture)
            if lines.count > 1 {
                let caption = Text(plain(lines.dropFirst().joined(separator: " "), font: .systemFont(ofSize: 12), color: dim, lineHeight: 16), width: column)
                caption.frame.origin = NSPoint(x: -2, y: size.height + 6)
                box.addSubview(caption)
                box.frame.size = NSSize(width: max(size.width, caption.frame.maxX), height: caption.frame.maxY)
            }
            return box
        }
        let input = (try? JSONSerialization.jsonObject(with: Data(spec.utf8))) as? [String: Any] ?? [:]
        let x = input["x"] as? String ?? "", y = (input["y"] as? [String])?.first ?? ""
        let bars = (input["data"] as? [[String: Any]] ?? []).compactMap { row -> Bars.Bar? in
            guard let name = row[x].map({ "\($0)" }), let value = (row[y] as? NSNumber)?.doubleValue else { return nil }
            return Bars.Bar(name: name, value: value)
        }
        let chart = NSHostingView(rootView: Bars(title: input["title"] as? String ?? "", bars: bars, ink: Color(nsColor: ink), dim: Color(nsColor: dim)))
        chart.frame = NSRect(x: 0, y: 0, width: column - 2, height: CGFloat(bars.count) * 38 + 30)
        return chart
    }
    private func iconText(_ name: String, _ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSMutableAttributedString {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: size, weight: weight).applying(.init(paletteColors: [dim])))!
        let mark = NSTextAttachment()
        mark.image = image
        mark.bounds = NSRect(x: 0, y: ((Self.body.capHeight - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
        let out = NSMutableAttributedString(attachment: mark), style = para()
        out.append(plain("\t" + text, color: dim))
        style.tabStops = [NSTextTab(textAlignment: .left, location: 20)]
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }
    private func truncated(_ text: NSAttributedString, width: CGFloat) -> Text {
        let line = NSMutableAttributedString(attributedString: text)
        line.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: line.length)) { style, range, _ in
            let cut = (style as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            cut.lineBreakMode = .byTruncatingTail
            line.addAttribute(.paragraphStyle, value: cut, range: range)
        }
        let field = Text(line, width: width)
        field.frame.size = NSSize(width: min(field.frame.width, width), height: 18)
        return field
    }
    private func rounded(_ frame: NSRect, fill: NSColor, radius: CGFloat) -> NSView {
        let view = Flip(frame: frame)
        view.wantsLayer = true
        view.layer!.backgroundColor = fill.cgColor
        view.layer!.cornerRadius = radius
        view.layer!.cornerCurve = .continuous
        return view
    }

    private func preview(_ images: [NSImage], at index: Int) {
        guard let window else { return }
        preview?.close()
        let shown = Preview(images, at: index, over: window)
        shown.closed = { [weak self] in
            self?.preview = nil
            self?.releaseKeys()
        }
        probe == nil ? shown.makeKeyAndOrderFront(nil) : shown.orderBack(nil)
        preview = shown
        previewKeys = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window, let hit = event.window?.contentView?.superview?.hitTest(event.locationInWindow), hit.isDescendant(of: scroll) || hit.isDescendant(of: glass) else { return event }
            releaseKeys()
            return event
        }
    }

    private func releaseKeys() {
        previewKeys.map(NSEvent.removeMonitor)
        previewKeys = nil
    }

    var probed: [String] {
        func box(_ view: NSView, _ part: NSRect? = nil) -> String { let r = view.convert(part ?? view.bounds, to: nil); return [r.minX, r.minY, r.width, r.height].map { String(format: "%g", $0) }.joined(separator: " ") }
        func pixels(_ image: NSImage?) -> String { image?.representations.first.map { "\($0.pixelsWide)x\($0.pixelsHigh)" } ?? "" }
        var lines: [String] = []
        if let editor = composer.currentEditor() as? NSTextView, let layout = editor.layoutManager, let container = editor.textContainer {
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, glyphs, _ in
                let text = (editor.string as NSString).substring(with: layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)).trimmingCharacters(in: .newlines)
                let ink = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                lines.append("composerline\t\(text)\t\(box(editor, ink))")
            }
        }
        return rows.flatMap { row -> [String] in
            switch row.item {
            case .images: return row.view.subviews.flatMap(\.subviews).compactMap { ($0 as? Mark).map { "image\t\(pixels($0.image))\t\(box($0))" } }
            case .user(let text), .unsent(let text): return ["said\t" + text.replacingOccurrences(of: "\n", with: " ")]
            case .notice(_, let kind, let title, _, _, _): return row.view.subviews.flatMap(\.subviews).compactMap { ($0 as? Mark).map { "chevron\t\(title)\t\(box($0))" } }
            case .compaction(_, let title, _, _, _, _, _):
                let views = row.view.subviews.flatMap(\.subviews)
                return views.compactMap { ($0 as? Mark).map { "chevron\t\(title)\t\(box($0))" } } + views.compactMap { view in (view as? Text).flatMap { text in text.string.length == 0 ? nil : (text.string.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment).map { "glyph\t\(title)\t\(Self.compacted)\t\(box(text, NSRect(x: 2, y: 0, width: $0.bounds.width, height: text.bounds.height)))" } } }
            default: return []
            }
        } + (preview.flatMap { $0.isVisible ? ["preview\t" + pixels($0.images[$0.index])] : nil } ?? []) + lines
    }
    var typed: [String] {
        func line(_ font: NSFont?, _ base: NSPoint, _ end: CGFloat, _ text: String) -> (CGFloat, String) {
            (base.y, "\(String(format: "%g", font?.pointSize ?? 0))\t\(base.y)\t\(Int(base.x)) \(Int(end))\t" + text.replacingOccurrences(of: "\u{fffc}\t", with: "").trimmingCharacters(in: .newlines))
        }
        func lines(_ view: NSView) -> [(CGFloat, String)] {
            guard !view.isHiddenOrHasHiddenAncestor else { return [] }
            if let text = view as? Text {
                let storage = NSTextStorage(attributedString: text.string), layout = NSLayoutManager(), box = NSTextContainer(size: NSSize(width: text.bounds.width - 4, height: 100_000))
                box.lineFragmentPadding = 0
                layout.addTextContainer(box)
                storage.addLayoutManager(layout)
                var out: [(CGFloat, String)] = []
                layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: box)) { rect, used, _, glyphs, _ in
                    let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), shown = (storage.string as NSString).substring(with: chars)
                    let skip = (shown as NSString).rangeOfCharacter(from: CharacterSet(charactersIn: "\u{fffc}\t").inverted).location, letter = chars.location + (skip == NSNotFound ? 0 : skip)
                    let base = text.convert(NSPoint(x: used.minX + 2, y: rect.minY + layout.location(forGlyphAt: glyphs.location).y), to: nil)
                    out.append(line(storage.attribute(.font, at: min(letter, storage.length - 1), effectiveRange: nil) as? NSFont, base, text.convert(NSPoint(x: used.maxX + 2, y: 0), to: nil).x, shown))
                }
                return out
            }
            if let field = view as? NSTextField {
                let shown = field.stringValue.isEmpty ? field.placeholderString ?? "" : field.stringValue
                let base = field.convert(NSPoint(x: 2, y: field.isFlipped ? field.firstBaselineOffsetFromTop : field.bounds.height - field.firstBaselineOffsetFromTop), to: nil)
                return shown.isEmpty ? [] : [line(field.font, base, base.x + NSAttributedString(string: shown, attributes: [.font: field.font as Any]).size().width, shown)]
            }
            return view.subviews.flatMap(lines)
        }
        return lines(self).sorted { $0.0 > $1.0 }.map(\.1)
    }


    private var term: Theme {
        if themed?.real != true { themed = theme() }
        return themed!.theme
    }
    private func hue(_ index: Int, _ fallback: NSColor) -> NSColor { term.palette.count > index ? term.palette[index] : fallback }
    private var printed: NSColor { hue(8, .gray).blended(withFraction: 0.5, of: term.ink) ?? term.ink }
    private var cell: CGFloat { ("M" as NSString).size(withAttributes: [.font: term.font]).width }
    private var read: CGFloat { Self.look == "A" ? term.font.pointSize : Self.read }
    private var lead: CGFloat { Self.look == "A" ? (term.font.pointSize * 18 / 13).rounded() : Self.lead }
    private func prose(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard Self.look == "A" else { return .systemFont(ofSize: size, weight: weight) }
        let font = NSFont(descriptor: term.font.fontDescriptor, size: size) ?? term.font
        return weight == .regular ? font : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }
    func relook() {
        column = 0
        needsLayout = true
    }
    private func termText(_ text: String, _ color: NSColor, bold: Bool = false, first: CGFloat = 0, rest: CGFloat = 0, words: Bool = false) -> NSMutableAttributedString {
        let style = para((term.font.pointSize * 18 / 13).rounded())
        style.lineBreakMode = words ? .byWordWrapping : .byCharWrapping
        if words { style.tabStops = [NSTextTab(textAlignment: .left, location: rest)] }
        (style.firstLineHeadIndent, style.headIndent) = (first, rest)
        return NSMutableAttributedString(string: text, attributes: [.font: bold ? NSFontManager.shared.convert(term.font, toHaveTrait: .boldFontMask) : term.font, .foregroundColor: color, .paragraphStyle: style])
    }
    private func inset(_ text: NSAttributedString, width: CGFloat, by indent: CGFloat) -> Text {
        let view = Text(text, width: width)
        view.frame.size.width = min(width, view.frame.width + indent)
        return view
    }
    private func glowing(_ run: (() -> Void)?, glow: Bool = true, _ parts: (Bool) -> [NSView]) -> Fact {
        let fact = Fact(parts(false), lit: parts(true), halo: glow ? halo : nil, click: run.map { run in { [unowned self] _ in
            window?.makeFirstResponder(self)
            run()
        } }, tall: true)
        fact.frame.origin.x = 2
        return fact
    }
    private func flip(_ key: String) {
        if open.remove(key) == nil { open.insert(key) }
        show()
    }
    static func diff(_ old: String, _ new: String) -> [(sign: Character, text: String)] {
        let before = old.components(separatedBy: "\n"), after = new.components(separatedBy: "\n")
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [(sign: Character, text: String)] = [], i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                out.append(("-", before[i]))
                i += 1
            } else if j < after.count, inserted.contains(j) {
                out.append(("+", after[j]))
                j += 1
            } else {
                out.append((" ", i < before.count ? before[i] : after[j]))
                i += 1
                j += 1
            }
        }
        return out
    }
    private func callView(_ call: Call, x0: CGFloat) -> NSView {
        let red = hue(1, .systemRed), green = hue(2, .systemGreen), ink = term.ink, indent = 2 * cell, frame = NSRect(x: x0, y: 0, width: column, height: 0)
        let copy = call.name == "Bash" ? copyButton(call.body, "Copy command", at: NSPoint(x: column - 24, y: 0)) : nil
        let view = copy.map { Code(frame: frame, copy: $0) } ?? Flip(frame: frame)
        let status = Text(termText(call.status, red), width: 120), room = column - 28 - (call.status.isEmpty ? 0 : status.frame.width + 8)
        let lines = Self.diff(call.old, call.new), edit = call.name == "Edit" && !(call.old + call.new).isEmpty
        let opens = ["Read", "Write"].contains(call.name) && !call.body.isEmpty
        let head = call.name == "Bash"
            ? glowing(call.output.isEmpty ? nil : { [unowned self] in flip("out " + call.id) }, glow: false) { lit in
                let line = self.termText("$ ", green, rest: indent)
                line.append(self.termText(call.body.replacingOccurrences(of: "\n", with: "\u{2028}"), lit || call.output.isEmpty ? ink : ink.withAlphaComponent(0.82), rest: indent))
                return [Text(line, width: room)]
            }
            : glowing(edit ? { [unowned self] in flip("out " + call.id) } : opens ? { [unowned self] in _ = link(call.body, false) } : nil) { lit in
                let line = self.termText(call.name + " ", ink, bold: true, rest: indent)
                line.append(self.termText(call.line, lit ? ink : self.printed, rest: indent))
                if edit {
                    line.append(self.termText("  +\(lines.filter { $0.sign == "+" }.count)", green))
                    line.append(self.termText(" \u{2212}\(lines.filter { $0.sign == "-" }.count)", red))
                }
                return [Text(line, width: room)]
            }
        view.addSubview(head)
        if !call.status.isEmpty {
            status.frame.origin.x = column - 28 - status.frame.width
            view.addSubview(status)
        }
        var y = head.frame.maxY
        func add(_ shown: NSView) {
            shown.frame.origin.y = y
            view.addSubview(shown)
            y = shown.frame.maxY
        }
        if call.name == "Bash", call.open, !call.output.isEmpty {
            let all = call.output.components(separatedBy: "\n"), shown = call.more ? all : Array(all.prefix(6)), left = all.count - shown.count
            add(inset(termText(shown.joined(separator: "\n"), printed, first: indent, rest: indent), width: column - 28, by: indent))
            if left > 0 { add(glowing({ [unowned self] in flip("more " + call.id) }) { lit in [self.inset(self.termText("\(left) more line\(left == 1 ? "" : "s")", lit ? ink : self.printed, first: indent), width: self.column, by: indent)] }) }
        }
        if edit, call.open {
            let text = NSMutableAttributedString()
            for (index, line) in lines.enumerated() { text.append(termText((index == 0 ? "" : "\n") + "\(line.sign) " + line.text, line.sign == "+" ? green : line.sign == "-" ? red : printed, first: indent, rest: indent + 2 * cell)) }
            add(inset(text, width: column - 28, by: indent))
        }
        copy.map(view.addSubview)
        view.frame.size.height = y
        return view
    }

    @objc private func sendNow() { keys("\u{18}\u{13}") }
    private func make(_ item: Item) -> (item: Item, view: NSView, gap: CGFloat) {
        let x0 = ((lane - column) / 2).rounded()
        switch item {
        case .user(let text) where Self.look == "A", .unsent(let text) where Self.look == "A":
            let line = termText("›\t", printed, rest: 20, words: true)
            line.append(termText(text.replacingOccurrences(of: "\n", with: "\u{2028}"), term.ink, rest: 20, words: true))
            let field = Text(line, width: column - 8), band = rounded(NSRect(x: x0 - 8, y: 0, width: column + 8, height: field.frame.height + 12), fill: term.ink.withAlphaComponent(dark ? 0.08 : 0.06), radius: 0)
            field.frame.origin = NSPoint(x: 8, y: field.centered(in: band.frame.height))
            band.addSubview(field)
            band.alphaValue = item == .user(text) ? 1 : 0.5
            return (item, band, 18)
        case .call(let call): return (item, callView(call, x0: x0), 4)
        case .user(let text), .unsent(let text):
            let field = Text(plain(text, font: .systemFont(ofSize: Self.read), lineHeight: Self.lead), width: max(column * 0.72 - 24, column / 2)), height = field.frame.height + 14
            let pill = rounded(NSRect(x: 0, y: 0, width: ceil(field.frame.width) + 24, height: height), fill: dark ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.06), radius: min(16, height / 2))
            field.frame.origin = NSPoint(x: 12, y: field.centered(in: height))
            pill.addSubview(field)
            pill.frame.origin.x = x0 + column - pill.frame.width
            pill.alphaValue = item == .user(text) ? 1 : 0.5
            return (item, pill, 18)
        case .sendNow:
            let button = LinkButton(title: "", target: self, action: #selector(sendNow))
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.text = "Send now"
            button.setFrameSize(button.fittingSize)
            button.frame.origin.x = x0 + column - button.frame.width - 12
            return (item, button, 4)
        case .reply(let text):
            let view = blocks(text)
            view.frame.origin.x = x0
            return (item, view, 12)
        case .figure(let spec):
            let view = figure(spec)
            view.frame.origin.x = x0 + 2
            return (item, view, 12)
        case .divider(let text):
            let row = Flip(frame: NSRect(x: x0, y: 0, width: column, height: 18)), field = Text(plain(text, font: .systemFont(ofSize: 12), color: dim), width: column)
            field.frame.origin.x = ((column - field.frame.width) / 2).rounded()
            row.addSubview(field)
            for rule in [NSRect(x: 0, y: 9, width: field.frame.minX - 8, height: 1), NSRect(x: field.frame.maxX + 8, y: 9, width: column - field.frame.maxX - 8, height: 1)] { row.addSubview(rounded(rule, fill: dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1), radius: 0)) }
            return (item, row, 18)
        case .compaction(let id, let title, let before, let after, let summary, let opened, let since):
            let glyph = Self.compacted, shrink = since.map { Self.duration(Date().timeIntervalSince($0)) } ?? ClaudeTTY.tokens(before) + " → " + ClaudeTTY.tokens(after)
            let toggle = { [unowned self] in
                if open.remove(id) == nil { open.insert(id) }
                let band = { [unowned self] in rows.first { if case .compaction(id, _, _, _, _, _, _) = $0.item { true } else { false } }?.view.frame.minY ?? 0 }
                let offset = band() - scroll.contentView.bounds.minY
                show()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, band() - offset), doc.frame.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                scrolled()
            }
            let row = Flip(frame: NSRect(x: x0, y: 0, width: column, height: 20)), body = summary.isEmpty ? nil : Text(inline((try? AttributedString(markdown: summary, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(summary), size: 13), width: column - 20)
            func live(_ field: Text, _ since: Date) {
                let spin = NSProgressIndicator(frame: NSRect(x: field.frame.minX + 1, y: field.frame.minY + 1, width: 14, height: 14)), line = NSMutableAttributedString(attributedString: field.string)
                spin.style = .spinning
                spin.controlSize = .small
                spin.startAnimation(nil)
                field.superview?.addSubview(spin)
                if let mark = line.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment { mark.image = NSImage(size: mark.bounds.size) }
                let seconds = Text(plain(shrink, color: dim), width: 60)
                line.replaceCharacters(in: NSRange(location: line.length - shrink.utf16.count, length: shrink.utf16.count), with: "")
                field.string = line
                seconds.frame.origin = NSPoint(x: field.frame.minX + line.size().width + 2, y: field.frame.minY)
                field.superview?.addSubview(seconds)
                clock = (seconds, since)
            }
            func chevron(_ x: CGFloat, _ y: CGFloat) -> NSView {
                let mark = Mark(frame: NSRect(x: x, y: y, width: 10, height: 10))
                mark.image = NSImage(systemSymbolName: opened ? "chevron.down" : "chevron.right", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [dim])))
                return mark
            }
            let head = Fold(frame: NSRect(x: 0, y: 0, width: column, height: 20)), line = iconText(glyph, title + "   ")
            head.toggle = toggle
            line.append(plain(shrink, color: dim))
            let field = Text(line, width: column)
            let width = field.frame.width + (body == nil ? 0 : 14), left = ((column - width) / 2).rounded()
            field.frame.origin = NSPoint(x: left, y: 1)
            head.addSubview(field)
            if let since { live(field, since) }
            if body != nil { head.addSubview(chevron(field.frame.maxX + 4, 5)) }
            for rule in [NSRect(x: 0, y: 10, width: left - 10, height: 1), NSRect(x: left + width + 10, y: 10, width: column - left - width - 10, height: 1)] { head.addSubview(rounded(rule, fill: dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.1), radius: 0)) }
            row.addSubview(head)
            if opened, let body {
                body.frame.origin = NSPoint(x: 20, y: 30)
                body.alphaValue = 0.78
                row.addSubview(rounded(NSRect(x: 7, y: body.frame.minY, width: 1, height: body.frame.height + 2), fill: dim, radius: 0))
                row.addSubview(body)
                row.frame.size.height = body.frame.maxY
            }
            return (item, row, 18)
        case .fold(let id, let text, let time, let opened):
            let line = iconText(opened ? "chevron.down" : "chevron.right", text + (time.isEmpty ? "" : "   "), size: 10, weight: .semibold)
            line.append(plain(time, color: dim))
            let row = Fold(frame: NSRect(x: x0, y: 0, width: column, height: 20)), field = Text(line, width: column)
            row.toggle = { [unowned self] in
                if open.remove(id) == nil { open.insert(id) }
                show()
            }
            field.frame.origin = NSPoint(x: 0, y: 1)
            row.addSubview(field)
            return (item, row, 10)
        case .live(let text, let at):
            let row = Flip(frame: NSRect(x: x0, y: 0, width: column, height: 20)), spin = NSProgressIndicator(frame: NSRect(x: 1, y: 2, width: 14, height: 14))
            spin.style = .spinning
            spin.controlSize = .small
            spin.startAnimation(nil)
            let field = truncated(plain(text), width: column - 80), seconds = Text(plain(Self.duration(Date().timeIntervalSince(at)), color: dim), width: 60)
            field.frame.origin = NSPoint(x: 20, y: 1)
            seconds.frame.origin = NSPoint(x: field.frame.maxX + 8, y: 1)
            for view in [spin, field, seconds] { row.addSubview(view) }
            clock = (seconds, at)
            return (item, row, 4)
        case .ask(let name, let head, let ask):
            let card = rounded(NSRect(x: x0, y: 0, width: column, height: 0), fill: dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.55), radius: 12)
            card.layer!.borderColor = NSColor(white: dark ? 1 : 0, alpha: 0.1).cgColor
            card.layer!.borderWidth = 0.5
            var y: CGFloat = 11
            for (text, font, color, lineHeight, gap) in [(head, NSFont.systemFont(ofSize: 13, weight: .semibold), ink, 18 as CGFloat, 0 as CGFloat), (ask.detail, Self.body, dim, 18, 2), (ask.body, NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), ink, 16, 8)] where !text.isEmpty {
                let field = Text(plain(text, font: font, color: color, lineHeight: lineHeight), width: column - 28)
                field.frame.origin = NSPoint(x: 14, y: y + gap)
                card.addSubview(field)
                y = field.frame.maxY
            }
            let answers = name == "AskUserQuestion" && ask.pick ? ask.options.enumerated().map { index, option in Press(option) { [unowned self] in keys("\(index + 1)") } } + [Press("Other") { [unowned self] in terminal() }]
                : name == "AskUserQuestion" || name == "ExitPlanMode" ? [Press("Answer in Terminal") { [unowned self] in terminal() }]
                : [Press("Deny") { [unowned self] in keys("\u{1b}") }, Press("Allow") { [unowned self] in keys("\r") }]
            if answers.count > 1 { numbered = card }
            for (index, button) in answers.enumerated() where answers.count > 1 { button.toolTip = button.title == "Allow" ? "1 or Return" : button.title == "Deny" ? "Esc" : button.title == "Other" ? nil : String(index + 1) }
            var right = column - 12
            for button in answers.reversed() {
                button.bezelStyle = .push
                button.controlSize = .regular
                button.sizeToFit()
                button.frame.size.width = max(button.frame.width, 76)
                button.frame.origin = NSPoint(x: right - button.frame.width, y: y + 10)
                if button.title == "Allow" {
                    button.bezelColor = .controlAccentColor
                    allow = button
                }
                card.addSubview(button)
                right = button.frame.minX - 8
            }
            card.frame.size.height = (answers.first?.frame.maxY ?? y) + 12
            return (item, card, 10)
        case .images(let datas, let pasted):
            let tall: CGFloat = 64, gap: CGFloat = 6, pictures = datas.compactMap { NSImage(data: $0) }
            let row = Flip(frame: NSRect(x: x0, y: 0, width: column, height: tall))
            var x: CGFloat = 0
            func tile(_ frame: NSRect, at index: Int) -> Fold {
                let tile = Fold(frame: frame)
                tile.toggle = { [unowned self] in preview(pictures, at: index) }
                row.addSubview(tile)
                return tile
            }
            for (index, picture) in pictures.enumerated() {
                let size = picture.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? picture.size
                let room = index == 0 && pictures.count > 1 ? column - gap - tall : column
                let width = min(room, (tall * size.width / max(size.height, 1)).rounded())
                if x + width > column {
                    var from = index
                    while from > 1, let last = row.subviews.last, from == index || x + tall > column {
                        last.removeFromSuperview()
                        x = last.frame.minX
                        from -= 1
                    }
                    let more = tile(NSRect(x: x, y: 0, width: tall, height: tall), at: from)
                    more.wantsLayer = true
                    more.layer!.backgroundColor = (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)).cgColor
                    more.layer!.cornerRadius = 8
                    more.layer!.cornerCurve = .continuous
                    let count = Text(plain("+\(pictures.count - from)", font: .systemFont(ofSize: 13, weight: .medium), color: dim), width: tall)
                    count.frame.origin = NSPoint(x: ((tall - count.frame.width) / 2).rounded(), y: ((tall - count.frame.height) / 2).rounded())
                    more.addSubview(count)
                    x += tall + gap
                    break
                }
                let shown = Fill(frame: NSRect(x: 0, y: 0, width: width, height: tall))
                shown.image = picture
                shown.wantsLayer = true
                shown.layer!.cornerRadius = 8
                shown.layer!.cornerCurve = .continuous
                shown.layer!.masksToBounds = true
                shown.layer!.borderWidth = 0.5
                shown.layer!.borderColor = NSColor(white: dark ? 1 : 0, alpha: 0.12).cgColor
                tile(NSRect(x: x, y: 0, width: width, height: tall), at: index).addSubview(shown)
                x += width + gap
            }
            if pasted { row.frame.origin.x = x0 + column - max(x - gap, 0) }
            return (item, row, pasted ? 18 : 8)
        case .notice(let id, let kind, let title, let status, let result, let opened):
            let icon = ["agent": "person.2", "shell": "terminal"][kind] ?? "bubble.left", failed = status == "Failed" || status.hasPrefix("Exit")
            let line = iconText(icon, title + (status.isEmpty ? "" : "   "))
            line.append(plain(status, color: failed ? .systemRed : dim))
            let row = Flip(frame: NSRect(x: x0, y: 0, width: column, height: 20)), head = Fold(frame: NSRect(x: 0, y: 0, width: column, height: 20)), field = truncated(line, width: column - 24)
            head.toggle = { [unowned self] in
                if open.remove(id) == nil { open.insert(id) }
                show()
            }
            field.frame.origin = NSPoint(x: 0, y: 1)
            head.addSubview(field)
            row.addSubview(head)
            guard !result.isEmpty else { return (item, row, 10) }
            let chevron = Mark(frame: NSRect(x: field.frame.maxX + 2, y: 5, width: 10, height: 10))
            chevron.image = NSImage(systemSymbolName: opened ? "chevron.down" : "chevron.right", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [dim])))
            head.addSubview(chevron)
            if opened {
                let body = Text(inline((try? AttributedString(markdown: result, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(result), size: 13), width: column - 20)
                body.frame.origin = NSPoint(x: 20, y: 26)
                body.alphaValue = 0.78
                row.addSubview(rounded(NSRect(x: 7, y: body.frame.minY, width: 1, height: body.frame.height + 2), fill: dim, radius: 0))
                row.addSubview(body)
                row.frame.size.height = body.frame.maxY
            }
            return (item, row, 10)
        }
    }
}

struct Worker: Equatable {
    let task: [String], owner, folder, name, doing: String, ask: String?, working: Bool
}

extension Tab {
    var workers: [Worker] {
        let asking = claude == "waiting" ? action : nil
        let tasks = claude == nil ? [] : reread(statusDir + "/" + name + ".agents") { _ in listed } ?? []
        return tasks.filter { $0[0] == "agent" }.map { task in
            let meta = ClaudeTTY.meta(task) { reread($0, json) }
            let working = meta["finished"] as? Bool != true && (modified(task[3])?.timeIntervalSinceNow ?? -60) > -60
            return Worker(task: task, owner: name, folder: folder, name: meta["agentType"] as? String ?? "agent", doing: meta["description"] as? String ?? "", ask: asking?.worker == task[1] ? asking?.ask : nil, working: working)
        }
    }
}

final class WorkerDiscs: NSView {
    static let limit = 4
    private let workers: [Worker]
    private let open: ((Worker) -> Void)?
    private let more: (NSButton) -> Void

    init(_ workers: [Worker], side: CGFloat = 14, ink: NSColor = .labelColor, open: ((Worker) -> Void)?, more: ((NSButton) -> Void)? = nil) {
        let shown = Array(workers.prefix(Self.limit)), step = side - 4, extra = more == nil ? 0 : workers.count - shown.count
        self.workers = shown
        self.open = open
        self.more = more ?? { _ in }
        super.init(frame: NSRect(x: 0, y: 0, width: side + step * CGFloat(max(shown.count - 1, 0) + (extra > 0 ? 1 : 0)), height: side))
        for (index, worker) in shown.enumerated() {
            let disc = NSButton(frame: NSRect(x: CGFloat(index) * step, y: 0, width: side, height: side))
            disc.isBordered = false
            disc.title = ""
            disc.image = avatar(worker.name, color: ClaudeTTY.hue(worker.name, in: worker.folder), side: side)
            disc.imagePosition = .imageOnly
            disc.imageScaling = .scaleNone
            disc.tag = index
            disc.target = self
            disc.action = #selector(pick)
            disc.toolTip = worker.name + ": " + worker.doing
            disc.setAccessibilityLabel([worker.name, worker.doing, worker.working ? "working" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
            disc.wantsLayer = true
            let shape = CGPath(ellipseIn: disc.bounds, transform: nil), mask = CAShapeLayer()
            mask.path = index < shown.count - 1 || extra > 0 ? shape.subtracting(CGPath(ellipseIn: NSRect(x: step - 1.5, y: -1.5, width: side + 3, height: side + 3), transform: nil)) : shape
            disc.layer?.mask = mask
            if worker.working { Self.sweep(disc, side: side, phase: index) }
            addSubview(disc)
        }
        guard extra > 0 else { return }
        let count = NSButton(frame: NSRect(x: CGFloat(shown.count) * step, y: 0, width: side, height: side))
        count.isBordered = false
        count.attributedTitle = NSAttributedString(string: "+\(extra)", attributes: [.font: NSFont.systemFont(ofSize: extra > 99 ? 6 : extra > 9 ? 7 : 8.5, weight: .semibold), .foregroundColor: ink])
        count.wantsLayer = true
        count.layer?.backgroundColor = ink.withAlphaComponent(0.2).cgColor
        count.layer?.cornerRadius = side / 2
        count.target = self
        count.action = #selector(showMore)
        count.toolTip = "Show agents"
        count.setAccessibilityLabel("\(extra) more agents")
        addSubview(count)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { frame.size }

    @objc private func showMore(_ sender: NSButton) { more(sender) }

    private static func sweep(_ disc: NSView, side: CGFloat, phase: Int) {
        let light = CALayer(), cycle = CAAnimationGroup()
        light.frame = disc.bounds
        light.backgroundColor = NSColor(white: 1, alpha: 0.6).cgColor
        light.zPosition = 1
        disc.layer?.addSublayer(light)
        cycle.duration = 2.6
        cycle.repeatCount = .infinity
        cycle.timeOffset = Double(phase) * 0.7
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0
            pulse.toValue = 0.6
            pulse.duration = 1.3
            pulse.autoreverses = true
            cycle.animations = [pulse]
            light.opacity = 0
            return light.add(cycle, forKey: "sweep")
        }
        let mask = CAGradientLayer(), move = CABasicAnimation(keyPath: "position.x")
        mask.frame = NSRect(x: -side, y: 0, width: side, height: side)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.clear, .black, .clear].map(\.cgColor)
        light.mask = mask
        move.fromValue = -side / 2
        move.toValue = side * 1.5
        move.duration = 1.6
        cycle.animations = [move]
        mask.add(cycle, forKey: "sweep")
    }

    override func resetCursorRects() {
        for view in subviews where open != nil || (view as? NSButton)?.action == #selector(showMore) { addCursorRect(view.frame, cursor: .pointingHand) }
    }

    @objc private func pick(_ sender: NSButton) { open?(workers[sender.tag]) }
}

struct Bars: View {
    struct Bar { let name: String, value: Double }
    let title: String, bars: [Bar], ink: Color, dim: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink) }
            Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
                BarMark(x: .value("Count", bar.value), y: .value("Name", bar.name), height: .fixed(14))
                    .foregroundStyle(Color.accentColor)
                    .cornerRadius(3)
                    .annotation(position: .top, alignment: .leading, spacing: 6) { Text(bar.name).font(.system(size: 12)).foregroundStyle(dim) }
                    .annotation(position: .trailing) { Text(bar.value.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(dim) }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
    }
}

func avatar(_ name: String, color: NSColor, side: CGFloat) -> NSImage {
    var seed = name.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    func next() -> CGFloat {
        seed &+= 0x9E3779B97F4A7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return CGFloat((z ^ (z >> 31)) >> 11) / CGFloat(1 << 53)
    }
    let base = color.usingColorSpace(.deviceRGB) ?? color
    return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        let ctx = NSGraphicsContext.current!.cgContext
        NSBezierPath(ovalIn: rect).addClip()
        base.setFill()
        rect.fill()
        for (shift, bright) in [(CGFloat(0.13), CGFloat(1.1)), (-0.1, 0.5)] {
            let blob = NSColor(hue: (base.hueComponent + shift + 1).truncatingRemainder(dividingBy: 1), saturation: base.saturationComponent, brightness: min(1, base.brightnessComponent * bright), alpha: 1)
            let center = CGPoint(x: rect.minX + next() * side, y: rect.minY + next() * side)
            let gradient = CGGradient(colorsSpace: nil, colors: [blob.cgColor, blob.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: side * (0.45 + next() * 0.3), options: [])
        }
        let cell = side * 0.62 / 5, origin = CGPoint(x: rect.midX - cell * 2.5, y: rect.midY - cell * 2.5)
        NSColor.white.withAlphaComponent(0.95).setFill()
        for row in 0..<5 { for col in 0..<3 where next() < 0.5 {
            for c in Set([col, 4 - col]) { NSRect(x: origin.x + CGFloat(c) * cell, y: origin.y + CGFloat(row) * cell, width: cell, height: cell).fill() }
        } }
        return true
    }
}

final class ProgressRing: NSView {
    private let track = CAShapeLayer(), arc = CAShapeLayer()
    var report: ghostty_action_progress_report_s { didSet { refresh() } }
    var shown: String { "\(report.state.rawValue) \(report.progress)" }

    init(_ report: ghostty_action_progress_report_s) {
        self.report = report
        super.init(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        wantsLayer = true
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 1.5, startAngle: .pi / 2, endAngle: -1.5 * .pi, clockwise: true)
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = path
            shape.fillColor = nil
            shape.lineWidth = 1.5
            layer?.addSublayer(shape)
        }
        arc.lineCap = .round
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { bounds.size }

    private func refresh() {
        let state = report.state, percent = report.progress >= 0 ? Int(report.progress) : state == GHOSTTY_PROGRESS_STATE_PAUSE ? 100 : nil
        let color = state == GHOSTTY_PROGRESS_STATE_ERROR ? NSColor.systemRed : state == GHOSTTY_PROGRESS_STATE_PAUSE ? .systemOrange : .controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arc.strokeColor = color.cgColor
            track.strokeColor = color.withAlphaComponent(0.3).cgColor
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        arc.strokeEnd = CGFloat(percent ?? 25) / 100
        CATransaction.commit()
        let turning = percent == nil, still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if turning != (arc.animation(forKey: "turn") != nil) {
            arc.removeAnimation(forKey: "turn")
            if turning {
                let turn = CABasicAnimation(keyPath: still ? "opacity" : "transform.rotation.z")
                turn.fromValue = still ? 1 : 0
                turn.toValue = still ? 0.4 : -2 * Double.pi
                turn.duration = still ? 1.2 : 1
                turn.autoreverses = still
                turn.timingFunction = CAMediaTimingFunction(name: still ? .easeInEaseOut : .linear)
                turn.repeatCount = .infinity
                arc.add(turn, forKey: "turn")
            }
        }
        setAccessibilityLabel(state == GHOSTTY_PROGRESS_STATE_ERROR ? "Failed" : state == GHOSTTY_PROGRESS_STATE_PAUSE ? "Paused" : "Progress")
        setAccessibilityValue(percent.map { "\($0) percent" })
    }
    override func viewDidChangeEffectiveAppearance() { refresh() }
}

final class Ring: NSView {
    private var radii = RectangleCornerRadii()
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { round() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        round()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: bounds.insetBy(dx: 1, dy: 1)).cgPath)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2)
        context.strokePath()
    }

    private func round() {
        guard let window, let edge = window.contentView?.bounds else { return }
        let frame = convert(bounds, to: nil), bottom = frame.minY < 0.5 && !window.styleMask.contains(.fullScreen)
        let radius: CGFloat = 16
        radii = RectangleCornerRadii(bottomLeading: bottom && frame.minX < 0.5 ? radius : 0, bottomTrailing: bottom && frame.maxX > edge.maxX - 0.5 ? radius : 0)
        needsDisplay = true
    }
}

final class SplitView: NSSplitView {
    override var dividerColor: NSColor { ink(0.12) }
}

final class SidebarEdge: NSView {
    var moved: (_ x: CGFloat, _ start: CGFloat) -> Void = { _, _ in }
    var ended: () -> Void = {}

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        let start = convert(NSPoint(x: bounds.maxX - 1, y: 0), to: nil).x, grab = event.locationInWindow.x - start
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), event.type == .leftMouseDragged { moved(event.locationInWindow.x - grab, start) }
        ended()
    }
}

final class BarIcon: NSImageView {
    override var firstBaselineOffsetFromTop: CGFloat { intrinsicContentSize.height / 2 + (TitleButton.font.ascender + TitleButton.font.descender) / 2 }
}

final class TitleButton: NSButton {
    static let font = NSFont.systemFont(ofSize: 13, weight: .bold)

    static let longest: CGFloat = 240
    private let box = CALayer()
    lazy var nameCap = widthAnchor.constraint(lessThanOrEqualToConstant: Self.longest)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        box.cornerRadius = 5
        layer?.addSublayer(box)
        nameCap.isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        box.frame = CGRect(x: -4, y: -2, width: bounds.width + 8, height: bounds.height + 5)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let cell, cell.cellSize.width > bounds.width + 0.5, let context = NSGraphicsContext.current?.cgContext else { return super.draw(dirtyRect) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        super.draw(dirtyRect)
        context.setBlendMode(.destinationOut)
        NSGradient(starting: .clear, ending: .black)?.draw(in: NSRect(x: bounds.maxX - 24, y: bounds.minY, width: 24, height: bounds.height), angle: 0)
        context.endTransparencyLayer()
    }
    override func mouseEntered(with event: NSEvent) { box.fadeFill(Row.hoverFill) }
    override func mouseExited(with event: NSEvent) { box.fadeFill(nil) }
    override func mouseMoved(with event: NSEvent) { if box.backgroundColor == nil { box.fadeFill(Row.hoverFill) } }

    override func mouseDown(with event: NSEvent) {
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]), next.type == .leftMouseDragged {
            if hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) >= 3 { return window!.performDrag(with: event) }
        }
        performClick(nil)
    }
}

extension CALayer {
    func fadeFill(_ color: NSColor?) {
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = presentation()?.backgroundColor ?? backgroundColor
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        backgroundColor = color?.cgColor
        add(fade, forKey: "fill")
    }
}

final class Blank: NSView {
    private let doubleClick: () -> Void, newFolder: () -> Void, header: () -> String, more: (NSMenu) -> Void
    init(newFolder: @escaping () -> Void, header: @escaping () -> String, more: @escaping (NSMenu) -> Void, doubleClick: @escaping () -> Void) {
        self.doubleClick = doubleClick
        self.newFolder = newFolder
        self.more = more
        self.header = header
        super.init(frame: .zero)
        setAccessibilityLabel("Groups")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { doubleClick() } }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu() }
    override func accessibilityPerformShowMenu() -> Bool { popUp(contextMenu(), at: .zero, in: self) }
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: header()))
        menu.addItem(withTitle: "New Group", action: #selector(newGroup), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "New Folder", action: #selector(makeFolder), keyEquivalent: "").target = self
        more(menu)
        return menu
    }
    @objc private func newGroup() { doubleClick() }
    @objc private func makeFolder() { newFolder() }
}

final class Ping: NSView {
    weak var pill: CountPill?
    override var isHidden: Bool { didSet { pill?.bitten = !isHidden } }
}

final class CountPill: NSTextField {
    var bitten = false { didSet { cut() } }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        cut()
    }
    private func cut() {
        guard bitten else {
            layer?.mask = nil
            return
        }
        let mask = CAShapeLayer(), path = CGMutablePath()
        path.addRect(bounds)
        path.addEllipse(in: NSRect(x: bounds.maxX - 5.5, y: -3.5, width: 9, height: 9))
        mask.path = path
        mask.fillRule = .evenOdd
        layer?.mask = mask
    }
}

final class Caps: Formatter {
    override func string(for value: Any?) -> String? { value as? String }
    override func getObjectValue(_ value: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        value?.pointee = string as NSString
        return true
    }
    override func isPartialStringValid(_ partial: AutoreleasingUnsafeMutablePointer<NSString>, proposedSelectedRange caret: NSRangePointer?, originalString: String, originalSelectedRange: NSRange, errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let upper = partial.pointee.uppercased as NSString
        guard upper != partial.pointee else { return true }
        caret?.pointee.location += upper.length - partial.pointee.length
        partial.pointee = upper
        return false
    }
}

final class LowPin: NSImageView {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: -1, left: 2, bottom: 1, right: 1) }
}

final class Ghost: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class KeyPill: NSView {
    static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let baseline: CGFloat = 2.5
    let key: String
    var edge: CGFloat = 0

    init(_ key: String) {
        self.key = key
        super.init(frame: NSRect(x: 0, y: 0, width: ceil((key as NSString).size(withAttributes: [.font: Self.font]).width) + 4, height: 13))
        clipsToBounds = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.4, dy: 0.4), xRadius: 4, yRadius: 4)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.22)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(srgbRed: 0x3a / 255, green: 0x3a / 255, blue: 0x3c / 255, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.18).setStroke()
        shape.lineWidth = 0.8
        shape.stroke()
        (key as NSString).draw(at: NSPoint(x: 2, y: Self.baseline + Self.font.descender), withAttributes: [.font: Self.font, .foregroundColor: NSColor(white: 1, alpha: 0.95)])
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class InfoRow: NSView {
    static let font = NSFont.menuFont(ofSize: 0)
    let title: String, info: String, inset: CGFloat

    init(_ title: String, info: String, inset: CGFloat) {
        self.title = title
        self.info = info
        self.inset = inset
        let width = { (text: String) in ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) }
        super.init(frame: NSRect(x: 0, y: 0, width: inset + width(title) + 20 + width(info) + 17, height: 24))
        autoresizingMask = .width
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        let lit = enclosingMenuItem?.isHighlighted == true
        if lit {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 7, yRadius: 7).fill()
        }
        let size = (info as NSString).size(withAttributes: [.font: Self.font]), y = ((bounds.height - size.height) / 2).rounded()
        (title as NSString).draw(at: NSPoint(x: inset, y: y), withAttributes: [.font: Self.font, .foregroundColor: lit ? NSColor.selectedMenuItemTextColor : .labelColor])
        (info as NSString).draw(at: NSPoint(x: bounds.width - 17 - size.width, y: y), withAttributes: [.font: Self.font, .foregroundColor: lit ? NSColor.selectedMenuItemTextColor : .tertiaryLabelColor])
    }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
    override func keyDown(with event: NSEvent) { [36, 76, 49].contains(event.keyCode) ? runItem() : super.keyDown(with: event) }
    override func mouseUp(with event: NSEvent) { runItem() }
}

func fade(_ view: NSView, start: Bool, end: Bool, width: CGFloat = 24) {
    guard start || end else {
        view.layer?.mask = nil
        return
    }
    view.wantsLayer = true
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let mask = view.layer?.mask as? CAGradientLayer ?? CAGradientLayer(), edge = Double(min(width / max(view.bounds.width, 1), 0.5))
    mask.frame = view.bounds
    mask.startPoint = CGPoint(x: 0, y: 0.5)
    mask.endPoint = CGPoint(x: 1, y: 0.5)
    mask.colors = [start ? NSColor.clear : .black, .black, .black, end ? .clear : .black].map(\.cgColor)
    mask.locations = [0, edge, 1 - edge, 1].map { NSNumber(value: $0) }
    view.layer?.mask = mask
    CATransaction.commit()
}

final class FadeLabel: NSTextField {
    var head = false
    override var stringValue: String { didSet { needsLayout = true } }
    override var attributedStringValue: NSAttributedString { didSet { needsLayout = true } }
    private var over: CGFloat { attributedStringValue.size().width - (bounds.width - 4) }
    override func layout() {
        super.layout()
        fade(self, start: head && over > 0, end: !head && over > 0)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard head, over > 0 else { return super.draw(dirtyRect) }
        cell?.draw(withFrame: NSRect(x: -over, y: 0, width: bounds.width + over, height: bounds.height), in: self)
    }
}

extension NSView {
    var inkImage: CGImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        let fill = layer?.backgroundColor
        layer?.backgroundColor = nil
        cacheDisplay(in: bounds, to: rep)
        layer?.backgroundColor = fill
        return rep.cgImage
    }

    func roll(from old: CGImage, span: CGFloat, up: Bool, hide: @escaping (Bool) -> Void) {
        guard let host = superview?.layer, let new = inkImage else { return }
        let scale = CGFloat(new.width) / max(bounds.width, 1), still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let holder = CALayer(), rest = CALayer(), clip = CALayer(), leaving = CALayer(), coming = CALayer(), restMask = CALayer()
        holder.frame = frame
        for (layer, image) in [(rest, new), (leaving, old), (coming, new)] {
            layer.contents = image
            layer.contentsScale = scale
            layer.frame = NSRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        }
        restMask.backgroundColor = .black
        restMask.frame = NSRect(x: span, y: 0, width: bounds.width - span, height: bounds.height)
        rest.mask = restMask
        clip.frame = NSRect(x: 0, y: 0, width: span, height: bounds.height)
        clip.masksToBounds = true
        clip.addSublayer(leaving)
        clip.addSublayer(coming)
        holder.addSublayer(rest)
        holder.addSublayer(clip)
        host.addSublayer(holder)
        hide(true)
        let travel = still ? 0 : (up == host.isGeometryFlipped ? 1 : -1) * bounds.height
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1))
        CATransaction.setCompletionBlock {
            holder.removeFromSuperlayer()
            hide(false)
        }
        for (layer, from, to) in [(leaving, CGFloat(0), -travel), (coming, travel, CGFloat(0))] {
            let move = CABasicAnimation(keyPath: "position.y"), fadeIn = CABasicAnimation(keyPath: "opacity")
            layer.actions = ["position": NSNull(), "opacity": NSNull()]
            move.fromValue = layer.position.y + from
            move.toValue = layer.position.y + to
            fadeIn.fromValue = layer === coming ? 0 : 1
            fadeIn.toValue = layer === coming ? 1 : 0
            layer.add(move, forKey: "roll")
            layer.add(fadeIn, forKey: "fade")
            layer.position.y += to
            layer.opacity = layer === coming ? 1 : 0
        }
        CATransaction.commit()
    }

    func runItem() {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
    }
}

struct Job {
    let name: String
    let detail: String
    let since: Date
    var claudes = false
}

class TabStrip: NSStackView {
    weak var stop: NSView?
    let gap: CGFloat = 12
    static let edgeWidth: CGFloat = 22
    static func markInk(_ color: NSColor, _ shade: CGFloat = 0.4) -> NSColor { NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? color.blended(withFraction: shade, of: .black)! : color } }
    static let amberInk = markInk(NSColor(cgColor: Marks.amber)!)
    static let waitingDot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Waiting")?.withSymbolConfiguration(.init(pointSize: 6, weight: .regular).applying(.init(paletteColors: [amberInk])))
    let tabs = NSStackView()
    let scroller = Lane()
    private(set) lazy var ends = [arrow("chevron.left"), arrow("chevron.right")]
    private lazy var fit = scroller.widthAnchor.constraint(equalToConstant: 0)
    private var shownPick: String?
    weak var crumb: BarIcon? { didSet { crumb.map { Self.look($0); mark($0, hidden: !ends[0].isHidden) } } }
    var crumbHidden: Bool { crumb?.isHidden == true }
    private static func look(_ crumb: BarIcon) {
        crumb.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        crumb.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        crumb.contentTintColor = ink(0.4)
    }
    private static let slack: CGFloat = { let crumb = BarIcon(); look(crumb); return ceil(crumb.fittingSize.width) + 6 }()
    private func mark(_ crumb: BarIcon, hidden: Bool) {
        crumb.isHidden = hidden
        setCustomSpacing(tabs.views(in: .leading).count > 1 ? 6 : 2, after: crumb)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setClippingResistancePriority(.defaultLow, for: .horizontal)
        tabs.spacing = 2
        tabs.alignment = .firstBaseline
        tabs.translatesAutoresizingMaskIntoConstraints = false
        scroller.documentView = tabs
        scroller.drawsBackground = false
        scroller.contentView.drawsBackground = false
        scroller.hasHorizontalScroller = false
        scroller.verticalScrollElasticity = .none
        scroller.automaticallyAdjustsContentInsets = false
        scroller.wantsLayer = true
        fit.priority = .init(999)
        NSLayoutConstraint.activate([tabs.leadingAnchor.constraint(equalTo: scroller.contentView.leadingAnchor), tabs.topAnchor.constraint(equalTo: scroller.contentView.topAnchor), scroller.heightAnchor.constraint(equalTo: tabs.heightAnchor), fit])
        scroller.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(edges), name: NSView.boundsDidChangeNotification, object: scroller.contentView)
        for end in ends { end.isHidden = true }
    }
    override func setViews(_ views: [NSView], in gravity: NSStackView.Gravity) {
        guard gravity == .leading else { return super.setViews(views, in: gravity) }
        let rows = views.filter { $0 is Row }
        tabs.setViews(rows, in: .leading)
        super.setViews(views.filter { !($0 is Row) } + (rows.isEmpty ? [] : [ends[0], scroller, ends[1]]), in: .leading)
    }
    func shows(_ row: Row) -> Bool { !ends.contains { past($0).contains(row) } }
    private func list(_ rows: [Row], at view: NSView) {
        let menu = NSMenu()
        for row in rows {
            let item = menu.addItem(withTitle: row.accessibilityLabel() ?? "", action: #selector(pickHidden), keyEquivalent: "")
            item.target = self
            item.representedObject = row
            if Self.waits(row) { item.image = Self.waitingDot }
        }
        popUp(menu, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
    private func arrow(_ symbol: String) -> Arrow {
        let arrow = Arrow(symbol)
        arrow.target = self
        arrow.action = #selector(page)
        arrow.list = { [unowned self, unowned arrow] in list(past(arrow), at: arrow) }
        return arrow
    }
    private func past(_ end: NSView) -> [Row] {
        let seen = scroller.documentVisibleRect
        return tabs.views(in: .leading).compactMap { $0 as? Row }.filter { row in
            let name = row.nameRect.offsetBy(dx: row.frame.minX, dy: 0)
            return end == ends[0] ? row.frame.minX < seen.minX - 0.5 && name.maxX - (seen.minX + Self.edgeWidth) < name.width / 2 : row.frame.maxX > seen.maxX + 0.5 && seen.maxX - Self.edgeWidth - name.minX < name.width / 2
        }
    }
    private static func waits(_ view: NSView) -> Bool { (view as? Spark)?.kind == "waiting" || view.subviews.contains(where: waits) }
    @objc func edges() {
        let sides = ends.map(past), seen = scroller.documentVisibleRect, rows = tabs.views(in: .leading).compactMap { $0 as? Row }
        let cuts = [rows.first { $0.frame.minX < seen.minX - 0.5 && $0.frame.maxX > seen.minX + 0.5 }, rows.first { $0.frame.minX < seen.maxX - 0.5 && $0.frame.maxX > seen.maxX + 0.5 }]
        let room = [seen.minX > 0.5, seen.maxX < tabs.frame.width - 0.5]
        fade(scroller, start: room[0], end: room[1])
        for side in 0..<2 {
            ends[side].isEnabled = room[side]
            ends[side].ink = (sides[side] + [cuts[side]].compactMap { $0 }).contains(where: Self.waits) ? (Self.amberInk, Self.amberInk) : (ink(room[side] ? 0.55 : 0.15), .labelColor)
        }
    }
    private func rest(near aim: CGFloat, where fits: (CGFloat) -> Bool) -> CGFloat? {
        let width = scroller.contentView.bounds.width, most = tabs.frame.width - width, peek: CGFloat = 40
        let spots = Set(tabs.views(in: .leading).flatMap { [$0.frame.minX - peek, $0.frame.maxX - width + peek] }.map { max(0, min($0, most)) }).filter(fits)
        return spots.min { abs($0 - aim) < abs($1 - aim) }
    }
    @objc private func page(_ sender: NSButton) {
        let clip = scroller.contentView, seen = clip.bounds, most = tabs.frame.width - seen.width, sign: CGFloat = sender == ends[0] ? -1 : 1
        let step = max(seen.width / 2, seen.width - 2 * Self.edgeWidth), aim = seen.minX + sign * step
        let x = rest(near: aim) { let moved = sign * ($0 - seen.minX); return moved > 0.5 && moved <= step + 0.5 && (moved >= seen.width / 2 - 0.5 || $0 == 0 || $0 == most) } ?? max(0, min(aim, most))
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, probe == nil else { return clip.scroll(to: NSPoint(x: x, y: seen.minY)) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            clip.animator().setBoundsOrigin(NSPoint(x: x, y: seen.minY))
        }
    }
    private func scroll(_ rows: [Row], cap water: CGFloat, span: CGFloat, names: [CGFloat], fixed: [CGFloat], pick: Int, title: TitleButton?, whole: CGFloat) {
        let over = water < min(40, names.max() ?? 0)
        let ends = over ? self.ends.reduce(0) { $0 + ceil($1.fittingSize.width) + spacing } : 0
        let cap = over ? 40 : water.rounded(.down)
        let titleWidth = max(0, whole - max(0, fixed[pick] + min(40, names[pick]) + ends - span))
        if let title, title.nameCap.constant != titleWidth { title.nameCap.constant = titleWidth }
        for row in rows { row.capName(cap) }
        let width = min(zip(fixed, names).reduce(0) { $0 + $1.0 + min($1.1, cap) } + tabs.spacing * CGFloat(rows.count - 1), span - ends).rounded(.down)
        if fit.constant != width { fit.constant = width }
        for end in self.ends where end.isHidden == over { end.isHidden = !over }
        if let crumb, crumbHidden != over { mark(crumb, hidden: over) }
        super.layout()
        tabs.layoutSubtreeIfNeeded()
        if abs(scroller.frame.width - width) < 0.5, rows[pick].accessibilityLabel() != shownPick {
            shownPick = rows[pick].accessibilityLabel()
            let clip = scroller.contentView, seen = clip.bounds, picked = rows[pick].frame
            let x = picked.minX >= seen.minX - 0.5 && picked.maxX <= seen.maxX + 0.5 ? seen.minX : rest(near: seen.minX) { $0 <= picked.minX + 0.5 && $0 + seen.width >= picked.maxX - 0.5 } ?? picked.minX
            clip.scroll(to: NSPoint(x: x, y: seen.minY))
        }
        edges()
    }
    @objc private func pickHidden(_ item: NSMenuItem) { _ = (item.representedObject as? Row)?.accessibilityPerformPress() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        let rows = tabs.views(in: .leading).compactMap { $0 as? Row }
        guard !rows.isEmpty else { return }
        let title = views(in: .leading).first as? TitleButton
        let whole = title.map { min($0.intrinsicContentSize.width, TitleButton.longest) } ?? 0
        let start = (ends[0].isHidden ? scroller : ends[0]).frame.minX + whole - (title?.frame.width ?? 0)
        let end = views(in: .trailing).first.map { $0.frame.minX - spacing } ?? stop.map { $0.frame.minX - gap - frame.minX } ?? bounds.width - edgeInsets.right
        let pick = rows.firstIndex { $0.isAccessibilitySelected() } ?? 0
        let names = rows.map { ceil($0.nameWidth) }, fixed = rows.map { ceil($0.fittingSize.width - $0.titleWidth) }
        let lead = arrangedSubviews.prefix { $0 !== ends[0] }.last { !$0.isHidden }, after = lead.map { customSpacing(after: $0) }.map { $0 == NSStackView.useDefaultSpacing ? spacing : $0 } ?? 0
        let fits = (lead.map { $0.alignmentRect(forFrame: $0.frame).maxX + after } ?? edgeInsets.left) + whole - (title?.frame.width ?? 0)
        let slack = crumbHidden ? Self.slack : 0
        var left = end - fits - slack - fixed.reduce(0, +) - tabs.spacing * CGFloat(rows.count - 1), count = CGFloat(rows.count), cap = names.max() ?? 0
        for width in names.sorted() {
            if width * count <= left { left -= width; count -= 1 } else { cap = left / count; break }
        }
        scroll(rows, cap: cap, span: end - start, names: names, fixed: fixed, pick: pick, title: title, whole: whole)
    }
}

final class Arrow: NSButton {
    var list: (() -> Void)?
    var ink: (rest: NSColor, hover: NSColor) = (.secondaryLabelColor, .labelColor) { didSet { tint() } }
    private var lit = false { didSet { tint() } }
    private var left: Bool { image?.accessibilityDescription == "Scroll Left" }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: left ? 5 : 0, bottom: 0, right: 0) }
    override var isEnabled: Bool { didSet { tint() } }
    convenience init(_ symbol: String) {
        self.init(frame: .zero)
        title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "chevron.left" ? "Scroll Left" : "Scroll Right")
        isBordered = false
        imagePosition = .imageOnly
        symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        widthAnchor.constraint(equalToConstant: left ? 11 : 16).isActive = true
        setAccessibilityLabel(image?.accessibilityDescription)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override var firstBaselineOffsetFromTop: CGFloat { intrinsicContentSize.height / 2 + (TitleButton.font.ascender + TitleButton.font.descender) / 2 }
    override func mouseEntered(with event: NSEvent) { lit = true }
    override func mouseExited(with event: NSEvent) { lit = false }
    override func mouseMoved(with event: NSEvent) { if !lit { lit = true } }
    private func tint() { contentTintColor = lit && isEnabled ? ink.hover : ink.rest }
    override func rightMouseDown(with event: NSEvent) { list?() }
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { return super.mouseDown(with: event) }
        list?()
    }
}

final class Lane: NSScrollView {
    override var firstBaselineOffsetFromTop: CGFloat { (documentView as? NSStackView)?.arrangedSubviews.first?.firstBaselineOffsetFromTop ?? 0 }
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let clip = contentView, most = (documentView?.frame.width ?? 0) - clip.bounds.width
        clip.scroll(to: NSPoint(x: max(0, min(clip.bounds.minX - delta * (event.hasPreciseScrollingDeltas ? 1 : horizontalLineScroll), most)), y: clip.bounds.minY))
        reflectScrolledClipView(clip)
    }
}

final class PaneBar: TabStrip {
    let hover = BarHover()
    var doubleClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        hover.views = { [unowned self] in views(in: .trailing).filter { !($0 is NSSegmentedControl) } }
        hover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hover)
        NSLayoutConstraint.activate([hover.topAnchor.constraint(equalTo: topAnchor), hover.bottomAnchor.constraint(equalTo: bottomAnchor), hover.leadingAnchor.constraint(equalTo: leadingAnchor), hover.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { doubleClick?() } }
}

final class BarHover: NSView {
    static let hoverKey = "pane buttons on hover " + zmxDir
    static var always: Bool { !UserDefaults.standard.bool(forKey: hoverKey) }
    var views: () -> [NSView] = { [] }
    private(set) var inside = false

    init() {
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { show(true) }
    override func mouseExited(with event: NSEvent) { show(false) }
    override func mouseMoved(with event: NSEvent) { if !inside { show(true) } }

    private func show(_ shown: Bool) {
        inside = shown
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = .init(name: .easeOut)
            for view in views() { view.animator().alphaValue = shown || Self.always ? 1 : 0 }
        }
    }
}

final class LinkButton: NSButton {
    var ink: (rest: NSColor, hover: NSColor) = (.secondaryLabelColor, .labelColor) { didSet { style() } }
    private var lit = false { didSet { style() } }
    var text = "" { didSet { style() } }
    var fill: (rest: NSColor, hover: NSColor)? { didSet { style() } }
    var mark: NSImage? { didSet { style() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { lit = true }
    override func mouseExited(with event: NSEvent) { lit = false }
    override func mouseMoved(with event: NSEvent) { if !lit { lit = true } }
    override func viewDidChangeEffectiveAppearance() { style() }

    private func style() {
        let color = lit ? ink.hover : ink.rest
        var line = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            line = color.withAlphaComponent(lit ? 1 : 0.4)
            layer?.backgroundColor = fill.map { lit ? $0.hover : $0.rest }?.cgColor
        }
        let title = NSMutableAttributedString(string: text, attributes: [.font: font ?? .systemFont(ofSize: 10), .foregroundColor: color, .underlineStyle: fill == nil ? NSUnderlineStyle.single.rawValue : 0, .underlineColor: line])
        if let mark {
            if !text.isEmpty { title.addAttribute(.kern, value: 2.5, range: NSRange(location: title.length - 1, length: 1)) }
            let attachment = NSTextAttachment()
            attachment.image = mark
            attachment.bounds = CGRect(x: 0, y: ((font ?? .systemFont(ofSize: 10)).capHeight - mark.size.height) / 2, width: mark.size.width, height: mark.size.height)
            let piece = NSMutableAttributedString(attachment: attachment)
            piece.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 10), .kern: 3.5 - NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 10)]).size().width]))
            title.insert(piece, at: 0)
        }
        attributedTitle = title
    }
}

final class HoverButton: NSButton {
    private let glow = Ghost()
    private var lit = false {
        didSet {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                glow.animator().alphaValue = lit ? 1 : 0
            }
        }
    }

    init(lit image: NSImage, size: CGFloat) {
        super.init(frame: .zero)
        glow.image = image
        glow.symbolConfiguration = .init(pointSize: size, weight: .regular)
        glow.contentTintColor = .labelColor
        glow.alphaValue = 0
        glow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glow)
        NSLayoutConstraint.activate([glow.centerXAnchor.constraint(equalTo: centerXAnchor), glow.centerYAnchor.constraint(equalTo: centerYAnchor)])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isEnabled: Bool { didSet { contentTintColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor } }
    override func mouseEntered(with event: NSEvent) { lit = isEnabled }
    override func mouseExited(with event: NSEvent) { lit = false }
    override func mouseMoved(with event: NSEvent) { if !lit && isEnabled { lit = true } }
}

final class Scratch: NSView {
    static let name = "claudetty-scratch"
    static let positionKey = "scratch position " + zmxDir
    static var position: String { UserDefaults.standard.string(forKey: positionKey) ?? "Floating" }
    let card = NSView()
    let ground = NSView()
    let folder = NSTextField(labelWithString: "")
    private let clip = NSView(), near = CALayer()
    private(set) var surface: SurfaceView?
    private var shows = 0
    private(set) var open = false
    var dimmed: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true
        card.wantsLayer = true
        for (layer, opacity, blur, y) in [(card.layer!, 0.6, 44.0, 14.0), (near, 0.4, 8, 2)] {
            layer.shadowOpacity = Float(opacity)
            layer.shadowRadius = blur / 2
            layer.shadowOffset = NSSize(width: 0, height: -y)
        }
        card.layer?.insertSublayer(near, at: 0)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 12
        clip.layer?.masksToBounds = true
        clip.layer?.borderWidth = 0.5
        clip.layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        ground.wantsLayer = true
        let title = NSTextField(labelWithString: "Scratch"), key = NSTextField(labelWithString: "⌘J"), line = NSBox()
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        for label in [folder, key] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
        }
        folder.lineBreakMode = .byTruncatingHead
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = .separatorColor
        addSubview(card)
        card.addSubview(clip)
        for view in [ground, title, folder, key, line] { clip.addSubview(view) }
        for view in [title, folder, key, line] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 12),
            folder.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            folder.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -12),
            key.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -12),
            line.topAnchor.constraint(equalTo: clip.topAnchor, constant: 26),
            line.heightAnchor.constraint(equalToConstant: 0.5),
            line.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ] + [title, folder, key].map { $0.centerYAnchor.constraint(equalTo: clip.topAnchor, constant: 13) })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let floating = Self.position == "Floating", width = floating ? min(max(560, bounds.width * 0.6).rounded(), bounds.width - 16) : bounds.width - 16
        let height = min(max(floating ? 300 : 230, bounds.height * (floating ? 0.5 : 0.4)).rounded(), bounds.height - 16)
        let y = ["Drop Down": bounds.height - height, "Bottom": 8][Self.position] ?? min(((bounds.height - height) / 2).rounded() + 4, bounds.height - height - 8)
        card.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: y, width: width, height: height)
        card.layer?.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        near.frame = card.bounds
        near.shadowPath = card.layer?.shadowPath
        clip.frame = card.bounds
        let bottom: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clip.layer?.maskedCorners = Self.position == "Drop Down" ? bottom : bottom.union([.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
        ground.frame = clip.bounds
        surface?.frame = NSRect(x: 0, y: 0, width: width, height: height - 26)
    }

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dimmed() }
    }

    func paint() { NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { ground.layer?.backgroundColor = dark(0x1c1a1a, light: .windowBackgroundColor).cgColor } }

    func start(_ view: SurfaceView, in cwd: String) {
        surface = view
        place(cwd)
        clip.addSubview(view)
        needsLayout = true
    }

    func place(_ cwd: String) { folder.stringValue = (cwd as NSString).abbreviatingWithTildeInPath }

    func end() {
        surface?.removeFromSuperview()
        surface = nil
        isHidden = true
        open = false
    }

    func show(_ shown: Bool) {
        shows += 1
        open = shown
        let show = shows, hidden = isHidden, reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let dim = NSColor(white: 0, alpha: 0.28).cgColor, clear = NSColor(white: 0, alpha: 0).cgColor
        isHidden = false
        layoutSubtreeIfNeeded()
        let moved = switch Self.position {
        case "Drop Down": CATransform3DMakeTranslation(0, bounds.height - card.frame.minY, 0)
        case "Bottom": CATransform3DMakeTranslation(0, -card.frame.maxY, 0)
        default: CATransform3DScale(CATransform3DMakeTranslation(card.bounds.width * 0.015, card.bounds.height * 0.015, 0), 0.97, 0.97, 1)
        }
        let away = reduced ? CATransform3DIdentity : moved
        let faded: Float = reduced || Self.position == "Floating" ? 0 : 1, drawn = (card.layer?.presentation(), layer?.presentation())
        let from: [(CALayer?, String, Any)] = [(layer, "backgroundColor", hidden ? clear : drawn.1?.backgroundColor ?? dim), (card.layer, "opacity", hidden ? faded : drawn.0?.opacity ?? 1),
                                               (card.layer, "transform", hidden ? away : drawn.0?.transform ?? CATransform3DIdentity)]
        surface?.setVisible(shown)
        layer?.backgroundColor = shown ? dim : clear
        card.layer?.opacity = shown ? 1 : faded
        card.layer?.transform = shown ? CATransform3DIdentity : away
        CATransaction.begin()
        CATransaction.setAnimationDuration(shown ? 0.16 : 0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1))
        CATransaction.setCompletionBlock { [weak self] in if let self, show == shows, !shown { isHidden = true } }
        for (target, key, value) in from {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = value
            target?.add(animation, forKey: key)
        }
        CATransaction.commit()
    }
}

final class FindBar: NSView, NSTextFieldDelegate {
    private let act: (String) -> Void
    private let back: () -> Void
    private let stays: Bool
    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let well = NSView()
    private var pending: DispatchWorkItem?
    var total: Int? { didSet { counted() } }
    var selected: Int? { didSet { counted() } }

    static func card(_ card: NSView & NSTextFieldDelegate, well: NSView, field: NSTextField, placeholder: String) {
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.shadowOpacity = 0.4
        card.layer?.shadowRadius = 4
        card.layer?.shadowOffset = NSSize(width: 0, height: -1)
        well.wantsLayer = true
        well.layer?.cornerRadius = 6
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.isScrollable = true
        field.delegate = card
    }

    convenience init(_ surface: SurfaceView) {
        self.init(over: surface, act: { [unowned surface] in surface.binding($0) }, back: { [unowned surface] in surface.window?.makeFirstResponder(surface) })
        surface.find = self
    }

    init(over host: NSView, top: CGFloat = 8, stays: Bool = true, act: @escaping (String) -> Void, back: @escaping () -> Void) {
        (self.act, self.back, self.stays) = (act, back, stays)
        super.init(frame: .zero)
        Self.card(self, well: well, field: field, placeholder: "Find")
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        let buttons = [("chevron.up", "Next", "Next (⌘G)", "navigate_search:next"), ("chevron.down", "Previous", "Previous (⇧⌘G)", "navigate_search:previous"), ("xmark", "Close", "Close (Esc)", "end_search")].map { symbol, label, tip, action in
            let button = ClaudeTTY.iconButton(ClaudeTTY.symbol(symbol), label, tip, self, #selector(press), size: 12, lit: ClaudeTTY.symbol(symbol))
            button.identifier = .init(action)
            return button
        }
        let row = NSStackView(views: [well] + buttons)
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
        for view in [field, count] { well.addSubview(view) }
        addSubview(row)
        for view in [row, well, field, count, self] { view.translatesAutoresizingMaskIntoConstraints = false }
        host.addSubview(self)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 38), well.widthAnchor.constraint(equalToConstant: 230), well.heightAnchor.constraint(equalToConstant: 26),
            field.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 8), field.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            count.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -8), count.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            topAnchor.constraint(equalTo: host.topAnchor, constant: top), trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
        ])
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        well.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
    }

    func open(_ needle: String?) {
        if let needle, !needle.isEmpty {
            field.stringValue = needle
            search()
        }
        window?.makeFirstResponder(field)
    }

    func close() {
        if window?.firstResponder.flatMap({ ($0 as? NSView)?.isDescendant(of: self) }) == true { back() }
        (superview as? SurfaceView)?.find = nil
        removeFromSuperview()
    }

    private func counted() { count.stringValue = total.map { "\(selected.map { String($0 + 1) } ?? "-")/\($0)" } ?? "" }

    private func search() {
        pending?.cancel()
        let needle = field.stringValue
        let send = DispatchWorkItem { [weak self] in self?.act("search:" + needle) }
        pending = send
        DispatchQueue.main.asyncAfter(deadline: .now() + (needle.isEmpty || needle.count >= 3 ? 0 : 0.3), execute: send)
    }

    func controlTextDidChange(_ notification: Notification) { search() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline):
            act(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? "navigate_search:previous" : "navigate_search:next")
        case #selector(NSResponder.cancelOperation):
            guard field.stringValue.isEmpty || !stays else {
                back()
                return true
            }
            act("end_search")
        default:
            return false
        }
        return true
    }

    @objc private func press(_ button: NSButton) { act(button.identifier!.rawValue) }
}

final class GoTo: NSView, NSTextFieldDelegate {
    typealias Entry = (tab: Tab, title: String, place: String, bar: NSColor?, claude: String?)
    typealias Command = (item: NSMenuItem, title: String, place: String)
    private enum Hit { case tab(Entry), command(Command) }
    private let entries: [Entry]
    private let commands: [Command]
    private let pick: (Tab) -> Void
    private let field = NSTextField()
    private let list = NSStackView()
    private weak var back: NSResponder?
    private var shown: [Hit] = []
    private var index = 0

    @discardableResult init(_ entries: [Entry], commands: [Command], in host: NSView, pick: @escaping (Tab) -> Void) {
        self.entries = entries
        self.commands = commands
        self.pick = pick
        super.init(frame: .zero)
        let well = NSView()
        FindBar.card(self, well: well, field: field, placeholder: "Go to tab or command")
        well.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        list.orientation = .vertical
        list.spacing = 2
        let stack = NSStackView(views: [well, list])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        well.addSubview(field)
        addSubview(stack)
        for view in [stack, well, field, list, self] { view.translatesAutoresizingMaskIntoConstraints = false }
        host.addSubview(self)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            well.heightAnchor.constraint(equalToConstant: 26), well.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12), list.widthAnchor.constraint(equalTo: well.widthAnchor),
            field.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 8), field.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -8), field.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            widthAnchor.constraint(equalToConstant: 360), centerXAnchor.constraint(equalTo: host.centerXAnchor), topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
        ])
        back = host.window?.firstResponder
        filter()
        host.window?.makeFirstResponder(field)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }

    private func filter() {
        let needle = field.stringValue.lowercased().filter { !$0.isWhitespace }
        let kind = { (text: String) in
            let text = text.lowercased().filter { !$0.isWhitespace }
            var rest = Substring(text)
            return text.contains(needle) ? 0 : needle.allSatisfy({ letter in rest.firstIndex(of: letter).map { rest = rest[rest.index(after: $0)...] } != nil }) ? 1 : 2
        }
        let kinds = entries.map { (kind("\($0.title) \($0.tab.title) \($0.place)"), Hit.tab($0)) } + commands.map { (kind("\($0.title) \($0.place)") == 0 ? 0 : 2, Hit.command($0)) }
        shown = Array(kinds.filter { $0.0 < 2 }.sorted { $0.0 < $1.0 }.map(\.1).prefix(8))
        index = 0
        draw()
    }

    private func draw() {
        list.setViews(shown.enumerated().map { offset, hit in
            switch hit {
            case .tab(let entry): Row(entry.title, icon: entry.claude == nil ? NSImage(systemSymbolName: "apple.terminal.fill", accessibilityDescription: "Shell") : nil, spark: entry.claude.map { Spark($0, phase: 0, selected: offset == index, key: entry.tab.name, mark: entry.tab.mark) },
                detail: entry.place, bar: entry.bar, selected: offset == index, fill: .controlAccentColor) { [unowned self] in choose(hit) }
            case .command(let command): Row(command.title, icon: command.item.state == .on ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "On") : nil,
                detail: [command.place, ClaudeTTY.keys(command.item)].filter { !$0.isEmpty }.joined(separator: "  "), selected: offset == index, fill: .controlAccentColor) { [unowned self] in choose(hit) }
            }
        }, in: .top)
        for row in list.views { row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        list.isHidden = shown.isEmpty
    }

    private func choose(_ hit: Hit) {
        switch hit {
        case .tab(let entry):
            removeFromSuperview()
            pick(entry.tab)
        case .command(let command):
            window?.makeFirstResponder(back)
            NSApp.sendAction(command.item.action!, to: command.item.target, from: command.item)
        }
    }

    func controlTextDidChange(_ notification: Notification) { filter() }

    func controlTextDidEndEditing(_ notification: Notification) { removeFromSuperview() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown), #selector(NSResponder.moveUp):
            guard !shown.isEmpty else { return true }
            index = (index + (selector == #selector(NSResponder.moveDown) ? 1 : shown.count - 1)) % shown.count
            draw()
        case #selector(NSResponder.insertNewline):
            if index < shown.count { choose(shown[index]) }
        case #selector(NSResponder.cancelOperation):
            window?.makeFirstResponder(back)
        default:
            return false
        }
        return true
    }
}

final class GroupEntry: NSView {
    private let state: String?
    private let place: String
    private let bar: NSColor?
    private static let font = NSFont.menuFont(ofSize: 0)
    private static let small = NSFont.menuFont(ofSize: 11)
    private static let bold = NSFont.boldSystemFont(ofSize: font.pointSize)

    init(_ item: NSMenuItem, state: String?, place: String, bar: NSColor?) {
        self.state = state
        self.place = place
        self.bar = bar
        let line = item.title.size(withAttributes: [.font: Self.bold]).width + ("  " + (state ?? "")).size(withAttributes: [.font: Self.small]).width + 40
        super.init(frame: NSRect(x: 0, y: 0, width: min(380, 32 + max(line, place.size(withAttributes: [.font: Self.small]).width)), height: 38))
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel([item.title, state, place].compactMap { $0 }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let item = enclosingMenuItem else { return }
        let lit = item.isHighlighted, current = item.state == .on
        if lit || current {
            (lit ? NSColor.selectedContentBackgroundColor : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        if let bar {
            bar.setFill()
            NSBezierPath(roundedRect: NSRect(x: 9, y: 6, width: 3, height: bounds.height - 12), xRadius: 1.5, yRadius: 1.5).fill()
        }
        let ink = lit ? NSColor.selectedMenuItemTextColor : .labelColor, dim = lit ? NSColor.selectedMenuItemTextColor : .secondaryLabelColor
        let key = item.keyEquivalent.isEmpty ? "" : "⌘" + item.keyEquivalent
        let keyWidth = key.size(withAttributes: [.font: Self.font]).width
        (key as NSString).draw(at: NSPoint(x: bounds.maxX - 14 - keyWidth, y: 3), withAttributes: [.font: Self.font, .foregroundColor: lit ? ink : .tertiaryLabelColor])
        let tail = NSMutableParagraphStyle()
        tail.lineBreakMode = .byTruncatingTail
        let line = NSMutableAttributedString(string: item.title, attributes: [.font: current ? Self.bold : Self.font, .foregroundColor: ink, .paragraphStyle: tail])
        if let state { line.append(NSAttributedString(string: "  " + state, attributes: [.font: Self.small, .foregroundColor: dim, .paragraphStyle: tail])) }
        line.draw(with: NSRect(x: 20, y: 3, width: bounds.maxX - 34 - keyWidth - 20, height: 17), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let head = NSMutableParagraphStyle()
        head.lineBreakMode = .byTruncatingHead
        (place as NSString).draw(with: NSRect(x: 20, y: 20, width: bounds.maxX - 34, height: 15), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: Self.small, .foregroundColor: dim, .paragraphStyle: head])
    }

    override func mouseUp(with event: NSEvent) { runItem() }
}

final class Row: NSView, NSTextFieldDelegate {
    private static let closeGroupIcon = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close group"), closeTabIcon = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
    static let tabFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static var hoverFill: NSColor { ink(0.09) }
    static var pickFill: NSColor { ink(0.12) }
    private var hoverable = false
    private let raised: CGColor?
    private let action: () -> Void
    private let close: (() -> Void)?
    private weak var activity: ActivityView?
    private var hoverButton: NSButton?
    private var hovered = false
    var contextMenu: (() -> NSMenu)?
    var rename: (() -> Void)?
    var picking: ((Bool) -> Void)?
    var clicked: (() -> Void)?
    var lane: String?
    var dropped: ((Int) -> Void)?
    var carried: ((NSPoint) -> Bool)?
    var aim: ((NSPoint) -> Row?)?
    var block: [Row]?
    static var lifted: Row?
    var ghost: NSImageView?
    private let titleLabel: NSTextField
    private let detail: String?
    private var detailLabel: NSTextField?
    private var problem: ((String) -> String?)?
    private var renamed: ((String?) -> Void)?
    private var typedWidth: NSLayoutConstraint?
    private var folderFit: NSLayoutConstraint?
    private var besideFolder: CGFloat = 0
    private var typedLimit = CGFloat.infinity
    private var sparkRoom: CGFloat = 17
    private weak var titleLine: NSStackView?
    private weak var tabClose: NSButton?
    private var dimmed: [NSView] = []
    var closeSlot: NSRect? {
        guard detail == nil else { return nil }
        let name = nameRect
        return tabClose.map { convert($0.frame, from: $0.superview) } ?? NSRect(x: name.maxX + 5, y: name.minY, width: 10, height: name.height)
    }
    var nameRect: NSRect { convert(titleLabel.frame, from: titleLabel.superview) }
    private lazy var nameCap = titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000)
    var nameWidth: CGFloat { renamed != nil && detail == nil ? typedWidth!.constant : titleLabel.intrinsicContentSize.width }
    var titleWidth: CGFloat { min(nameWidth, nameCap.isActive ? nameCap.constant : 10_000) }
    func capName(_ width: CGFloat) {
        guard nameCap.constant != width else { return }
        nameCap.constant = width
        nameCap.isActive = true
    }
    var nameBaseline: CGFloat {
        titleLabel.convert(NSPoint(x: 0, y: titleLabel.isFlipped ? titleLabel.firstBaselineOffsetFromTop : titleLabel.bounds.height - titleLabel.firstBaselineOffsetFromTop), to: nil).y
    }

    init(_ title: String, icon: NSImage? = nil, spark: NSView? = nil, badge: NSView? = nil, meter: NSTextField? = nil, activity: ActivityView? = nil, detail: String? = nil, pull: [NSView] = [], bar: NSColor? = nil, head: Bool = false, pin: Bool = false, tint: NSColor? = nil, selected: Bool, fill: NSColor, close: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.action = action
        self.close = close
        self.activity = activity
        titleLabel = FadeLabel(labelWithString: title)
        if head { titleLabel.formatter = Caps() }
        self.detail = detail
        raised = selected && detail != nil ? fill.cgColor : nil
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilitySelected(selected)
        wantsLayer = true
        layer?.cornerRadius = detail == nil ? 5 : 8
        layer?.backgroundColor = selected && raised == nil ? fill.cgColor : nil
        clipsToBounds = raised == nil
        titleLabel.font = head ? .systemFont(ofSize: 11, weight: .semibold) : detail == nil ? Self.tabFont : .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = selected && detail != nil ? .white : head || selected || detail != nil ? .labelColor : .secondaryLabelColor
        titleLabel.lineBreakMode = .byClipping
        if detail != nil { titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let name = NSStackView(views: [titleLabel] + [meter].compactMap { $0 })
        name.alignment = .firstBaseline
        name.spacing = 5
        name.setHuggingPriority(.defaultHigh, for: .horizontal)
        let titleLine = NSStackView(views: [name])
        self.titleLine = titleLine
        titleLine.spacing = 5
        if let icon {
            let iconView = NSImageView(image: icon)
            iconView.symbolConfiguration = .init(pointSize: head ? 8 : 11, weight: head ? .bold : .regular)
            iconView.contentTintColor = head || selected && detail == nil ? .labelColor : .secondaryLabelColor
            head ? titleLine.addView(iconView, in: .leading) : titleLine.insertView(iconView, at: 0, in: .leading)
            if head { titleLine.spacing = 4 }
        }
        if pin {
            let upright = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")!.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))!, side = max(upright.size.width, upright.size.height)
            let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let turn = NSAffineTransform()
                turn.translateX(by: rect.midX, yBy: rect.midY)
                turn.rotate(byDegrees: -45)
                turn.concat()
                upright.draw(in: NSRect(x: -upright.size.width / 2, y: -upright.size.height / 2, width: upright.size.width, height: upright.size.height))
                return true
            }
            image.isTemplate = true
            let pinView = LowPin(image: image)
            pinView.contentTintColor = .labelColor
            titleLine.insertView(pinView, at: 0, in: .leading)
        }
        if let spark { titleLine.insertView(spark, at: 0, in: .leading) }
        meter?.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        meter?.textColor = .tertiaryLabelColor
        if head, let meter {
            meter.wantsLayer = true
            meter.layer?.backgroundColor = (tint ?? .quaternaryLabelColor).cgColor
            meter.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            meter.layer?.cornerRadius = 5.5
            meter.stringValue = " \(meter.stringValue) "
            meter.textColor = tint == nil ? .secondaryLabelColor : .white
            name.alignment = .notAnAttribute
            meter.centerYAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor, constant: -titleLabel.font!.capHeight / 2).isActive = true
        }

        if head {
            dimmed = titleLine.views.filter { $0 !== name } + [titleLabel]
            for view in dimmed { view.alphaValue = 0.65 }
        }
        let isGroup = detail != nil
        let closeButton = close.map { _ in NSButton() }
        if let closeButton {
            closeButton.image = isGroup ? Self.closeGroupIcon : Self.closeTabIcon
            closeButton.target = self
            closeButton.action = #selector(closeTab)
            closeButton.title = ""
            closeButton.imagePosition = .imageOnly
            closeButton.isBordered = false
            closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            closeButton.contentTintColor = !selected ? .secondaryLabelColor : isGroup ? NSColor(white: 1, alpha: 0.8) : .labelColor
            closeButton.toolTip = isGroup ? "Close group (⇧⌘W)" : "Close tab (⌘W)"
            if !isGroup {
                titleLine.addView(closeButton, in: .leading)
                tabClose = closeButton
            }
        }
        var labels: [NSView] = [titleLine] + [activity].compactMap { $0 }
        var detailLine: NSView?
        if let detail {
            let detailLabel = FadeLabel(labelWithString: detail)
            detailLabel.head = true
            detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            detailLabel.textColor = selected ? NSColor(white: 1, alpha: 0.8) : .secondaryLabelColor
            detailLabel.lineBreakMode = .byClipping
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = pull.isEmpty ? nil : NSStackView(views: [detailLabel] + pull)
            line?.alignment = .firstBaseline
            line?.spacing = 10
            folderFit = line.map { _ in detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: detailLabel.intrinsicContentSize.width) }
            folderFit?.isActive = true
            besideFolder = 24 + (line.map { $0.fittingSize.width - detailLabel.intrinsicContentSize.width } ?? 0)
            detailLine = line ?? detailLabel
            labels.append(detailLine!)
            self.detailLabel = detailLabel
        }
        let stack = NSStackView(views: labels)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        if let activity, activity.single {
            titleLine.addView(activity.sparks, in: .leading)
            titleLine.setCustomSpacing(4, after: name)
            sparkRoom = 0
        } else if activity != nil {
            stack.setCustomSpacing(3, after: titleLine)
        }
        stack.edgeInsets = detail == nil ? NSEdgeInsets(top: 3, left: head ? 12 : 8, bottom: 3, right: 8) : NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            isGroup ? stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor) : stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        detailLine?.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12).isActive = true
        if let badge, let meter {
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.systemRed.cgColor
            badge.layer?.cornerRadius = 2.7
            badge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(badge)
            NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 5.4), badge.heightAnchor.constraint(equalToConstant: 5.4),
                                         badge.centerXAnchor.constraint(equalTo: meter.trailingAnchor, constant: 1), badge.centerYAnchor.constraint(equalTo: meter.topAnchor, constant: 1)])
        }
        if isGroup, let closeButton {
            closeButton.alphaValue = 0
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            addSubview(closeButton)
            NSLayoutConstraint.activate([
                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                closeButton.centerYAnchor.constraint(equalTo: titleLine.centerYAnchor),
                titleLine.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            ])
            hoverButton = closeButton
        }
        hoverable = !selected && !isGroup && !head
        if isGroup || hoverable || head { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)) }
        guard let bar else { return }
        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = bar.cgColor
        capsule.layer?.cornerRadius = 1.5
        capsule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsule)
        NSLayoutConstraint.activate([
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            capsule.widthAnchor.constraint(equalToConstant: 3),
            capsule.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard let raised else { return }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.45 : 0.18)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        NSColor(cgColor: raised)?.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func layout() {
        folderFit?.constant = bounds.width - besideFolder
        super.layout()
    }

    override func mouseDown(with event: NSEvent) {
        if let picking, !event.modifierFlags.isDisjoint(with: [.command, .shift]) { return picking(event.modifierFlags.contains(.shift)) }
        let point = titleLabel.convert(event.locationInWindow, from: nil)
        let onName = NSRect(origin: .zero, size: NSSize(width: min(titleLabel.bounds.width, titleLabel.cell!.cellSize.width), height: titleLabel.bounds.height)).contains(point)
        guard event.clickCount == 2, onName, let rename else {
            if block != nil {
                if !drag(from: event) { action() }
                return
            }
            let stack = superview as? NSStackView, nth = stack.flatMap { twins(in: $0.arrangedSubviews).firstIndex(of: self) }
            if activity?.openLine(event) != true { action() }
            let successors = stack.map { twins(in: $0.arrangedSubviews) } ?? []
            let next = nth.flatMap { successors.indices.contains($0) ? successors[$0] as? Row : nil }
            if next?.drag(from: event) != true { next?.clicked?() }
            return
        }
        rename()
    }

    private func twins(in rows: [NSView]) -> [NSView] { rows.filter { ($0 as? Row).map { $0.lane == lane && $0.titleLabel.stringValue == titleLabel.stringValue } ?? false } }

    @discardableResult private func drag(from down: NSEvent) -> Bool {
        guard let lane, let stack = superview as? NSStackView, let window, let root = window.contentView else { return false }
        let rows = stack.arrangedSubviews.filter { ($0 as? Row)?.lane == lane }
        guard rows.count > 1 || carried != nil else { return false }
        root.layoutSubtreeIfNeeded()
        let vertical = stack.orientation == .vertical
        let along = { (point: NSPoint) in vertical ? -point.y : point.x }
        let across = { (point: NSPoint) in vertical ? point.x : point.y }
        let mid = { (view: NSView) in view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
        let centre = mid(self)
        let extent = { (row: NSView) -> ClosedRange<Double> in
            let ends = ([row] + ((row as? Row)?.block ?? []).filter { !$0.isHidden }).flatMap { view in [view.bounds.origin, NSPoint(x: view.bounds.maxX, y: view.bounds.maxY)].map { along(view.convert($0, to: nil)) } }
            return ends.min()!...ends.max()!
        }
        let middle = { (row: NSView) in (extent(row).lowerBound + extent(row).upperBound) / 2 }
        var middles = rows.map(middle)
        let from = rows.firstIndex(of: self)!, others = rows.filter { $0 !== self }
        let start = along(down.locationInWindow), slide = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
        let half = (vertical ? bounds.height : bounds.width) / 2
        let band = { (past: Double) in half * past / (past + half * 3) }
        var ends = (extent(rows[0]).lowerBound + half, extent(rows.last!).upperBound - half)
        var origin = along(stack.convert(NSPoint.zero, to: nil))
        let ownBar = sequence(first: stack, next: \.superview).first { $0 is PaneBar }
        var place = from, point = down.locationInWindow, out = false
        var over: Row?
        var tick: Date?
        let image = { [self] in bitmapImageRepForCachingDisplay(in: bounds).map { rep in
            cacheDisplay(in: bounds, to: rep)
            return NSImage(cgImage: rep.cgImage!, size: bounds.size)
        } }
        while true {
            let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: tick ?? .distantFuture, inMode: .eventTracking, dequeue: true)
            point = event?.locationInWindow ?? point
            guard event?.type != .leftMouseUp else { break }
            let drift = along(stack.convert(NSPoint.zero, to: nil)) - origin
            let wanted = middles[from] + along(point) - drift - start
            guard ghost != nil || abs(wanted - middles[from]) > 3 || carried != nil && abs(across(point) - across(down.locationInWindow)) > 3 else { continue }
            if ghost == nil, superview !== stack {
                let successors = twins(in: stack.arrangedSubviews), nth = twins(in: rows).firstIndex(of: self)!
                return (successors.indices.contains(nth) ? successors[nth] as? Row : nil)?.drag(from: down) ?? false
            }
            if let ghost, let drawn = ghost.image, drawn.size != bounds.size {
                let grown = vertical ? bounds.height - drawn.size.height : bounds.width - drawn.size.width
                (middles, ends) = (middles.indices.map { middles[$0] + ($0 > from ? grown : $0 == from ? grown / 2 : 0) }, (ends.0 + grown / 2, ends.1 + grown / 2))
                alphaValue = 1
                ghost.image = image()
                alphaValue = 0
            }
            if ghost == nil, let snapshot = image() {
                ghost = Ghost(image: snapshot)
                ghost!.wantsLayer = true
                ghost!.layer?.backgroundColor = (ClaudeTTY.light ? NSColor.white : .black).cgColor
                ghost!.layer?.cornerRadius = layer!.cornerRadius
                stack.addSubview(ghost!)
                alphaValue = 0
                Row.lifted = self
                if let block, !block.isEmpty {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = slide
                        context.allowsImplicitAnimation = true
                        for row in block { row.isHidden = true }
                        stack.layoutSubtreeIfNeeded()
                    }
                    middles = rows.map(middle)
                    ends = (extent(rows[0]).lowerBound + half, extent(rows.last!).upperBound - half)
                    origin = along(stack.convert(NSPoint.zero, to: nil))
                }
            }
            let under = carried == nil ? nil : root.superview.flatMap { root.hitTest($0.convert(point, from: nil)) }
            let otherBar = under.flatMap { sequence(first: $0, next: \.superview).first { $0 is PaneBar } }.map { $0 !== ownBar } ?? false
            let wide = abs(across(point) - across(centre)) > (vertical ? bounds.width : bounds.height)
            let held = carried == nil || wide ? nil : rows.first { $0 !== self && ($0 as? Row)?.block != nil && extent($0).contains(along(point)) }
            let target = held.map { aim?(mid($0)) } ?? (carried == nil ? nil : aim?(point))
            let passing = target.map { head in rows.contains { $0 === head } } == true
            out = carried != nil && (target != nil && !passing || wide || otherBar)
            if ghost!.superview !== (out ? root : stack) { (out ? root : stack).addSubview(ghost!) }
            if out {
                let at = root.convert(NSPoint(x: centre.x + point.x - down.locationInWindow.x, y: centre.y + point.y - down.locationInWindow.y), from: nil)
                ghost!.frame = NSRect(x: at.x - bounds.width / 2, y: at.y - bounds.height / 2, width: bounds.width, height: bounds.height)
            } else {
                let at = wanted < ends.0 ? ends.0 - band(ends.0 - wanted) : wanted > ends.1 ? ends.1 + band(wanted - ends.1) : wanted
                let now = middles.indices.filter { index in
                    guard index != from else { return false }
                    guard aim != nil, (rows[index] as? Row)?.block != nil else { return middles[index] < at }
                    let span = extent(rows[index])
                    return along(point) > span.upperBound || along(point) >= span.lowerBound && (index < from ? index : index - 1) < place
                }.count
                if now != place {
                    place = now
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = slide
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        context.allowsImplicitAnimation = true
                        let rest = stack.arrangedSubviews.filter { $0 !== self }
                        stack.insertArrangedSubview(self, at: place < others.count ? rest.firstIndex(of: others[place])! : rest.firstIndex(of: ([others.last!] + ((others.last as? Row)?.block ?? [])).last!)! + 1)
                        Row.space(stack)
                        stack.layoutSubtreeIfNeeded()
                    }
                }
                let point = stack.convert(vertical ? NSPoint(x: centre.x, y: -(at + drift)) : NSPoint(x: at + drift, y: centre.y), from: nil)
                ghost!.frame = NSRect(x: point.x - bounds.width / 2, y: point.y - bounds.height / 2, width: bounds.width, height: bounds.height)
            }
            if target !== over {
                over?.layer?.borderWidth = 0
                target?.layer?.borderWidth = 2
                target?.layer?.borderColor = NSColor.controlAccentColor.cgColor
                over = target
            }
            if tick.map({ $0 <= Date() }) ?? true { tick = (out ? under : stack)?.enclosingScrollView.map { Self.autoscroll($0, at: point) } == true ? Date() + 1.0 / 60 : nil }
        }
        over?.layer?.borderWidth = 0
        guard let ghost else { return false }
        if out || over != nil {
            Row.lifted = nil
            if carried?(over.map { head in rows.contains { $0 === head } } == true ? mid(over!) : point) == true {
                ghost.removeFromSuperview()
                return true
            }
            Row.lifted = self
        }
        let settled = { [self] in
            guard self.ghost === ghost else { return }
            ghost.removeFromSuperview()
            self.ghost = nil
            alphaValue = 1
            Row.lifted = nil
            dropped?(place)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = slide
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ghost.animator().frame = ghost.superview!.convert(frame, from: stack)
        }, completionHandler: settled)
        DispatchQueue.main.asyncAfter(deadline: .now() + slide + 0.1, execute: settled)
        return true
    }

    static func space(_ stack: NSStackView) {
        let shown = stack.arrangedSubviews.filter { !$0.isHidden }
        guard shown.contains(where: { ($0 as? Row)?.block != nil }) else { return }
        for (above, below) in zip(shown, shown.dropFirst()) {
            let head = (below as? Row)?.block != nil, own = (above as? Row)?.block?.contains { $0 === below } == true
            stack.setCustomSpacing(head ? 10 : own ? 1 : NSStackView.useDefaultSpacing, after: above)
        }
    }

    private static func autoscroll(_ scroll: NSScrollView, at point: NSPoint) -> Bool {
        let clip = scroll.contentView, sideways = scroll is Lane
        let size = sideways ? clip.bounds.width : clip.bounds.height, origin = sideways ? clip.bounds.minX : clip.bounds.minY
        let local = clip.convert(point, from: nil), at = (sideways ? local.x : local.y) - origin
        let depth = at < 44 ? at - 44 : at > size - 44 ? at - (size - 44) : 0
        guard depth != 0 else { return false }
        let document = scroll.documentView?.frame.size ?? .zero
        let to = min(max(origin + (2 + 10 * min(1, abs(depth) / 44)) * (depth < 0 ? -1 : 1), 0), (sideways ? document.width : document.height) - size)
        guard to != origin else { return false }
        clip.scroll(to: sideways ? NSPoint(x: to, y: clip.bounds.minY) : NSPoint(x: 0, y: to))
        scroll.reflectScrolledClipView(clip)
        return true
    }

    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { close?() } }

    func edit(_ problem: @escaping (String) -> String?, done: @escaping (String?) -> Void) {
        self.problem = problem
        renamed = done
        titleLabel.isEditable = true
        titleLabel.delegate = self
        layoutSubtreeIfNeeded()
        let name = convert(titleLabel.bounds, from: titleLabel)
        let after = titleLine?.views.filter { convert($0.bounds, from: $0).minX >= name.maxX }.map { $0.fittingSize.width + 5 }.reduce(0, +) ?? 0
        typedLimit = (hoverButton.map { $0.frame.minX - 4 } ?? bounds.maxX - 8) - after - sparkRoom - name.minX
        typedWidth = titleLabel.widthAnchor.constraint(equalToConstant: 0)
        typedWidth?.priority = .required - 1
        typedWidth?.isActive = true
        fitTyped()
        window?.makeFirstResponder(titleLabel)
    }

    func controlTextDidChange(_ obj: Notification) {
        detailLabel?.stringValue = problem?(titleLabel.stringValue) ?? detail ?? ""
        fitTyped()
    }

    private func fitTyped() {
        let width = ceil((titleLabel.stringValue as NSString).size(withAttributes: [.font: titleLabel.font!]).width) + 6
        typedWidth?.constant = detail == nil ? width : min(width, typedLimit)
        superview?.needsLayout = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(cancelOperation): finish(nil)
        case #selector(insertNewline): problem?(titleLabel.stringValue) == nil ? finish(titleLabel.stringValue) : NSSound.beep()
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finish(problem?(titleLabel.stringValue) == nil ? titleLabel.stringValue : nil)
    }

    func finish(_ name: String?) {
        guard let renamed else { return }
        self.renamed = nil
        titleLabel.isEditable = false
        renamed(name)
    }
    @objc func _opaqueRectForWindowMoveWhenInTitlebar() -> NSRect { bounds }
    override var firstBaselineOffsetFromTop: CGFloat { 3 + Self.tabFont.ascender }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = contextMenu?() else { return false }
        return popUp(menu, at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }
    override func mouseEntered(with event: NSEvent) { fadeClose(true) }
    override func mouseExited(with event: NSEvent) { fadeClose(false) }

    override func mouseMoved(with event: NSEvent) { if !hovered { fadeClose(true) } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === hoverButton && !hovered ? self : hit
    }

    private func fadeClose(_ shown: Bool) {
        hovered = shown
        if hoverable { layer?.fadeFill(shown ? Self.hoverFill : nil) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            hoverButton?.animator().alphaValue = shown ? 1 : 0
            for view in dimmed { view.animator().alphaValue = shown ? 1 : 0.65 }
        }
    }

    @objc private func closeTab() { close?() }

}

struct Activity: Equatable {
    struct Cell: Equatable { let name, title, state: String, mark: String?, cold: Bool }
    var sparks: [Cell]
    var name: String
    var who, what: String
    var ask: Bool
    var ago: String
    var agents: String?
    var workers: [Worker]
    var thinking = false
}

func ink(_ alpha: CGFloat) -> NSColor { NSColor(white: ClaudeTTY.light ? 0 : 1, alpha: alpha) }

func dark(_ hex: Int, light: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1) : light }
}

final class ActivityView: NSStackView {
    let sparks = NSStackView()
    let single: Bool
    private let count = LinkButton(title: "", target: nil, action: #selector(showAgents))
    private let line = FadeLabel(labelWithString: "")
    private let glint = NSTextField(labelWithString: "")
    private var glintStart: CGFloat?
    private let ago = NSTextField(labelWithString: "")
    private let selected: Bool
    private let width: CGFloat
    private let open: (String) -> Void
    private let agentsMenu: () -> NSMenu
    var openWorker: (Worker) -> Void = { _ in }
    private var shown: Activity?
    private var turn = 0
    var moving: Bool { sparks.views.contains { ($0 as? Spark)?.moving == true } }

    init(selected: Bool, single: Bool, width: CGFloat, open: @escaping (String) -> Void, agentsMenu: @escaping () -> NSMenu) {
        self.selected = selected
        self.single = single
        self.width = width
        self.open = open
        self.agentsMenu = agentsMenu
        super.init(frame: .zero)
        count.target = self
        count.isBordered = false
        count.font = .systemFont(ofSize: 10)
        count.ink = selected ? (NSColor(white: 1, alpha: 0.8), .white) : (.secondaryLabelColor, .labelColor)
        count.toolTip = "Show agents"
        sparks.spacing = 6
        sparks.heightAnchor.constraint(equalToConstant: 14).isActive = true
        line.font = .systemFont(ofSize: 11)
        glint.frame = line.bounds
        glint.autoresizingMask = [.width, .height]
        glint.wantsLayer = true
        line.addSubview(glint)
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ago.font = .systemFont(ofSize: 9.5)
        ago.textColor = selected ? NSColor(white: 1, alpha: 0.6) : dark(0x6e6e73, light: .secondaryLabelColor)
        let lineRow = NSStackView(views: [line, ago])
        lineRow.spacing = 4
        lineRow.alignment = .firstBaseline
        lineRow.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        orientation = .vertical
        alignment = .leading
        spacing = 2
        setViews(single ? [lineRow] : [sparks, lineRow], in: .top)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func cold(_ name: String) -> Bool { shown?.sparks.first { $0.name == name }?.cold ?? false }

    func openLine(_ event: NSEvent) -> Bool {
        guard let row = line.superview, !row.isHidden, let name = shown?.name, row.bounds.contains(row.convert(event.locationInWindow, from: nil)) else { return false }
        open(name)
        return true
    }

    func show(_ activity: Activity) {
        guard activity != shown else { return }
        if activity.sparks.map(\.name) != shown?.sparks.map(\.name) || activity.workers != shown?.workers || activity.agents != shown?.agents {
            let before = activity.agents != nil && shown?.agents != nil && activity.agents != shown?.agents ? count.inkImage : nil
            count.text = activity.agents ?? ""
            let discs = activity.workers.isEmpty ? [] : [WorkerDiscs(activity.workers, ink: selected ? .white : .labelColor, open: { [unowned self] in openWorker($0) }, more: { [unowned self] in showAgents($0) })]
            let tail: [NSView] = activity.agents == nil ? discs : [count]
            let room = Int((width - (tail.first.map { $0.fittingSize.width + 6 } ?? 0) + 6) / 19)
            let fit = activity.sparks.count <= room ? activity.sparks[...] : activity.sparks.prefix(room - 1)
            let cells = fit.enumerated().map { index, cell in
                let spark = Spark(cell.state, phase: [0, 2, 3][index % 3], selected: selected, key: cell.name)
                spark.target = self
                spark.action = #selector(openTab)
                spark.identifier = .init(cell.name)
                return spark
            }
            let more = fit.count < activity.sparks.count ? [Spark("more", phase: 0, selected: selected, glyph: "+\(activity.sparks.count - fit.count)")] : []
            more.first?.setAccessibilityLabel("\(activity.sparks.count - fit.count) more")
            sparks.setViews(cells + more + tail, in: .leading)
            if let before, let agents = activity.agents, let number = Int(agents.prefix { $0.isNumber }), let old = shown?.agents.flatMap({ Int($0.prefix { $0.isNumber }) }) {
                sparks.layoutSubtreeIfNeeded()
                let digits = NSAttributedString(string: String(number), attributes: [.font: count.font ?? .systemFont(ofSize: 10)]).size().width
                count.roll(from: before, span: (count.bounds.width - count.attributedTitle.size().width) / 2 + digits + 1, up: number > old) { [count] in count.alphaValue = $0 ? 0 : 1 }
            }
        }
        for case (let spark as Spark, let cell) in zip(sparks.views, activity.sparks) where spark.action != nil {
            spark.kind = cell.state
            spark.mark = cell.mark
            spark.cold = cell.cold
            spark.toolTip = cell.title
            spark.setAccessibilityLabel([cell.title, cell.state].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        shown = activity
        line.superview?.isHidden = activity.who.isEmpty
        ago.stringValue = activity.ago
        ago.isHidden = activity.ago.isEmpty
        isHidden = single && activity.who.isEmpty
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = .byClipping
        let text = NSMutableAttributedString(string: activity.who + ": ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: selected ? .white : dark(0xe8e8ea, light: .labelColor), .paragraphStyle: oneLine])
        let whatAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: selected ? activity.ask ? .white : dark(0xe6eeff, light: .white) : activity.ask ? Spark.orange : dark(0x98989d, light: .secondaryLabelColor), .paragraphStyle: oneLine]
        let full = text.size().width
        text.append(NSAttributedString(string: activity.what, attributes: whatAttributes))
        line.attributedStringValue = text
        shimmer(text, word: activity.thinking && !selected ? NSRange(location: text.length - activity.what.utf16.count, length: activity.what.utf16.count) : nil, from: full)
    }

    private func shimmer(_ text: NSAttributedString, word: NSRange?, from start: CGFloat) {
        glint.isHidden = word == nil
        guard let word, let layer = glint.layer else { return glintStart = nil }
        let lit = NSMutableAttributedString(attributedString: text)
        lit.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: 0, length: word.location))
        lit.addAttribute(.foregroundColor, value: dark(0xffffff, light: .labelColor), range: word)
        glint.attributedStringValue = lit
        guard glintStart != start else { return }
        glintStart = start
        let band: CGFloat = 40, cycle = CAAnimationGroup()
        cycle.duration = 2.6
        cycle.repeatCount = .infinity
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer.mask = nil
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0
            pulse.toValue = 0.6
            pulse.duration = 1.3
            pulse.autoreverses = true
            cycle.animations = [pulse]
            layer.opacity = 0
            return layer.add(cycle, forKey: "glint")
        }
        let mask = CAGradientLayer()
        mask.frame = NSRect(x: -band, y: 0, width: band, height: 40)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.clear, .black, .clear].map(\.cgColor)
        layer.mask = mask
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = start - band / 2
        sweep.toValue = width + band / 2
        sweep.duration = 1.6
        cycle.animations = [sweep]
        mask.add(cycle, forKey: "glint")
    }

    func spin() {
        turn += 1
        for case let spark as Spark in sparks.views { spark.spin(turn) }
    }

    @objc private func openTab(_ sender: Spark) { sender.identifier.map { open($0.rawValue) } }
    @objc private func showAgents(_ sender: NSButton) { popUp(agentsMenu(), at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender) }
}

final class Spark: NSButton {
    static let orange = NSColor(srgbRed: 215 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
    static let frames = ["✢", "✳", "✶", "✻", "✽", "✽", "✻", "✶", "✳", "✢"]
    static let morph = NSImage(contentsOfFile: deps + "/spark.webp")?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    static var settings = ["spinner": "dots", "clawd wait": "C", "sleep z": "on"].reduce(into: [String: String]()) { $0[$1.key] = UserDefaults.standard.string(forKey: $1.key + " " + zmxDir) ?? $1.value }
    static var style: String { settings["spinner"]! }
    private var style: String { setting("spinner") }
    private func setting(_ key: String) -> String { picks[key] ?? Self.settings[key]! }
    private let picks: [String: String]
    var kind: String {
        didSet {
            guard kind != oldValue else { return }
            glyph = moving ? Self.frames[phase] : "✻"
            refresh()
            if kind == "waiting" || oldValue == "waiting" { (sequence(first: self, next: \.superview).first { $0 is TabStrip } as? TabStrip)?.edges() }
        }
    }
    var mark: String? {
        didSet {
            if mark == nil, dots == nil { Marks.forget(key) }
            if mark != oldValue { refresh() }
        }
    }
    var cold = false {
        didSet { if cold != oldValue { refresh() } }
    }
    private var dots: Marks?
    private var figure: CALayer?
    private var playing: String?
    private var acting = false
    private var hold: Timer?
    private var onScreen: (act: String, ends: CFTimeInterval)?
    private var queued: String?
    private static var changed: [String: (from: String?, to: String, at: CFTimeInterval)] = [:]
    private static var acted: [String: (act: String, at: CFTimeInterval)] = [:]
    var shown: String { (dots != nil ? mark ?? "" : style == "clawd" ? mark ?? glyph : glyph) + (cold ? " cold" : "") }
    var drawn: String { dots?.target ?? (acting ? onScreen?.act : nil) ?? "" }
    var loopAt: String {
        guard let loop = figure?.animation(forKey: "loop") ?? figure?.sublayers?.lazy.compactMap({ $0.animation(forKey: "rest") }).first else { return "" }
        let period = loop.duration * (loop.autoreverses ? 2 : 1)
        return String(format: "\t%.3f\t%.3f", (loop.beginTime - loop.timeOffset).truncatingRemainder(dividingBy: period), period)
    }
    var moving: Bool { kind == "working" || kind == "background" }
    private let phase: Int
    private let selected: Bool
    private let key: String
    private(set) var glyph: String

    init(_ kind: String, phase: Int, selected: Bool, key: String = "", mark: String? = nil, glyph: String? = nil, picks: [String: String] = [:]) {
        self.picks = picks
        self.kind = kind
        self.mark = mark
        self.key = key
        self.phase = phase
        self.selected = selected
        self.glyph = glyph ?? (["working", "background"].contains(kind) ? Self.frames[phase] : "✻")
        super.init(frame: .zero)
        title = ""
        isBordered = false
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func refresh() {
        needsDisplay = true
        guard let mark, style == "dots" || style == "sparkle" && Self.morph == nil else {
            guard let dots, mark == nil, window != nil else {
                if dots != nil { layer?.sublayers = nil }
                dots = nil
                morphing()
                return mascot(grow: false)
            }
            return dots.settle { [weak self] in
                guard let self, self.mark == nil, self.dots === dots else { return }
                self.fade()
                self.layer?.sublayers = nil
                self.dots = nil
                self.needsDisplay = true
                self.mascot(grow: true)
            }
        }
        if dots == nil {
            let dots = Marks(selected: selected, phase: phase, key: key)
            wantsLayer = true
            if window != nil { fade() }
            dots.layer.frame = NSRect(origin: .zero, size: intrinsicContentSize)
            layer?.sublayers = [dots.layer]
            self.dots = dots
        }
        dots?.show(mark)
    }

    private func mascot(grow: Bool) {
        let act = style == "clawd" ? mark.map { $0 == "background" ? "background " + setting("clawd wait") : $0 } : nil
        guard dots == nil, act != nil || ["", "idle", "asleep"].contains(kind) else {
            Self.changed[key] = nil
            hold?.invalidate()
            queued = nil
            acting = false
            figure?.removeFromSuperlayer()
            figure = nil
            playing = nil
            return
        }
        let ink = selected ? "selected" : effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        let rest = act == nil && style == "dots", frost = Clawd.frost(ink)
        let cold = self.cold && !selected
        let next = (act ?? (rest ? "dots " + kind : kind)) + (cold ? " cold " : " ") + ink
        if figure?.superlayer == nil {
            let figure = CALayer()
            figure.contentsScale = 2
            figure.magnificationFilter = .nearest
            figure.actions = ["contents": NSNull()]
            wantsLayer = true
            layer?.addSublayer(figure)
            self.figure = figure
            playing = nil
        }
        guard grow || playing != next, let figure else { return }
        if act == "think", queued != nil {
            playing = next
            return
        }
        hold?.invalidate()
        queued = nil
        if playing != nil, !acting, act != nil || rest { fade() }
        playing = next
        needsDisplay = true
        defer { acting = act != nil }
        if let act {
            Self.changed[key] = nil
            figure.frame = CGRect(x: -1.5, y: 1, width: 16, height: 17)
            func start() {
                if Self.acted[key]?.act != act { Self.acted[key] = (act, CACurrentMediaTime()) }
                onScreen = (act, CACurrentMediaTime() + Clawd.act(figure, act, ink: ink, since: Self.acted[key]!.at))
            }
            let wait = (onScreen?.ends ?? 0) - CACurrentMediaTime()
            guard acting, onScreen?.act != "think", wait > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                if acting { fade() }
                start()
                return
            }
            queued = act
            hold = .scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                guard let self else { return }
                queued = nil
                fade()
                start()
                if playing != next {
                    playing = nil
                    mascot(grow: false)
                }
            }
            return
        }
        Self.acted[key] = nil
        if rest {
            figure.frame = NSRect(origin: .zero, size: intrinsicContentSize)
            let gray: [CGFloat] = ink == "dark" ? [138, 144] : [72, 76]
            let color = cold ? CGColor(srgbRed: frost[0] / 255, green: frost[1] / 255, blue: frost[2] / 255, alpha: 1) : ink == "selected" ? .white : CGColor(srgbRed: gray[0] / 255, green: gray[0] / 255, blue: gray[1] / 255, alpha: 1)
            Marks.rest(figure, asleep: kind == "asleep", color: color, fade: ["dark": 0.75, "light": 1][ink] ?? 0.85, phase: phase)
        } else {
            figure.frame = CGRect(x: -1.5, y: 1, width: 16, height: 17)
            figure.sublayers = nil
            if Self.changed[key]?.to != kind { Self.changed[key] = (Self.changed[key]?.to, kind, CACurrentMediaTime()) }
            let change = Self.changed[key]!
            Clawd.play(figure, from: change.from, to: kind, since: change.at, grow: grow, seed: Double(phase) * 1.7, frost: selected ? [255, 255, 255] : cold ? frost : [])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard playing?.hasSuffix(" selected") == false else { return }
        playing = nil
        mascot(grow: false)
    }

    private func fade() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        layer?.add(fade, forKey: nil)
    }

    private func morphing() {
        guard let morph = Self.morph, style == "sparkle" else { return }
        guard moving else {
            layer?.sublayers = nil
            return
        }
        wantsLayer = true
        let mask = CALayer(), ink = CALayer()
        mask.contents = morph
        let frame = { (index: Int) in CGRect(x: 0, y: CGFloat(83 - index) / 84, width: 1, height: 1 / 84) }
        mask.contentsRect = frame(4)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let play = CAKeyframeAnimation(keyPath: "contentsRect")
            play.values = (0..<63).map { NSValue(rect: frame($0)) }
            play.calculationMode = .discrete
            play.duration = 63 * 0.06
            play.repeatCount = .infinity
            play.timeOffset = Double(phase) * 0.42
            mask.add(play, forKey: nil)
        }
        ink.backgroundColor = selected ? .white : Marks.ink(kind == "background" ? "background" : nil)
        ink.frame = bounds.isEmpty ? NSRect(origin: .zero, size: intrinsicContentSize) : bounds
        mask.frame = ink.bounds
        ink.mask = mask
        layer?.sublayers = [ink]
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 13, height: 13) }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { action == nil ? nil : super.hitTest(point) }

    override func mouseDown(with event: NSEvent) {
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { sendAction(action, to: target) }
                return
            }
            guard hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) > 3 else { continue }
            return sequence(first: self as NSView, next: \.superview).first { $0 is Row }?.mouseDown(with: event) ?? ()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let (fill, ink, size): (NSColor?, NSColor, CGFloat) = switch kind {
        case "working": (nil, selected ? .white : Self.orange, 12)
        case "waiting": (selected ? .white : Self.orange, selected ? .controlAccentColor : .white, 10)
        case "more": (selected ? NSColor(white: 1, alpha: 0.3) : dark(0x4a4a4f, light: .tertiaryLabelColor), selected ? .white : dark(0xe6e6ea, light: .white), 7.5)
        default: (nil, selected ? dark(0xc8d9fc, light: .white) : dark(0x8a8a90, light: .tertiaryLabelColor), 12)
        }
        guard dots == nil, figure == nil else { return }
        if let symbol = Self.stopSymbol(kind, tint: selected ? .white : kind == "error" ? Self.orange : dark(0x8a8a90, light: NSColor(srgbRed: 72 / 255, green: 72 / 255, blue: 76 / 255, alpha: 1))) {
            return symbol.draw(in: NSRect(x: bounds.midX - symbol.size.width / 2, y: bounds.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
        }
        if let fill {
            fill.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        guard !moving || Self.morph == nil || style != "sparkle" else { return }
        let text = NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: size, weight: kind == "more" ? .semibold : .regular), .foregroundColor: ink])
        let box = text.boundingRect(with: bounds.size, options: .usesDeviceMetrics)
        text.draw(with: NSRect(x: bounds.midX - box.midX, y: bounds.midY - box.midY, width: bounds.width, height: bounds.height))
    }

    static func stopSymbol(_ kind: String, tint: NSColor) -> NSImage? {
        if kind == "limited" {
            let image = NSImage(size: NSSize(width: 10, height: 13), flipped: false) { _ in
                let (w, h, x, y, cap) = (5.7, 9.3, 2.15, 1.85, 1.3)
                let (left, right, mid) = (x + w / 2 - 0.4, x + w / 2 + 0.4, y + h / 2)
                let glass = NSBezierPath()
                glass.move(to: NSPoint(x: x, y: y))
                glass.line(to: NSPoint(x: x + w, y: y))
                glass.line(to: NSPoint(x: x + w, y: y + cap))
                glass.curve(to: NSPoint(x: right, y: mid), controlPoint1: NSPoint(x: x + w - 0.6, y: y + h * 0.3), controlPoint2: NSPoint(x: right, y: y + h * 0.4))
                glass.curve(to: NSPoint(x: x + w, y: y + h - cap), controlPoint1: NSPoint(x: right, y: y + h * 0.6), controlPoint2: NSPoint(x: x + w - 0.6, y: y + h * 0.7))
                glass.line(to: NSPoint(x: x + w, y: y + h))
                glass.line(to: NSPoint(x: x, y: y + h))
                glass.line(to: NSPoint(x: x, y: y + h - cap))
                glass.curve(to: NSPoint(x: left, y: mid), controlPoint1: NSPoint(x: x + 0.6, y: y + h * 0.7), controlPoint2: NSPoint(x: left, y: y + h * 0.6))
                glass.curve(to: NSPoint(x: x, y: y + cap), controlPoint1: NSPoint(x: left, y: y + h * 0.4), controlPoint2: NSPoint(x: x + 0.6, y: y + h * 0.3))
                glass.close()
                glass.lineJoinStyle = .round
                glass.lineWidth = 0.8
                tint.set()
                glass.fill()
                glass.stroke()
                return true
            }
            image.accessibilityDescription = "Usage limit"
            return image
        }
        return kind == "error" ? NSImage(systemSymbolName: "exclamationmark", accessibilityDescription: "API error")?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [tint]))) : nil
    }

    func spin(_ turn: Int) {
        guard moving, dots == nil else { return }
        glyph = Self.frames[(turn + phase) % Self.frames.count]
        needsDisplay = true
    }
}

@discardableResult func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView) -> Bool {
    guard let probe, !FileManager.default.fileExists(atPath: probe + "/real") else {
        if probe != nil { RunLoop.main.add(Timer(timeInterval: 3, repeats: false) { _ in menu.cancelTracking() }, forMode: .common) }
        return menu.popUp(positioning: nil, at: point, in: view)
    }
    let anchor = view.convert(point, to: nil)
    menu.update()
    let lines = ["at \(Int(anchor.x)) \(Int(anchor.y))"] + menu.items.filter { !$0.isHidden }.map { item in
        if item.isSeparatorItem { return "-" }
        if let view = item.view as? NSStackView { return view.arrangedSubviews.map { "button " + ($0.accessibilityLabel() ?? "") + (($0 as? NSButton)?.state == .on ? " ✓" : "") + (($0 as? NSControl)?.isEnabled == false ? " (off)" : "") }.joined(separator: "\n") }
        return item.title + (item.image?.accessibilityDescription.map { " (\($0))" } ?? "") + (item.keyEquivalent.isEmpty ? "" : " ⌘" + item.keyEquivalent) + (item.state == .on ? " ✓" : "") + (item.isEnabled ? "" : " (off)") + (item.subtitle.map { " [\($0)]" } ?? "") + ((item.view as? InfoRow).map { " {\($0.info)}" } ?? "") + (item.submenu.map { " ▸ " + $0.items.map(\.title).joined(separator: ", ") } ?? "")
    }
    try? lines.joined(separator: "\n").write(toFile: probe + "/menu", atomically: true, encoding: .utf8)
    try? String(Int(menu.size.width)).write(toFile: probe + "/menuwidth", atomically: true, encoding: .utf8)
    let views = menu.items.compactMap { item in item.view is GroupEntry ? item.view : item.attributedTitle.map { text in
        let field = NSTextField(labelWithAttributedString: text)
        field.frame = NSRect(x: 20, y: 0, width: text.size().width + 20, height: 22)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: field.frame.maxX, height: 22)), icon = NSImageView(image: item.image ?? NSImage())
        icon.frame = NSRect(x: 4, y: 4, width: 14, height: 14)
        row.subviews = [field, icon]
        return row
    } }
    let size = NSSize(width: views.map(\.frame.width).max() ?? 0, height: views.map(\.frame.height).reduce(10, +))
    if !views.isEmpty, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.17, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        var top = size.height - 5
        for view in views {
            top -= view.frame.height
            view.appearance = NSAppearance(named: .darkAqua)
            NSGraphicsContext.saveGraphicsState()
            NSAffineTransform(transform: AffineTransform(translationByX: 0, byY: top)).concat()
            view.displayIgnoringOpacity(view.bounds, in: NSGraphicsContext.current!)
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: probe + "/menu.png"))
    }
    guard let pick = try? String(contentsOfFile: probe + "/pick", encoding: .utf8).trimmingCharacters(in: .newlines) else { return true }
    try? FileManager.default.removeItem(atPath: probe + "/pick")
    let path = pick.components(separatedBy: "\t"), picked = path.dropLast().reduce(Optional(menu)) { menu, title in menu?.items.first { $0.title == title }?.submenu }
    if let picked, let index = picked.items.firstIndex(where: { $0.title == path.last && $0.isEnabled }) { picked.performActionForItem(at: index) }
    (menu.items.compactMap(\.view).flatMap(\.subviews).first { $0.accessibilityLabel() == pick } as? NSButton)?.performClick(nil)
    return true
}


extension ClaudeTTY {
    @objc private func setUp() { openGuide(byItself: false) }

    private func openGuide(byItself: Bool) {
        if guide == nil {
            if !hidden { _ = windowShouldClose(window) }
            let kept = [Self.themeKey, Self.soundKey, Self.askKey, Self.wakeKey, Self.lookKey] + Spark.settings.keys.map { $0 + " " + zmxDir }
            let found = kept.map { ($0, UserDefaults.standard.object(forKey: $0)) }, sparks = Spark.settings
            let theme = UserDefaults.standard.string(forKey: Self.themeKey), themes = ["Light", "Dark", "System"]
            let icons = Guide.column([], spacing: 8)
            guideIcons(icons)
            let preview = GroundShot(), blur = steps(Self.blurs, "background-blur", tag: 1)
            blur.isEnabled = Self.look["background-opacity"] != "1"
            let background = Guide.column([preview, Guide.line("Transparency", steps(Self.transparencies, "background-opacity", tag: 0)), Guide.line("Blur", blur)], spacing: 10)
            let bypass = NSSwitch()
            bypass.controlSize = .small
            bypass.state = UserDefaults.standard.bool(forKey: Self.askKey) ? .off : .on
            bypass.target = self
            bypass.action = #selector(toggleBypass)
            let sound = NSPopUpButton()
            sound.controlSize = .small
            sound.font = .systemFont(ofSize: 13)
            sound.menu!.addItem(withTitle: "None", action: nil, keyEquivalent: "").representedObject = ""
            Self.sounds(sound.menu!, action: nil)
            sound.menu!.removeItem(at: sound.menu!.numberOfItems - 1)
            sound.selectItem(at: sound.menu!.items.firstIndex { $0.representedObject as? String == UserDefaults.standard.string(forKey: Self.soundKey) ?? "Glass" } ?? 0)
            sound.target = self
            sound.action = #selector(guideSound)
            let sleep = NSSwitch()
            sleep.controlSize = .small
            sleep.state = UserDefaults.standard.bool(forKey: Self.wakeKey) ? .off : .on
            sleep.target = self
            sleep.action = #selector(toggleSleep)
            let both = NSTextField(wrappingLabelWithString: "An asleep tab wakes when you open it, or when your main session messages it.")
            both.font = .systemFont(ofSize: 12)
            both.textColor = .secondaryLabelColor
            both.preferredMaxLayoutWidth = 448
            let claude = Guide.column([Guide.line("Bypass Permissions in New Claude Tabs", bypass), Guide.column([Guide.line("Sleep Idle Tabs", sleep), both], spacing: 2), Guide.line("Notification Sound", sound)], spacing: 10)
            let buttons = (byItself ? [("Skip", "⎋"), ("Done", "↩")] : [("Done", "↩")]).map { title, key in
                let button = NSButton(title: title, target: self, action: #selector(endGuide(_:)))
                button.keyEquivalent = key == "↩" ? "\r" : "\u{1b}"
                Self.keyed(button, key)
                return button
            }
            let themeRow = Tile.row(themes.map { ($0, ThemeShot($0.lowercased())) }, picked: ["light": 0, "dark": 1][theme ?? ""] ?? 2, height: 100) { [unowned self] in choose(#selector(pickTheme), nil, title: themes[$0]) }
            guide = Guide([("Theme", themeRow), ("Icons", icons), ("Background", background), ("Claude", claude)], preview: preview, blur: blur, buttons: buttons, byItself: byItself)
            guide!.finish = { [unowned self] in endGuide(skip: $0) }
            guide!.undo = { [unowned self] in
                for (key, value) in found { UserDefaults.standard.set(value, forKey: key) }
                Spark.settings = sparks
                self.theme()
                tabs.map(\.name).forEach(nap)
                rebuild()
                animate()
                relook()
            }
            if probe != nil { guide!.setFrameOrigin(NSPoint(x: 20_000, y: 20_000)) }
        }
        showWindow()
    }

    private func guideIcons(_ stack: NSStackView) {
        let style = Spark.style, looks = ["Terminal", "Hourglass", "Fishing"], letters = ["A", "B", "C"]
        let pick = { [unowned self] (setting: String, value: String) in
            choose(#selector(pickSpinner), [setting, value])
            DispatchQueue.main.async { self.guideIcons(stack) }
        }
        let states: [[(String, String?)]] = [[("working", "code"), ("working", "think"), ("working", "write"), ("working", "default")], [("waiting", "blocked"), ("background", "background"), ("idle", nil), ("asleep", nil)]]
        let styles = Tile.row([("Dots", IconShot(states, scale: 1.5, picks: ["spinner": "dots"], height: 100)), ("Clawd", IconShot(states, scale: 1, picks: ["spinner": "clawd"], height: 100))], picked: ["dots": 0, "clawd": 1][style], height: 100) { pick("spinner", ["dots", "clawd"][$0]) }
        stack.setViews(style != "clawd" ? [styles] : [
            styles,
            Guide.label("Clawd Waiting on a Command", 12, .medium, .secondaryLabelColor),
            Tile.row(letters.enumerated().map { (looks[$0], IconShot([[("background", "background")]], scale: 2, picks: ["spinner": style, "clawd wait": $1], height: 64)) }, picked: letters.firstIndex(of: Spark.settings["clawd wait"]!) ?? 0, height: 64) { pick("clawd wait", letters[$0]) },
        ], in: .top)
    }

    private func steps(_ steps: [(title: String, value: String)], _ key: String, tag: Int) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: steps.map(\.title), trackingMode: .selectOne, target: self, action: #selector(guideLook))
        control.selectedSegment = steps.firstIndex { $0.value == Self.look[key] } ?? 2
        control.controlSize = .small
        control.tag = tag
        return control
    }

    private func choose(_ action: Selector, _ object: Any?, title: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = object
        perform(action, with: item)
    }

    @objc private func guideLook(_ control: NSSegmentedControl) {
        let (key, steps) = control.tag == 0 ? ("background-opacity", Self.transparencies) : ("background-blur", Self.blurs)
        choose(#selector(pickLook), [key: steps[control.selectedSegment].value])
        guide?.relook(blur: Self.look["background-opacity"] != "1")
    }

    @objc private func guideSound(_ popup: NSPopUpButton) { choose(#selector(pickSound), popup.selectedItem?.representedObject) }

    @objc private func endGuide(_ button: NSButton) { endGuide(skip: button.keyEquivalent == "\u{1b}") }

    private func endGuide(skip: Bool) {
        guard let guide else { return }
        if skip { guide.undo() }
        guide.orderOut(nil)
        self.guide = nil
        showWindow()
    }
}

final class Guide: NSWindow {
    let byItself: Bool
    var finish: (Bool) -> Void = { _ in }
    var undo: () -> Void = {}
    private let preview: GroundShot
    private let blur: NSSegmentedControl

    static func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    init(_ sections: [(String, NSView)], preview: GroundShot, blur: NSSegmentedControl, buttons: [NSButton], byItself: Bool) {
        self.byItself = byItself
        self.preview = preview
        self.blur = blur
        super.init(contentRect: NSRect(x: 0, y: 0, width: 496, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Set Up ClaudeTTY"
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        let glyphs = ["Theme": "circle.lefthalf.filled", "Icons": "sparkles", "Background": "square.2.layers.3d", "Claude": "terminal"]
        let parts = sections.map { title, view in
            let glyph = NSImageView(image: NSImage(systemSymbolName: glyphs[title]!, accessibilityDescription: nil)!)
            glyph.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
            glyph.contentTintColor = Spark.orange
            return Self.column([NSStackView(views: [glyph, Self.label(title, 17, .bold)]), view], spacing: 10)
        }
        let columns = [Array(parts.prefix(2)), Array(parts.dropFirst(2))].map { half in
            let room = NSView()
            room.setContentHuggingPriority(.init(1), for: .vertical)
            let column = Self.column(half + [room], spacing: 24)
            column.distribution = .fill
            column.setCustomSpacing(0, after: half.last!)
            return column
        }
        let halves = NSStackView(views: columns)
        halves.alignment = .top
        halves.spacing = 24
        let stack = Self.column([halves], spacing: 24)
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 24, bottom: 24, right: 24)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let words = Self.column([Self.label(byItself ? "Welcome to ClaudeTTY" : title, 22, .bold), Self.label("Change any of this later from the menu bar.", 13, .regular, .secondaryLabelColor)], spacing: 2)
        let header = NSStackView(views: [icon, words])
        header.spacing = 12
        stack.insertArrangedSubview(header, at: 0)
        let rule = NSBox(), bar = NSStackView(views: [NSView()] + buttons), content = NSVisualEffectView()
        content.material = .sidebar
        content.state = .active
        rule.boxType = .separator
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        for child in [stack, rule, bar] {
            content.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: content.topAnchor), stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.widthAnchor.constraint(equalToConstant: 968),
                                     rule.topAnchor.constraint(equalTo: stack.bottomAnchor), rule.leadingAnchor.constraint(equalTo: content.leadingAnchor), rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                                     bar.topAnchor.constraint(equalTo: rule.bottomAnchor), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor), bar.trailingAnchor.constraint(equalTo: content.trailingAnchor), bar.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        contentView = content
        setContentSize(content.fittingSize)
        center()
    }

    @objc func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish(byItself)
        return false
    }

    override func cancelOperation(_ sender: Any?) { performClose(nil) }

    func relook(blur on: Bool) {
        preview.paint()
        blur.isEnabled = on
    }

    static func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    static func line(_ title: String, _ control: NSView) -> NSView {
        let line = NSStackView(views: [label(title, 13), NSView(), control])
        line.widthAnchor.constraint(equalToConstant: 448).isActive = true
        return line
    }
}

final class Tile: NSButton {
    var picked: Bool { didSet { restyle() } }
    private let ring = NSView()
    private let name: NSTextField
    private let pick: () -> Void

    init(_ title: String, _ picture: NSView, picked: Bool, height: CGFloat, pick: @escaping () -> Void) {
        self.picked = picked
        self.pick = pick
        name = Guide.label(title, 12)
        super.init(frame: NSRect(x: 0, y: 0, width: 140, height: height + 8 + 6 + name.fittingSize.height))
        self.title = ""
        isBordered = false
        target = self
        action = #selector(fire)
        setAccessibilityLabel(title)
        ring.frame = NSRect(x: 0, y: 0, width: 140, height: height + 8)
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 9
        picture.frame = NSRect(x: 4, y: 4, width: 132, height: height)
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 6
        picture.layer?.masksToBounds = true
        ring.addSubview(picture)
        name.alignment = .center
        name.frame = NSRect(x: -20, y: height + 14, width: 180, height: name.fittingSize.height)
        addSubview(ring)
        addSubview(name)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var intrinsicContentSize: NSSize { frame.size }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func isAccessibilitySelected() -> Bool { picked }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    @objc private func fire() {
        for case let tile as Tile in superview?.subviews ?? [] { tile.picked = tile === self }
        pick()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.layer?.borderWidth = picked ? 2.5 : 1
            ring.layer?.borderColor = (picked ? NSColor.controlAccentColor : .separatorColor).cgColor
        }
        name.font = .systemFont(ofSize: 12, weight: picked ? .semibold : .regular)
        name.textColor = picked ? .labelColor : .secondaryLabelColor
    }

    static func row(_ items: [(String, NSView)], picked: Int?, height: CGFloat, pick: @escaping (Int) -> Void) -> NSStackView {
        let row = NSStackView(views: items.enumerated().map { index, item in Tile(item.0, item.1, picked: index == picked, height: height) { pick(index) } })
        row.spacing = 14
        row.alignment = .top
        return row
    }
}

final class ThemeShot: NSView {
    private let look: String

    init(_ look: String) {
        self.look = look
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        window(dark: look == "dark")
        guard look == "system" else { return }
        let context = NSGraphicsContext.current!.cgContext
        context.addLines(between: [NSPoint(x: bounds.maxX, y: bounds.maxY), NSPoint(x: bounds.maxX, y: 0), .zero])
        context.clip()
        window(dark: true)
    }

    private func window(dark: Bool) {
        let top = bounds.height, side: CGFloat = 38, grey = NSColor(white: dark ? 0.36 : 0.62, alpha: 1)
        NSColor(white: dark ? 0.17 : 0.87, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: dark ? 0 : 1, alpha: 1).setFill()
        NSRect(x: side, y: 0, width: bounds.width - side, height: top).fill()
        grey.setFill()
        NSRect(x: side + 5, y: top - 5.75, width: 18, height: 2.5).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4 + CGFloat(index) * 5.5, y: top - 6.5, width: 4, height: 4)).fill()
        }
        for index in 0..<5 {
            let y = top - 22 - CGFloat(index) * 15
            if index == 1 {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 3, y: y - 3, width: side - 6, height: 12), xRadius: 3, yRadius: 3).fill()
            }
            (index == 1 ? NSColor.white : grey).setFill()
            NSRect(x: 6, y: y + 4, width: 16, height: 2.5).fill()
            (index == 1 ? NSColor.white.withAlphaComponent(0.6) : grey.withAlphaComponent(0.6)).setFill()
            NSRect(x: 6, y: y, width: 24, height: 2).fill()
        }
        for (index, width) in [70, 52, 0, 64, 44, 0, 58].enumerated() where width > 0 {
            let y = top - 18 - CGFloat(index) * 8
            Spark.orange.setFill()
            NSBezierPath(ovalIn: NSRect(x: side + 5, y: y, width: 3, height: 3)).fill()
            grey.setFill()
            NSRect(x: side + 11, y: y + 0.5, width: CGFloat(width), height: 2).fill()
        }
    }
}

final class IconShot: NSVisualEffectView {
    init(_ lines: [[(String, String?)]], scale: CGFloat, picks: [String: String], height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: 132, height: height))
        material = .sidebar
        blendingMode = .behindWindow
        let tint = NSView(frame: bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(white: 0, alpha: 0.18).cgColor
        addSubview(tint)
        let side = 13 * scale
        for (row, line) in lines.enumerated() {
            for (column, state) in line.enumerated() {
                let x = bounds.width * (CGFloat(column) + 0.5) / CGFloat(line.count), y = bounds.height * (CGFloat(lines.count - row) - 0.5) / CGFloat(lines.count)
                let holder = NSView(frame: NSRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
                holder.bounds.size = NSSize(width: 13, height: 13)
                let spark = Spark(state.0, phase: column, selected: false, key: "guide \(picks) \(row) \(column)", mark: state.1, picks: picks)
                spark.frame = holder.bounds
                holder.addSubview(spark)
                addSubview(holder)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class GroundShot: NSView {
    private let ground = NSView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 448, height: 124))
        widthAnchor.constraint(equalToConstant: 448).isActive = true
        heightAnchor.constraint(equalToConstant: 124).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        let scene = NSImageView(image: NSImage(size: bounds.size, flipped: true) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.93, green: 0.28, blue: 0.6, alpha: 1), NSColor(srgbRed: 0.98, green: 0.62, blue: 0.1, alpha: 1)])!.draw(in: rect, angle: -20)
            for (index, (name, color)) in [("Standup", NSColor.systemGreen), ("Design review", .systemPurple), ("Lunch", .systemOrange), ("1:1 with Sam", .systemTeal), ("Ship 1.2", .systemRed), ("Gym", .systemIndigo)].enumerated() {
                let event = NSRect(x: 14 + CGFloat(index % 3) * 146, y: 12 + CGFloat(index / 3) * 56 + CGFloat(index % 2) * 10, width: 128, height: 40)
                NSColor(white: 1, alpha: 0.9).setFill()
                NSBezierPath(roundedRect: event, xRadius: 6, yRadius: 6).fill()
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: event.minX, y: event.minY, width: 5, height: event.height), xRadius: 2.5, yRadius: 2.5).fill()
                (name as NSString).draw(at: NSPoint(x: event.minX + 12, y: event.minY + 11), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: color])
            }
            return true
        })
        for view in [scene, ground] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
        }
        ground.wantsLayer = true
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), quiet = NSColor.secondaryLabelColor
        let text = NSMutableAttributedString()
        for (part, color) in [("> ", quiet), ("the sidebar feels cramped when it's narrow\n\n", .labelColor), ("● ", Spark.orange), ("I'll check how a row lays out its title.\n\n", .labelColor),
                              ("● ", Spark.orange), ("Read", Spark.orange), ("(Sources/ClaudeTTY/ClaudeTTY.swift)\n", .labelColor), ("  ⎿  Read 412 lines", quiet)] as [(String, NSColor)] {
            text.append(NSAttributedString(string: part, attributes: [.font: mono, .foregroundColor: color]))
        }
        let lines = NSTextField(labelWithAttributedString: text)
        lines.frame = NSRect(x: 12, y: 12, width: 424, height: 100)
        addSubview(scene)
        addSubview(ground)
        addSubview(lines)
        paint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func paint() { ClaudeTTY.ground(ground.layer!, light: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }
}


enum Share {
    static let offKey = "no mcp sharing " + zmxDir
    static let marker = "/claudetty/"
    static let dir = probe.map { $0 + "/share" } ?? (statusDir as NSString).deletingLastPathComponent + "/share"
    static let crashes = (count: 3, within: 600.0)
    static let catalog = ["@supabase/mcp-server-supabase": ["SUPABASE_ACCESS_TOKEN"], "dataforseo-mcp-server": ["DATAFORSEO_USERNAME", "DATAFORSEO_LOGIN", "DATAFORSEO_PASSWORD"], "mcp-server-time": [], "mcp-server-fetch": []]

    static func flag() -> String {
        guard !UserDefaults.standard.bool(forKey: offKey) else { return "" }
        let env = ProcessInfo.processInfo.environment, cwd = FileManager.default.currentDirectoryPath, home = env["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        let config = json(env["CLAUDE_CONFIG_DIR"].map { $0 + "/.claude.json" } ?? NSHomeDirectory() + "/.claude.json") ?? [:], project = (config["projects"] as? [String: Any])?[cwd] as? [String: Any] ?? [:]
        let folders = sequence(first: cwd) { $0 == "/" ? nil : ($0 as NSString).deletingLastPathComponent }
        let skipped = Set((project["disabledMcpServers"] as? [String] ?? []) + folders.flatMap { (json($0 + "/.mcp.json")?["mcpServers"] as? [String: Any] ?? [:]).keys })
        let known = [home + "/settings.json", cwd + "/.claude/settings.json", cwd + "/.claude/settings.local.json"].reduce(env) { $0.merging(json($1)?["env"] as? [String: String] ?? [:]) { $1 } }
        let entries = (config["mcpServers"] as? [String: [String: Any]] ?? [:]).merging(project["mcpServers"] as? [String: [String: Any]] ?? [:]) { $1 }
        var shared: [(name: String, key: String)] = []
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) where !skipped.contains(name) && (entry["type"] as? String ?? "stdio") == "stdio" && name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            let command = entry["command"] as? String ?? "", args = entry["args"] as? [String] ?? []
            guard let creds = catalog.first(where: { package, _ in (command as NSString).lastPathComponent == package || args.contains { $0 == package || $0.hasPrefix(package + "@") } })?.value,
                  let path = command.contains("/") ? command : known["PATH"]?.split(separator: ":").map({ String($0) + "/" + command }).first(where: FileManager.default.isExecutableFile) else { continue }
            let spec: [String: Any] = ["name": name, "command": path, "args": args, "env": creds.reduce(into: [String: String]()) { $0[$1] = known[$1] }.merging(entry["env"] as? [String: String] ?? [:]) { $1 }]
            guard let data = try? JSONSerialization.data(withJSONObject: spec, options: .sortedKeys), !String(decoding: data, as: UTF8.self).contains("${") else { continue }
            let key = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
            try? FileManager.default.createDirectory(atPath: dir + "/servers", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            write(data, to: "servers/" + key + ".json")
            shared.append((name, key))
        }
        guard !shared.isEmpty, let port = ensure(env) else { return "" }
        return #"--mcp-config={"mcpServers":{"# + shared.map { #""\#($0.name)":{"type":"http","url":"http://127.0.0.1:\#(port)\#(marker)\#($0.key)"}"# }.joined(separator: ",") + "}}"
    }

    static func ensure(_ env: [String: String]) -> Int? {
        func port() -> Int? {
            guard let port = (try? String(contentsOfFile: dir + "/port", encoding: .utf8)).flatMap({ Int($0) }) else { return nil }
            var answer: Data?
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: URLRequest(url: URL(string: "http://127.0.0.1:\(port)/claudetty")!, timeoutInterval: 1)) { data, _, _ in answer = data; done.signal() }.resume()
            done.wait()
            return answer == Data("claudetty".utf8) ? port : nil
        }
        if let port = port() { return port }
        guard crashed(since: Date().timeIntervalSince1970 - 60).filter({ $0 == "bridge" }).count < 5 else { return nil }
        ClaudeTTY.spawn(["--share"], environment: env.filter { $0.key != "CLAUDETTY_READY" }.map { "\($0)=\($1)" })
        for _ in 0..<30 {
            usleep(100_000)
            if let port = port() { return port }
        }
        return nil
    }

    static func supervise() -> Int32 {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard flock(open(dir + "/lock", O_CREAT | O_RDWR, 0o600), LOCK_EX | LOCK_NB) == 0 else { return 0 }
        write(Data(String(getpid()).utf8), to: "pid")
        var deaths: [Date] = []
        while true {
            let bridge = ClaudeTTY.spawn(["--share-serve"], environment: ProcessInfo.processInfo.environment.map { "\($0)=\($1)" })
            var status: Int32 = 0
            waitpid(bridge, &status, 0)
            if status == 0 { return 0 }
            crashed("bridge")
            deaths = deaths.filter { $0 > Date() - 60 } + [Date()]
            if deaths.count == 5 { return 1 }
            usleep(300_000)
        }
    }

    static func stale(_ pid: Int32) -> Bool {
        guard let word = ClaudeTTY.arguments(pid).first(where: { $0.hasPrefix("--mcp-config=") && $0.contains(marker) }) else { return false }
        let keeper = (try? String(contentsOfFile: dir + "/pid", encoding: .utf8)).flatMap { Int32($0) } ?? 0
        guard !UserDefaults.standard.bool(forKey: offKey), ClaudeTTY.arguments(keeper).last == "--share", let since = ClaudeTTY.info(keeper)?.pbi_start_tvsec,
              since <= ClaudeTTY.info(pid)?.pbi_start_tvsec ?? 0, let port = try? String(contentsOfFile: dir + "/port", encoding: .utf8) else { return true }
        return !word.contains("127.0.0.1:" + port + marker)
    }

    static func users() -> [Int32: Set<String>] {
        var pids = [Int32](repeating: 0, count: Int(max(proc_listallpids(nil, 0), 0)) + 64)
        let found = Int(max(proc_listallpids(&pids, Int32(pids.count * 4)), 0))
        var users: [Int32: Set<String>] = [:]
        for pid in pids.prefix(found) {
            let keys = ClaudeTTY.arguments(pid).filter { $0.hasPrefix("--mcp-config=") }.flatMap { $0.components(separatedBy: marker).dropFirst().map { String($0.prefix(16)) } }
            if !keys.isEmpty { users[pid] = Set(keys) }
        }
        return users
    }

    static func server(_ key: String) -> Int32? {
        guard let pid = (try? String(contentsOfFile: dir + "/servers/" + key + ".pid", encoding: .utf8)).flatMap({ Int32($0) }),
              let parent = ClaudeTTY.info(pid)?.pbi_ppid, ClaudeTTY.arguments(Int32(parent)).last == "--share-serve" else { return nil }
        return pid
    }

    static func crashed(_ name: String) {
        let lines = ((try? String(contentsOfFile: dir + "/crashes", encoding: .utf8)) ?? "").split(separator: "\n").suffix(19).map(String.init)
        write(Data((lines + ["\(Int(Date().timeIntervalSince1970)) \(name)"]).joined(separator: "\n").utf8), to: "crashes")
    }

    static func crashed(since: Double) -> [String] {
        ((try? String(contentsOfFile: dir + "/crashes", encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 && Double(parts[0]) ?? 0 > since ? String(parts[1]) : nil
        }
    }

    static func write(_ data: Data, to name: String) {
        let temp = dir + "/." + (name as NSString).lastPathComponent + ".\(getpid())"
        FileManager.default.createFile(atPath: temp, contents: data, attributes: [.posixPermissions: 0o600])
        rename(temp, dir + "/" + name)
    }
}

final class Bridge {
    final class Server {
        let process = Process(), input = Pipe(), output = Pipe()
        var buffer = Data()
        var result: Any?
        var waiting: [() -> Void] = []
        var pending: [Int: ([String: Any]) -> Void] = [:]
        var used = Date()
        var gone = false
    }
    let queue = DispatchQueue(label: "bridge")
    var servers: [String: Server] = [:]
    var next = 1
    var used = Date()
    var listener: NWListener?

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        listen((try? String(contentsOfFile: Share.dir + "/port", encoding: .utf8)).flatMap { UInt16($0) } ?? 0)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [self] in scan() }
        timer.resume()
        withExtendedLifetime(timer) { dispatchMain() }
    }

    func listen(_ port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { exit(1) }
        listener.stateUpdateHandler = { [self] state in
            if case .ready = state { Share.write(Data(String(listener.port!.rawValue).utf8), to: "port") }
            if case .failed = state, port == 0 { exit(1) }
            if case .failed = state { listener.cancel(); listen(0) }
        }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            receive(connection, Data())
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
            var buffer = buffer + (data ?? Data())
            while let head = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: buffer[..<head.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() { if let colon = line.firstIndex(of: ":") { headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) } }
                let end = head.upperBound + (Int(headers["content-length"] ?? "") ?? 0)
                guard buffer.count >= end else { break }
                handle(lines[0].split(separator: " ").map(String.init), headers["mcp-session-id"] ?? UUID().uuidString, Data(buffer[head.upperBound..<end]), connection)
                buffer = Data(buffer[end...])
            }
            if done || error != nil { connection.cancel() } else { receive(connection, buffer) }
        }
    }

    func respond(_ connection: NWConnection, _ status: String, _ session: String, _ body: Data = Data()) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nMcp-Session-Id: \(session)\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .idempotent)
    }

    func handle(_ request: [String], _ session: String, _ body: Data, _ connection: NWConnection) {
        let key = request.count > 1 && request[1].hasPrefix(Share.marker) ? String(request[1].dropFirst(Share.marker.count)) : ""
        switch request.first {
        case "GET" where request.count > 1 && request[1] == "/claudetty": return respond(connection, "200 OK", session, Data("claudetty".utf8))
        case "DELETE": return respond(connection, "200 OK", session)
        case "POST" where !key.isEmpty: break
        default: return respond(connection, "405 Method Not Allowed", session)
        }
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let spec = json(Share.dir + "/servers/" + key + ".json") else { return respond(connection, "404 Not Found", session) }
        used = Date()
        guard let method = message["method"] as? String, let id = message["id"] else { return respond(connection, "202 Accepted", session) }
        let reply = { [self] (answer: [String: Any]) in respond(connection, "200 OK", session, (try? JSONSerialization.data(withJSONObject: answer.merging(["jsonrpc": "2.0", "id": id]) { $1 })) ?? Data()) }
        if ["ping", "logging/setLevel"].contains(method) { return reply(["result": [:]]) }
        let server = servers[key] ?? start(key, spec, message["params"] as? [String: Any])
        server.used = Date()
        let send = { [self] in
            if server.gone { return reply(["error": ["code": -32000, "message": (spec["name"] as? String ?? key) + " stopped"]]) }
            if method == "initialize" { return reply(["result": server.result!]) }
            server.pending[next] = reply
            write(message.merging(["id": next]) { $1 }, to: server)
            next += 1
        }
        server.result == nil && !server.gone ? server.waiting.append(send) : send()
    }

    func start(_ key: String, _ spec: [String: Any], _ params: [String: Any]?) -> Server {
        let server = Server(), credentials = Set(Share.catalog.values.joined())
        server.process.executableURL = URL(fileURLWithPath: spec["command"] as? String ?? "/")
        server.process.arguments = spec["args"] as? [String] ?? []
        server.process.environment = ProcessInfo.processInfo.environment.filter { !credentials.contains($0.key) }.merging(spec["env"] as? [String: String] ?? [:]) { $1 }
        server.process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        (server.process.standardInput, server.process.standardOutput, server.process.standardError) = (server.input, server.output, FileHandle.nullDevice)
        server.output.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            queue.async { self.read(data, server, key) }
        }
        server.process.terminationHandler = { [self] _ in queue.async { self.exited(server, key, spec["name"] as? String ?? key) } }
        servers[key] = server
        do {
            try server.process.run()
            Share.write(Data(String(server.process.processIdentifier).utf8), to: "servers/" + key + ".pid")
        } catch { queue.async { [self] in exited(server, key, "") } }
        write(["id": 0, "method": "initialize", "params": ["protocolVersion": params?["protocolVersion"] ?? "2025-06-18", "capabilities": [:], "clientInfo": params?["clientInfo"] ?? ["name": "ClaudeTTY", "version": "1"]]], to: server)
        return server
    }

    func read(_ data: Data, _ server: Server, _ key: String) {
        server.buffer += data
        while let end = server.buffer.firstIndex(of: 10) {
            let line = server.buffer[..<end]
            server.buffer = Data(server.buffer[(end + 1)...])
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = message["id"] as? Int else { continue }
            if message["method"] != nil {
                write(["id": id, "error": ["code": -32601, "message": "not supported"]], to: server)
            } else if id == 0 {
                server.result = message["result"]
                guard server.result != nil else { stop(key); continue }
                write(["method": "notifications/initialized"], to: server)
                server.waiting.forEach { $0() }
                server.waiting = []
            } else {
                server.pending.removeValue(forKey: id)?(message)
            }
        }
    }

    func write(_ message: [String: Any], to server: Server) {
        guard let data = try? JSONSerialization.data(withJSONObject: message.merging(["jsonrpc": "2.0"]) { $1 }) else { return }
        try? server.input.fileHandleForWriting.write(contentsOf: data + Data([10]))
    }

    func exited(_ server: Server, _ key: String, _ name: String) {
        if servers[key] === server { servers[key] = nil }
        if server.result != nil && !server.gone { Share.crashed(name) }
        server.gone = true
        let error: [String: Any] = ["error": ["code": -32000, "message": name + " stopped"]]
        server.pending.values.forEach { $0(error) }
        server.pending = [:]
        server.waiting.forEach { $0() }
        server.waiting = []
    }

    func stop(_ key: String) {
        guard let server = servers.removeValue(forKey: key), server.process.processIdentifier > 0 else { return }
        server.gone = true
        var tree: [(pid: Int32, start: UInt64?)] = [], next = [server.process.processIdentifier]
        while let pid = next.popLast() {
            tree.append((pid, ClaudeTTY.info(pid)?.pbi_start_tvsec))
            next += ClaudeTTY.children(pid)
        }
        for process in tree where ClaudeTTY.info(process.pid)?.pbi_start_tvsec == process.start { kill(process.pid, SIGTERM) }
        queue.asyncAfter(deadline: .now() + 2) { for process in tree where ClaudeTTY.info(process.pid)?.pbi_start_tvsec == process.start { kill(process.pid, SIGKILL) } }
    }

    func scan() {
        guard getppid() != 1 else { kill(0, SIGKILL); return }
        let named = Set(Share.users().values.joined())
        for (key, server) in servers where !named.contains(key) && server.used < Date() - 30 { stop(key) }
        if named.isEmpty && servers.isEmpty && used < Date() - 60 { exit(0) }
    }
}
