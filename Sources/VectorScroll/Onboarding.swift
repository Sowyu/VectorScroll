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
    let primary: NSButton
    let secondary: NSButton

    override init() {
        let setupWindow = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        setupWindow.title = L("VectorScroll Setup")
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
        stepLabel = label(11, color: SettingsStyle.secondary)
        title = label(20, weight: .semibold)
        body = label(13)
        status = label(11, weight: .regular, color: SettingsStyle.secondary)
        primary = SettingsStyle.actionButton("", symbol: "arrow.right", target: nil, action: nil)
        secondary = SettingsStyle.actionButton("", symbol: "xmark", target: nil, action: nil)
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
        content.addSubview(stack)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 52),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -28)
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
        SettingsStyle.present(window)
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

    private struct RenderState: Equatable {
        let step: Step
        let askedInputMonitoring: Bool
        let askedAccessibility: Bool
    }
    private var renderedState: RenderState?

    private func render() {
        let state = RenderState(step: step, askedInputMonitoring: askedInputMonitoring,
                                askedAccessibility: askedAccessibility)
        guard state != renderedState else { return }
        renderedState = state
        stepLabel.stringValue = step == .welcome ? L("Setup") : step == .done ? L("Setup complete") : L("Step %ld of %ld", step.rawValue, 2)
        secondary.isHidden = false
        status.stringValue = ""
        switch step {
        case .welcome:
            title.stringValue = L("Welcome to VectorScroll")
            body.stringValue = L("Hold the middle mouse button and move the pointer to scroll any window. macOS needs two permissions first. This takes about a minute, and you can come back to it from Settings.")
            primary.title = L("Set up permissions")
            secondary.title = L("Later")
        case .inputMonitoring:
            title.stringValue = L("Allow Input Monitoring")
            body.stringValue = L("This lets VectorScroll notice when you press the middle button. Nothing you type is read. macOS shows its own dialog once. If it does not appear, open System Settings, turn on VectorScroll under Input Monitoring, then come back here.")
            primary.title = askedInputMonitoring ? L("Open System Settings") : L("Allow Input Monitoring")
            secondary.title = L("Later")
            status.stringValue = askedInputMonitoring ? L("Waiting for Input Monitoring. This page moves on by itself once it is allowed.") : L("Required")
        case .accessibility:
            title.stringValue = L("Allow Accessibility")
            body.stringValue = L("Accessibility lets VectorScroll bring the window under your pointer forward and send scroll events to it. Vector scrolling stays off until this permission is allowed.")
            primary.title = askedAccessibility ? L("Open System Settings") : L("Allow Accessibility")
            secondary.title = L("Later")
            status.stringValue = askedAccessibility ? L("Waiting for Accessibility. This page moves on by itself once it is allowed.") : L("Required")
        case .done:
            title.stringValue = L("You're set")
            body.stringValue = L("Hold the middle button over any window and move the pointer. Change the mode, speed, direction, and indicator in Settings.")
            primary.title = L("Finish")
            secondary.title = L("Open Settings")
        }
        secondary.keyEquivalent = step == .done ? "" : "\u{1b}"
        primary.needsDisplay = true
        // Measure wrapped content at the fixed window width, allowing longer translations.
        let fields = [stepLabel, title, body, status]
        let textHeight = fields.reduce(CGFloat.zero) { total, field in
            let rect = (field.stringValue as NSString).boundingRect(
                with: NSSize(width: 416, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: field.font!])
            return total + ceil(rect.height) + 2
        }
        let height = max(320, 52 + textHeight + 30 + 24 + max(primary.fittingSize.height, secondary.fittingSize.height) + 28)
        if abs(window.contentView!.bounds.height - height) > 0.5 {
            window.setContentSize(NSSize(width: 500, height: height))
        }
    }

    private func transition(to newStep: Step) {
        guard newStep != step else { return }
        step = newStep
        render()
        window.makeFirstResponder(primary)
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: L("%@. %@", stepLabel.stringValue, title.stringValue),
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
