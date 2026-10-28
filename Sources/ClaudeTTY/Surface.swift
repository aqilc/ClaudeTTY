// MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.
import AppKit
import Carbon
import GhosttyKit

final class SurfaceView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var leadSurrogate: UTF16Char?
    private var lastPerformKeyEvent: TimeInterval?
    private var suppressNextLeftMouseUp = false
    private var eventMonitor: Any?
    private(set) var focused = false
    var onFocus: (() -> Void)?
    var cellSize: CGSize = .zero
    var edge: (color: NSColor, explicit: Bool)?
    var find: FindBar?
    var onDrop: ((NSPasteboard) -> [String])?
    var tabItems: (() -> (claude: Bool, brief: String?, items: [NSMenuItem]))?
    private(set) var scrolled: UInt64 = 0
    private var restoring = false
    private var settle: DispatchWorkItem?

    init(app: ghostty_app_t, command: String, cwd: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            return event.type == .keyUp ? self.localKeyUp(event) : self.localLeftMouseDown(event)
        }
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_TAB
        surface = command.withCString { cmd in
            cwd.withCString { dir in
                config.command = cmd
                config.working_directory = dir
                return ghostty_surface_new(app, &config)
            }
        }
        surface.map { ghostty_surface_set_focus($0, false) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self))
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let surface { ghostty_surface_free(surface) }
    }

    func restore(_ rows: UInt64) {
        scrolled = rows
        restoring = true
    }

    func scrollbar(_ bar: ghostty_action_scrollbar_s) {
        let history = bar.total - bar.len
        guard restoring else { return scrolled = history - bar.offset }
        settle?.cancel()
        guard history >= scrolled else { return }
        settle = DispatchWorkItem { [unowned self] in
            restoring = false
            binding("scroll_to_row:\(history - scrolled)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: settle!)
    }

    func setVisible(_ visible: Bool) { surface.map { ghostty_surface_set_occlusion($0, visible) } }


    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.contentsGravity = .topLeft
        guard let surface else { return }
        let scaled = convertToBacking(newSize)
        ghostty_surface_set_size(surface, UInt32(scaled.width), UInt32(scaled.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if layer?.contentsScale != window.backingScaleFactor { layer?.contentsGravity = .resize }
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface else { return }
        let backing = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, backing.width / frame.width, backing.height / frame.height)
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            focusDidChange(true)
            onFocus?()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusDidChange(false) }
        return result
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { focusDidChange(false) }
        super.viewWillMove(toWindow: newWindow)
    }

    func focusDidChange(_ focused: Bool) {
        guard let surface, self.focused != focused else { return }
        self.focused = focused
        if !focused { suppressNextLeftMouseUp = false }
        ghostty_surface_set_focus(surface, focused)
    }


    private func localLeftMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window == window,
              let location = window.contentView?.convert(event.locationInWindow, from: nil),
              window.contentView?.hitTest(location) == self else { return event }
        suppressNextLeftMouseUp = false
        guard window.firstResponder !== self else { return event }
        window.makeFirstResponder(self)
        if NSApp.isActive && window.isKeyWindow {
            suppressNextLeftMouseUp = true
            return nil
        }
        return event
    }

    private func localKeyUp(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command), focused else { return event }
        keyUp(with: event)
        return nil
    }


    private func mouseButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) -> Bool {
        guard let surface else { return false }
        mouseMoved(with: event)
        return ghostty_surface_mouse_button(surface, state, button, ghosttyMods(event.modifierFlags))
    }

    private static let buttons = [GHOSTTY_MOUSE_LEFT, GHOSTTY_MOUSE_RIGHT, GHOSTTY_MOUSE_MIDDLE, GHOSTTY_MOUSE_EIGHT, GHOSTTY_MOUSE_NINE, GHOSTTY_MOUSE_SIX, GHOSTTY_MOUSE_SEVEN, GHOSTTY_MOUSE_FOUR, GHOSTTY_MOUSE_FIVE, GHOSTTY_MOUSE_TEN, GHOSTTY_MOUSE_ELEVEN]
    private static func button(_ number: Int) -> ghostty_input_mouse_button_e { buttons.indices.contains(number) ? buttons[number] : GHOSTTY_MOUSE_UNKNOWN }

    override func mouseDown(with event: NSEvent) { _ = mouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event) }

    override func mouseUp(with event: NSEvent) {
        if suppressNextLeftMouseUp {
            suppressNextLeftMouseUp = false
            return
        }
        _ = mouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }

    override func otherMouseDown(with event: NSEvent) { _ = mouseButton(GHOSTTY_MOUSE_PRESS, Self.button(event.buttonNumber), event) }
    override func otherMouseUp(with event: NSEvent) { _ = mouseButton(GHOSTTY_MOUSE_RELEASE, Self.button(event.buttonNumber), event) }

    override func rightMouseDown(with event: NSEvent) {
        if tabItems?().claude == true || !mouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event), let menu = menu(for: event) { popUp(menu, at: convert(event.locationInWindow, from: nil), in: self) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if tabItems?().claude != true, !mouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseUp(with: event) }
    }

    private func sendMousePos(_ x: Double, _ y: Double, _ event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, x, y, ghosttyMods(event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if NSEvent.pressedMouseButtons != 0 { return }
        NSCursor.arrow.set()
        sendMousePos(-1, -1, event)
    }

    override func mouseMoved(with event: NSEvent) {
        let pos = convert(event.locationInWindow, from: nil)
        sendMousePos(pos.x, frame.height - pos.y, event)
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        mouseMoved(with: event)
        let precise = event.hasPreciseScrollingDeltas
        let factor = precise ? 2.0 : 1.0
        let momentum = Int32(Self.phases.firstIndex(of: event.momentumPhase).map { $0 + 1 } ?? 0)
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX * factor, event.scrollingDeltaY * factor, (precise ? 1 : 0) | momentum << 1)
    }

    private static let phases: [NSEvent.Phase] = [.began, .stationary, .changed, .ended, .cancelled, .mayBegin]

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }


    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        let translationModsGhostty = eventModifierFlags(ghostty_surface_key_translation_mods(surface, ghosttyMods(event.modifierFlags)))
        let translationMods = event.modifierFlags.subtracting([.shift, .control, .option, .command]).union(translationModsGhostty)
        let translationEvent = translationMods == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        let keyboardIdBefore = markedTextBefore ? nil : Self.keyboardLayoutId
        lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])
        if !markedTextBefore && keyboardIdBefore != Self.keyboardLayoutId { return }
        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if markedTextBefore, let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.suppressComposingControl(text, composing: composing) {
                _ = committedText(action, text)
            }
            if Self.replaysCommittedPreeditKey(translationEvent) {
                _ = keyAction(action, event: event, translationEvent: translationEvent)
            }
            return
        }
        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.suppressComposingControl(text, composing: composing) {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            if Self.suppressComposingControl(event.characters, composing: composing) { return }
            _ = keyAction(action, event: event, translationEvent: translationEvent, text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) { _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }
        var keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        let isBinding = (event.characters ?? "").withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
        if isBinding {
            if flags.rawValue & (GHOSTTY_BINDING_FLAGS_ALL.rawValue | GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) == 0, flags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue != 0,
               NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
            keyDown(with: event)
            return true
        }
        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            if !event.modifierFlags.contains(.control) { return false }
            equivalent = "\r"
        case "/":
            if !event.modifierFlags.contains(.control) || !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent, last == event.timestamp {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
                break
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }
        guard let finalEvent = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: finalEvent)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }
        var action = GHOSTTY_ACTION_RELEASE
        if ghosttyMods(event.modifierFlags).rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed = switch event.keyCode {
            case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = keyAction(action, event: event)
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil, text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var keyEvent = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing
        guard let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F else {
            return ghostty_surface_key(surface, keyEvent)
        }
        return text.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    private func committedText(_ action: ghostty_input_action_e, _ text: String) -> Bool {
        guard let surface else { return false }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    private static func replaysCommittedPreeditKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 0x7D, 0x7C, 0x7E: true
        case 0x7B: !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
        default: false
        }
    }

    private static func suppressComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20
    }

    private static var keyboardLayoutId: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return unsafeBitCast(pointer, to: CFString.self) as String
    }


    func binding(_ action: String) { surface.map { _ = ghostty_surface_binding_action($0, action, UInt(action.utf8.count)) } }

    @IBAction func copy(_ sender: Any?) { binding("copy_to_clipboard") }
    @IBAction func paste(_ sender: Any?) { binding("paste_from_clipboard") }
    @IBAction override func selectAll(_ sender: Any?) { binding("select_all") }
    @objc private func menuAction(_ item: NSMenuItem) { binding(item.representedObject as! String) }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let tab = tabItems?()
        if let brief = tab?.brief { menu.addItem(.sectionHeader(title: brief)) }
        for (title, action) in [("Copy", "copy_to_clipboard"), ("Paste", "paste_from_clipboard"), ("", ""), ("Split Right", "new_split:right"), ("Split Down", "new_split:down"), ("", ""), ("Find…", "start_search")] where tab?.claude != true || title != "Copy" {
            guard !title.isEmpty else {
                menu.addItem(.separator())
                continue
            }
            let item = menu.addItem(withTitle: title, action: #selector(menuAction), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            item.isEnabled = action != "copy_to_clipboard" || surface.map(ghostty_surface_has_selection) == true
        }
        if let items = tab?.items, !items.isEmpty { menu.items += [.separator()] + items }
        return menu
    }


    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { drop(sender.draggingPasteboard) }

    func drop(_ pasteboard: NSPasteboard) -> Bool {
        guard let surface, let texts = onDrop?(pasteboard), !texts.isEmpty else { return false }
        texts.forEach { ghostty_surface_text(surface, $0, UInt($0.utf8.count)) }
        window?.makeFirstResponder(self)
        return true
    }


    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange() }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return NSRect(origin: frame.origin, size: .zero) }
        var x = 0.0, y = 0.0, width = Double(cellSize.width), height = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0, width > 0 {
            width = 0
            x += Double(cellSize.width) * Double(range.location + range.length)
        }
        let viewRect = NSRect(x: x, y: frame.height - y, width: width, height: max(height, Double(cellSize.height)))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        var chars: String
        switch string {
        case let value as NSAttributedString: chars = value.string
        case let value as NSString:
            if value.length == 1, UTF16.isLeadSurrogate(value.character(at: 0)) {
                leadSurrogate = value.character(at: 0)
                chars = ""
            } else if value.length == 1, UTF16.isTrailSurrogate(value.character(at: 0)) {
                chars = leadSurrogate.map { String(decoding: [$0, value.character(at: 0)], as: UTF16.self) } ?? ""
                leadSurrogate = nil
            } else {
                chars = value as String
                leadSurrogate = nil
            }
        default: return
        }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        if !chars.isEmpty { _ = committedText(GHOSTTY_ACTION_PRESS, chars) }
    }

    override func doCommand(by selector: Selector) {
        if let lastPerformKeyEvent, let current = NSApp.currentEvent, lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let string = markedText.string
            string.withCString { ptr in ghostty_surface_preedit(surface, ptr, UInt(string.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}


func eventModifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
    var flags = NSEvent.ModifierFlags()
    if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
    if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
    if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
    return flags
}

func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    let raw = flags.rawValue
    if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
    if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
    return ghostty_input_mods_e(mods)
}

extension NSEvent {
    func ghosttyKeyEvent(_ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(keyCode)
        keyEvent.mods = ghosttyMods(modifierFlags)
        keyEvent.consumed_mods = ghosttyMods((translationMods ?? modifierFlags).subtracting([.control, .command]))
        if type == .keyDown || type == .keyUp, let scalar = characters(byApplyingModifiers: [])?.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }
        return keyEvent
    }

    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 { return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control)) }
            if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        }
        return characters
    }
}
