import AppKit

// First-launch setup. One permission per step, live status, and no system
// prompt fires until the person presses the button for it.
@MainActor
final class Onboarding {
    enum Step: Int { case welcome, inputMonitoring, accessibility, done }

    private(set) var step = Step.welcome
    let window: NSWindow
    var promptAccessibility: () -> Void = {}
    var openSettings: () -> Void = {}
    var finish: () -> Void = {}
    private var askedInputMonitoring = false
    private var askedAccessibility = false
    private var canListen = false
    private var canAccess = false
    private let stepLabel: NSTextField
    private let title: NSTextField
    private let body: NSTextField
    private let status: NSTextField
    let primary: SettingsButton
    let secondary: SettingsButton

    init() {
        window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "VectorScroll Setup"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for control in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(control)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.backgroundColor = SettingsStyle.background
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()

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
        secondary = SettingsButton("", symbol: "arrow.uturn.forward", target: nil, action: nil)

        let stack = NSStackView(views: [stepLabel, title, body, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: stepLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [primary, secondary])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.wantsLayer = true
        content.layer?.backgroundColor = SettingsStyle.background.cgColor
        content.addSubview(stack)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -32)
        ])
        primary.target = self
        primary.action = #selector(primaryPressed)
        secondary.target = self
        secondary.action = #selector(secondaryPressed)
        render()
    }

    func show() {
        render()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // Called every second by the app. Advances as soon as a permission lands.
    func refresh(canListen: Bool, canAccess: Bool) {
        self.canListen = canListen
        self.canAccess = canAccess
        if step == .inputMonitoring, canListen { step = canAccess ? .done : .accessibility }
        if step == .accessibility, canAccess { step = .done }
        render()
    }

    @objc private func primaryPressed() {
        switch step {
        case .welcome:
            step = canListen ? (canAccess ? .done : .accessibility) : .inputMonitoring
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
            window.close()
            finish()
        }
        render()
    }

    @objc private func secondaryPressed() {
        switch step {
        case .welcome, .inputMonitoring:
            window.close()
            finish()
        case .accessibility:
            step = .done
        case .done:
            window.close()
            finish()
            openSettings()
        }
        render()
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
            body.stringValue = "With Accessibility, VectorScroll brings the window under your pointer to the front before scrolling, so background windows scroll too. Without it, only the active window scrolls."
            primary.title = askedAccessibility ? "Open System Settings" : "Allow Accessibility"
            secondary.title = "Skip"
            status.stringValue = askedAccessibility ? "Waiting for Accessibility. This page moves on by itself once it is allowed." : "Recommended, not required"
        case .done:
            title.stringValue = "You're set"
            body.stringValue = canAccess ? "Hold the middle button over any window and move the pointer. Change the mode, speed, direction, and indicator in Settings."
                : "Hold the middle button over the active window and move the pointer. Accessibility can be allowed later from Settings."
            primary.title = "Finish"
            secondary.title = "Open Settings"
        }
        primary.symbolName = step == .done ? "checkmark" : (askedInputMonitoring && step == .inputMonitoring) || (askedAccessibility && step == .accessibility) ? "gearshape" : "arrow.right"
        primary.needsDisplay = true
    }
}
