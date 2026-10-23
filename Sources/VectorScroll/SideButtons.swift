@preconcurrency import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class SideButtons: NSObject {
    enum Direction { case back, forward }

    private let defaults: UserDefaults
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var capture: (Direction, (Int?) -> Void)?
    private var captureTimeout: DispatchWorkItem?
    private var consumed = Set<Int>()
    private var backLabel: NSTextField?
    private var forwardLabel: NSTextField?
    private var enabledSwitch: NSSwitch?
    private var cancelButton: NSButton?
    private static let eventMarker: Int64 = 0x56534353494445

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    static func settings(in defaults: UserDefaults) -> (enabled: Bool, back: Int, forward: Int) {
        (defaults.bool(forKey: "sideButtonsEnabled"),
         max(3, (defaults.object(forKey: "backButton") as? Int) ?? 3),
         max(3, (defaults.object(forKey: "forwardButton") as? Int) ?? 4))
    }

    static func keyCode(for direction: Direction) -> CGKeyCode {
        direction == .back ? 0x21 : 0x1E
    }

    static func mapping(_ button: Int, for direction: Direction, back: Int, forward: Int) -> (back: Int, forward: Int) {
        guard button >= 3 else { return (back, forward) }
        switch direction {
        case .back: return (button, button == forward ? back : forward)
        case .forward: return (button == back ? forward : back, button)
        }
    }

    func refresh() {
        let needed = Self.settings(in: defaults).enabled || capture != nil || !consumed.isEmpty
        guard needed, AXIsProcessTrusted() else {
            removeTap()
            return
        }
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
                   (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                               options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<SideButtons>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        consumed.removeAll()
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        captureTimeout?.cancel()
    }

    func beginCapture(for direction: Direction, completion: @escaping (Int?) -> Void) {
        cancelCapture()
        capture = (direction, completion)
        updateLabels()
        let timeout = DispatchWorkItem { [weak self] in self?.cancelCapture() }
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        refresh()
    }

    func cancelCapture() { finishCapture(nil) }

    private func finishCapture(_ button: Int?) {
        let completion = capture?.1
        capture = nil
        captureTimeout?.cancel()
        captureTimeout = nil
        updateLabels()
        refresh()
        completion?(button)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.eventMarker else {
            return Unmanaged.passUnretained(event)
        }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard button >= 3 else { return Unmanaged.passUnretained(event) }
        if type == .otherMouseUp, consumed.remove(button) != nil {
            refresh()
            return nil
        }
        guard type == .otherMouseDown else { return Unmanaged.passUnretained(event) }
        if let (direction, _) = capture {
            let settings = Self.settings(in: defaults)
            let mapping = Self.mapping(button, for: direction, back: settings.back, forward: settings.forward)
            defaults.set(mapping.back, forKey: "backButton")
            defaults.set(mapping.forward, forKey: "forwardButton")
            consumed.insert(button)
            finishCapture(button)
            return nil
        }
        let settings = Self.settings(in: defaults)
        guard settings.enabled, !ExcludedApps.isExcluded(at: event.location) else { return Unmanaged.passUnretained(event) }
        let direction: Direction
        if button == settings.back { direction = .back }
        else if button == settings.forward { direction = .forward }
        else { return Unmanaged.passUnretained(event) }
        consumed.insert(button)
        for down in [true, false] {
            if let key = CGEvent(keyboardEventSource: nil, virtualKey: Self.keyCode(for: direction), keyDown: down) {
                key.flags = .maskCommand
                key.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
                key.post(tap: .cgSessionEventTap)
            }
        }
        return nil
    }

    func makeSettingsSection() -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        toggle.state = Self.settings(in: defaults).enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(changeEnabled(_:))
        toggle.setAccessibilityLabel(L("Back and forward buttons"))
        let back = NSTextField(labelWithString: "")
        let forward = NSTextField(labelWithString: "")
        backLabel = back
        forwardLabel = forward
        enabledSwitch = toggle
        let backButton = SettingsStyle.actionButton(L("Set…"), symbol: "computermouse", target: self, action: #selector(captureBack))
        let forwardButton = SettingsStyle.actionButton(L("Set…"), symbol: "computermouse", target: self, action: #selector(captureForward))
        let cancel = SettingsStyle.actionButton(L("Cancel"), symbol: "xmark", target: self, action: #selector(cancelMapping))
        cancelButton = cancel
        for label in [back, forward] {
            label.font = .systemFont(ofSize: 13)
            label.textColor = SettingsStyle.secondary
        }
        let section = SettingsStyle.column([
            SettingsStyle.group([
                SettingsStyle.row(L("Back and forward buttons"), control: toggle),
                SettingsStyle.row(L("Back"), control: NSStackView(views: [back, backButton])),
                SettingsStyle.row(L("Forward"), control: NSStackView(views: [forward, forwardButton, cancel]))
            ]),
            SettingsStyle.footnote(L("Sends ⌘[ and ⌘]. Apps that use those shortcuts for something else can be excluded below."))
        ], spacing: 6)
        updateLabels()
        return section
    }

    func updateLabels() {
        let settings = Self.settings(in: defaults)
        enabledSwitch?.state = settings.enabled ? .on : .off
        cancelButton?.isHidden = capture == nil
        backLabel?.stringValue = capture?.0 == .back ? L("Press a side button…") : L("Button %ld", settings.back + 1)
        forwardLabel?.stringValue = capture?.0 == .forward ? L("Press a side button…") : L("Button %ld", settings.forward + 1)
    }
    @objc private func changeEnabled(_ sender: NSSwitch) {
        defaults.set(sender.state == .on, forKey: "sideButtonsEnabled")
        refresh()
    }
    @objc private func captureBack() { beginCapture(for: .back) { _ in } }
    @objc private func captureForward() { beginCapture(for: .forward) { _ in } }
    @objc private func cancelMapping() { cancelCapture() }
}
