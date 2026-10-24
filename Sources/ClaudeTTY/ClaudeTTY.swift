// Runtime callbacks follow Ghostty's macOS app (Ghostty.App.swift), MIT, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
import AppKit
import Carbon
import GhosttyKit
import ServiceManagement
import SwiftUI
import UserNotifications

let deps = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/claudetty-deps").path
let contents = URL(fileURLWithPath: Bundle.main.executablePath!).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().path
let bundled = FileManager.default.fileExists(atPath: contents + "/Helpers/zmx")
let zmx = bundled ? contents + "/Helpers/zmx" : deps + "/zmx/zmx"
let zmxDir = ProcessInfo.processInfo.environment["ZMX_DIR"] ?? NSTemporaryDirectory() + "zmx-\(getuid())"
let probe = ProcessInfo.processInfo.environment["CLAUDETTY_PROBE"]
let statusDir = probe.map { $0 + "/status" } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/claudetty/status").path
let colors: [(name: String, color: NSColor)] = [("red", .systemRed), ("orange", .systemOrange), ("yellow", .systemYellow), ("green", .systemGreen), ("teal", .systemTeal), ("blue", .systemBlue), ("purple", .systemPurple), ("gray", .systemGray)]

struct Tab: Equatable, Codable {
    private enum CodingKeys: CodingKey { case name, group, cwd, labels }

    let name: String
    var group: String
    let cwd: String
    var labels: [String: String] = [:]
    var pid: Int32?

    static func == (lhs: Tab, rhs: Tab) -> Bool { lhs.name == rhs.name }

    var topic: String?
    var title: String { labels["title"] ?? topic ?? name }

    var folder: String {
        var info = proc_vnodepathinfo()
        guard let pid, proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return cwd }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
    }

    var claude: String? {
        guard let pid, isClaude(pid) else { return nil }
        let state = (try? String(contentsOfFile: statusDir + "/" + name, encoding: .utf8)) ?? ""
        return (state == "working" || state == "waiting") && interrupted ? "idle" : state
    }

    private var interrupted: Bool {
        guard let message = transcript.map(lastMessages)?.first, message["type"] as? String == "user", let content = (message["message"] as? [String: Any])?["content"] else { return false }
        return ((content as? String) ?? (content as? [[String: Any]])?.first?["text"] as? String)?.hasPrefix("[Request interrupted by user") == true
    }

    var tasks: [[String]] {
        guard claude != nil, let text = try? String(contentsOfFile: statusDir + "/" + name + ".agents", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 3).map(String.init) }.filter { $0.count == 4 }
    }

    var action: (text: String, tool: String?, ask: String?, at: Date)? {
        let path = statusDir + "/" + name + ".action"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), let at = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), first = lines[0].split(separator: "\t", maxSplits: 1).map(String.init)
        return (first.first == "Thinking" && writing(since: at) ? "Writing" : first.first ?? "", first.count > 1 ? first[1] : nil, lines.count > 1 ? lines[1] : nil, at)
    }

    var mark: String? {
        switch claude {
        case "waiting": return "blocked"
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

    var transcript: String? { try? String(contentsOfFile: statusDir + "/" + name + ".transcript", encoding: .utf8) }
    var session: String? { transcript.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } }
}

let stamps = { let format = ISO8601DateFormatter(); format.formatOptions.insert(.withFractionalSeconds); return format }()

func lastMessages(_ path: String) -> [[String: Any]] {
    guard let file = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? file.close() }
    let end = (try? file.seekToEnd()) ?? 0, start = end > 65_536 ? end - 65_536 : 0
    let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
    if let cached = parsed[path], cached.stamp == stamp, cached.size == end { return cached.messages }
    try? file.seek(toOffset: start)
    let lines = (try? file.readToEnd())?.split(separator: UInt8(ascii: "\n")) ?? []
    let messages = lines.dropFirst(start > 0 ? 1 : 0).reversed().compactMap { line in
        (try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]).flatMap { ["assistant", "user"].contains($0["type"] as? String) ? $0 : nil }
    }
    parsed[path] = (stamp, end, messages)
    return messages
}
private var parsed: [String: (stamp: Date, size: UInt64, messages: [[String: Any]])] = [:]

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

