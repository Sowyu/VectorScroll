import AppKit

// First-launch setup. One permission per step, live status, and no system
// prompt fires until the person presses the button for it.
@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    enum Step: Int { case welcome, inputMonitoring, accessibility, done }

    private(set) var step = Step.welcome
    let window: NSWindow
    var promptAccessibility: () -> Void = {}
    var openSettings: () -> Void = {}
    var finish: (Bool) -> Void = { _ in }
    private var askedInputMonitoring = false
    private var askedAccessibility = false
    private var canListen = false
    private var canAccess = false
    private var didFinish = false
    private var openSettingsAfterFinish = false
    private let stepLabel: NSTextField
    private let title: NSTextField
    private let body: NSTextField
    private let status: NSTextField
    let primary: SettingsButton
    let secondary: SettingsButton

    override init() {
        let setupWindow = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        setupWindow.title = "VectorScroll Setup"
        SettingsStyle.prepareWindow(setupWindow)
        setupWindow.isReleasedWhenClosed = false
        setupWindow.center()
        window = setupWindow

        func label(_ size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = SettingsStyle.text) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: "")
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.preferredMaxLayoutWidth = 416
            return field
        }
        stepLabel = label(12, color: SettingsStyle.secondary)
        title = label(22, weight: .semibold)
        body = label(14)
        status = label(12, weight: .medium, color: SettingsStyle.secondary)
        primary = SettingsButton("", symbol: "arrow.right", target: nil, action: nil)
        secondary = SettingsButton("", symbol: "xmark", target: nil, action: nil)
        super.init()

        window.delegate = self
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        let stack = NSStackView(views: [stepLabel, title, body, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: stepLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [secondary, primary])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        let backdrop = SettingsStyle.backdrop()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backdrop)
        backdrop.addSubview(stack)
        backdrop.addSubview(buttons)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 52),
            buttons.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -32),
            buttons.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -28)
        ])
        primary.target = self
        primary.action = #selector(primaryPressed)
        primary.keyEquivalent = "\r"
        primary.keyEquivalentModifierMask = []
        secondary.target = self
        secondary.action = #selector(secondaryPressed)
        secondary.keyEquivalent = "\u{1b}"
        secondary.keyEquivalentModifierMask = []
        render()
    }

    func show() {
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // Called by the app's status timer. No permission prompt starts here.
    func refresh(canListen: Bool, canAccess: Bool) {
        self.canListen = canListen
        self.canAccess = canAccess
        if step == .inputMonitoring, canListen {
            transition(to: canAccess ? .done : .accessibility)
        } else if step == .accessibility, canAccess {
            transition(to: canListen ? .done : .inputMonitoring)
        } else if step == .done, !canListen || !canAccess {
            transition(to: canListen ? .accessibility : .inputMonitoring)
        } else {
            render()
        }
    }

    @objc private func primaryPressed() {
        switch step {
        case .welcome:
            transition(to: canListen ? (canAccess ? .done : .accessibility) : .inputMonitoring)
            return
        case .inputMonitoring:
            if askedInputMonitoring {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            } else {
                askedInputMonitoring = true
                _ = CGRequestListenEventAccess()
            }
        case .accessibility:
            if askedAccessibility {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            } else {
                askedAccessibility = true
                promptAccessibility()
            }
        case .done:
            window.performClose(nil)
        }
        render()
    }

    @objc private func secondaryPressed() {
        openSettingsAfterFinish = step == .done
        window.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        completeOnce()
    }

    private func render() {
        stepLabel.stringValue = step == .welcome ? "Setup" : step == .done ? "Setup complete" : "Step \(step.rawValue) of 2"
        secondary.isHidden = false
        status.stringValue = ""
        switch step {
        case .welcome:
            title.stringValue = "Welcome to VectorScroll"
            body.stringValue = "Hold the middle mouse button and move the pointer to scroll any window. macOS needs two permissions first. This takes about a minute, and you can come back to it from Settings."
            primary.title = "Set up permissions"
            secondary.title = "Later"
        case .inputMonitoring:
            title.stringValue = "Allow Input Monitoring"
            body.stringValue = "This lets VectorScroll notice when you press the middle button. Nothing you type is read. macOS shows its own dialog once. If it does not appear, open System Settings, turn on VectorScroll under Input Monitoring, then come back here."
            primary.title = askedInputMonitoring ? "Open System Settings" : "Allow Input Monitoring"
            secondary.title = "Later"
            status.stringValue = askedInputMonitoring ? "Waiting for Input Monitoring. This page moves on by itself once it is allowed." : "Required"
        case .accessibility:
            title.stringValue = "Allow Accessibility"
            body.stringValue = "Accessibility lets VectorScroll bring the window under your pointer forward and send scroll events to it. Vector scrolling stays off until this permission is allowed."
            primary.title = askedAccessibility ? "Open System Settings" : "Allow Accessibility"
            secondary.title = "Later"
            status.stringValue = askedAccessibility ? "Waiting for Accessibility. This page moves on by itself once it is allowed." : "Required"
        case .done:
            title.stringValue = "You're set"
            body.stringValue = "Hold the middle button over any window and move the pointer. Change the mode, speed, direction, and indicator in Settings."
            primary.title = "Finish"
            secondary.title = "Open Settings"
        }
        primary.symbolName = step == .done ? "checkmark" : (askedInputMonitoring && step == .inputMonitoring) || (askedAccessibility && step == .accessibility) ? "gearshape" : "arrow.right"
        secondary.symbolName = step == .done ? "gearshape" : "xmark"
        secondary.keyEquivalent = step == .done ? "" : "\u{1b}"
        primary.needsDisplay = true
    }

    private func transition(to newStep: Step) {
        guard newStep != step else { render(); return }
        step = newStep
        render()
        window.makeFirstResponder(primary)
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: "\(stepLabel.stringValue). \(title.stringValue)",
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
    }

    private func completeOnce() {
        guard !didFinish else { return }
        didFinish = true
        let completed = canListen && canAccess
        let shouldOpenSettings = openSettingsAfterFinish
        let finishHandler = finish
        let settingsHandler = openSettings
        finishHandler(completed)
        if shouldOpenSettings { settingsHandler() }
    }
}