func isClaude(_ pid: Int32) -> Bool {
    guard let front = foreground(pid) else { return false }
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    proc_pidpath(front, &path, UInt32(path.count))
    return String(cString: path).contains("/claude/versions/") || path[0] == 0 && started(front)?.strings.first?.hasSuffix("/claude") == true
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
    private var securing = false
    private static let sortKey = "sort by state " + zmxDir
    private static let collapsedKey = "collapsed folders " + zmxDir
    private static let buttonsKey = "hide pane buttons " + zmxDir
    private static let askKey = "claude asks permission " + zmxDir
    private static let contextKey = "hide context size " + zmxDir
    private static let lookKey = "look " + zmxDir
    private static let lookDefaults = ["cursor-style": "block", "cursor-style-blink": "", "background-opacity": "1", "background-blur": "0", "window-padding-x": "1", "window-padding-y": "0,4"]
    private static var look: [String: String] { lookDefaults.merging(UserDefaults.standard.dictionary(forKey: lookKey) as? [String: String] ?? [:]) { $1 } }
    static var padding: CGSize {
        CGSize(width: Double(look["window-padding-x"]!) ?? 1, height: look["window-padding-y"]!.split(separator: ",").compactMap { Double($0) }.reduce(0, +))
    }
    private var meters: [String: NSTextField] = [:]
    private var shown: Set<String> = []
    private var panes: [String: (bar: PaneBar?, body: Body)] = [:]
    private var arranged = ""
    private var placed: Set<String> = []
    private let titleButtons = NSStackView()
    private let titleHover = BarHover()
    private var surfaces: [String: SurfaceView] = [:]
    private var commands: [String: [String]] = [:]
    private var closedTabs: [(tab: Tab, index: Int, command: [String]?, history: Data?)] = []
    private let sidebar = NSStackView()
    private let tabBar = NSStackView()
    private let terminal = NSView()
    private var side: NSView!
    private var sidebarShown = true
    private var zoomed: [String: String] = [:]
    private var renaming = false
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
    private var replies: [String: (stamp: Date, reply: (text: String, at: Date)?)] = [:]
    private var transcripts: [String: (path: String, watch: DispatchSourceFileSystemObject)] = [:]
    private var fronts: [String] = []
    private var spinner: Timer?
    private var tabSparks: [String: Spark] = [:]
    private var turn = 0
    private var rebuilds = 0
    private var oldApp: DispatchSourceProcess?
    private var predecessor = ClaudeTTY.saved?.handover.flatMap { kill($0.pid, 0) == 0 ? $0 : nil }
    private var hidden = false
    private let groupsMenu = NSMenu(title: "Groups")
    private var iconCount: Int?
    private var statusItem: NSStatusItem?
    private var hintTimer: Timer?
    private var pills: [KeyPill] = []
    private var paneRows: [Row] = []
    private var hintModifier = "⌘"
    private static let port = "dev.claudetty.app" + (probe.map { "." + $0 } ?? "") as CFString
    private static var server: CFMessagePort?
    private static let keeperPort = "dev.claudetty.keeper" as CFString
    private static let kept: Set = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "ZMX_DIR", "CLAUDETTY_PROBE", "CLAUDETTY_RELEASES"]
    private static let executable = URL(fileURLWithPath: Bundle.main.executablePath!).resolvingSymlinksInPath().path
    private static let bundle = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    private static let released = bundle.hasSuffix(".app") && Bundle(path: bundle)?.object(forInfoDictionaryKey: "ClaudeTTYSource") == nil
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
    }
    private static let stateFile = probe.map { $0 + "/state.json" } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/ClaudeTTY/state.json").path
    private static let saved = (try? Data(contentsOf: URL(fileURLWithPath: stateFile))).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    private var saving = false
    private var normalFrame = NSRect.zero
    private var menuMarks: [(item: NSMenuItem, mark: String)] = []
    private var menuTimer: Timer?
    private enum Swap { case running, failed, ready }
    private var newer: (version: String, page: URL, swap: Swap)?
    private var updateWait: Timer?
    private struct Notice: Equatable { let text: String, at: Date; var bannered: Bool }
    private var notices: [String: Notice] = [:]
    private var lastBanner = Date.distantPast
    private var retryBanner: Timer?
    private var probeWasActive = false
    private var look: (tab: String, since: Date, timer: Timer)?

    static func main() {
        let ready = ProcessInfo.processInfo.environment["CLAUDETTY_READY"].flatMap(Int32.init)
        if ready == nil {
            switch CommandLine.arguments.dropFirst().first {
            case "--app":
                for key in ProcessInfo.processInfo.environment.keys where !kept.contains(key) { unsetenv(key) }
                setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
            case "notify": exit(notice())
            case "list", "events", "wait": exit(states())
            case "--attach": attach()
            case "--keeper": exit(keeper())
            case "reload": exit(reload())
            default: exit(request())
            }
        }
        let listening = listen()
        if let ready { close(ready) }
        unsetenv("CLAUDETTY_READY")
        guard listening else { exit(0) }
        setenv("GHOSTTY_RESOURCES_DIR", bundled ? contents + "/Resources/ghostty" : deps + "/ghostty/zig-out/share/ghostty", 0)
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
        let running = CFMessagePortCreateRemote(nil, port) != nil
        if executable.hasSuffix(".app/Contents/MacOS/ClaudeTTY"), !running || focus {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = focus
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
        guard let app = CFMessagePortCreateRemote(nil, port) else { return failed("didn't start") }
        let request = try! JSONSerialization.data(withJSONObject: ["args": args, "cwd": FileManager.default.currentDirectoryPath, "path": ProcessInfo.processInfo.environment["PATH"] ?? "", "focus": focus])
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(app, 0, request as CFData, 5, 30, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess else { return failed("didn't answer (\(status))") }
        if let problem = reply?.takeRetainedValue() as Data?, !problem.isEmpty { return failed(String(decoding: problem, as: UTF8.self)) }
        let name = args.first == "split" ? args[3] : args.count > 1 ? args[1] : args.first
        let deadline = Date() + 10
        while let name, !FileManager.default.fileExists(atPath: zmxDir + "/" + name), Date() < deadline { usleep(50_000) }
        return 0
    }

    @discardableResult private static func spawn(keeping ready: Int32? = nil) -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd in Int32(0)...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) }
        if let ready { posix_spawn_file_actions_addinherit_np(&actions, ready) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        if disclaims(executable, probe: probe) {
            if let disclaim = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") {
                _ = unsafeBitCast(disclaim, to: (@convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32).self)(&attributes, 1)
            } else {
                fputs("ClaudeTTY can't disclaim: tabs ask for permissions as the app that ran ct\n", stderr)
            }
        } else if probe != nil {
            fputs("ClaudeTTY probe: no responsibility disclaim\n", stderr)
        }
        let environment = ProcessInfo.processInfo.environment.filter { kept.contains($0.key) }.map { "\($0)=\($1)" } + ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"] + (ready.map { ["CLAUDETTY_READY=\($0)"] } ?? [])
        let argv = [strdup(executable)] + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        var pid: pid_t = 0
        posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        return pid
    }

    static func disclaims(_ executable: String, probe: String?) -> Bool { probe == nil && executable.hasSuffix(".app/Contents/MacOS/ClaudeTTY") }

    private static func settle() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path, bin = home + "/.local/bin"
        try? FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for (name, target) in [("ct", executable), ("zmx", zmx)] where !FileManager.default.fileExists(atPath: bin + "/" + name) {
            try? FileManager.default.removeItem(atPath: bin + "/" + name)
            try? FileManager.default.createSymbolicLink(atPath: bin + "/" + name, withDestinationPath: target)
        }
        func json(_ path: String) -> [String: Any]? { (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
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

    private static func attach() -> Never {
        let args = ["attach"] + CommandLine.arguments.dropFirst(2)
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

    private static func keeper() -> Int32 {
        let local = CFMessagePortCreateLocal(nil, keeperPort, { _, _, data, _ in
            guard let request = (data as Data?).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                  let args = request["args"] as? [String], let env = request["env"] as? [String] else { return nil }
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
        CFRunLoopRun()
        return 0
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

    private static func states() -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        func state(_ tab: Tab) -> String { tab.claude.map { $0.isEmpty ? "idle" : $0 } ?? "shell" }
        if args.first == "list" {
            let keys = ["group", "tab", "title", "state", "folder", "context"]
            let rows = sessions().map { tab in Dictionary(uniqueKeysWithValues: zip(keys, [tab.group, tab.name, tab.title, state(tab), tab.folder, tab.context.map(String.init) ?? ""])) }
            if args.last == "--json" { print(String(decoding: try! JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)) }
            else { for row in rows { print(keys.map { row[$0]! }.joined(separator: "\t")) } }
            return 0
        }
        let wait = args.first == "wait" ? Array(args.dropFirst()) : []
        guard args.first == "events" || wait.count == 2 else { return failed("wait <tab> working|waiting|idle|shell") }
        var last: [String: String] = [:]
        func check() {
            let now = sessions().map { ($0.name, state($0)) }
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
        let watches = [statusDir, zmxDir].map { path in
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: Darwin.open(path, O_EVTONLY), eventMask: .write, queue: .main)
            watch.setEventHandler { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: check) }
            watch.resume()
            return watch
        }
        withExtendedLifetime(watches) { dispatchMain() }
    }

    private static func config() -> ghostty_config_t? {
        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        let overrides = NSTemporaryDirectory() + "claudetty.conf"
        var look = look
        if look["background-opacity"] != "1" { look["background-opacity"] = "0" }
        try? (["background = #000000"] + look.sorted { $0.key < $1.key }.map { "\($0) = \($1)" }).joined(separator: "\n").write(toFile: overrides, atomically: true, encoding: .utf8)
        ghostty_config_load_file(config, overrides)
        ghostty_config_finalize(config)
        return config
    }

    private func paint() {
        let opacity = Double(Self.look["background-opacity"]!) ?? 1
        window.backgroundColor = NSColor.black.withAlphaComponent(opacity)
        window.isOpaque = opacity == 1
        app.map { ghostty_set_window_background_blur($0, Unmanaged.passUnretained(window).toOpaque()) }
    }

    private static func failed(_ reason: String) -> Int32 {
        fputs("ClaudeTTY \(reason)\n", stderr)
        return 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.disclaims(Self.executable, probe: probe) {
            try? SMAppService.agent(plistName: "dev.claudetty.keeper.plist").register()
            if bundled { DispatchQueue.global(qos: .utility).async(execute: Self.settle) }
        }
        let config = Self.config()
        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in DispatchQueue.main.async { ClaudeTTY.shared.app.map(ghostty_app_tick) } },
            action_cb: { _, target, action in ClaudeTTY.shared.perform(target, action) },
            read_clipboard_cb: { userdata, location, state, _, _, _ in ClaudeTTY.readClipboard(userdata, location, state) },
            confirm_read_clipboard_cb: { userdata, request, state, kind in
                guard let view = ClaudeTTY.view(userdata), let surface = view.surface else { return }
                guard kind == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let content = request?.pointee.contents, let data = content.pointee.data else { return ghostty_surface_deny_clipboard_request(surface, state) }
                let text = String(decoding: UnsafeRawBufferPointer(start: data, count: content.pointee.len), as: UTF8.self)
                DispatchQueue.main.async { ClaudeTTY.shared.pasting(text, view, state) }
            },
            write_clipboard_cb: { _, location, content, count, _ in ClaudeTTY.writeClipboard(location, content, count) },
            close_surface_cb: { userdata, _ in DispatchQueue.main.async { ClaudeTTY.shared.name(ClaudeTTY.view(userdata)).map { ClaudeTTY.shared.closing([$0]) } } })
        guard let app = ghostty_app_new(&runtime, config) else { fatalError("ghostty_app_new failed") }
        ghostty_config_free(config)
        self.app = app
        ghostty_app_set_focus(app, true)

        tabs = Self.sessions()
        let restored = Self.saved?.boot == Self.boot ? [] : (Self.saved?.kept ?? []).filter { !tabs.contains($0) }
        for tab in restored { commands[tab.name] = Self.saved?.resume?[tab.name].map { Self.claude("--dangerously-skip-permissions --resume " + $0) } }
        tabs += restored
        hidden = predecessor?.hidden ?? false
        if let old = predecessor?.pid {
            let reclaim = { [unowned self] in
                oldApp?.cancel()
                oldApp = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.children(getpid()).flatMap(Self.children).forEach { kill($0, SIGWINCH) } }
            }
            oldApp = DispatchSource.makeProcessSource(identifier: old, eventMask: .exit, queue: .main)
            oldApp!.setEventHandler(handler: reclaim)
            oldApp!.resume()
            if kill(old, 0) != 0 { reclaim() }
        }
        if let saved = Self.saved {
            lastTab = saved.lastTab.compactMapValues { name in tabs.first { $0.name == name } }
            (shown, zoomed, recent) = (Set(saved.shown), saved.zoomed, saved.recent)
        }
        readNotices(fresh: false)
        if probe == nil, Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        window = Window(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
        window.layoutIfNeeded()
        for tab in restored { makeSurface(tab).setVisible(false) }
        for dir in [statusDir, zmxDir] { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        watches = ([(statusDir, self.statusSoon),((Self.executable as NSString).deletingLastPathComponent, self.update), (zmxDir, { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: self.refresh) })] + (probe.map { [($0, { self.probeKey(); self.probeClick(); self.probeMenu(); self.probeDrop(); self.probeShot(); self.probeActive() })] } ?? [])).map { path, handler in
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: Darwin.open(path, O_EVTONLY), eventMask: .write, queue: .main)
            watch.setEventHandler(handler: handler)
            watch.resume()
            return watch
        }
        if Self.released {
            checkUpdates()
            Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [unowned self] _ in checkUpdates() }.tolerance = 3600
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [unowned self] _ in if drawing { activities.keys.forEach(redraw) } }.tolerance = 10
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [unowned self] _ in update() }
        NSApp.mainMenu = menu()
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [unowned self] in keyHints($0) }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, Self.server, 0), .commonModes)
    }

    private func update() {
        let build = Self.build
        guard build != nil, build != running, newer == nil else { return }
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
                swap.terminationHandler = { swap in DispatchQueue.main.async { self.newer?.swap = swap.terminationStatus == 0 ? .ready : .failed } }
                if (try? swap.run()) == nil { newer?.swap = .failed }
            }
        }.resume()
    }

    @objc private func pickUpdate() {
        switch newer?.swap {
        case nil: checkUpdates(manual: true)
        case .failed: NSWorkspace.shared.open(newer!.page)
        case .ready:
            newer = nil
            update()
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
        if parts[0] == "fullscreen" { return window.toggleFullScreen(nil) }
        if parts[0] == "minimize" { return window.miniaturize(nil) }
        if parts[0] == "close" { return window.performClose(nil) }
        if parts[0] == "activate" { return applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification)) }
        let flags: [String: NSEvent.ModifierFlags] = ["cmd": .command, "shift": .shift, "ctrl": .control, "opt": .option]
        let modifiers = parts.dropFirst(2).reduce(into: NSEvent.ModifierFlags()) { $0.insert(flags[$1] ?? []) }
        if parts[0] == "flags" {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
            return NSApp.postEvent(NSEvent(cgEvent: event)!, atStart: false)
        }
        let characters = ["return": "\r", "esc": "\u{1b}", "up": "\u{F700}", "down": "\u{F701}"][parts[0]] ?? parts[0]
        if let sheet = window.attachedSheet, let content = sheet.contentView {
            func button(_ view: NSView) -> NSButton? { (view as? NSButton).flatMap { $0.keyEquivalent == characters ? $0 : nil } ?? view.subviews.lazy.compactMap(button).first }
            return (characters == "\r" ? sheet.defaultButtonCell?.controlView as? NSButton : button(content))?.performClick(nil) ?? ()
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        _ = keyHints(event)
        let shown = window.isVisible
        let handled = shown && window.performKeyEquivalent(with: event) || !modifiers.isDisjoint(with: [.command, .control]) && NSApp.mainMenu?.performKeyEquivalent(with: event) == true
        if !handled && shown { window.firstResponder?.keyDown(with: event) }
    }

    private func onscreen() {
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
    }

    private func probeMenu() {
        guard let probe, let line = try? String(contentsOfFile: probe + "/run", encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: probe + "/run")
        let names = line.trimmingCharacters(in: .newlines).components(separatedBy: "\t")
        guard let menu = names.dropLast().reduce(NSApp.mainMenu, { menu, name in menu?.items.first { $0.submenu?.title == name }?.submenu }) else { return }
        menu.update()
        try? menu.items.map { $0.title + ($0.isEnabled ? "" : " (off)") }.joined(separator: "\n").write(toFile: probe + "/menu", atomically: true, encoding: .utf8)
        guard let index = menu.items.firstIndex(where: { $0.title == names.last && $0.isEnabled }) else { return }
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
        guard let probe, let line = try? String(contentsOfFile: probe + "/click", encoding: .utf8), let frame = window.contentView?.superview else { return }
        try? FileManager.default.removeItem(atPath: probe + "/click")
        var parts = line.split { $0 == " " || $0.isNewline }.map(String.init)
        func find(_ view: NSView, _ label: String, row: Bool = false) -> NSView? {
            let parts = label.split(separator: "#"), nth = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            func all(_ view: NSView) -> [NSView] { (view.accessibilityLabel() == String(parts.first ?? "") && (!row || view is Row) ? [view] : []) + view.subviews.flatMap(all) }
            return all(view).dropFirst(nth - 1).first
        }
        let moved = parts.last == "cmd-move", command = moved || parts.last == "cmd"
        if command { parts.removeLast() }
        let mouse = { [window] (type: NSEvent.EventType, point: NSPoint, count: Int) in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window!.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        if parts.first == "hover", parts.count == 3, let x = Double(parts[1]), let y = Double(parts[2]) {
            func all(_ view: NSView) -> [NSView] { (view is BarHover || view is HoverButton || view is TitleButton || view is Row ? [view] : []) + view.subviews.flatMap(all) }
            for view in all(frame) { view.convert(view.bounds, to: nil).contains(NSPoint(x: x, y: y)) ? view.mouseEntered(with: mouse(.mouseMoved, NSPoint(x: x, y: y), 0)) : view.mouseExited(with: mouse(.mouseMoved, NSPoint(x: x, y: y), 0)) }
            return
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
            guard let start = (label.hasPrefix("bar:") ? find(tabBar, String(label.dropFirst(4)), row: true) ?? find(terminal, String(label.dropFirst(4)), row: true) : find(frame, label)).map({ $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }), let view = frame.hitTest(start) else { return }
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
        let label = parts.dropFirst().joined(separator: " ")
        if menu { _ = find(frame, label)?.accessibilityPerformShowMenu(); return }
        if label == "ClaudeTTY", hidden {
            let menu = NSMenu()
            menuNeedsUpdate(menu)
            popUp(menu, at: .zero, in: window.contentView!)
            return
        }
        guard let clicks = Int(parts.first ?? ""), let point = parts.count == 3 && Double(parts[1]) != nil ? NSPoint(x: Double(parts[1])!, y: Double(parts[2]) ?? 0) : find(frame, label).map({ $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }) else { return }
        for count in 1...clicks {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(count - 1)) {
                guard let view = frame.hitTest(point) else { return }
                if right { return view.rightMouseDown(with: mouse(.rightMouseDown, point, count)) }
                if !middle, !(view is SurfaceView) { NSApp.postEvent(mouse(.leftMouseUp, point, count), atStart: false) }
                let press = mouse(middle ? .otherMouseDown : .leftMouseDown, point, count)
                func commandKey(_ flags: NSEvent.ModifierFlags) {
                    view.flagsChanged(with: NSEvent.keyEvent(with: .flagsChanged, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x37)!)
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

    private func probeShot() {
        guard let probe, FileManager.default.fileExists(atPath: probe + "/shot"), let view = window.contentView?.superview else { return }
        try? FileManager.default.removeItem(atPath: probe + "/shot")
        for (shot, name) in [(view, "shot"), (window.attachedSheet?.contentView?.superview, "sheet")] {
            guard let shot, let rep = shot.bitmapImageRepForCachingDisplay(in: shot.bounds) else { continue }
            shot.layoutSubtreeIfNeeded()
            shot.cacheDisplay(in: shot.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: probe + "/\(name).png"))
        }
        func labels(_ view: NSView) -> [String] {
            let text = (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title ?? ""
            let baseline = view.convert(NSPoint(x: 0, y: view.isFlipped ? view.firstBaselineOffsetFromTop : view.bounds.height - view.firstBaselineOffsetFromTop), to: nil).y
            let span = view.convert(view.bounds, to: nil)
            return (text.isEmpty || view.isHiddenOrHasHiddenAncestor ? [] : ["\(text)\t\(baseline)\t\(Int(span.minX)) \(Int(span.maxX))"]) + view.subviews.flatMap(labels)
        }
        let grids = surfaces.compactMap { name, surface in surface.surface.map { size in
            let grid = ghostty_surface_size(size)
            let top = surface.convert(NSPoint(x: 0, y: surface.isFlipped ? 0 : surface.bounds.height), to: nil)
            return "grid \(name)\t\(surface.frame.height)\t\(surface.cellSize.height)\t\(grid.rows)\t\(surface.frame.width)\t\(surface.cellSize.width)\t\(grid.columns)\t\(top.x) \(top.y)"
        } }
        func rows(_ view: NSView) -> [String] {
            let drawn = (view as? Row)?.ghost ?? view, at = drawn.convert(NSPoint(x: drawn.bounds.midX, y: drawn.bounds.midY), to: nil)
            let kind = view is Row ? "row" : view is Spark ? "spark" : view is Ring ? "ring" : nil
            return (kind != nil && !view.isHiddenOrHasHiddenAncestor ? ["\(kind!)\t\(view.accessibilityLabel() ?? "")\t\((view as? Spark)?.shown ?? "\(view.isAccessibilitySelected())")\t\(Int(at.x)) \(Int(at.y))"] : []) + view.subviews.flatMap(rows)
        }
        let scrolled = sidebar.enclosingScrollView.map { ["scroll\t\(Int($0.contentView.bounds.minY))"] } ?? []
        (NSApp.mainMenu?.items.compactMap(\.submenu) ?? []).forEach { $0.update() }
        let glyphs: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let menus = (NSApp.mainMenu?.items.compactMap(\.submenu) ?? []).flatMap { menu in menu.items.map { item in
            "menu\t\(menu.title)\t" + (item.isSeparatorItem ? "-\t" : "\(item.title)\(item.state == .on ? " ✓" : "")\t" + glyphs.filter { item.keyEquivalentModifierMask.union(item.keyEquivalent == item.keyEquivalent.lowercased() ? [] : .shift).contains($0.0) }.map(\.1).joined() + (item.keyEquivalent == "\r" ? "↩" : item.keyEquivalent.uppercased()))
        } }
        let off = (NSApp.mainMenu?.items.compactMap(\.submenu) ?? []).flatMap { menu -> [String] in
            menu.items.filter { !$0.isEnabled && !$0.isSeparatorItem }.map { "menuoff\t\(menu.title)\t\($0.title)" }
        }
        let keys = pills.map { "pill\t\($0.key)\t\($0.frame.minX) \($0.frame.minY) \($0.frame.maxX) \($0.frame.maxY)\t\($0.frame.minY + KeyPill.baseline)" }
        try? (labels(view) + grids + rows(view) + scrolled + keys + menus + off + ["spinner \(spinner != nil)", "rebuilds \(rebuilds)", "looking \(look != nil)", "badge \(NSApp.dockTile.badgeLabel ?? "")", "window \(window.isVisible ? "shown" : "hidden")", "frame \(Int(window.frame.minX)) \(Int(window.frame.minY)) \(Int(window.frame.width))x\(Int(window.frame.height))\(window.isZoomed ? " zoomed" : "")"]).joined(separator: "\n").write(toFile: probe + "/baselines", atomically: true, encoding: .utf8)
    }

    @discardableResult private func open(_ request: [String: Any]) -> String? {
        var args = request["args"] as? [String] ?? []
        let cwd = request["cwd"] as? String ?? NSHomeDirectory()
        let focus = request["focus"] as? Bool ?? false
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
            if !tabs.contains(where: { $0.name == name }) { tabs.append(Tab(name: name, group: group, cwd: cwd, labels: ["named": tabs.first { $0.group == group }?.labels["named"] ?? (name == group ? "0" : "1")])) }
            let command = Array(args.dropFirst(2))
            commands[name] = command.isEmpty ? [] : ["env", "PATH=" + (request["path"] as? String ?? "")] + command
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
        if let predecessor, !predecessor.hidden {
            window.order(.below, relativeTo: predecessor.window)
            window.makeKey()
        } else if !hidden { window.makeKeyAndOrderFront(nil) }
        if first, !hidden, Self.saved?.fullScreen == true { window.toggleFullScreen(nil) }
        menuBarIcon()
        if first, predecessor == nil { snap() }
        predecessor = nil
        if focus, probe == nil { NSApp.activate() }
        return nil
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
        for tab in gone { closed(tab.name) }
        for i in tabs.indices { tabs[i].pid = live.first { $0 == tabs[i] }?.pid ?? tabs[i].pid }
        tabs += live.filter { !tabs.contains($0) && FileManager.default.fileExists(atPath: zmxDir + "/" + $0.name) }
        for group in groups where tabs.first(where: { $0.group == group })?.labels["named"] == nil { label(group, "named", named(group) ? "1" : "0") }
        selected = selected.flatMap { old in tabs.first { $0 == old } }
        guard state() != before else { return }
        rebuild()
        saveSoon()
    }

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
    func windowDidMove(_ notification: Notification) { saveSoon() }
    func windowDidResize(_ notification: Notification) { saveSoon() }
    func applicationWillTerminate(_ notification: Notification) { save() }

    private func save(handover: State.Handover? = nil) {
        saving = false
        guard let server = Self.server, CFMessagePortIsValid(server), selected != nil else { return }
        let frame = window.styleMask.contains(.fullScreen) ? normalFrame : window.frame
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) } ?? NSScreen.screens[0]
        let state = State(frame: frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), display: Self.display(screen), sidebar: sidebarShown,
                          scroll: sidebar.enclosingScrollView?.contentView.bounds.minY ?? 0, selected: selected?.name, shown: Array(shown),
                          lastTab: lastTab.mapValues(\.name), zoomed: zoomed, recent: recent, handover: handover,
                          fullScreen: window.styleMask.contains(.fullScreen), scrolled: surfaces.reduce(into: Self.saved?.scrolled ?? [:]) { $0[$1.key] = $1.value.scrolled }.filter { $0.value > 0 },
                          boot: Self.boot, kept: tabs.map { Tab(name: $0.name, group: $0.group, cwd: $0.folder, labels: $0.labels) },
                          resume: tabs.reduce(into: [:]) { ids, tab in if tab.claude != nil { ids[tab.name] = tab.session } }, sidebarWidth: sidebarWidth)
        try? FileManager.default.createDirectory(atPath: (Self.stateFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: URL(fileURLWithPath: Self.stateFile), options: .atomic)
    }

    private func saveSoon() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in if saving { save() } }
    }

    private static func display(_ screen: NSScreen) -> UInt32 { screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0 }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return false
    }

    @objc private func showWindow() {
        hidden = false
        window.makeKeyAndOrderFront(nil)
        menuBarIcon()
        if probe == nil { NSApp.activate() }
    }

    private func menuBarIcon() {
        guard hidden || updateWait?.isValid == false else {
            statusItem.map(NSStatusBar.system.removeStatusItem)
            statusItem = nil
            iconCount = nil
            if let probe { try? FileManager.default.removeItem(atPath: probe + "/menubar.png") }
            return
        }
        let waiting = tabs.filter { $0.claude == "waiting" }.count
        guard waiting != iconCount else { return }
        iconCount = waiting
        let text = NSMutableAttributedString(string: "✻_", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .kern: -1])
        if waiting > 0 { text.append(NSAttributedString(string: " \(waiting)", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .baselineOffset: 1])) }
        let image = NSImage(size: NSSize(width: ceil(text.size().width), height: ceil(text.size().height)), flipped: false) { _ in
            text.draw(at: .zero)
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
        var rows: [(item: NSMenuItem, detail: String)] = []
        let cap = { (text: String) in text.count > 40 ? text.prefix(39).trimmingCharacters(in: .whitespaces) + "…" : text }
        menuMarks = []
        let row = { (title: String, detail: String, action: Selector, target: String, claude: Bool, mark: String?) in
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = target
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
            for tab in waiting { row(tab.title, cap(tab.action.map { $0.ask ?? $0.text } ?? ""), #selector(pickTab), tab.name, true, "blocked") }
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: "Groups"))
        for group in groups {
            let groupTabs = tabs.filter { $0.group == group }
            let activity = activity(groupTabs)
            row(group, [activity.map { cap($0.what) }, activity?.ago, agents(groupTabs)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), #selector(pickGroup), group, activity != nil, groupTabs.lazy.compactMap(\.mark).first)
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
        menu.addItem(withTitle: "Show ClaudeTTY", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit ClaudeTTY", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let rows = groups.enumerated().compactMap { index, group in Self.digitKey(index, of: groups.count).flatMap { key in groupRows[group].map { ("⌘" + key, $0 as NSView, true) } } }
        let tabKeys = paneRows.enumerated().compactMap { index, row in Self.digitKey(index, of: paneRows.count).map { ("⌃" + $0, row as NSView, false) } }
        let targets = hintModifier == "⌃" ? tabKeys : buttons(root).map { ($0, $1, false) } + rows
        let topDown = targets.filter { !$0.1.isHiddenOrHasHiddenAncestor && !$0.1.visibleRect.isEmpty }.map { key, view, corner in
            let pill = KeyPill(key), slot = corner ? nil : (view as? Row)?.closeSlot, box = view.convert(slot ?? view.bounds, to: root)
            let bar = sequence(first: view, next: \.superview).first { $0 is PaneBar } ?? root
            pill.edge = bar.convert(bar.bounds, to: root).maxX - 2
            let y = slot != nil ? (view as! Row).nameBaseline - KeyPill.baseline : box.midY - pill.frame.height / 2
            pill.setFrameOrigin(corner ? NSPoint(x: box.maxX - 6 - pill.frame.width, y: box.maxY - 7 - pill.frame.height) : NSPoint(x: slot == nil ? box.midX - pill.frame.width / 2 : box.minX, y: y))
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
        guard let view = selected.flatMap({ surfaces[$0.name] }), view.cellSize.height > 0, !Body.unsnapped(sender, frameSize) else { return frameSize }
        func snap(_ proposed: CGFloat, _ now: CGFloat, _ surface: CGFloat, _ padding: CGFloat, _ cell: CGFloat) -> CGFloat {
            proposed - (surface + proposed - now - padding).truncatingRemainder(dividingBy: cell)
        }
        return NSSize(width: snap(frameSize.width, sender.frame.width, view.frame.width, 2 * Self.padding.width, view.cellSize.width),
                      height: snap(frameSize.height, sender.frame.height, (view.superview ?? view).frame.height, Self.padding.height, view.cellSize.height))
    }

    private func snap() {
        let size = windowWillResize(window, to: window.frame.size)
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        panes.values.forEach { $0.body.fit() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        app.map { ghostty_app_set_focus($0, true) }
        secure(true)
        if hidden { showWindow() }
        activityChanged()
    }

    func applicationDidResignActive(_ notification: Notification) {
        app.map { ghostty_app_set_focus($0, false) }
        secure(false)
        hideHints()
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
        appMenu.addItem(withTitle: "Secure Keyboard Entry", action: #selector(toggleSecure), keyEquivalent: "")
        appMenu.addItem(withTitle: "Bypass Permissions in New Claude Tabs", action: #selector(toggleBypass), keyEquivalent: "")
        appMenu.addItem(withTitle: "Simple Spinner", action: #selector(pickSpinner), keyEquivalent: "").representedObject = "simple"
        if Spark.morph != nil { appMenu.addItem(withTitle: "Sparkle Spinner", action: #selector(pickSpinner), keyEquivalent: "").representedObject = "sparkle" }
        let sounds = NSMenu(title: "Notification Sound")
        sounds.addItem(withTitle: "None", action: #selector(pickSound), keyEquivalent: "").representedObject = ""
        sounds.addItem(.separator())
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []).sorted() {
            sounds.addItem(withTitle: (file as NSString).deletingPathExtension, action: #selector(pickSound), keyEquivalent: "").representedObject = (file as NSString).deletingPathExtension
        }
        appMenu.addItem(withTitle: "Notification Sound", action: nil, keyEquivalent: "").submenu = sounds
        if Self.released { appMenu.addItem(withTitle: "Check for Updates", action: #selector(pickUpdate), keyEquivalent: "") }
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
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        let old = view.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        old.keyEquivalentModifierMask = [.control, .command]
        old.isHidden = true
        old.allowsKeyEquivalentWhenHidden = true
        view.addItem(withTitle: "Go to Tab…", action: #selector(goToTab), keyEquivalent: "p")
        view.addItem(withTitle: "Next Waiting Tab", action: #selector(nextWaiting), keyEquivalent: "U")
        view.addItem(withTitle: "Rename Group", action: #selector(renameSelected), keyEquivalent: "R")
        view.addItem(withTitle: "Show Pane Buttons", action: #selector(togglePaneButtons), keyEquivalent: "")
        view.addItem(withTitle: "Show Context Size", action: #selector(toggleContext), keyEquivalent: "")
        for (title, picks) in [("Cursor", [("Block", ["cursor-style": "block"]), ("Bar", ["cursor-style": "bar"]), ("Underline", ["cursor-style": "underline"]), ("Hollow Block", ["cursor-style": "block_hollow"]), ("", [:]), ("Blinking", ["cursor-style-blink": ""])]),
                               ("Background", [("Opaque", ["background-opacity": "1"]), ("90%", ["background-opacity": "0.9"]), ("80%", ["background-opacity": "0.8"]), ("70%", ["background-opacity": "0.7"]), ("", [:]), ("Blur", ["background-blur": "20"])]),
                               ("Padding", [("Small", ["window-padding-x": "1", "window-padding-y": "0,4"]), ("Medium", ["window-padding-x": "8", "window-padding-y": "4,8"]), ("Large", ["window-padding-x": "16", "window-padding-y": "8,16"])])] {
            let submenu = NSMenu(title: title)
            for (title, pick) in picks {
                guard !title.isEmpty else {
                    submenu.addItem(.separator())
                    continue
                }
                submenu.addItem(withTitle: title, action: #selector(pickLook), keyEquivalent: "").representedObject = pick
            }
            view.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
        }
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen), keyEquivalent: "f").keyEquivalentModifierMask = [.control, .command]
        let file = NSMenu(title: "File")
        for (title, action, key, modifiers) in [("New Terminal Tab", "new_tab", "t", [.command]), ("New Claude Tab", "claude", "t", [.command, .option]), ("Reopen Closed Tab", "reopen", "T", [.command]), ("New Group", "new_window", "n", [.command]), ("", "", "", []),
                                                ("Split Right", "new_split:right", "d", [.command]), ("Split Down", "new_split:down", "D", [.command]), ("Zoom Pane", "toggle_split_zoom", "\r", [.command, .shift]), ("", "", "", []),
                                                ("Close Tab", "close_surface", "w", [.command]), ("Close Group", "close_window", "W", [.command])] as [(String, String, String, NSEvent.ModifierFlags)] {
            guard !title.isEmpty else {
                file.addItem(.separator())
                continue
            }
            let item = file.addItem(withTitle: title, action: #selector(fileAction), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.representedObject = action
        }
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
        sidebar.alignment = .leading
        sidebar.spacing = 4
        tabBar.spacing = 2
        tabBar.alignment = .firstBaseline
        tabBar.appearance = NSAppearance(named: .darkAqua)
        let blank = Blank { [unowned self] in newGroup() }
        blank.addSubview(sidebar)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = blank
        side.addSubview(scroll)
        let fit = blank.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        fit.priority = .defaultLow - 1
        let buttons = NSStackView(views: [Self.iconButton(Self.symbol("sidebar.left"), "Sidebar", "Hide or show the sidebar (⌘B)", self, #selector(toggleSidebar)), Self.iconButton(Self.symbol("plus"), "New group", "New group (⌘N)", self, #selector(newGroup))])
        buttons.spacing = 12
        let lights = window.standardWindowButton(.zoomButton)!.frame.maxX
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
        titleButtons.spacing = 10
        titleButtons.appearance = tabBar.appearance
        titleHover.views = { [unowned self] in titleButtons.arrangedSubviews }
        for view in [side, tabBar, terminal, buttons, titleButtons, titleHover, edge] { root.addSubview(view) }
        for view in [side, scroll, blank, sidebar, tabBar, terminal, buttons, titleButtons, titleHover, edge] { view.translatesAutoresizingMaskIntoConstraints = false }
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
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: lights + 16),
            buttons.centerYAnchor.constraint(equalTo: root.topAnchor, constant: titlebar / 2),
            besideSidebar,
            tabBar.leadingAnchor.constraint(greaterThanOrEqualTo: buttons.trailingAnchor, constant: 16),
            tabBar.firstBaselineAnchor.constraint(equalTo: root.topAnchor, constant: titlebar / 2 + TitleButton.font.capHeight / 2),
            tabBar.trailingAnchor.constraint(lessThanOrEqualTo: titleButtons.leadingAnchor, constant: -12),
            titleButtons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            titleButtons.centerYAnchor.constraint(equalTo: root.topAnchor, constant: titlebar / 2),
            titleHover.topAnchor.constraint(equalTo: root.topAnchor),
            titleHover.heightAnchor.constraint(equalToConstant: titlebar),
            titleHover.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            titleHover.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminal.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            fill,
            terminal.topAnchor.constraint(equalTo: root.topAnchor, constant: titlebar / 2 + Self.paneBar / 2),
            terminal.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func select(_ tab: Tab) {
        let tab = tabs.first { $0 == tab } ?? tab
        focus(tab)
        rebuild()
        window.makeFirstResponder(surfaces[tab.name])
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

    private func arrange(_ layout: Layout) {
        guard let selected else { return }
        let zoom = zoomedPane(selected.group, in: layout)
        if arranged != selected.group + " " + layout.text + " " + (zoom ?? "") {
            arranged = selected.group + " " + layout.text + " " + (zoom ?? "")
            panes.values.forEach { $0.body.subviews.forEach(park) }
            panes = [:]
            terminal.subviews.filter { !($0 is SurfaceView) }.forEach { $0.removeFromSuperview() }
            let root = zoom.map { paneView(.pane($0), split: true) } ?? paneView(layout, split: layout.panes.count > 1)
            root.frame = terminal.bounds
            root.autoresizingMask = [.width, .height]
            terminal.addSubview(root)
            terminal.layoutSubtreeIfNeeded()
            even(root)
        }
        var now: Set<String> = []
        for (id, pane) in panes {
            let tab = shownTab(selected.group, id, in: layout)
            let view = surfaces[tab.name] ?? makeSurface(tab)
            if view.superview !== pane.body {
                pane.body.subviews.forEach(park)
                view.isHidden = false
                pane.body.addSubview(view)
                pane.body.fit()
            }
            now.insert(tab.name)
        }
        for name in placed.subtracting(now) { surfaces[name]?.setVisible(false) }
        for name in now.subtracting(placed) { surfaces[name]?.setVisible(drawing) }
        placed = now
        if window.firstResponder === window { window.makeFirstResponder(surfaces[selected.name]) }
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
        window.makeFirstResponder(surfaces[selected.name])
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let typing = (window.firstResponder as? NSText).map { !sequence(first: $0 as NSView, next: \.superview).contains { $0 is FindBar } } ?? false
        let asking = window.attachedSheet != nil || typing
        let groups = item.action == #selector(pickGroup) || item.action == #selector(pickTab)
        if item.action == #selector(toggleSecure) { item.state = UserDefaults.standard.bool(forKey: Self.secureKey) ? .on : .off }
        if item.action == #selector(pickSound) { item.state = item.representedObject as? String == UserDefaults.standard.string(forKey: Self.soundKey) ?? "Glass" ? .on : .off }
        if item.action == #selector(pickSpinner) { item.state = item.representedObject as? String == Spark.style ? .on : .off }
        if item.action == #selector(togglePaneButtons) { item.state = UserDefaults.standard.bool(forKey: Self.buttonsKey) ? .off : .on }
        if item.action == #selector(pickLook), let pick = item.representedObject as? [String: String] {
            item.state = pick.allSatisfy { Self.look[$0] == $1 } ? .on : .off
            if pick["background-blur"] != nil { return Self.look["background-opacity"] != "1" }
        }
        if item.action == #selector(toggleBypass) { item.state = UserDefaults.standard.bool(forKey: Self.askKey) ? .off : .on }
        if item.action == #selector(pickUpdate) {
            item.title = switch newer?.swap {
            case nil: "Check for Updates"
            case .running: "Updating to \(newer!.version)…"
            case .failed: "Update to \(newer!.version)…"
            case .ready: "Restart to Update"
            }
            return newer?.swap != .running
        }
        if item.action == #selector(toggleContext) { item.state = UserDefaults.standard.bool(forKey: Self.contextKey) ? .off : .on }
        if item.menu?.supermenu === NSApp.mainMenu, unseen && !groups || asking && (groups || item.action == #selector(fileAction) || item.action == #selector(goToTab)) { return false }
        if item.action == #selector(nextWaiting) { return longestWaiting != nil }
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
        bar.doubleClick = { [unowned self] in newTab(pane: id) }
        bar.spacing = 2
        bar.setHuggingPriority(.init(249), for: .horizontal)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
        bar.appearance = NSAppearance(named: .darkAqua)
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
        let labels = (["group=" + tab.group] + tab.labels.map { $0.key + "=" + $0.value }).joined(separator: " ")
        let command = (["env", "ZMX_NO_DETACH_KEY=1", Self.executable, "--attach", "--labels", labels, tab.name] + (commands[tab.name].map { $0.isEmpty ? [] : Self.attached + $0 } ?? []))
            .map(Self.quoted).joined(separator: " ")
        let view = SurfaceView(app: app!, command: command, cwd: tab.cwd)
        surfaces[tab.name] = view
        if let rows = Self.saved?.scrolled?[tab.name] { view.restore(rows) }
        view.onFocus = { [unowned self] in
            guard let tab = tabs.first(where: { $0.name == tab.name }), tab != selected else { return }
            focus(tab)
            rebuild()
        }
        view.onDrop = { [unowned self] in Self.dropTexts($0, claude: tabs.first { $0.name == tab.name }?.claude != nil) }
        view.frame = terminal.bounds
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        terminal.addSubview(view, positioned: .below, relativeTo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.redrawClaude(tab.name) }
        return view
    }

    private func newTab(pane: String? = nil, claude: Bool = false) {
        guard let selected else { return }
        zoomed[selected.group] = nil
        let pane = pane ?? self.pane(of: selected)
        let taken = Set(Self.list().compactMap { $0["name"] } + tabs.map(\.name))
        let name = (2...).lazy.map { selected.group + "-\($0)" }.first { !taken.contains($0) }!
        commands[name] = claude ? Self.claude(UserDefaults.standard.bool(forKey: Self.askKey) ? "" : "--dangerously-skip-permissions") : nil
        select(insertTab(name, in: pane, beside: selected, cwd: selected.folder))
    }

    private static let attached = ["sh", "-c", "i=0; until [ -n \"$(\"$0\" print-env \"$ZMX_SESSION\")\" ] || [ $i -ge 100 ]; do sleep 0.05; i=$((i+1)); done; exec \"$@\"", zmx]
    private static func claude(_ args: String) -> [String] { ["zsh", "-lic", "exec env BUN_OPTIONS=--smol claude " + args] }
    private static func quoted(_ word: String) -> String { "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static let boot: Int = {
        var time = timeval(), size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &time, &size, nil, 0)
        return time.tv_sec
    }()

    @discardableResult private func insertTab(_ name: String, in pane: String, beside from: Tab, cwd: String) -> Tab {
        var labels = tabs.first { $0.group == from.group }!.labels
        labels["pane"] = pane
        labels["title"] = nil
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
        return label(group, "split", layout.splitting(pane, with: new, across: across, before: before).text) ? new : nil
    }

    @objc private func fileAction(_ item: NSMenuItem) {
        guard let action = item.representedObject as? String else { return }
        if action == "reopen" { return reopenTab() }
        guard let surface = selected.flatMap({ surfaces[$0.name]?.surface }) else { return }
        if action == "claude" { return newTab(claude: true) }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @objc private func toggleSecure() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.secureKey), forKey: Self.secureKey)
        secure(NSApp.isActive)
    }

    @objc private func pickSound(_ item: NSMenuItem) {
        let sound = item.representedObject as? String ?? ""
        UserDefaults.standard.set(sound, forKey: Self.soundKey)
        NSSound(named: sound)?.play()
    }

    @objc private func pickSpinner(_ item: NSMenuItem) {
        Spark.style = item.state == .on ? "dots" : item.representedObject as? String ?? "dots"
        UserDefaults.standard.set(Spark.style, forKey: Spark.styleKey)
        rebuild()
        animate()
    }

    private func secure(_ active: Bool) {
        let on = active && UserDefaults.standard.bool(forKey: Self.secureKey)
        guard on != securing else { return }
        securing = on
        _ = on ? EnableSecureEventInput() : DisableSecureEventInput()
    }

    @objc private func toggleSort() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.sortKey), forKey: Self.sortKey)
        rebuild()
    }

    @objc private func togglePaneButtons() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.buttonsKey), forKey: Self.buttonsKey)
        rebuild()
    }

    @objc private func pickLook(_ item: NSMenuItem) {
        guard let app, var pick = item.representedObject as? [String: String] else { return }
        if pick.allSatisfy({ Self.look[$0] == $1 }), pick.keys.contains(where: { $0 == "cursor-style-blink" || $0 == "background-blur" }) { pick = pick.mapValues { $0.isEmpty ? "false" : "0" } }
        UserDefaults.standard.set((UserDefaults.standard.dictionary(forKey: Self.lookKey) ?? [:]).merging(pick) { $1 }, forKey: Self.lookKey)
        guard let config = Self.config() else { return }
        ghostty_app_update_config(app, config)
        ghostty_config_free(config)
        paint()
        snap()
    }

    @objc private func toggleBypass() { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.askKey), forKey: Self.askKey) }

    @objc private func toggleContext() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Self.contextKey), forKey: Self.contextKey)
        rebuild()
    }

    static func tokens(_ count: Int) -> String { count < 1000 ? "\(count)" : "\(Int((Double(count) / 1000).rounded()))k" }

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

    private func paneButtons(_ pane: String, shown: Bool) -> [NSView] {
        if UserDefaults.standard.bool(forKey: Self.buttonsKey) { return [] }
        return [(Self.clawd(nil), "New Claude tab", "New Claude tab (⌥⌘T)", Self.clawd(Spark.orange)), (Self.symbol("terminal"), "New terminal", "New terminal (⌘T)", nil), (Self.symbol("square.split.2x1"), "Split right", "Split right (⌘D)", nil), (Self.symbol("square.split.1x2"), "Split down", "Split down (⇧⌘D)", nil)].enumerated().map { index, button in
            let view = Self.iconButton(button.0, button.1, button.2, self, #selector(paneButton), size: 12, lit: button.3 ?? button.0)
            view.alphaValue = shown ? 1 : 0
            view.tag = index
            view.identifier = .init(pane)
            return view
        }
    }

    static func symbol(_ name: String) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: nil)! }

    static func iconButton(_ image: NSImage, _ label: String, _ tip: String, _ target: AnyObject, _ action: Selector, size: CGFloat = 13, lit: NSImage? = nil) -> NSButton {
        image.accessibilityDescription = label
        let button = lit.map { HoverButton(lit: $0, size: size) } ?? NSButton(image: image, target: target, action: action)
        button.image = image
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

    @objc private func newGroup() {
        let cwd = selected?.folder ?? NSHomeDirectory()
        let base = (cwd as NSString).lastPathComponent.replacingOccurrences(of: " ", with: "-")
        let name = Self.unused(base, takenNames())
        let tab = Tab(name: name, group: name, cwd: cwd, labels: ["named": "0"])
        tabs.append(tab)
        select(tab)
    }

    private func takenNames() -> Set<String> { Set(Self.list().compactMap { $0["name"] } + tabs.flatMap { [$0.name, $0.group] }) }

    private static func unused(_ base: String, _ taken: Set<String>) -> String { (1...).lazy.map { $0 == 1 ? base : base + "-\($0)" }.first { !taken.contains($0) }! }

    private func title(_ group: String) -> String { named(group) ? group : tabs.first { $0.group == group }!.title }

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

    private func select(group: String) { select(lastTab[group] ?? tabs.first { $0.group == group }!) }

    private var longestWaiting: Tab? {
        tabs.filter { $0 != selected && $0.claude == "waiting" }
            .map { ((try? FileManager.default.attributesOfItem(atPath: statusDir + "/" + $0.name))?[.modificationDate] as? Date ?? .distantFuture, $0) }
            .min { $0.0 < $1.0 }?.1
    }

    @objc private func nextWaiting() { longestWaiting.map(select) }

    @objc private func goToTab() {
        guard let selected else { return }
        let ranked = tabs.map { tab in (tab == selected ? Int.max : recent.firstIndex(of: tab.name) ?? Int.max - 1, tab) }.sorted { $0.0 < $1.0 }.map(\.1)
        let counts = Dictionary(tabs.map { ($0.group, 1) }, uniquingKeysWith: +)
        GoTo(ranked.map { tab in (tab, counts[tab.group]! > 1 ? "\(title(tab.group)) › \(tab.title)" : title(tab.group), place(tab.folder), colors.first { $0.name == tab.labels["color"] }?.color, tab.claude) }, in: terminal) { [unowned self] in select($0) }
    }

    @objc private func switchGroup(_ sender: NSButton) {
        let menu = NSMenu()
        for (index, group) in groups.enumerated() {
            let groupTabs = tabs.filter { $0.group == group }
            let item = groupItem(group, at: index, in: menu)
            item.view = GroupEntry(item, state: status(groupTabs).map { ([$0] + [agents(groupTabs)].compactMap { $0 }).joined(separator: " · ") }, place: place(groupTabs[0].folder),
                                   bar: colors.first { $0.name == groupTabs[0].labels["color"] }?.color)
        }
        let width = menu.items.compactMap { $0.view?.frame.width }.max() ?? 0
        for item in menu.items { item.view?.frame.size.width = width }
        popUp(menu, at: NSPoint(x: 0, y: sender.bounds.maxY + 6), in: sender)
    }

    @discardableResult private func groupItem(_ group: String, at index: Int, in menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title(group), action: #selector(pickGroup), keyEquivalent: Self.digitKey(index, of: groups.count) ?? "")
        item.target = self
        item.representedObject = group
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

    private var groups: [String] {
        let ranked = rankedGroups.map { ($0, folder($0)) }
        let folders = ranked.compactMap(\.1).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return ranked.filter { $0.1 == nil }.map(\.0) + folders.flatMap { name in ranked.filter { $0.1 == name }.map(\.0) }
    }

    private var rankedGroups: [String] {
        let firsts = tabs.reduce(into: [Tab]()) { found, tab in if !found.contains(where: { $0.group == tab.group }) { found.append(tab) } }
        var states: [String: Int] = [:]
        if UserDefaults.standard.bool(forKey: Self.sortKey) {
            for tab in tabs { states[tab.group] = min(states[tab.group] ?? 2, ["waiting": 0, "working": 1][tab.claude ?? ""] ?? 2) }
        }
        return firsts.map { ($0.labels["pinned"] == nil ? 1 : 0, states[$0.group] ?? 2, Int($0.labels["order"] ?? "") ?? .max, $0.group) }
            .sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }.map(\.3)
    }

    private func peers(_ group: String, folder sharing: Bool = true) -> [String] {
        let pinned = { (group: String) in self.tabs.first { $0.group == group }?.labels["pinned"] != nil }
        return groups.filter { pinned($0) == pinned(group) && (!sharing || folder($0) == folder(group)) }
    }

    private func folder(_ group: String) -> String? { tabs.first { $0.group == group }?.labels["folder"] }

    private func shown(_ group: String) -> Bool {
        guard let folder = folder(group), collapsed.contains(folder) else { return true }
        return group == selected?.group || tabs.contains { $0.group == group && $0.claude == "waiting" }
    }

    private var collapsed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.collapsedKey) }
    }

    private func rebuild() {
        guard let selected, !renaming, Row.lifted == nil else { return }
        rebuilds += 1
        fronts = front
        for tab in tabs where tab.claude != nil {
            guard let front = tab.pid.flatMap(foreground), claudeExits[front] == nil else { continue }
            let exit = DispatchSource.makeProcessSource(identifier: front, eventMask: .exit, queue: .main)
            exit.setEventHandler { [unowned self] in
                claudeExits.removeValue(forKey: front)?.cancel()
                rebuild()
            }
            exit.resume()
            claudeExits[front] = exit
        }
        activities = [:]
        tabSparks = [:]
        meters = [:]
        groupRows = [:]
        folderRows = [:]
        let closed = collapsed
        sidebar.setViews(groups.flatMap { group -> [NSView] in
            let folder = folder(group)
            let head = folder.flatMap { name in groups.first { self.folder($0) == name } == group ? folderRow(name, open: !closed.contains(name)) : nil }
            guard shown(group) else { return [head].compactMap { $0 } }
            let groupTabs = tabs.filter { $0.group == group }
            let pinned = groupTabs[0].labels["pinned"] != nil
            let sparks = activity(groupTabs).map { activity in
                let view = ActivityView(selected: group == selected.group, single: activity.sparks.count == 1, width: sidebarWidth - 36, open: { [unowned self] name in tabs.first { $0.name == name }.map(select) }) { [unowned self] in agentsMenu(groupTabs) }
                view.show(activity)
                activities[group] = view
                return view
            }
            let row = Row(title(group), icon: pinned ? NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned") : nil, activity: sparks, detail:place(groupTabs[0].folder), bar: colors.first { $0.name == groupTabs[0].labels["color"] }?.color, selected: group == selected.group, fill: .controlAccentColor,
                          close: { [unowned self] in closing(group: group) }) { [unowned self] in
                select(group: group)
            }
            row.contextMenu = { [unowned self] in groupMenu(group, pinned: pinned) }
            row.rename = { [unowned self] in rename(group) }
            row.lane = folder.flatMap(closed.contains) == true ? nil : (pinned ? "pinned" : "groups") + (folder.map { " in " + $0 } ?? "")
            row.dropped = { [unowned self] to in reorder(group, to: to) }
            groupRows[group] = row
            return [head, row].compactMap { $0 }
        }, in: .top)
        for row in sidebar.views { row.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true }
        for head in folderRows.values { sidebar.views.firstIndex(of: head).map { $0 > 0 ? sidebar.setCustomSpacing(10, after: sidebar.views[$0 - 1]) : () } }
        let folderIcon = NSWorkspace.shared.icon(forFile: selected.folder)
        window.title = title(selected.group)
        let named = named(selected.group) || tabs.count(where: { $0.group == selected.group }) > 1
        let title = TitleButton(title: window.title, target: self, action: #selector(switchGroup))
        title.image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in folderIcon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16)); return true }
        title.imagePosition = .imageLeading
        title.isBordered = false
        title.font = TitleButton.font
        title.contentTintColor = .labelColor
        title.toolTip = "Switch group (⌘1-9)"
        let layout = layout(selected.group), focused = pane(of: selected, in: layout)
        arrange(layout)
        let rows = { [unowned self] (pane: String) -> [NSView] in
            let paneTabs = tabs.filter { $0.group == selected.group && self.pane(of: $0, in: layout) == pane }
            let pick = shownTab(selected.group, pane, in: layout)
            if pane == focused { paneRows = [] }
            return paneTabs.map { tab in
                let lone = paneTabs.count == 1
                let spark = tab.claude.map { Spark($0, phase: 0, selected: false, mark: tab.mark) }
                tabSparks[tab.name] = spark
                let meter = tab.claude != nil && !UserDefaults.standard.bool(forKey: Self.contextKey) ? NSTextField(labelWithString: "") : nil
                meter.map { self.meter($0, tab) }
                meters[tab.name] = meter
                let row = Row(named ? tab.title : "", icon: tab.claude != nil || !named ? nil : NSImage(systemSymbolName: "apple.terminal.fill", accessibilityDescription: "Shell"), spark: spark, meter: meter, selected: lone || tab == pick, fill: lone ? .clear : pane == focused ? Row.pickFill : Row.hoverFill,
                              close: lone && layout.panes.count == 1 ? nil : { [unowned self] in closing([tab.name]) }) { [unowned self] in select(tab) }
                row.contextMenu = { [unowned self, unowned row] in tabMenu(tab, row, paneTabs.map(\.name), layout) }
                if pane == focused { paneRows.append(row) }
                row.rename = { [unowned self, unowned row] in rename(tab: tab.name, in: row) }
                row.lane = "tabs"
                row.dropped = { [unowned self] to in
                    reorder(tab.name, among: paneTabs.map(\.name), to: to)
                    rebuild()
                }
                row.carried = { [unowned self] point in carry(tab.name, to: point) }
                return row
            }
        }
        if layout.panes.count == 1 {
            let focusedRows = rows(focused)
            let chevron = BarIcon(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!)
            chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            chevron.contentTintColor = NSColor(white: 1, alpha: 0.4)
            tabBar.setViews([title] + (named ? [chevron] : []) + focusedRows, in: .leading)
            if named { tabBar.setCustomSpacing(focusedRows.count > 1 ? 6 : 2, after: chevron) }
            titleButtons.setViews(paneButtons(focused, shown: titleHover.inside), in: .leading)
        } else {
            tabBar.setViews([title], in: .leading)
            titleButtons.setViews([], in: .leading)
            for (id, pane) in panes {
                pane.bar?.setViews(rows(id), in: .leading)
                pane.bar.map { $0.setViews(paneButtons(id, shown: $0.hover.inside), in: .trailing) }
            }
        }
        tabBar.setCustomSpacing(6, after: title)
        animate()
        marks()
        lookAt()
        if hidden { menuBarIcon() }
        groupsMenu.removeAllItems()
        for (index, group) in groups.enumerated() { groupItem(group, at: index, in: groupsMenu) }
        groupsMenu.addItem(.separator())
        let paneTabs = tabs.filter { $0.group == selected.group && pane(of: $0, in: layout) == focused }
        for (index, tab) in paneTabs.enumerated() {
            let item = groupsMenu.addItem(withTitle: tab.title, action: #selector(pickTab), keyEquivalent: Self.digitKey(index, of: paneTabs.count) ?? "")
            item.keyEquivalentModifierMask = .control
            item.target = self
            item.representedObject = tab.name
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
        [(folder as NSString).abbreviatingWithTildeInPath, Self.branch(folder)].compactMap { $0 }.joined(separator: " · ")
    }

    private func status(_ groupTabs: [Tab]) -> String? {
        let states = groupTabs.map(\.claude)
        guard let state = (["waiting", "working", "idle"] as [String]).first(where: { states.contains($0) }) else { return nil }
        let names = zip(groupTabs, states).filter { $0.1 == state }.map(\.0.name)
        return groupTabs.count < 2 || state == "idle" ? state : state + " · " + names.joined(separator: ", ")
    }

    private func agents(_ groupTabs: [Tab]) -> String? {
        let count = groupTabs.flatMap(\.tasks).filter { $0[0] == "agent" }.count
        return count == 0 ? nil : count == 1 ? "1 agent" : "\(count) agents"
    }

    private func activity(_ groupTabs: [Tab]) -> Activity? {
        let claudes = groupTabs.compactMap { tab in tab.claude.map { (tab: tab, state: $0) } }
        guard !claudes.isEmpty else { return nil }
        let line = claudes.compactMap { tab, state in state == "idle" ? nil : tab.action.map { (who: tab.title, what: state == "waiting" ? $0.ask ?? $0.text : $0.text, ask: state == "waiting", at: $0.at) } }
            .filter { !$0.what.isEmpty }.max { ($0.ask ? 1 : 0, $0.ask ? $1.at : $0.at) < ($1.ask ? 1 : 0, $1.ask ? $0.at : $1.at) }
        let done = line == nil ? claudes.filter { $0.state == "idle" }.compactMap { tab, _ in reply(tab).map { (who: tab.title, what: $0.text, at: $0.at) } }.max { $0.at < $1.at } : nil
        return Activity(sparks: claudes.map { .init(name: $0.tab.name, title: $0.tab.title, state: $0.state, mark: $0.tab.mark) }, who: line?.who ?? done?.who ?? "", what: line?.what ?? done?.what ?? "", ask: line?.ask ?? false,
                        ago: done.map { Self.ago($0.at) } ?? "", agents: agents(groupTabs))
    }

    private func reply(_ tab: Tab) -> (text: String, at: Date)? {
        guard let path = tab.transcript, let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
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
            tabSparks[tab.name]?.kind = tab.claude ?? ""
            tabSparks[tab.name]?.mark = tab.mark
            meters[tab.name].map { meter($0, tab) }
        }
        animate()
    }

    private var front: [String] { tabs.map { ($0.claude == nil ? "" : "✻ ") + $0.folder } + groups + groups.filter(shown) }

    private func redraw(_ group: String) {
        activity(tabs.filter { $0.group == group }).map { activities[group]?.show($0) }
        for tab in tabs where tab.group == group {
            tabSparks[tab.name]?.kind = tab.claude ?? ""
            tabSparks[tab.name]?.mark = tab.mark
        }
    }

    private func watchTranscripts() {
        let paths = Dictionary(uniqueKeysWithValues: tabs.filter { $0.claude != nil }.compactMap { tab in tab.transcript.map { (tab.name, $0) } })
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
            }
            watch.setCancelHandler { Darwin.close(file) }
            watch.resume()
            transcripts[name] = (path, watch)
        }
    }

    private func animate() {
        let live = Spark.style == "simple" && drawing && (sidebarShown && activities.values.contains { $0.working } || tabSparks.values.contains { $0.kind == "working" })
        guard live != (spinner != nil) else { return }
        spinner?.invalidate()
        spinner = live ? Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [unowned self] _ in
            for view in activities.values { view.spin() }
            turn += 1
            for spark in tabSparks.values { spark.spin(turn) }
        } : nil
    }


    private func readNotices(fresh: Bool = true) {
        var read: [String: Notice] = [:]
        for tab in tabs {
            let path = statusDir + "/" + tab.name + ".notice"
            guard let at = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let old = notices[tab.name], old.at == at {
                read[tab.name] = old
            } else if fresh && (tab.labels["notify"] == "0" || tab == selected && !away) {
                try? FileManager.default.removeItem(atPath: path)
            } else {
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
        let title = tabs.first { $0.name == newest.key }?.title ?? newest.key
        let sound = UserDefaults.standard.string(forKey: Self.soundKey) ?? "Glass"
        if let probe {
            let posted = (try? String(contentsOfFile: probe + "/banner", encoding: .utf8)) ?? ""
            try? (posted + title + "\t" + newest.value.text + "\t" + sound + "\n").write(toFile: probe + "/banner", atomically: true, encoding: .utf8)
            return
        }
        NSSound(named: sound)?.play()
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = newest.value.text
            content.userInfo = ["tab": newest.key]
            center.add(UNNotificationRequest(identifier: newest.key, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let name = response.notification.request.content.userInfo["tab"] as? String
        DispatchQueue.main.async { [self] in
            tabs.first { $0.name == name }.map(select)
            showWindow()
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) { done(.banner) }

    private func marks() {
        NSApp.dockTile.badgeLabel = notices.isEmpty ? nil : String(notices.count)
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

    private func clear(_ name: String) {
        guard notices.removeValue(forKey: name) != nil else { return }
        try? FileManager.default.removeItem(atPath: statusDir + "/" + name + ".notice")
        withdraw([name])
        marks()
        lookAt()
    }

    private func withdraw(_ names: [String]) {
        if probe == nil, Bundle.main.bundleIdentifier != nil, !names.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: names) }
    }

    @objc private func mute(_ item: NSMenuItem) {
        let tab = item.representedObject as! Tab
        label(tab.group, "notify", tab.labels["notify"] == "0" ? "" : "0", tab: tab.name)
    }

    private func agentsMenu(_ groupTabs: [Tab]) -> NSMenu {
        let menu = NSMenu()
        let clock = Date.FormatStyle(date: .omitted, time: .shortened)
        let short = { (text: String) in text.count > 60 ? text.prefix(59).trimmingCharacters(in: .whitespaces) + "…" : text }
        let item = { [unowned self] (title: String, task: [String], tab: Tab, detail: String) in
            let item = menu.addItem(withTitle: short(title), action: #selector(openTask), keyEquivalent: "")
            item.target = self
            item.representedObject = (tab.name, task)
            item.toolTip = title
            item.subtitle = [Date(timeIntervalSince1970: Double(task[2]) ?? 0).formatted(clock), short(detail)].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        var shells: [(Tab, [String])] = []
        for tab in groupTabs {
            let tasks = tab.tasks
            shells += tasks.filter { $0[0] == "shell" }.map { (tab, $0) }
            let agents = tasks.filter { $0[0] == "agent" }
            guard !agents.isEmpty else { continue }
            menu.addItem(.sectionHeader(title: [tab.name, tab.context.map(Self.tokens)].compactMap { $0 }.joined(separator: " · ")))
            for agent in agents {
                let meta = Self.meta(agent)
                let quiet = (try? FileManager.default.attributesOfItem(atPath: agent[3])[.modificationDate] as? Date).map { -$0.timeIntervalSinceNow } ?? 0
                item([meta["agentType"] as? String, meta["description"] as? String ?? agent[1]].compactMap { $0 }.joined(separator: "  "), agent, tab, quiet < 60 ? "active" : "quiet \(Int(quiet / 60)) min")
            }
        }
        if !shells.isEmpty {
            menu.addItem(.sectionHeader(title: "shells"))
            for (tab, shell) in shells { item(shell[3], shell, tab, "") }
        }
        return menu
    }

    @objc private func openTask(_ item: NSMenuItem) {
        guard let (owner, task) = item.representedObject as? (String, [String]), let tab = tabs.first(where: { $0.name == owner }) else { return }
        let name = owner + "-" + task[1].prefix(8)
        if let open = tabs.first(where: { $0.name == name }) { return select(open) }
        guard let pane = newPane(beside: pane(of: tab), in: tab.group, across: true, before: false) else { return NSSound.beep() }
        commands[name] = task[0] == "agent" ? ["sh", "-c", "tail -n +1 -F \"$0\" | /usr/bin/jq --unbuffered -rR \"$1\"", task[3], Self.transcriptView]
            : ["sh", "-c", "f=$(ls /private/tmp/claude-$(id -u)/*/*/tasks/\"$0\".output 2>/dev/null | head -1); [ -n \"$f\" ] && exec tail -n +1 -F \"$f\"; echo No output yet.", task[1]]
        insertTab(name, in: pane, beside: tab, cwd: tab.folder)
        let index = tabs.firstIndex { $0.name == name }!
        tabs[index].labels["title"] = Self.oneWord(task[0] == "agent" ? Self.meta(task)["agentType"] as? String ?? "agent" : "shell")
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

    private func groupMenu(_ group: String, pinned: Bool) -> NSMenu {
        let menu = NSMenu()
        let pin = menu.addItem(withTitle: pinned ? "Unpin Group" : "Pin Group", action: #selector(setLabel), keyEquivalent: "")
        pin.target = self
        pin.representedObject = [group, "pinned", pinned ? "" : "1"]
        let rename = menu.addItem(withTitle: "Rename Group", action: #selector(renameGroup), keyEquivalent: "R")
        rename.target = self
        rename.representedObject = group
        let inFolder = folder(group), folders = groups.compactMap(folder).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let folderMenu = NSMenu()
        for (title, target) in folders.filter { $0 != inFolder }.map({ ($0, Optional($0)) }) + [("New Folder", nil)] + (inFolder == nil ? [] : [("Out of \(inFolder!)", Optional(""))]) {
            let item = folderMenu.addItem(withTitle: title, action: #selector(moveToFolder), keyEquivalent: "")
            item.target = self
            item.representedObject = (group, target)
        }
        menu.addItem(withTitle: "Move to Folder", action: nil, keyEquivalent: "").submenu = folderMenu
        menu.addItem(.separator())
        let current = tabs.first { $0.group == group }?.labels["color"]
        let circles = NSStackView(views: ([("none", nil)] + colors.map { ($0.name, Optional($0.color)) }).enumerated().map { index, choice in
            let button = NSButton(image: Self.dot(choice.1, ringed: current == (choice.1 == nil ? nil : choice.0)), target: self, action: #selector(pickColor))
            button.isBordered = false
            button.tag = index
            button.toolTip = choice.0.capitalized
            button.setAccessibilityLabel(choice.0.capitalized)
            return button
        })
        circles.spacing = 2
        circles.edgeInsets = NSEdgeInsets(top: 2, left: 13, bottom: 2, right: 14)
        circles.setFrameSize(circles.fittingSize)
        let colorItem = menu.addItem(withTitle: "Color", action: nil, keyEquivalent: "")
        colorItem.view = circles
        colorItem.representedObject = group
        menu.addItem(.separator())
        let sorting = UserDefaults.standard.bool(forKey: Self.sortKey)
        let order = peers(group)
        let index = order.firstIndex(of: group)!
        for (title, to) in [("Move Up", index - 1), ("Move Down", index + 1), ("Move to Top", 0)] {
            let item = menu.addItem(withTitle: title, action: sorting || to == index || !order.indices.contains(to) ? nil : #selector(move), keyEquivalent: "")
            item.target = self
            item.representedObject = (group, to)
        }
        let sort = menu.addItem(withTitle: "Sort by State", action: #selector(toggleSort), keyEquivalent: "")
        sort.target = self
        sort.state = sorting ? .on : .off
        let others = tabs.contains { $0.group != group && $0.labels["pinned"] == nil }
        for (title, action) in [("-", nil), ("Show in Finder", #selector(showInFinder)), ("-", nil), ("Close Group", #selector(closeGroup)), ("Close Other Groups", others ? #selector(closeOthers) : nil)] {
            let item = title == "-" ? NSMenuItem.separator() : NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = group
            menu.addItem(item)
        }
        return menu
    }

    private func folderRow(_ name: String, open: Bool) -> Row {
        let row = Row(name, icon: NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: open ? "Close folder" : "Open folder"), head: true, selected: false, fill: .clear) { [unowned self] in
            if open { collapsed.insert(name) } else { collapsed.remove(name) }
            rebuild()
        }
        row.contextMenu = { [unowned self] in
            let menu = NSMenu()
            for (title, action) in [("Rename Folder", #selector(renameFolder)), ("Remove Folder", #selector(removeFolder))] {
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = name
            }
            return menu
        }
        row.rename = { [unowned self] in rename(folder: name) }
        folderRows[name] = row
        return row
    }

    @objc private func moveToFolder(_ item: NSMenuItem) {
        let (group, target) = item.representedObject as! (String, String?)
        let name = target ?? Self.unused("Folder", Set(tabs.compactMap { $0.labels["folder"] }))
        label(group, "folder", name)
        rebuild()
        if target == nil { rename(folder: name) }
    }

    @objc private func renameFolder(_ item: NSMenuItem) { rename(folder: item.representedObject as! String) }

    @objc private func removeFolder(_ item: NSMenuItem) {
        let name = item.representedObject as! String
        for group in groups where folder(group) == name { label(group, "folder", "") }
        collapsed.remove(name)
        rebuild()
    }

    private func rename(folder name: String) {
        guard let row = folderRows[name] else { return }
        let taken = Set(tabs.compactMap { $0.labels["folder"] }).subtracting([name])
        renaming = true
        row.edit({ text in
            let typed = Self.oneWord(text)
            return typed.isEmpty ? "A folder needs a name." : taken.contains(typed) ? "Another folder is named \(typed)." : nil
        }) { [unowned self] text in
            renaming = false
            if let typed = text.map(Self.oneWord), typed != name {
                for group in groups where folder(group) == name { label(group, "folder", typed) }
                if collapsed.remove(name) != nil { collapsed.insert(typed) }
            }
            rebuild()
            window.makeFirstResponder(selected.flatMap { surfaces[$0.name] })
        }
    }

    @objc private func showInFinder(_ item: NSMenuItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tabs.first { $0.group == item.representedObject as! String }!.folder)])
    }

    @objc private func closeGroup(_ item: NSMenuItem) { closing(group: item.representedObject as! String) }

    @objc private func closeOthers(_ item: NSMenuItem) {
        closing(tabs.filter { $0.group != item.representedObject as! String && $0.labels["pinned"] == nil }.map(\.name), title: "Close other groups?", ask: true)
    }

    @objc private func move(_ item: NSMenuItem) {
        let (group, to) = item.representedObject as! (String, Int)
        reorder(group, to: to)
    }

    private func reorder(_ group: String, to: Int) {
        var lane = peers(group).filter { $0 != group }
        lane.insert(group, at: to)
        var next = lane.makeIterator()
        let order = peers(group, folder: false).map { folder($0) == folder(group) ? next.next()! : $0 }
        for (index, peer) in order.enumerated() where tabs.first(where: { $0.group == peer })?.labels["order"] != String(index) { label(peer, "order", String(index)) }
        rebuild()
    }

    private func reorder(_ name: String, among paneTabs: [String], to: Int) {
        var order = paneTabs.filter { $0 != name }
        order.insert(name, at: to)
        let old = Dictionary(uniqueKeysWithValues: tabs.map { ($0.name, $0) })
        var next = order.makeIterator()
        tabs = tabs.map { paneTabs.contains($0.name) ? old[next.next()!]! : $0 }
        let group = old[name]!.group
        for (index, tab) in tabs.filter({ $0.group == group }).enumerated() where tab.labels["rank"] != String(index) { label(group, "rank", String(index), tab: tab.name) }
    }

    private func tabMenu(_ tab: Tab, _ row: Row, _ paneTabs: [String], _ layout: Layout) -> NSMenu {
        let menu = NSMenu()
        let add = { (title: String, action: Selector?, object: Any?) in
            let item = title == "-" ? NSMenuItem.separator() : NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = object
            menu.addItem(item)
        }
        add("Rename Tab", #selector(renameTab), (tab.name, row))
        if tab.labels["title"] != nil { add("Remove Custom Tab Name", #selector(retitle), tab.name) }
        add(tab.labels["notify"] == "0" ? "Unmute Notifications" : "Mute Notifications", #selector(mute), tab)
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
        for (index, (title, step)) in moves.enumerated() where zoomedPane(tab.group, in: layout) == nil && ids.contains(where: { neighbor($0, step, in: ids) != nil }) {
            if index == 0 || index == 2 { add("-", nil, nil) }
            let to = neighbor(from, step, in: ids)
            add(title, to == nil ? nil : #selector(moveTab), (tab.name, to ?? ""))
        }
        return menu
    }

    @objc private func renameTab(_ item: NSMenuItem) {
        let (name, row) = item.representedObject as! (String, Row)
        rename(tab: name, in: row)
    }

    private func rename(tab name: String, in row: Row) {
        renaming = true
        row.edit({ _ in nil }) { [unowned self] text in
            renaming = false
            if let text, let tab = tabs.first(where: { $0.name == name }) {
                let title = Self.oneWord(text)
                if !label(tab.group, "title", title == name ? "" : title, tab: name) { NSSound.beep() }
            }
            rebuild()
            window.makeFirstResponder(selected.flatMap { surfaces[$0.name] })
        }
    }

    @objc private func retitle(_ item: NSMenuItem) {
        let name = item.representedObject as! String
        _ = tabs.first { $0.name == name }.map { label($0.group, "title", "", tab: name) }
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

    private func carry(_ name: String, to point: NSPoint) -> Bool {
        guard let tab = tabs.first(where: { $0.name == name }), let scroll = sidebar.enclosingScrollView else { return false }
        let under = { (view: NSView) in !view.isHiddenOrHasHiddenAncestor && view.bounds.contains(view.convert(point, from: nil)) }
        if case let (pane, bar)? = panes.lazy.compactMap({ id, pane in pane.bar.flatMap { under($0) ? (id, $0) : nil } }).first {
            guard pane != self.pane(of: tab) else { return false }
            guard label(tab.group, "pane", pane, tab: name) else { NSSound.beep(); return false }
            let layout = layout(tab.group), left = bar.arrangedSubviews.filter { $0 is Row && $0.convert(NSPoint(x: $0.bounds.midX, y: 0), to: nil).x < point.x }.count
            reorder(name, among: tabs.filter { $0.group == tab.group && self.pane(of: $0, in: layout) == pane }.map(\.name), to: left)
            select(tabs.first { $0 == tab }!)
            return true
        }
        guard under(scroll) else { return false }
        if let group = groupRows.first(where: { under($0.value) })?.key { return group != tab.group && regroup(name, to: group) }
        guard tabs.contains(where: { $0.group == tab.group && $0 != tab }) else { return false }
        return regroup(name, to: Self.unused(name, takenNames().subtracting([name]).union(groups)))
    }

    private func regroup(_ name: String, to group: String) -> Bool {
        let tab = tabs.first { $0.name == name }!, source = tab.group, target = tabs.first { $0.group == group }
        var wanted = (target?.labels ?? ["named": "0"]).filter { ["color", "pinned", "order", "split", "named", "folder"].contains($0.key) }
        wanted["pane"] = target.map { pane(of: tabs.first { $0 == lastTab[group] } ?? $0) }
        wanted["title"] = tab.labels["title"]
        guard label(source, "group", group, tab: name) else { NSSound.beep(); return false }
        for key in Set(wanted.keys).union(tab.labels.keys) where wanted[key] != tab.labels[key] && !label(group, key, wanted[key] ?? "", tab: name) { NSSound.beep() }
        let index = tabs.firstIndex(of: tab)!
        let moved = tabs.remove(at: index)
        if let next = tabs.firstIndex(where: { $0.group == source }), next > index { tabs.insert(tabs.remove(at: next), at: index) }
        tabs.insert(moved, at: (tabs.lastIndex { $0.group == group } ?? tabs.count - 1) + 1)
        lastTab = lastTab.filter { $0.value.name != name }
        select(moved)
        return true
    }

    @objc private func pickColor(_ sender: NSButton) {
        let item = sender.enclosingMenuItem!
        item.menu?.cancelTracking()
        label(item.representedObject as! String, "color", sender.tag == 0 ? "" : colors[sender.tag - 1].name)
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
        let label = item.representedObject as! [String]
        self.label(label[0], label[1], label[2])
        rebuild()
    }

    @discardableResult private func label(_ group: String, _ key: String, _ value: String, tab: String? = nil) -> Bool {
        var all = true
        for index in tabs.indices where tabs[index].group == group && (tab == nil || tabs[index].name == tab) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: zmx)
            process.arguments = ["set", tabs[index].name, key + "=" + value]
            guard let done = Self.launch(process) else { all = false; continue }
            done.wait()
            guard process.terminationStatus == 0 else { all = false; continue }
            if key == "group" { tabs[index].group = value } else { tabs[index].labels[key] = value.isEmpty ? nil : value }
        }
        return all
    }

    private static func oneWord(_ text: String) -> String { text.split { $0.isWhitespace || $0 == "=" }.joined(separator: "-") }

    @objc private func renameGroup(_ item: NSMenuItem) { rename(item.representedObject as! String) }

    @objc private func renameSelected() {
        guard let selected else { return }
        if !sidebarShown { toggleSidebar() }
        rename(selected.group)
    }

    private func rename(_ group: String) {
        guard let row = groupRows[group] else { return }
        let shown = title(group)
        renaming = true
        row.edit({ [unowned self] text in
            let name = Self.oneWord(text)
            return name.isEmpty ? "A group needs a name." : name != group && groups.contains(name) ? "Another group is named \(name)." : nil
        }) { [unowned self] text in
            renaming = false
            if let name = text.map(Self.oneWord), text != shown, name != group {
                if !label(group, "group", name) { label(name, "group", group) } else { label(name, "named", "1") }
                selected = selected.flatMap { old in tabs.first { $0.name == old.name } }
                lastTab = Dictionary(lastTab.values.compactMap { old in tabs.first { $0.name == old.name } }.map { ($0.group, $0) }, uniquingKeysWith: { first, _ in first })
            }
            rebuild()
            window.makeFirstResponder(selected.flatMap { surfaces[$0.name] })
        }
    }

    private static func branch(_ path: String) -> String? {
        var dir = URL(fileURLWithPath: path)
        while dir.path != "/" {
            let git = dir.appending(path: ".git")
            let pointer = try? String(contentsOf: git, encoding: .utf8)
            let headPath = pointer.map { String($0.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespacesAndNewlines) + "/HEAD" } ?? git.appending(path: "HEAD").path
            if let head = try? String(contentsOfFile: headPath, encoding: .utf8) {
                return head.hasPrefix("ref: refs/heads/") ? String(head.dropFirst(16)).trimmingCharacters(in: .whitespacesAndNewlines) : nil
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    private func closing(_ names: [String], title: String = "Close tab?", ask: Bool = false) {
        let sessions = Self.list().filter { names.contains($0["name"] ?? "") && $0["pid"] != nil }
        let end = { [unowned self] in
            closedTabs = Array((closedTabs + sessions.compactMap(closedTab)).suffix(10))
            for session in sessions { _ = try? Process.run(URL(fileURLWithPath: zmx), arguments: ["kill", session["name"]!]) }
            names.sorted { _, last in last == selected?.name }.forEach(closed)
        }
        let doomed = names.compactMap { name in sessions.first { $0["name"] == name } }.compactMap { session -> (tab: String, jobs: [Job])? in
            let tab = tabs.first { $0.name == session["name"] }
            let jobs = Self.jobs(session, tab)
            return jobs.isEmpty ? nil : (tab?.title ?? session["name"]!, jobs)
        }
        guard !doomed.isEmpty || ask else { return end() }
        confirm(doomed.count == 1 && title == "Close tab?" ? "Close \u{201C}\(doomed[0].tab)\u{201D}?" : title, Self.doomedList(doomed), "Close") { if $0 { end() } }
    }

    private func confirm(_ message: String, _ accessory: NSView, _ action: String, then: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.accessoryView = accessory
        for (title, key) in [(action, "↩"), ("Cancel", "⎋")] {
            let button = alert.addButton(withTitle: title)
            let color = key == "↩" ? NSColor.alternateSelectedControlTextColor : .controlTextColor
            let label = NSMutableAttributedString(string: title + "  ", attributes: [.font: button.font!, .foregroundColor: color])
            label.append(NSAttributedString(string: key, attributes: [.font: button.font!, .foregroundColor: color.withAlphaComponent(0.55)]))
            button.attributedTitle = label
        }
        alert.buttons[1].keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { then($0 == .alertFirstButtonReturn) }
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
        if tab.claude != nil, let session = tab.session, let front = tab.pid.flatMap(foreground) { return (kept, index, Self.claude(Self.flags(Self.arguments(front)) + " --resume " + session), nil) }
        if tab.labels["replay"] == nil, let command = commands[name] { return (kept, index, command, nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = ["history", name, "--vt"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard let done = Self.launch(process) else { return (kept, index, nil, nil) }
        let history = pipe.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return (kept, index, nil, history.lastIndex(of: 10).map { history.prefix(through: $0) })
    }

    private static func flags(_ argv: [String]) -> String {
        let switches: Set = ["--dangerously-skip-permissions", "--verbose", "--ide", "--strict-mcp-config", "--chrome", "--fork-session"]
        var kept: [String] = [], index = 1
        while index < argv.count {
            let word = argv[index]
            index += 1
            if ["--resume", "-r", "--session-id"].contains(word) {
                if index < argv.count, !argv[index].hasPrefix("-") { index += 1 }
                continue
            }
            let value = kept.last.map { $0.hasPrefix("-") && !$0.contains("=") && !switches.contains($0) } ?? false
            guard word.hasPrefix("-") ? !["--continue", "-c"].contains(word) && !word.hasPrefix("--resume=") && !word.hasPrefix("--session-id=") : value else { continue }
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
            for key in ["color", "pinned", "order", "split", "named"] { tab.labels[key] = peer.labels[key] }
            if !layout.panes.contains(old.labels["pane"] ?? "") { tab.labels["pane"] = pane(of: peer, in: layout) }
        } else {
            tab.labels["split"] = nil
            tab.labels["pane"] = nil
        }
        tab.labels["replay"] = history.map { _ in "1" }
        commands[name] = history.map { history in
            let path = NSTemporaryDirectory() + "claudetty-" + UUID().uuidString
            FileManager.default.createFile(atPath: path, contents: history)
            return ["sh", "-c", "cat \"$0\"; rm -f \"$0\"; exec \"$SHELL\" -l", path]
        } ?? command
        tabs.insert(tab, at: min(index, tabs.count))
        for (rank, peer) in tabs.filter({ $0.group == tab.group }).enumerated() where peer.labels["rank"] != String(rank) {
            if peer == tab { tabs[tabs.firstIndex(of: tab)!].labels["rank"] = String(rank) } else { label(tab.group, "rank", String(rank), tab: peer.name) }
        }
        select(tab)
    }

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

    private static func info(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 { return info }
        var process = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size, mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &process, &size, nil, 0) == 0, size > 0 else { return nil }
        (info.pbi_pid, info.pbi_ppid, info.pbi_pgid, info.pbi_start_tvsec) = (UInt32(pid), UInt32(process.kp_eproc.e_ppid), UInt32(process.kp_eproc.e_pgid), UInt64(process.kp_proc.p_starttime.tv_sec))
        info.pbi_comm = withUnsafeBytes(of: process.kp_proc.p_comm) { $0.load(as: type(of: info.pbi_comm)) }
        return info
    }

    private static func children(_ pid: Int32) -> [Int32] {
        var pids = [Int32](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids, Int32(pids.count * 4))
        return Array(pids.prefix(Int(max(bytes, 0)) / 4))
    }

    static func meta(_ agent: [String]) -> [String: Any] {
        (try? Data(contentsOf: URL(fileURLWithPath: String(agent[3].dropLast(5)) + "meta.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private static func arguments(_ pid: Int32, launcher: Bool = false) -> [String] {
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

    private func closed(_ name: String) {
        guard let tab = tabs.first(where: { $0.name == name }) else { return }
        clear(name)
        try? FileManager.default.removeItem(atPath: statusDir + "/" + name + ".topic")
        let index = groups.firstIndex(of: selected?.group ?? "") ?? 0
        let pane = pane(of: tab)
        surfaces.removeValue(forKey: name)?.removeFromSuperview()
        tabs.removeAll { $0.name == name }
        lastTab = lastTab.filter { $0.value.name != name }
        shown.remove(name)
        guard !tabs.isEmpty else { return NSApp.terminate(nil) }
        guard let group = selected?.group, selected?.name == name else { return rebuild() }
        if let sibling = tabs.first(where: { $0.group == group && self.pane(of: $0) == pane }) { return select(sibling) }
        select(group: groups.contains(group) ? group : groups[min(index, groups.count - 1)])
    }

    private static func sessions() -> [Tab] {
        let found = list().compactMap { fields -> (Int, Tab)? in
            guard let name = fields["name"], let group = fields["group"] else { return nil }
            return (Int(fields["created"] ?? "") ?? 0, Tab(name: name, group: group, cwd: URL(string: fields["cwd"] ?? "")?.path ?? NSHomeDirectory(), labels: fields.filter { ["color", "pinned", "order", "split", "pane", "title", "rank", "notify", "named", "replay"].contains($0.key) }, pid: fields["pid"].flatMap(Int32.init), topic: try? String(contentsOfFile: statusDir + "/" + name + ".topic", encoding: .utf8)))
        }.sorted { $0.0 < $1.0 }.map(\.1)
        let first = Dictionary(found.enumerated().map { ($1.group, $0) }, uniquingKeysWith: { first, _ in first })
        return found.map { (first[$0.group]!, Int($0.labels["rank"] ?? "") ?? .max, $0) }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    private static func redrawClaude(_ name: String) {
        guard let pid = list().first(where: { $0["name"] == name })?["pid"].flatMap(Int32.init), isClaude(pid) else { return }
        _ = try? Process.run(URL(fileURLWithPath: zmx), arguments: ["send", name, "\u{0c}"])
    }

    private static func launch(_ process: Process) -> DispatchSemaphore? {
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        return (try? process.run()) == nil ? nil : done
    }

    private static func list() -> [[String: String]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zmx)
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard let done = launch(process) else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        done.wait()
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
        let view = target.tag == GHOSTTY_TARGET_SURFACE ? Self.view(ghostty_surface_userdata(target.target.surface)) : nil
        switch action.tag {
        case GHOSTTY_ACTION_CELL_SIZE:
            let backing = NSSize(width: Double(action.action.cell_size.width), height: Double(action.action.cell_size.height))
            view?.cellSize = view?.convertFromBacking(backing) ?? .zero
            if view != nil, view === selected.flatMap({ surfaces[$0.name] }) { snap() }
        case GHOSTTY_ACTION_OPEN_URL:
            open(String(decoding: UnsafeRawBufferPointer(start: action.action.open_url.url, count: Int(action.action.open_url.len)), as: UTF8.self), from: view)
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = action.action.desktop_notification
            let parts = [note.title, note.body].compactMap { $0.map { String(cString: $0) } }.filter { !$0.isEmpty }
            guard parts.first != "Claude Code" else { return true }
            let text = parts.joined(separator: ": ")
            guard let name = tabs.first(where: { surfaces[$0.name] === view })?.name, !text.isEmpty else { return false }
            try? text.write(toFile: statusDir + "/" + name + ".notice", atomically: true, encoding: .utf8)
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            (action.action.mouse_shape == GHOSTTY_MOUSE_SHAPE_POINTER ? NSCursor.pointingHand : action.action.mouse_shape == GHOSTTY_MOUSE_SHAPE_TEXT ? .iBeam : .arrow).set()
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
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
            (view.find ?? FindBar(view)).open(action.action.start_search.needle.map { String(cString: $0) })
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
            if let name = name(view), let tab = tabs.first(where: { $0.name == name }), let topic = action.action.set_title.title.flatMap({ Self.topic(String(cString: $0)) }), topic != tab.topic ?? "", tab.claude != nil {
                let path = statusDir + "/" + name + ".topic"
                _ = topic.isEmpty ? try? FileManager.default.removeItem(atPath: path) : try? topic.write(toFile: path, atomically: true, encoding: .utf8)
                tabs[tabs.firstIndex(of: tab)!].topic = topic.isEmpty ? nil : topic
                rebuild()
            }
        default:
            return false
        }
        return true
    }

    private func open(_ link: String, from view: SurfaceView?) {
        let start = URL(fileURLWithPath: tabs.first { surfaces[$0.name] === view }?.folder ?? NSHomeDirectory(), isDirectory: true)
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
        url = url ?? Self.links.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)).flatMap { $0.range.length == link.utf16.count ? $0.url : nil }
        guard var url else { return }
        var xed: [String]?
        if let line, let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            if Bundle(url: app)?.bundleIdentifier == "com.apple.dt.Xcode" { xed = ["--line", String(line.row), url.path] }
            else if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil { url = URL(string: "vscode://file")!.appending(path: url.path + ":\(line.row):\(line.column)") }
        }
        if let probe { return try! (link + " → " + (xed.map { "xed " + $0.joined(separator: " ") } ?? url.absoluteString)).write(toFile: probe + "/opened", atomically: true, encoding: .utf8) }
        if let xed {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/xed"), arguments: xed)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
    private static let links = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
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

    private static func readClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> ghostty_clipboard_read_result_e {
        guard let surface = view(userdata)?.surface, let pasteboard = pasteboard(location) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        guard let text = pasteText(pasteboard) else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, text, state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    private func pasting(_ text: String, _ view: SurfaceView, _ state: UnsafeMutableRawPointer?) {
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

    private static func complete(_ surface: ghostty_surface_t, _ text: String, _ state: UnsafeMutableRawPointer?, confirmed: Bool) {
        let bytes = Array(text.utf8)
        "text/plain".withCString { mime in
            bytes.withUnsafeBufferPointer { buffer in
                buffer.withMemoryRebound(to: CChar.self) { data in
                    withUnsafePointer(to: ghostty_clipboard_content_s(mime: mime, data: data.baseAddress, len: data.count)) { content in
                        var complete = ghostty_clipboard_complete_s(contents: content, contents_len: 1, available: nil, available_len: 0, confirmed: confirmed, remember: false)
                        ghostty_surface_complete_clipboard_request(surface, &complete, state)
                    }
                }
            }
        }
    }

    private static func writeClipboard(_ location: ghostty_clipboard_e, _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int) {
        guard let pasteboard = pasteboard(location), let content else { return }
        let items = (0..<count).compactMap { index -> (NSPasteboard.PasteboardType, Data)? in
            let item = content[index]
            guard let mime = item.mime.map({ String(cString: $0) }), let type = NSPasteboard.PasteboardType(mimeType: mime), let data = item.data else { return nil }
            return (type, Data(bytes: data, count: item.len))
        }
        guard !items.isEmpty else { return }
        pasteboard.declareTypes(items.map(\.0), owner: nil)
        for (type, data) in items {
            pasteboard.setData(data, forType: type)
        }
    }
}

extension NSPasteboard.PasteboardType {
    init?(mimeType: String) {
        switch mimeType {
        case "text/plain": self = .string
        case "text/html": self = .html
        case "image/png": self = .png
        default: return nil
        }
    }
}

final class Window: NSWindow {
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        fit()
    }
    func fit() {
        let unsnapped = window.map { Self.unsnapped($0, $0.frame.size) } ?? false
        for case let view as SurfaceView in subviews {
            let left = unsnapped && view.cellSize.height > 0 ? (bounds.height - ClaudeTTY.padding.height).truncatingRemainder(dividingBy: view.cellSize.height) : 0
            view.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + (left > 0.5 ? view.cellSize.height - left : 0))
        }
    }
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
    override var dividerColor: NSColor { NSColor(white: 1, alpha: 0.12) }
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

    private let box = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        box.cornerRadius = 5
        layer?.addSublayer(box)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        box.frame = CGRect(x: -4, y: -2, width: bounds.width + 8, height: bounds.height + 5)
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
    private let doubleClick: () -> Void
    init(doubleClick: @escaping () -> Void) {
        self.doubleClick = doubleClick
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { doubleClick() } }
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

struct Job {
    let name: String
    let detail: String
    let since: Date
    var claudes = false
}

final class PaneBar: NSStackView {
    let hover = BarHover()
    var doubleClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        hover.views = { [unowned self] in views(in: .trailing) }
        hover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hover)
        NSLayoutConstraint.activate([hover.topAnchor.constraint(equalTo: topAnchor), hover.bottomAnchor.constraint(equalTo: bottomAnchor), hover.leadingAnchor.constraint(equalTo: leadingAnchor), hover.trailingAnchor.constraint(equalTo: trailingAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { doubleClick?() } }
}

final class BarHover: NSView {
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
            for view in views() { view.animator().alphaValue = shown ? 1 : 0 }
        }
    }
}

final class LinkButton: NSButton {
    var ink: (rest: NSColor, hover: NSColor) = (.secondaryLabelColor, .labelColor) { didSet { style() } }
    private var lit = false
    var text = "" { didSet { style() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { light(true) }
    override func mouseExited(with event: NSEvent) { light(false) }
    override func mouseMoved(with event: NSEvent) { if !lit { light(true) } }

    private func light(_ on: Bool) {
        lit = on
        style()
    }

    private func style() {
        let color = lit ? ink.hover : ink.rest
        attributedTitle = NSAttributedString(string: text, attributes: [.font: font ?? .systemFont(ofSize: 10), .foregroundColor: color, .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: color.withAlphaComponent(lit ? 1 : 0.4)])
    }
}

final class HoverButton: NSButton {
    private let glow = Ghost()
    private var lit = false

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
    override func mouseEntered(with event: NSEvent) { light(true) }
    override func mouseExited(with event: NSEvent) { light(false) }
    override func mouseMoved(with event: NSEvent) { if !lit { light(true) } }

    private func light(_ on: Bool) {
        lit = on
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            glow.animator().alphaValue = on ? 1 : 0
        }
    }
}

final class FindBar: NSView, NSTextFieldDelegate {
    private unowned let surface: SurfaceView
    private let field = NSTextField()
    private let count = NSTextField(labelWithString: "")
    private let well = NSView()
    private var pending: DispatchWorkItem?
    var total: Int? { didSet { counted() } }
    var selected: Int? { didSet { counted() } }

    init(_ surface: SurfaceView) {
        self.surface = surface
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        well.wantsLayer = true
        well.layer?.cornerRadius = 6
        field.placeholderString = "Find"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.isScrollable = true
        field.delegate = self
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
        surface.addSubview(self)
        surface.find = self
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 38), well.widthAnchor.constraint(equalToConstant: 230), well.heightAnchor.constraint(equalToConstant: 26),
            field.leadingAnchor.constraint(equalTo: well.leadingAnchor, constant: 8), field.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            count.trailingAnchor.constraint(equalTo: well.trailingAnchor, constant: -8), count.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            topAnchor.constraint(equalTo: surface.topAnchor, constant: 8), trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8),
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
        let window = window
        if window?.firstResponder.flatMap({ ($0 as? NSView)?.isDescendant(of: self) }) == true { window?.makeFirstResponder(surface) }
        surface.find = nil
        removeFromSuperview()
    }

    private func binding(_ action: String) { surface.surface.map { _ = ghostty_surface_binding_action($0, action, UInt(action.utf8.count)) } }

    private func counted() { count.stringValue = total.map { "\(selected.map { String($0 + 1) } ?? "-")/\($0)" } ?? "" }

    private func search() {
        pending?.cancel()
        let needle = field.stringValue
        let send = DispatchWorkItem { [weak self] in self?.binding("search:" + needle) }
        pending = send
        DispatchQueue.main.asyncAfter(deadline: .now() + (needle.isEmpty || needle.count >= 3 ? 0 : 0.3), execute: send)
    }

    func controlTextDidChange(_ notification: Notification) { search() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline):
            binding(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? "navigate_search:previous" : "navigate_search:next")
        case #selector(NSResponder.cancelOperation):
            guard field.stringValue.isEmpty else { return window?.makeFirstResponder(surface) ?? true }
            binding("end_search")
        default:
            return false
        }
        return true
    }

    @objc private func press(_ button: NSButton) { binding(button.identifier!.rawValue) }
}

final class GoTo: NSView, NSTextFieldDelegate {
    typealias Entry = (tab: Tab, title: String, place: String, bar: NSColor?, claude: String?)
    private let entries: [Entry]
    private let pick: (Tab) -> Void
    private let field = NSTextField()
    private let list = NSStackView()
    private weak var back: NSResponder?
    private var shown: [Entry] = []
    private var index = 0

    @discardableResult init(_ entries: [Entry], in host: NSView, pick: @escaping (Tab) -> Void) {
        self.entries = entries
        self.pick = pick
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        let well = NSView()
        well.wantsLayer = true
        well.layer?.cornerRadius = 6
        well.layer?.backgroundColor = NSColor(white: 1, alpha: 0.1).cgColor
        field.placeholderString = "Go to tab"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.isScrollable = true
        field.delegate = self
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
        let texts = entries.map { "\($0.title) \($0.tab.title) \($0.place)".lowercased().filter { !$0.isWhitespace } }
        let ordered = { (text: String) in
            var rest = Substring(text)
            return needle.allSatisfy { letter in rest.firstIndex(of: letter).map { rest = rest[rest.index(after: $0)...] } != nil }
        }
        let kinds = zip(entries, texts).map { entry, text in (text.contains(needle) ? 0 : ordered(text) ? 1 : 2, entry) }
        shown = Array(kinds.filter { $0.0 < 2 }.sorted { $0.0 < $1.0 }.map(\.1).prefix(8))
        index = 0
        draw()
    }

    private func draw() {
        list.setViews(shown.enumerated().map { offset, entry in
            Row(entry.title, icon: entry.claude == nil ? NSImage(systemSymbolName: "apple.terminal.fill", accessibilityDescription: "Shell") : nil, spark: entry.claude.map { Spark($0, phase: 0, selected: offset == index, mark: entry.tab.mark) },
                detail: entry.place, bar: entry.bar, selected: offset == index, fill: .controlAccentColor) { [unowned self] in choose(entry.tab) }
        }, in: .top)
        for row in list.views { row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        list.isHidden = shown.isEmpty
    }

    private func choose(_ tab: Tab) {
        removeFromSuperview()
        pick(tab)
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
            if index < shown.count { choose(shown[index].tab) }
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

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let menu = item.menu else { return }
        menu.cancelTracking()
        menu.performActionForItem(at: menu.index(of: item))
    }
}

final class Row: NSView, NSTextFieldDelegate {
    static let tabFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let hoverFill = NSColor(white: 1, alpha: 0.09)
    static let pickFill = NSColor(white: 1, alpha: 0.12)
    private var hoverable = false
    private let action: () -> Void
    private let close: (() -> Void)?
    private var hoverButton: NSButton?
    private var hovered = false
    var contextMenu: (() -> NSMenu)?
    var rename: (() -> Void)?
    var lane: String?
    var dropped: ((Int) -> Void)?
    var carried: ((NSPoint) -> Bool)?
    static var lifted: Row?
    var ghost: NSImageView?
    private let titleLabel: NSTextField
    private let detail: String?
    private var detailLabel: NSTextField?
    private var problem: ((String) -> String?)?
    private var renamed: ((String?) -> Void)?
    private var typedWidth: NSLayoutConstraint?
    private weak var tabClose: NSButton?
    var closeSlot: NSRect? {
        guard detail == nil else { return nil }
        let name = convert(titleLabel.frame, from: titleLabel.superview)
        return tabClose.map { convert($0.frame, from: $0.superview) } ?? NSRect(x: name.maxX + 5, y: name.minY, width: 10, height: name.height)
    }
    var nameBaseline: CGFloat {
        titleLabel.convert(NSPoint(x: 0, y: titleLabel.isFlipped ? titleLabel.firstBaselineOffsetFromTop : titleLabel.bounds.height - titleLabel.firstBaselineOffsetFromTop), to: nil).y
    }

    init(_ title: String, icon: NSImage? = nil, spark: Spark? = nil, meter: NSTextField? = nil, activity: ActivityView? = nil, detail: String? = nil, bar: NSColor? = nil, head: Bool = false, selected: Bool, fill: NSColor, close: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.action = action
        self.close = close
        titleLabel = NSTextField(labelWithString: title)
        self.detail = detail
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilitySelected(selected)
        wantsLayer = true
        layer?.cornerRadius = detail == nil ? 5 : 8
        layer?.backgroundColor = selected ? fill.cgColor : nil
        titleLabel.font = head ? .systemFont(ofSize: 11, weight: .semibold) : detail == nil ? Self.tabFont : .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = selected || detail != nil ? .labelColor : .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        if detail != nil { titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let name = NSStackView(views: [titleLabel] + [meter].compactMap { $0 })
        name.alignment = .firstBaseline
        name.spacing = 5
        name.setHuggingPriority(.defaultHigh, for: .horizontal)
        let titleLine = NSStackView(views: [name])
        titleLine.spacing = 5
        if let icon {
            let iconView = NSImageView(image: icon)
            iconView.symbolConfiguration = .init(pointSize: head ? 8 : 11, weight: head ? .bold : .regular)
            iconView.contentTintColor = selected && detail == nil ? .labelColor : .secondaryLabelColor
            head ? titleLine.addView(iconView, in: .leading) : titleLine.insertView(iconView, at: 0, in: .leading)
            if head { titleLine.spacing = 4 }
        }
        if let spark { titleLine.insertView(spark, at: 0, in: .leading) }
        meter?.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        meter?.textColor = .tertiaryLabelColor
        let isGroup = detail != nil
        let closeButton = close.map { _ in NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: isGroup ? "Close group" : "Close tab")!, target: self, action: #selector(closeTab)) }
        if let closeButton {
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
        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            detailLabel.textColor = selected ? NSColor(white: 1, alpha: 0.8) : .secondaryLabelColor
            detailLabel.lineBreakMode = .byTruncatingHead
            detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labels.append(detailLabel)
            self.detailLabel = detailLabel
        }
        let stack = NSStackView(views: labels)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        if let activity, activity.single {
            titleLine.addView(activity.sparks, in: .leading)
            titleLine.setCustomSpacing(4, after: name)
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
        detailLabel?.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12).isActive = true
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
        hoverable = !selected && !isGroup
        if isGroup || hoverable { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)) }
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

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let rename else {
            let stack = superview as? NSStackView, index = stack?.arrangedSubviews.firstIndex(of: self)
            action()
            return (index.flatMap { stack?.arrangedSubviews[$0] } as? Row)?.drag(from: event) ?? ()
        }
        rename()
    }

    private func drag(from down: NSEvent) {
        guard let lane, let stack = superview as? NSStackView, let window, let root = window.contentView else { return }
        let rows = stack.arrangedSubviews.filter { ($0 as? Row)?.lane == lane }
        guard rows.count > 1 || carried != nil else { return }
        root.layoutSubtreeIfNeeded()
        let vertical = stack.orientation == .vertical
        let along = { (point: NSPoint) in vertical ? -point.y : point.x }
        let across = { (point: NSPoint) in vertical ? point.x : point.y }
        let centre = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        let middles = rows.map { along($0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil)) }, from = rows.firstIndex(of: self)!, first = stack.arrangedSubviews.firstIndex(of: rows[0])!
        let start = along(down.locationInWindow), slide = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
        let half = (vertical ? bounds.height : bounds.width) / 2
        let band = { (past: Double) in half * past / (past + half * 3) }
        let origin = along(stack.convert(NSPoint.zero, to: nil))
        var place = from, point = down.locationInWindow, out = false
        var over: Row?
        var tick: Date?
        while true {
            let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: tick ?? .distantFuture, inMode: .eventTracking, dequeue: true)
            point = event?.locationInWindow ?? point
            guard event?.type != .leftMouseUp else { break }
            let drift = along(stack.convert(NSPoint.zero, to: nil)) - origin
            let wanted = middles[from] + along(point) - drift - start
            guard ghost != nil || abs(wanted - middles[from]) > 3 || carried != nil && abs(across(point) - across(down.locationInWindow)) > 3 else { continue }
            if ghost == nil, superview !== stack {
                let twin = { (row: NSView) in (row as? Row).map { $0.lane == lane && $0.titleLabel.stringValue == self.titleLabel.stringValue } ?? false }
                let successors = stack.arrangedSubviews.filter(twin), nth = rows.filter(twin).firstIndex(of: self)!
                return (successors.indices.contains(nth) ? successors[nth] as? Row : nil)?.drag(from: down) ?? ()
            }
            if ghost == nil, let snapshot = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: snapshot)
                ghost = Ghost(image: NSImage(cgImage: snapshot.cgImage!, size: bounds.size))
                ghost!.wantsLayer = true
                ghost!.layer?.backgroundColor = NSColor.black.cgColor
                ghost!.layer?.cornerRadius = layer!.cornerRadius
                stack.addSubview(ghost!)
                alphaValue = 0
                Row.lifted = self
            }
            let under = carried == nil ? nil : root.superview.flatMap { root.hitTest($0.convert(point, from: nil)) }
            let otherBar = under.flatMap { sequence(first: $0, next: \.superview).first { $0 is PaneBar } }.map { $0 !== stack } ?? false
            out = carried != nil && (abs(across(point) - across(centre)) > (vertical ? bounds.width : bounds.height) || otherBar)
            if ghost!.superview !== (out ? root : stack) { (out ? root : stack).addSubview(ghost!) }
            if out {
                let at = root.convert(NSPoint(x: centre.x + point.x - down.locationInWindow.x, y: centre.y + point.y - down.locationInWindow.y), from: nil)
                ghost!.frame = NSRect(x: at.x - bounds.width / 2, y: at.y - bounds.height / 2, width: bounds.width, height: bounds.height)
            } else {
                let at = wanted < middles[0] ? middles[0] - band(middles[0] - wanted) : wanted > middles.last! ? middles.last! + band(wanted - middles.last!) : wanted
                let now = middles.indices.filter { $0 != from && middles[$0] < at }.count
                if now != place {
                    place = now
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = slide
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        context.allowsImplicitAnimation = true
                        stack.insertArrangedSubview(self, at: first + place)
                        stack.layoutSubtreeIfNeeded()
                    }
                }
                let point = stack.convert(vertical ? NSPoint(x: centre.x, y: -(at + drift)) : NSPoint(x: at + drift, y: centre.y), from: nil)
                ghost!.frame = NSRect(x: point.x - bounds.width / 2, y: point.y - bounds.height / 2, width: bounds.width, height: bounds.height)
            }
            let target = (out ? under : nil).flatMap { sequence(first: $0, next: \.superview).lazy.compactMap { $0 as? Row }.first { $0.detail != nil && !$0.isAccessibilitySelected() } }
            if target !== over {
                over?.layer?.borderWidth = 0
                target?.layer?.borderWidth = 2
                target?.layer?.borderColor = NSColor.controlAccentColor.cgColor
                over = target
            }
            if tick.map({ $0 <= Date() }) ?? true { tick = (out ? under : stack)?.enclosingScrollView.map { Self.autoscroll($0, at: point) } == true ? Date() + 1.0 / 60 : nil }
        }
        over?.layer?.borderWidth = 0
        guard let ghost else { return }
        if out {
            Row.lifted = nil
            if carried?(point) == true { return ghost.removeFromSuperview() }
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
    }

    private static func autoscroll(_ scroll: NSScrollView, at point: NSPoint) -> Bool {
        let clip = scroll.contentView, height = clip.bounds.height
        let y = clip.convert(point, from: nil).y - clip.bounds.minY
        let depth = y < 44 ? y - 44 : y > height - 44 ? y - (height - 44) : 0
        guard depth != 0 else { return false }
        let top = min(max(clip.bounds.minY + (2 + 10 * min(1, abs(depth) / 44)) * (depth < 0 ? -1 : 1), 0), (scroll.documentView?.frame.height ?? 0) - height)
        guard top != clip.bounds.minY else { return false }
        clip.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(clip)
        return true
    }

    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { close?() } }

    func edit(_ problem: @escaping (String) -> String?, done: @escaping (String?) -> Void) {
        self.problem = problem
        renamed = done
        titleLabel.isEditable = true
        titleLabel.delegate = self
        if detail != nil {
            titleLabel.trailingAnchor.constraint(equalTo: hoverButton?.leadingAnchor ?? trailingAnchor, constant: -4).isActive = true
        } else {
            typedWidth = titleLabel.widthAnchor.constraint(equalToConstant: 0)
            typedWidth?.isActive = true
            fitTyped()
        }
        window?.makeFirstResponder(titleLabel)
    }

    func controlTextDidChange(_ obj: Notification) {
        detailLabel?.stringValue = problem?(titleLabel.stringValue) ?? detail ?? ""
        fitTyped()
    }

    private func fitTyped() { typedWidth?.constant = ceil((titleLabel.stringValue as NSString).size(withAttributes: [.font: titleLabel.font!]).width) + 6 }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(cancelOperation): finish(nil)
        case #selector(insertNewline): problem?(titleLabel.stringValue) == nil ? finish(titleLabel.stringValue) : NSSound.beep()
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) { finish(problem?(titleLabel.stringValue) == nil ? titleLabel.stringValue : nil) }

    private func finish(_ name: String?) {
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
        }
    }

    @objc private func closeTab() { close?() }

}

struct Activity: Equatable {
    struct Cell: Equatable { let name, title, state: String, mark: String? }
    var sparks: [Cell]
    var who, what: String
    var ask: Bool
    var ago: String
    var agents: String?
}

func dark(_ hex: Int, light: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1) : light }
}

final class ActivityView: NSStackView {
    let sparks = NSStackView()
    let single: Bool
    private let count = LinkButton(title: "", target: nil, action: #selector(showAgents))
    private let line = NSTextField(labelWithString: "")
    private let ago = NSTextField(labelWithString: "")
    private let selected: Bool
    private let width: CGFloat
    private let open: (String) -> Void
    private let agentsMenu: () -> NSMenu
    private var shown: Activity?
    private var turn = 0
    var working: Bool { sparks.views.contains { ($0 as? Spark)?.kind == "working" } }

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
        sparks.spacing = 3
        sparks.heightAnchor.constraint(equalToConstant: 14).isActive = true
        line.font = .systemFont(ofSize: 11)
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        ago.font = .systemFont(ofSize: 9.5)
        ago.textColor = selected ? NSColor(white: 1, alpha: 0.6) : dark(0x6e6e73, light: .tertiaryLabelColor)
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

    func show(_ activity: Activity) {
        guard activity != shown else { return }
        if activity.sparks.map(\.name) != shown?.sparks.map(\.name) || activity.agents != shown?.agents {
            count.text = activity.agents ?? ""
            let room = Int((width - (activity.agents == nil ? 0 : count.fittingSize.width + 3) + 3) / 16)
            let fit = activity.sparks.count <= room ? activity.sparks[...] : activity.sparks.prefix(room - 1)
            let cells = fit.enumerated().map { index, cell in
                let spark = Spark(cell.state, phase: [0, 2, 3][index % 3], selected: selected)
                spark.target = self
                spark.action = #selector(openTab)
                spark.identifier = .init(cell.name)
                return spark
            }
            let more = fit.count < activity.sparks.count ? [Spark("more", phase: 0, selected: selected, glyph: "+\(activity.sparks.count - fit.count)")] : []
            more.first?.setAccessibilityLabel("\(activity.sparks.count - fit.count) more")
            sparks.setViews(cells + more + (activity.agents == nil ? [] : [count]), in: .leading)
        }
        for case (let spark as Spark, let cell) in zip(sparks.views, activity.sparks) where spark.action != nil {
            spark.kind = cell.state
            spark.mark = cell.mark
            spark.toolTip = cell.title
            spark.setAccessibilityLabel([cell.title, cell.state].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        shown = activity
        line.superview?.isHidden = activity.who.isEmpty
        ago.stringValue = activity.ago
        ago.isHidden = activity.ago.isEmpty
        isHidden = single && activity.who.isEmpty
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: activity.who + ": ", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: selected ? .white : dark(0xe8e8ea, light: .labelColor), .paragraphStyle: oneLine])
        let whatAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: selected ? activity.ask ? .white : dark(0xe6eeff, light: .white) : activity.ask ? Spark.orange : dark(0x98989d, light: .secondaryLabelColor), .paragraphStyle: oneLine]
        let full = text.size().width
        text.append(NSAttributedString(string: activity.what, attributes: whatAttributes))
        line.attributedStringValue = text
        let room = width - (line.fittingSize.width - text.size().width) - (ago.isHidden ? 0 : ago.fittingSize.width + 4)
        if text.size().width > room, !activity.what.isEmpty {
            let what = Array(activity.what)
            var low = 0, high = what.count
            while low < high {
                let mid = (low + high + 1) / 2
                if full + NSAttributedString(string: String(what[..<mid]) + "…", attributes: whatAttributes).size().width <= room { low = mid } else { high = mid - 1 }
            }
            text.replaceCharacters(in: NSRange(location: text.length - activity.what.utf16.count, length: activity.what.utf16.count), with: NSAttributedString(string: String(what[..<low]).trimmingCharacters(in: .whitespaces) + "…", attributes: whatAttributes))
            line.attributedStringValue = text
        }
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
    static let styleKey = "spinner " + zmxDir
    static var style = UserDefaults.standard.string(forKey: styleKey) ?? "dots"
    var kind: String {
        didSet {
            guard kind != oldValue else { return }
            glyph = kind == "working" ? Self.frames[phase] : "✻"
            refresh()
        }
    }
    var mark: String? { didSet { if mark != oldValue { refresh() } } }
    private var dots: Marks?
    var shown: String { dots == nil ? glyph : mark ?? "" }
    private let phase: Int
    private let selected: Bool
    private(set) var glyph: String

    init(_ kind: String, phase: Int, selected: Bool, mark: String? = nil, glyph: String? = nil) {
        self.kind = kind
        self.mark = mark
        self.phase = phase
        self.selected = selected
        self.glyph = glyph ?? (kind == "working" ? Self.frames[phase] : "✻")
        super.init(frame: .zero)
        title = ""
        isBordered = false
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func refresh() {
        needsDisplay = true
        guard let mark, Self.style == "dots" || Self.style == "sparkle" && Self.morph == nil else {
            if dots != nil { layer?.sublayers = nil }
            dots = nil
            return morphing()
        }
        if dots == nil {
            let dots = Marks(selected: selected, phase: phase)
            wantsLayer = true
            dots.layer.frame = NSRect(origin: .zero, size: intrinsicContentSize)
            layer?.sublayers = [dots.layer]
            self.dots = dots
        }
        dots?.show(mark)
    }

    private func morphing() {
        guard let morph = Self.morph, Self.style == "sparkle" else { return }
        guard kind == "working" else {
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
        ink.backgroundColor = (selected ? NSColor.white : Self.orange).cgColor
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
            var row = superview
            while let view = row, !(view is Row) { row = view.superview }
            return row?.mouseDown(with: event) ?? ()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let (fill, ink, size): (NSColor?, NSColor, CGFloat) = switch kind {
        case "working": (nil, selected ? .white : Self.orange, 12)
        case "waiting": (selected ? .white : Self.orange, selected ? .controlAccentColor : .white, 10)
        case "more": (selected ? NSColor(white: 1, alpha: 0.3) : dark(0x4a4a4f, light: .tertiaryLabelColor), selected ? .white : dark(0xe6e6ea, light: .white), 7.5)
        default: (nil, selected ? dark(0xc8d9fc, light: .white) : dark(0x8a8a90, light: .tertiaryLabelColor), 12)
        }
        guard dots == nil else { return }
        if let fill {
            fill.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        guard kind != "working" || Self.morph == nil || Self.style != "sparkle" else { return }
        let text = NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: size, weight: kind == "more" ? .semibold : .regular), .foregroundColor: ink])
        let box = text.boundingRect(with: bounds.size, options: .usesDeviceMetrics)
        text.draw(with: NSRect(x: bounds.midX - box.midX, y: bounds.midY - box.midY, width: bounds.width, height: bounds.height))
    }

    func spin(_ turn: Int) {
        guard kind == "working", dots == nil else { return }
        glyph = Self.frames[(turn + phase) % Self.frames.count]
        needsDisplay = true
    }
}

@discardableResult func popUp(_ menu: NSMenu, at point: NSPoint, in view: NSView) -> Bool {
    guard let probe else { return menu.popUp(positioning: nil, at: point, in: view) }
    let anchor = view.convert(point, to: nil)
    menu.update()
    let lines = ["at \(Int(anchor.x)) \(Int(anchor.y))"] + menu.items.map { item in
        if item.isSeparatorItem { return "-" }
        if let view = item.view, !view.subviews.isEmpty { return view.subviews.map { "button " + ($0.accessibilityLabel() ?? "") }.joined(separator: "\n") }
        return item.title + (item.keyEquivalent.isEmpty ? "" : " ⌘" + item.keyEquivalent) + (item.state == .on ? " ✓" : "") + (item.isEnabled ? "" : " (off)") + (item.subtitle.map { " [\($0)]" } ?? "") + (item.submenu.map { " ▸ " + $0.items.map(\.title).joined(separator: ", ") } ?? "")
    }
    try? lines.joined(separator: "\n").write(toFile: probe + "/menu", atomically: true, encoding: .utf8)
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
