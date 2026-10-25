@preconcurrency import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import ServiceManagement

private final class FocusCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@MainActor
private final class VectorScrollApp: NSObject, NSApplicationDelegate {
    private static let restorableDefaultsKeys: [String] = [
        "scrollMode", "holdToLockMode", "holdDelayEnabled", "holdDelayMilliseconds", "scrollSpeedPercent",
        "reverseVertical", "reverseHorizontal", "reverseDirection", "raiseWindowOnScroll",
        "darkMode", "markerSize"
    ]
    private let markerSizes = [28, 32, 40, 48]
    private let defaults = UserDefaults.standard
    private var updateItem: NSButton!
    private var downloadItem: NSButton!
    private var updateStatusLabel: NSTextField!
    private var updateProgress: NSProgressIndicator!
    private var availableUpdate: AppUpdate?
    private var updateTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var updateTimer: DispatchSourceTimer?
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var permissionItem: NSButton!
    private var permissionStatusLabel: NSTextField!
    private var indicatorAppearance: NSSegmentedControl!
    private var holdScrollItem: NSButton!
    private var holdToLockItem: NSButton!
    private var holdOrClickItem: NSButton!
    private var launchAtStartupItem: NSSwitch!
    private var launchAtStartupStatusLabel: NSTextField!
    private var hideIconItem: NSSwitch!
    private var sizePicker: NSPopUpButton!
    private let markerPreview = ScrollOverlayView(frame: .zero)
    private var builtSettingsWindow: NSWindow?
    private var settingsWindow: NSWindow! {
        if builtSettingsWindow == nil { configureSettingsWindow() }
        return builtSettingsWindow
    }
    private var pendingUpdateStatus = (text: "", busy: false)
    private var lastPermissionStatus: PermissionStatus?
    private var lastLaunchAtStartupStatus: SMAppService.Status?
    private var permissionStatusInterval: Int?
    private struct PermissionStatus: Equatable {
        let text: String
        let title: String
        let hidden: Bool
    }
    private var openSettingsButton: NSSwitch!
    private var openSettingsOnLaunch = true
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Pointer movement only matters mid-scroll, so a listen-only tap reports it
    // while a session is active and never sits in the path of ordinary cursor motion.
    private var motionTap: CFMachPort?
    private var motionRunLoopSource: CFRunLoopSource?
    private var timer: DispatchSourceTimer?
    private var permissionStatusTimer: DispatchSourceTimer?
    private var anchor: CGPoint?
    private var isActive = false {
        didSet {
            if let motionTap, isActive != oldValue { CGEvent.tapEnable(tap: motionTap, enable: isActive) }
        }
    }
    private enum TapState { case none, filtering, listenOnly }
    private var tapState: TapState = .none
    private enum ScrollMode: String { case hold, toggle, both }
    private var scrollMode: ScrollMode = .hold
    // Compatibility for the existing toggle-mode checks.
    private var holdToLockMode: Bool {
        get { scrollMode == .toggle }
        set { scrollMode = newValue ? .toggle : .hold }
    }
    private let accessibilityQueue = DispatchQueue(label: "local.vectorscroll.accessibility", qos: .userInitiated)
    private var engageWorkItem: DispatchWorkItem?
    private var feedbackWorkItem: DispatchWorkItem?
    private var focusWorkItem: DispatchWorkItem?
    private var focusCancellation: FocusCancellation?
    private var lastScrollTime: TimeInterval?
    private var heldMiddleClick: CGPoint?
    private var middleDownTimestamp: CGEventTimestamp?
    // Set once the pointer leaves the dead zone. Hold or click uses it to tell a drag from a click.
    private var leftDeadZone = false
    // Pointer position from the latest middle-button drag. With a real mouse, NSEvent.mouseLocation
    // stops following the pointer while the button is held, so the drags themselves are the source.
    private var heldPointer: CGPoint?
    private var swallowedButtonUps: Set<Int64> = []
    private var excludedMiddleClick = false
    private var scrollingGeneration: UInt64 = 0
    // Ask the hardware state. Once the tap swallows the press, the session state reports it released.
    private var middleButtonIsDown: () -> Bool = {
        CGEventSource.buttonState(.hidSystemState, button: .center)
    }
    private static let replayEventMarker: Int64 = 0x56534352434C494B
    private var postClick: (CGPoint) -> Void = { (point: CGPoint) -> Void in
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .center) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            event.setIntegerValueField(.eventSourceUserData, value: VectorScrollApp.replayEventMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }
    private var menuBarIconHidden = false
    private let overlay = ScrollOverlayWindow()

    private let baseScrollScale: CGFloat = 0.42
    private var scrollSpeedPercent = 100
    private var scrollScale: CGFloat { baseScrollScale * CGFloat(scrollSpeedPercent) / 100 }
    private var reverseVertical = false
    private var reverseHorizontal = false
    private var raiseWindowOnScroll = true
    private var scrollRemainder = CGPoint.zero
    private var engaged = false
    private var pendingTarget: CGPoint?
    private let deadZone: CGFloat = 10
    private let maxDeltaPerTick: CGFloat = 120
    private var holdDelayEnabled = true
    private var holdDelayMilliseconds = 200
    private var holdToLockThreshold: TimeInterval {
        holdDelayEnabled ? Double(holdDelayMilliseconds) / 1000 : 0
    }
    private var delayItem: NSStackView!
    private var reverseVerticalItem: NSSwitch!
    private var reverseHorizontalItem: NSSwitch!
    private var raiseWindowItem: NSSwitch!
    private var restoreDefaultsButton: NSButton!
    private var onboarding: Onboarding?
    private var speedSlider: NSSlider!
    private var speedLabel: NSTextField!
    private var delayToggle: NSSwitch!
    private var delaySlider: NSSlider!
    private var delayLabel: NSTextField!
    private var hasAccessibilityAccess: Bool { CGPreflightPostEventAccess() && AXIsProcessTrusted() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherCopies()
        NSApp.setActivationPolicy(.accessory)
        restoreSettings()
        configureMenu()
        // Fresh installs get the guided setup instead of bare system prompts.
        // Copies that were already set up are marked complete silently.
        if !defaults.bool(forKey: "onboardingCompleted"), CGPreflightListenEventAccess(), hasAccessibilityAccess {
            defaults.set(true, forKey: "onboardingCompleted")
        }
        if !defaults.bool(forKey: "onboardingCompleted") {
            showOnboarding()
        } else {
            if openSettingsOnLaunch { showSettings() }
        }
        if let error = defaults.string(forKey: "updateInstallError"), !error.isEmpty {
            defaults.set("", forKey: "updateInstallError")
            showSettings()
            showUpdateError(L(error))
        }
        if CommandLine.arguments.contains("--show-settings") { showSettings() }
        installEventTap()
        startPermissionStatusTimer()
        for (center, name) in [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"))
        ] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopScrolling() }
            }
        }
        let checkAutomatically: @MainActor () -> Void = { [weak self] in
            guard let self, self.installTask == nil, self.updateTask == nil,
                  AppUpdate.beginAutomaticCheck(defaults: self.defaults) else { return }
            self.checkForUpdates(manual: false)
        }
        checkAutomatically()
        let updateTimer = DispatchSource.makeTimerSource(queue: .main)
        updateTimer.schedule(wallDeadline: .now() + AppUpdate.automaticCheckDelay(defaults: defaults),
                             repeating: .seconds(86400), leeway: .seconds(60))
        // The timer fires on the main queue. Handing Dispatch the @MainActor closure itself crashes release builds.
        updateTimer.setEventHandler { MainActor.assumeIsolated { checkAutomatically() } }
        self.updateTimer = updateTimer
        updateTimer.resume()
        _ = try? UpdateInstaller.acknowledgeLaunch()
    }

    private func terminateOtherCopies() {
        // The updater must be able to launch its health-check copy independently.
        guard !CommandLine.arguments.contains("--vector-scroll-update-health"),
              let bundleID = Bundle.main.bundleIdentifier else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { (application: NSRunningApplication) -> Bool in application.processIdentifier != ownPID }
        for application in others { application.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) {
            for application in others where !application.isTerminated { application.forceTerminate() }
        }
    }

    private func configureMenu() {
        let menu = NSMenu(title: L("VectorScroll"))
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        menu.addItem(.separator())
        let donate = NSMenuItem(title: L("Donate on Ko-fi"), action: #selector(openKofi), keyEquivalent: "")
        donate.target = self
        donate.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        menu.addItem(donate)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit VectorScroll"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        self.menu = menu
        if !menuBarIconHidden { installStatusItem() }
    }

    @objc private func openKofi() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/anikodev")!)
    }

    @objc private func showSettings() {
        stopScrolling()
        if builtSettingsWindow != nil {
            updateLaunchAtStartupItem()
            updatePermissionMenuItem()
        }
        SettingsStyle.present(settingsWindow)
    }

    private func configureSettingsWindow() {
        builtSettingsWindow = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 820),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        settingsWindow.title = L("VectorScroll Settings")
        SettingsStyle.prepareWindow(settingsWindow)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.minSize = NSSize(width: 520, height: 500)
        if !settingsWindow.setFrameUsingName("VectorScrollSettingsV6") { settingsWindow.center() }
        settingsWindow.setFrameAutosaveName("VectorScrollSettingsV6")

        func label(_ text: String, secondary: Bool = false) -> NSTextField {
            SettingsStyle.label(text, secondary: secondary)
        }
        func row(_ views: NSView...) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 12
            return stack
        }
        func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
            SettingsStyle.actionButton(title, symbol: symbol, target: self, action: action)
        }
        func help(_ view: NSView, _ text: String) {
            view.toolTip = text
            view.setAccessibilityHelp(text)
        }
        func toggle(_ accessibilityLabel: String, _ action: Selector) -> NSSwitch {
            let control = NSSwitch(frame: .zero)
            control.target = self
            control.action = action
            control.controlSize = .small
            control.setAccessibilityLabel(accessibilityLabel)
            return control
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        var headings: [NSView] = []
        func fullWidth(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        func sectionHeading(_ title: String, _ symbol: String) -> NSView {
            let icon = NSImageView(image: SettingsStyle.symbol(symbol)!)
            icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 17).isActive = true
            let heading = label(title)
            heading.font = .systemFont(ofSize: 14, weight: .semibold)
            let headingRow = row(icon, heading)
            headings.append(headingRow)
            return headingRow
        }
        func settingsRow(_ title: String, control: NSView, detail: String? = nil) -> NSView {
            SettingsStyle.row(title, control: control, description: detail.map { label($0, secondary: true) })
        }
        func group(_ views: NSView...) -> NSView { SettingsStyle.group(views) }
        let guideButton = button(L("Setup Guide"), "questionmark.circle", #selector(showOnboarding))
        help(guideButton, L("Review the permissions needed for middle-button scrolling."))
        let appIcon = NSImageView(image: NSApp.applicationIconImage)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let appTitle = label(L("VectorScroll"))
        appTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        guideButton.setContentHuggingPriority(.required, for: .horizontal)
        fullWidth(row(appIcon, appTitle, headerSpacer, guideButton))

        fullWidth(sectionHeading(L("Scrolling"), "computermouse"))
        let hold = SettingsButton(L("Scroll while holding the middle button"), symbol: "hand.point.up.left", target: self, action: #selector(selectHoldToScroll))
        hold.displayTitle = L("Hold to scroll")
        hold.detail = L("Release the middle button to stop")
        holdScrollItem = hold
        let click = SettingsButton(L("Keep scrolling until the next click"), symbol: "cursorarrow.click", target: self, action: #selector(selectHoldToLock))
        click.displayTitle = L("Toggle scrolling")
        holdToLockItem = click
        let both = SettingsButton(L("Hold or click"), symbol: "hand.draw", target: self, action: #selector(selectBoth))
        both.detail = L("Hold and drag, or click to keep scrolling")
        holdOrClickItem = both
        // Cards must not outrank the window's stay-put priority (500), or the
        // window widens to fit their full accessibility titles.
        for card in [hold, click, both] { card.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let modes = SettingsStyle.column([hold, click, both], spacing: 6)
        modes.translatesAutoresizingMaskIntoConstraints = false
        let modesPadding = NSView()
        modesPadding.addSubview(modes)
        NSLayoutConstraint.activate([
            modes.leadingAnchor.constraint(equalTo: modesPadding.leadingAnchor, constant: 8),
            modes.trailingAnchor.constraint(equalTo: modesPadding.trailingAnchor, constant: -8),
            modes.topAnchor.constraint(equalTo: modesPadding.topAnchor, constant: 8),
            modes.bottomAnchor.constraint(equalTo: modesPadding.bottomAnchor, constant: -8)
        ])
        fullWidth(SettingsStyle.glassContainer(for: modesPadding, cornerRadius: 12))
        reverseVerticalItem = toggle(L("Reverse vertical"), #selector(toggleReverseVertical))
        help(reverseVerticalItem, L("Drag down to scroll up instead of down."))
        reverseHorizontalItem = toggle(L("Reverse horizontal"), #selector(toggleReverseHorizontal))
        help(reverseHorizontalItem, L("Drag right to scroll left instead of right."))
        raiseWindowItem = toggle(L("Bring window to front"), #selector(toggleRaiseWindow))
        help(raiseWindowItem, L("Activate the app under the pointer when scrolling starts. Scrolling works either way."))
        speedSlider = NSSlider(value: Double(scrollSpeedPercent), minValue: 20, maxValue: 300,
                               target: self, action: #selector(changeScrollSpeed(_:)))
        speedSlider.numberOfTickMarks = 29
        speedSlider.tickMarkPosition = .below
        speedSlider.allowsTickMarkValuesOnly = true
        speedSlider.isContinuous = true
        speedSlider.setAccessibilityLabel(L("Scroll speed"))
        help(speedSlider, L("Adjust scrolling speed from 20% to 300% in 10% steps. 100% is the default."))
        speedSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        speedLabel = NSTextField(labelWithString: "")
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let speedControl = row(speedSlider, speedLabel)
        let speedRow = settingsRow(L("Scroll speed"), control: speedControl)
        delayToggle = toggle(L("Delay before scrolling starts"), #selector(toggleHoldDelay))
        help(delayToggle, L("Require a brief hold so a normal middle-click can still open a link in a new tab."))
        delaySlider = NSSlider(value: Double(holdDelayMilliseconds), minValue: 50, maxValue: 1000,
                               target: self, action: #selector(changeHoldDelay(_:)))
        delaySlider.numberOfTickMarks = 20
        delaySlider.tickMarkPosition = .below
        delaySlider.allowsTickMarkValuesOnly = true
        delaySlider.isContinuous = true
        delaySlider.setAccessibilityLabel(L("Hold duration"))
        help(delaySlider, L("How long to hold the middle button before toggle scrolling starts."))
        delaySlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        delayLabel = NSTextField(labelWithString: "")
        delayLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let delaySeparator = NSBox()
        delaySeparator.boxType = .separator
        delayItem = SettingsStyle.column([
            settingsRow(L("Delay before scrolling starts"), control: delayToggle),
            delaySeparator,
            settingsRow(L("Hold duration"), control: row(delaySlider, delayLabel))
        ], spacing: 0)
        let scrollingGroup = group(
            settingsRow(L("Reverse vertical"), control: reverseVerticalItem),
            settingsRow(L("Reverse horizontal"), control: reverseHorizontalItem),
            speedRow, delayItem,
            settingsRow(L("Bring window to front"), control: raiseWindowItem)
        )
        fullWidth(scrollingGroup)

        fullWidth(sectionHeading(L("Indicator"), "scope"))
        indicatorAppearance = NSSegmentedControl(labels: [L("Light"), L("Dark")], trackingMode: .selectOne,
                                                  target: self, action: #selector(changeIndicatorAppearance(_:)))
        indicatorAppearance.controlSize = .small
        indicatorAppearance.setAccessibilityLabel(L("Indicator appearance"))
        sizePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for size in markerSizes {
            sizePicker.addItem(withTitle: L("%ld pt", size))
            sizePicker.lastItem?.tag = size
        }
        sizePicker.target = self
        sizePicker.action = #selector(selectMarkerSize(_:))
        sizePicker.setAccessibilityLabel(L("Indicator size"))
        help(indicatorAppearance, L("Choose a light or dark scrolling indicator for contrast with the content beneath it."))
        help(sizePicker, L("Change the scrolling indicator's diameter. The preview shows its actual size."))
        let previewBox = NSView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
        previewBox.widthAnchor.constraint(equalToConstant: 48).isActive = true
        previewBox.heightAnchor.constraint(equalToConstant: 48).isActive = true
        previewBox.addSubview(markerPreview)
        markerPreview.setAccessibilityElement(true)
        markerPreview.setAccessibilityRole(.image)
        markerPreview.setAccessibilityLabel(L("Scrolling indicator preview"))
        help(markerPreview, L("Actual-size preview of the scrolling indicator."))
        let appearanceRow = settingsRow(L("Appearance"), control: indicatorAppearance)
        let sizeAndPreview = row(sizePicker, previewBox)
        let sizeRow = settingsRow(L("Size"), control: sizeAndPreview, detail: L("Actual-size preview"))
        fullWidth(group(appearanceRow, sizeRow))

        fullWidth(sectionHeading(L("Excluded apps"), "nosign"))
        fullWidth(ExcludedApps.makeSettingsSection())

        fullWidth(sectionHeading(L("App"), "slider.horizontal.3"))
        openSettingsButton = toggle(L("Open settings on launch"), #selector(toggleOpenSettings))
        hideIconItem = toggle(L("Show menu bar icon"), #selector(toggleMenuBarIcon))
        launchAtStartupItem = toggle(L("Launch at login"), #selector(toggleLaunchAtStartup))
        help(openSettingsButton, L("Show this window when VectorScroll starts. If both access options are off, the menu bar icon returns."))
        help(hideIconItem, L("Keep Settings and Quit in the menu bar. Hiding the icon enables Open settings on launch."))
        permissionStatusLabel = label("")
        permissionItem = button("", "hand.raised", #selector(openPermissionSettings))
        launchAtStartupStatusLabel = label("", secondary: true)
        restoreDefaultsButton = button(L("Restore Defaults"), "arrow.counterclockwise", #selector(restoreDefaults))
        let appGroup = group(
            settingsRow(L("Open settings on launch"), control: openSettingsButton),
            settingsRow(L("Show menu bar icon"), control: hideIconItem),
            SettingsStyle.row(L("Launch at login"), control: launchAtStartupItem, description: launchAtStartupStatusLabel),
            SettingsStyle.row(title: permissionStatusLabel, control: SettingsActionBar(actions: [permissionItem], maximumWidth: 300))
        )
        fullWidth(appGroup)
        stack.setCustomSpacing(20, after: appGroup)

        updateItem = button(L("Check for Updates…"), "arrow.clockwise", #selector(checkUpdatesFromMenu))
        downloadItem = button(L("Install Update…"), "arrow.down", #selector(installUpdate))
        downloadItem.isHidden = true
        updateProgress = NSProgressIndicator()
        updateProgress.style = .spinning
        updateProgress.controlSize = .small
        updateProgress.isIndeterminate = true
        updateProgress.isDisplayedWhenStopped = false
        updateProgress.isHidden = true
        updateProgress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        updateProgress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        updateProgress.setAccessibilityLabel(L("Update in progress"))
        updateStatusLabel = label("", secondary: true)
        updateStatusLabel.isHidden = true
        let version = NSTextField(labelWithString: L("Version %@", AppUpdate.installedVersion))
        version.font = .systemFont(ofSize: 11)
        version.textColor = SettingsStyle.secondary
        help(updateItem, L("Checks daily and installs only when you choose."))
        fullWidth(SettingsActionBar(leading: row(LanguagePicker(), version),
                                    actions: [restoreDefaultsButton, updateItem, downloadItem, updateProgress]))
        fullWidth(updateStatusLabel)

        // Sections breathe: more room above each heading than between a heading and its group.
        for heading in headings {
            if let index = stack.arrangedSubviews.firstIndex(of: heading), index > 0 {
                stack.setCustomSpacing(20, after: stack.arrangedSubviews[index - 1])
            }
            stack.setCustomSpacing(6, after: heading)
        }
        let content = settingsWindow.contentView!
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay // A plugged-in mouse would otherwise reserve a 15pt legacy scroller.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            NSLayoutConstraint(item: scroll, attribute: .top, relatedBy: .equal,
                               toItem: settingsWindow.contentLayoutGuide, attribute: .top, multiplier: 1, constant: 0),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        updateMarkerMenuItem()
        updateSizeMenuItems()
        updateScrollModeMenuItems()
        updateSpeedControls()
        updateLaunchAtStartupItem()
        updatePermissionMenuItem()
        refreshAccessControls()
        applyUpdate(availableUpdate)
        setUpdateStatus(pendingUpdateStatus.text, busy: pendingUpdateStatus.busy)
    }

    @objc private func toggleReverseVertical() {
        reverseVertical = reverseVerticalItem.state == .on
        defaults.set(reverseVertical, forKey: "reverseVertical")
    }

    @objc private func toggleReverseHorizontal() {
        reverseHorizontal = reverseHorizontalItem.state == .on
        defaults.set(reverseHorizontal, forKey: "reverseHorizontal")
    }

    @objc private func toggleRaiseWindow() {
        raiseWindowOnScroll = raiseWindowItem.state == .on
        defaults.set(raiseWindowOnScroll, forKey: "raiseWindowOnScroll")
    }

    @objc private func restoreDefaults() {
        _ = settingsWindow
        stopScrolling()
        for key in Self.restorableDefaultsKeys { defaults.removeObject(forKey: key) }
        holdToLockMode = false
        holdDelayEnabled = true
        holdDelayMilliseconds = 200
        scrollSpeedPercent = 100
        reverseVertical = false
        reverseHorizontal = false
        raiseWindowOnScroll = true
        scrollRemainder = .zero
        overlay.setDarkMode(false)
        overlay.setSize(32)
        updateScrollModeMenuItems()
        updateSpeedControls()
        updateMarkerMenuItem()
        updateSizeMenuItems()
    }

    @objc private func changeScrollSpeed(_ sender: NSSlider) {
        scrollSpeedPercent = min(300, max(20, Int((sender.doubleValue / 10).rounded()) * 10))
        defaults.set(scrollSpeedPercent, forKey: "scrollSpeedPercent")
        updateSpeedControls()
    }

    private func updateSpeedControls() {
        _ = settingsWindow
        reverseVerticalItem.state = reverseVertical ? .on : .off
        reverseHorizontalItem.state = reverseHorizontal ? .on : .off
        raiseWindowItem.state = raiseWindowOnScroll ? .on : .off
        speedSlider.doubleValue = Double(scrollSpeedPercent)
        speedLabel.stringValue = L("%ld%%", scrollSpeedPercent)
        speedSlider.setAccessibilityValueDescription(L("%ld percent", scrollSpeedPercent))
    }

    @objc private func checkUpdatesFromMenu() {
        checkForUpdates(manual: true)
    }

    private func checkForUpdates(manual: Bool) {
        guard installTask == nil, updateTask == nil else { return }
        setUpdateStatus(L("Checking for updates…"), busy: true)
        updateTask = Task { [weak self] in
            do {
                let update = try await AppUpdate.check()
                guard let self, !Task.isCancelled else { return }
                self.applyUpdate(update)
                self.setUpdateStatus(update.map { L("VectorScroll %@ is available.", $0.version) }
                    ?? L("VectorScroll %@ is up to date.", AppUpdate.installedVersion), busy: false)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.setUpdateStatus(manual ? L("Couldn't check for updates. %@", L(error.localizedDescription)) : "", busy: false)
            }
            if let self, manual {
                NSAccessibility.post(element: self.updateStatusLabel!, notification: .announcementRequested,
                                     userInfo: [.announcement: self.updateStatusLabel.stringValue,
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            self?.updateTask = nil
        }
    }

    private func setUpdateStatus(_ status: String, busy: Bool) {
        pendingUpdateStatus = (status, busy)
        guard builtSettingsWindow != nil else { return }
        updateStatusLabel.stringValue = status
        updateStatusLabel.isHidden = status.isEmpty
        updateProgress.isHidden = !busy
        (updateProgress.superview as? SettingsActionBar)?.refresh()
        updateItem.isEnabled = !busy
        downloadItem.isEnabled = !busy
        if busy {
            updateProgress.startAnimation(nil)
        } else {
            updateProgress.stopAnimation(nil)
        }
    }

    private func applyUpdate(_ update: AppUpdate?) {
        guard installTask == nil else { return }
        availableUpdate = update
        guard builtSettingsWindow != nil else { return }
        downloadItem.isHidden = update == nil
        downloadItem.title = update.map { L("Install Update %@…", $0.version) } ?? L("Install Update…")
        (downloadItem.superview as? SettingsActionBar)?.refresh()
    }

    @objc private func installUpdate() {
        guard let update = availableUpdate, installTask == nil, updateTask == nil else { return }
        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard let helper = Bundle.main.executableURL else { return }
        do { _ = try UpdateInstaller.validateDestination(destination) }
        catch { showUpdateError(L(error.localizedDescription)); return }
        showSettings()
        defaults.set("", forKey: "updateInstallError")
        setUpdateStatus(L("Downloading VectorScroll %@…", update.version), busy: true)
        installTask = Task { [weak self] in
            do {
                let data = try await UpdateInstaller.download(update)
                guard let self, !Task.isCancelled else { return }
                self.setUpdateStatus(L("Verifying the update…"), busy: true)
                let pid = ProcessInfo.processInfo.processIdentifier
                let plan = try await Task.detached {
                    try UpdateInstaller.prepare(update, image: data, destination: destination,
                                                helperSource: helper, parentPID: pid)
                }.value
                guard !Task.isCancelled else { return }
                self.setUpdateStatus(L("Restarting VectorScroll…"), busy: true)
                try await Task.detached { try UpdateInstaller.launchHelper(plan) }.value
                self.installTask = nil
                NSApp.terminate(nil)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.installTask = nil
                self.applyUpdate(self.availableUpdate)
                self.setUpdateStatus(L("Update failed."), busy: false)
                self.showUpdateError(L(error.localizedDescription))
            }
        }
    }

    private func showUpdateError(_ message: String) {
        stopScrolling()
        let alert = NSAlert()
        alert.messageText = L("Update could not be completed")
        alert.informativeText = localizedUpdateError(L(message))
        alert.addButton(withTitle: L("OK"))
        NSApp.activate()
        alert.runModal()
    }

    @objc private func toggleHoldDelay() {
        stopScrolling()
        holdDelayEnabled.toggle()
        defaults.set(holdDelayEnabled, forKey: "holdDelayEnabled")
        updateDelayMenu()
    }

    @objc private func changeHoldDelay(_ sender: NSSlider) {
        stopScrolling()
        holdDelayMilliseconds = min(1000, max(50, Int((sender.doubleValue / 50).rounded()) * 50))
        defaults.set(holdDelayMilliseconds, forKey: "holdDelayMilliseconds")
        updateDelayMenu()
    }

    private func updateDelayMenu() {
        _ = settingsWindow
        delayToggle.state = holdDelayEnabled ? .on : .off
        delaySlider.isEnabled = holdDelayEnabled
        delaySlider.doubleValue = Double(holdDelayMilliseconds)
        delayLabel.stringValue = L("%ld ms", holdDelayMilliseconds)
        delaySlider.setAccessibilityValueDescription(L("%ld milliseconds", holdDelayMilliseconds))
        delayLabel.textColor = holdDelayEnabled ? .labelColor : .secondaryLabelColor
        delayItem.isHidden = !holdToLockMode
        let detail = holdDelayEnabled ? L("Hold to start, click to stop") : L("Click to start, click to stop")
        (holdToLockItem as? SettingsButton)?.detail = detail
        holdToLockItem.setAccessibilityHelp(detail)

    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.up.and.down.circle.fill", accessibilityDescription: L("Vector Scroll"))
            button.image?.isTemplate = true
        }
    }

    private func hideMenuBarIcon() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        menuBarIconHidden = true
    }

    private func refreshAccessControls() {
        _ = settingsWindow
        hideIconItem.state = menuBarIconHidden ? .off : .on
        openSettingsButton.state = openSettingsOnLaunch ? .on : .off
    }

    private func setAccessPreferences(showMenuBar: Bool, openSettings: Bool) {
        // Repair invalid persisted or requested combinations before hiding access.
        let showMenuBar = showMenuBar || !openSettings
        openSettingsOnLaunch = openSettings
        defaults.set(openSettings, forKey: "openSettingsOnLaunch")
        defaults.set(showMenuBar, forKey: "showMenuBarIcon")
        if showMenuBar {
            menuBarIconHidden = false
            installStatusItem()
        } else {
            hideMenuBarIcon()
        }
        refreshAccessControls()
    }

    @objc private func toggleMenuBarIcon() {
        let show = hideIconItem.state == .on
        setAccessPreferences(showMenuBar: show, openSettings: openSettingsOnLaunch || !show)
    }

    @objc private func toggleOpenSettings() {
        let open = openSettingsButton.state == .on
        setAccessPreferences(showMenuBar: !menuBarIconHidden || !open, openSettings: open)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboarding != nil { showOnboarding() } else { showSettings() }
        return true
    }

    @objc private func selectLightMode() {
        overlay.setDarkMode(false)
        defaults.set(false, forKey: "darkMode")
        updateMarkerMenuItem()
    }

    @objc private func selectDarkMode() {
        overlay.setDarkMode(true)
        defaults.set(true, forKey: "darkMode")
        updateMarkerMenuItem()
    }

    @objc private func changeIndicatorAppearance(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            selectLightMode()
        } else if sender.selectedSegment == 1 {
            selectDarkMode()
        }
    }

    @objc private func selectHoldToScroll() {
        stopScrolling()
        holdToLockMode = false
        defaults.set(scrollMode.rawValue, forKey: "scrollMode")
        updateScrollModeMenuItems()
    }

    @objc private func selectHoldToLock() {
        stopScrolling()
        holdToLockMode = true
        defaults.set(scrollMode.rawValue, forKey: "scrollMode")
        updateScrollModeMenuItems()
    }

    @objc private func selectBoth() {
        stopScrolling()
        scrollMode = .both
        defaults.set(scrollMode.rawValue, forKey: "scrollMode")
        updateScrollModeMenuItems()
    }

    @objc private func selectMarkerSize(_ sender: NSPopUpButton) {
        guard let size = sender.selectedItem?.tag, markerSizes.contains(size) else { return }
        overlay.setSize(CGFloat(size))
        defaults.set(size, forKey: "markerSize")
        updateSizeMenuItems()
    }

    @objc private func toggleLaunchAtStartup() {
        stopScrolling()
        // The switch has already changed locally, even if registration leaves the status unchanged.
        lastLaunchAtStartupStatus = nil
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            // macOS reports notFound until the app has been registered once, wherever it lives.
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            @unknown default:
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Launch at login could not be changed")
            alert.informativeText = L(error.localizedDescription)
            alert.addButton(withTitle: L("Open Login Items"))
            alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { SMAppService.openSystemSettingsLoginItems() }
        }
        updateLaunchAtStartupItem()
    }

    @objc private func showOnboarding() {
        stopScrolling()
        if onboarding == nil {
            let guide = Onboarding()
            guide.promptAccessibility = { [weak self] in
                self?.requestAccessibilityPermission()
            }
            guide.openSettings = { [weak self] in self?.showSettings() }
            guide.finish = { [weak self] completed in
                guard let self else { return }
                self.defaults.set(completed, forKey: "onboardingCompleted")
                self.onboarding = nil
                if self.openSettingsOnLaunch, self.builtSettingsWindow?.isVisible != true,
                   !CGPreflightListenEventAccess() || !self.hasAccessibilityAccess { self.showSettings() }
            }
            onboarding = guide
        }
        onboarding?.refresh(canListen: CGPreflightListenEventAccess(), canAccess: hasAccessibilityAccess)
        onboarding?.show()
    }

    @objc private func openPermissionSettings() {
        let pane = CGPreflightListenEventAccess() ? "Privacy_Accessibility" : "Privacy_ListenEvent"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private func requestAccessibilityPermission() {
        // Only the setup button calls this. Polling and launch never prompt.
        guard !hasAccessibilityAccess else { return }
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        } else {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        updatePermissionMenuItem()
    }

    private func updateMarkerMenuItem() {
        _ = settingsWindow
        indicatorAppearance.selectedSegment = overlay.isDarkMode ? 1 : 0
        updateMarkerPreview()
    }

    private func updateMarkerPreview() {
        let size = overlay.size
        markerPreview.frame = NSRect(x: (48 - size) / 2, y: (48 - size) / 2, width: size, height: size)
        markerPreview.isDarkMode = overlay.isDarkMode
        markerPreview.needsDisplay = true
        markerPreview.setAccessibilityValue(L("%@, %ld points", overlay.isDarkMode ? L("Dark") : L("Light"), Int(size)))
    }

    private func updateScrollModeMenuItems() {
        _ = settingsWindow
        holdScrollItem.state = scrollMode == .hold ? .on : .off
        holdToLockItem.state = scrollMode == .toggle ? .on : .off
        holdOrClickItem.state = scrollMode == .both ? .on : .off
        updateDelayMenu()
    }

    private func updatePermissionMenuItem() {
        applyPermissionStatus(canListen: CGPreflightListenEventAccess(), canAccess: hasAccessibilityAccess)
    }

    private func applyPermissionStatus(canListen: Bool, canAccess: Bool) {
        onboarding?.refresh(canListen: canListen, canAccess: canAccess)
        schedulePermissionStatusTimer(canListen: canListen, canAccess: canAccess)
        guard builtSettingsWindow != nil else { return }
        let enabled = eventTap.map { (tap: CFMachPort) -> Bool in CGEvent.tapIsEnabled(tap: tap) } ?? false
        let status = PermissionStatus(
            text: Self.permissionStatusText(canListen: canListen, canAccess: canAccess,
                                            tapState: tapState, tapEnabled: enabled),
            title: canListen ? L("Accessibility Settings…") : L("Input Monitoring Settings…"),
            hidden: canListen && canAccess)
        guard status != lastPermissionStatus else { return }
        lastPermissionStatus = status
        if permissionStatusLabel.stringValue != status.text { permissionStatusLabel.stringValue = status.text }
        let actionsChanged = permissionItem.isHidden != status.hidden || permissionItem.title != status.title
        if permissionItem.isHidden != status.hidden { permissionItem.isHidden = status.hidden }
        if permissionItem.title != status.title { permissionItem.title = status.title }
        if actionsChanged { (permissionItem.superview as? SettingsActionBar)?.refresh() }
    }

    private static func permissionStatusText(canListen: Bool, canAccess: Bool,
                                             tapState: TapState, tapEnabled: Bool) -> String {
        if !canListen && !canAccess {
            return L("Input Monitoring and Accessibility are required")
        } else if !canListen {
            return L("Input Monitoring is required")
        } else if !canAccess {
            return L("Accessibility is required")
        } else if tapEnabled, tapState == .filtering {
            return L("Ready to scroll")
        } else if tapEnabled, tapState == .listenOnly {
            return L("Ready to scroll. macOS didn't allow holding back clicks, so middle-clicks also reach apps.")
        } else {
            return L("VectorScroll can't watch the mouse. Quit and reopen it. If that doesn't help, remove it from Accessibility and Input Monitoring in System Settings and add it again.")
        }
    }

    private func updateSizeMenuItems() {
        _ = settingsWindow
        sizePicker.selectItem(withTag: Int(overlay.size))
        updateMarkerPreview()
    }

    private func updateLaunchAtStartupItem() {
        applyLaunchAtStartupStatus(SMAppService.mainApp.status)
    }

    private func applyLaunchAtStartupStatus(_ status: SMAppService.Status) {
        guard builtSettingsWindow != nil, status != lastLaunchAtStartupStatus else { return }
        lastLaunchAtStartupStatus = status
        var state: NSControl.StateValue = .off
        var text = ""
        var toolTip: String?
        switch status {
        case .enabled:
            state = .on
        case .notRegistered, .notFound:
            break
        case .requiresApproval:
            text = L("Approval is required in Login Items.")
            toolTip = L("Open Login Items to allow VectorScroll.")
        @unknown default:
            text = L("Review VectorScroll in Login Items.")
        }
        if launchAtStartupItem.state != state { launchAtStartupItem.state = state }
        if launchAtStartupItem.toolTip != toolTip { launchAtStartupItem.toolTip = toolTip }
        if launchAtStartupStatusLabel.stringValue != text { launchAtStartupStatusLabel.stringValue = text }
        if launchAtStartupStatusLabel.isHidden != text.isEmpty { launchAtStartupStatusLabel.isHidden = text.isEmpty }
    }

    private func restoreSettings() {
        openSettingsOnLaunch = defaults.object(forKey: "openSettingsOnLaunch") as? Bool ?? true
        let show = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        menuBarIconHidden = !show && openSettingsOnLaunch
        if !show && !openSettingsOnLaunch {
            defaults.set(true, forKey: "showMenuBarIcon")
        }
        if let stored = defaults.object(forKey: "holdDelayEnabled") as? Bool {
            holdDelayEnabled = stored
        }
        let savedDelay = defaults.integer(forKey: "holdDelayMilliseconds")
        if (50...1000).contains(savedDelay), savedDelay.isMultiple(of: 50) {
            holdDelayMilliseconds = savedDelay
        }
        overlay.setDarkMode(defaults.bool(forKey: "darkMode"))
        let savedSize = defaults.integer(forKey: "markerSize")
        if markerSizes.contains(savedSize) {
            overlay.setSize(CGFloat(savedSize))
        }
        if let stored = defaults.string(forKey: "scrollMode") {
            scrollMode = ScrollMode(rawValue: stored) ?? .hold
        } else {
            scrollMode = defaults.bool(forKey: "holdToLockMode") ? .toggle : .hold
            defaults.set(scrollMode.rawValue, forKey: "scrollMode")
        }
        if defaults.object(forKey: "reverseVertical") == nil,
           defaults.object(forKey: "reverseHorizontal") == nil,
           let legacy = defaults.object(forKey: "reverseDirection") as? Bool {
            defaults.set(legacy, forKey: "reverseVertical")
            defaults.set(legacy, forKey: "reverseHorizontal")
        }
        reverseVertical = defaults.bool(forKey: "reverseVertical")
        reverseHorizontal = defaults.bool(forKey: "reverseHorizontal")
        raiseWindowOnScroll = defaults.object(forKey: "raiseWindowOnScroll") as? Bool ?? true
        let savedSpeed = defaults.integer(forKey: "scrollSpeedPercent")
        if (20...300).contains(savedSpeed), savedSpeed.isMultiple(of: 10) {
            scrollSpeedPercent = savedSpeed
        }
    }

    private func installEventTap() {
        let canListen = CGPreflightListenEventAccess()
        let canAccess = hasAccessibilityAccess
        defer { applyPermissionStatus(canListen: canListen, canAccess: canAccess) }
        guard canListen, canAccess else {
            tearDownEventTap()
            return
        }
        if let eventTap {
            if CGEvent.tapIsEnabled(tap: eventTap) { return }
            // A disabled notification can be lost. Poll and recover independently.
            clearMouseState()
            CGEvent.tapEnable(tap: eventTap, enable: true)
            if CGEvent.tapIsEnabled(tap: eventTap) { return }
            tearDownEventTap()
        }

        ExcludedApps.prepare()
        let events: [CGEventType] = [
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .otherMouseDragged
        ]

        func mask(_ events: [CGEventType]) -> CGEventMask {
            events.reduce(CGEventMask(0)) { (partial: CGEventMask, type: CGEventType) -> CGEventMask in
                partial | (CGEventMask(1) << CGEventMask(type.rawValue))
            }
        }

        let callback: CGEventTapCallBack = { (_, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<VectorScrollApp>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated {
                app.handleEvent(type: type, event: event)
            }
        }

        for (options, state) in [(CGEventTapOptions.defaultTap, TapState.filtering), (.listenOnly, .listenOnly)] {
            if let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: mask(events),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) {
                eventTap = tap
                tapState = state
                break
            }
        }
        guard let eventTap else {
            tapState = .none
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            tearDownEventTap()
            return
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                       eventsOfInterest: mask([.mouseMoved, .leftMouseDragged, .rightMouseDragged]),
                                       callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
           let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            motionTap = tap
            motionRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: isActive)
        }
    }

    private func clearMouseState() {
        stopScrolling()
        swallowedButtonUps.removeAll()
        excludedMiddleClick = false
    }

    private func tearDownEventTap() {
        clearMouseState()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        if let motionRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), motionRunLoopSource, .commonModes)
            self.motionRunLoopSource = nil
        }
        if let motionTap {
            CFMachPortInvalidate(motionTap)
            self.motionTap = nil
        }
        tapState = .none
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        installEventTap()
        if builtSettingsWindow != nil { updateLaunchAtStartupItem() }
    }

    private func startPermissionStatusTimer() {
        permissionStatusTimer?.cancel()
        permissionStatusInterval = nil
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in self?.installEventTap() }
        permissionStatusTimer = timer
        schedulePermissionStatusTimer(canListen: CGPreflightListenEventAccess(), canAccess: hasAccessibilityAccess)
        timer.resume()
    }

    private func schedulePermissionStatusTimer(canListen: Bool, canAccess: Bool) {
        guard let timer = permissionStatusTimer else { return }
        // Keep recovery for missed tap-disabled notifications, without waking every second when ready.
        let interval = canListen && canAccess ? 30 : 1
        guard interval != permissionStatusInterval else { return }
        permissionStatusInterval = interval
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval),
                       leeway: interval == 1 ? .milliseconds(300) : .seconds(5))
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayEventMarker {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The release may have happened while input delivery was disabled.
            clearMouseState()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Listen-only taps observe the same gestures, but cannot consume events.
        let filteredEvent: Unmanaged<CGEvent>? = tapState == .filtering ? nil : Unmanaged.passUnretained(event)
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let toggled = scrollMode == .toggle || (scrollMode == .both && heldMiddleClick == nil)
        if isActive, toggled, type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            stopScrolling()
            if tapState == .filtering { swallowedButtonUps.insert(button) }
            return filteredEvent
        }
        if type == .otherMouseDown, button == 2, appIsExcluded(event.location) {
            excludedMiddleClick = true
            return Unmanaged.passUnretained(event)
        }
        if button == 2, excludedMiddleClick, type == .otherMouseUp || type == .otherMouseDragged {
            if type == .otherMouseUp { excludedMiddleClick = false }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseUp || type == .rightMouseUp || type == .otherMouseUp {
            let swallowed = swallowedButtonUps.remove(button) != nil
            guard swallowed || (button == 2 && heldMiddleClick != nil) else { return Unmanaged.passUnretained(event) }
            if button == 2, let point = heldMiddleClick {
                // A release outside the dead zone was a drag, not a click. This also caps
                // how far posting the replay can move the pointer.
                let moved = abs(event.location.x - point.x) > deadZone || abs(event.location.y - point.y) > deadZone
                let shortPress = middleDownTimestamp.map {
                    event.timestamp >= $0 && Double(event.timestamp - $0) / 1_000_000_000 < 0.2
                } ?? false
                let replay = tapState == .filtering && scrollMode != .both
                    && (scrollMode == .toggle ? !isActive : shortPress && !leftDeadZone) && !moved
                heldMiddleClick = nil
                middleDownTimestamp = nil
                heldPointer = nil
                switch scrollMode {
                case .toggle:
                    cancelArmedHoldToLock()
                case .hold:
                    stopScrolling()
                case .both:
                    if isActive && !leftDeadZone && !moved {
                        // No held click now means this session stops on the next down.
                        engage()
                    } else {
                        stopScrolling()
                    }
                }
                if replay { postClick(point) }
            }
            return filteredEvent
        }

        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            if type == .otherMouseDragged, button == 2, heldMiddleClick != nil {
                heldPointer = event.unflippedLocation
            }
            if isActive { updateScrollMotion(at: event.unflippedLocation) }
            // Drags pass through. Holding them back keeps macOS from updating its pointer position.
            return Unmanaged.passUnretained(event)
        }

        if isActive { return Unmanaged.passUnretained(event) }

        if type == .otherMouseDown, button == 2 {
            heldMiddleClick = event.location
            middleDownTimestamp = event.timestamp
            heldPointer = nil
            if tapState == .filtering { swallowedButtonUps.insert(button) }
            if holdToLockMode {
                armHoldToLock(at: event.unflippedLocation, target: event.location)
            } else {
                startScrolling(at: event.unflippedLocation, target: event.location)
            }
            return filteredEvent
        }

        return Unmanaged.passUnretained(event)
    }

    private var appIsExcluded: @MainActor (CGPoint) -> Bool = { ExcludedApps.isExcluded(at: $0) }

    private func armHoldToLock(at point: CGPoint, target: CGPoint) {
        cancelArmedHoldToLock()
        if !holdDelayEnabled {
            startScrolling(at: point, target: target)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.engageWorkItem = nil
            // A delayed main queue must not turn a released click into a hold.
            guard self.middleButtonIsDown() else { return }
            self.startScrolling(at: point, target: target)
        }
        engageWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdToLockThreshold, execute: work)
    }

    private func cancelArmedHoldToLock() {
        engageWorkItem?.cancel()
        engageWorkItem = nil
    }

    private func startScrolling(at point: CGPoint, target: CGPoint) {
        guard tapState != .none else { return }
        scrollRemainder = .zero
        anchor = point
        isActive = true
        // Hold mode shows feedback after movement or a short hold, so a plain
        // middle-click never raises a window or flashes the indicator.
        // Toggle mode already filtered clicks with the delay, so show feedback now.
        engaged = false
        leftDeadZone = false
        pendingTarget = target
        scrollingGeneration &+= 1
        updateOverlay()
        let generation = scrollingGeneration
        // Toggle shows feedback right after the tap callback returns. Hold and Hold or click
        // show it after a short hold, so a quick middle-click never flashes the indicator.
        let feedbackDelay: TimeInterval = holdToLockMode ? 0 : 0.2
        let feedback = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, self.scrollingGeneration == generation else { return }
            self.feedbackWorkItem = nil
            guard self.holdToLockMode || self.heldMiddleClick == nil || self.middleButtonIsDown() else { return }
            self.engage()
        }
        feedbackWorkItem = feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + feedbackDelay, execute: feedback)
        stopScrollTimer()
        if let heldPointer { updateScrollMotion(at: heldPointer) }
    }

    private func stopScrollTimer() {
        timer?.cancel()
        timer = nil
        lastScrollTime = nil
        scrollRemainder = .zero
    }

    private func updateScrollMotion(at pointer: CGPoint) {
        guard isActive, let anchor else { return }
        let adjusted = CGPoint(x: applyDeadZone(pointer.x - anchor.x), y: applyDeadZone(pointer.y - anchor.y))
        guard adjusted.x != 0 || adjusted.y != 0 else {
            stopScrollTimer()
            return
        }
        leftDeadZone = true
        engage()
        guard timer == nil else { return }
        lastScrollTime = ProcessInfo.processInfo.systemUptime
        let generation = scrollingGeneration
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(16), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.scrollingGeneration == generation else { return }
            self.emitScrollTick()
        }
        self.timer = timer
        timer.resume()
    }

    private func stopScrolling() {
        cancelArmedHoldToLock()
        feedbackWorkItem?.cancel()
        feedbackWorkItem = nil
        focusCancellation?.cancel()
        focusCancellation = nil
        focusWorkItem?.cancel()
        focusWorkItem = nil
        // Discard replay eligibility, but still swallow any matching releases.
        heldMiddleClick = nil
        middleDownTimestamp = nil
        heldPointer = nil
        scrollingGeneration &+= 1
        stopScrollTimer()
        anchor = nil
        isActive = false
        engaged = false
        pendingTarget = nil
        updateOverlay()
    }

    private func updateOverlay() {
        let generation = scrollingGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scrollingGeneration == generation else { return }
            if self.isActive, self.engaged, let anchor = self.anchor {
                self.overlay.show(at: anchor)
            } else {
                self.overlay.hide()
            }
        }
    }

    private func engage() {
        guard !engaged, anchor != nil else { return }
        engaged = true
        updateOverlay()
        if raiseWindowOnScroll, let target = pendingTarget {
            focusCancellation?.cancel()
            focusWorkItem?.cancel()
            let cancellation = FocusCancellation()
            let work = DispatchWorkItem { Self.focusTarget(at: target, cancellation: cancellation) }
            focusCancellation = cancellation
            focusWorkItem = work
            // AX objects stay on this queue; cancelled pending requests never perform AX work.
            accessibilityQueue.async(execute: work)
        }
    }

    private func emitScrollTick() {
        guard isActive, timer != nil, let anchor else { return }
        let pointer = heldMiddleClick != nil ? heldPointer ?? NSEvent.mouseLocation : NSEvent.mouseLocation
        let adjusted = CGPoint(x: applyDeadZone(pointer.x - anchor.x), y: applyDeadZone(pointer.y - anchor.y))
        guard adjusted.x != 0 || adjusted.y != 0 else {
            stopScrollTimer()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastScrollTime.map { now - $0 } ?? 0
        lastScrollTime = now
        guard let delta = nextScrollDelta(for: adjusted, elapsed: elapsed) else { return }

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: delta.vertical,
            wheel2: delta.horizontal,
            wheel3: 0
        ) else {
            return
        }

        scrollEvent.post(tap: .cgSessionEventTap)
    }

    private func nextScrollDelta(for adjusted: CGPoint, elapsed: TimeInterval = 1.0 / 60) -> (vertical: Int32, horizontal: Int32)? {
        guard adjusted.x != 0 || adjusted.y != 0 else { return nil }
        func curved(_ value: CGFloat) -> CGFloat {
            value * pow(abs(value) / 120, 0.35)
        }
        // Preserve the nominal 60 Hz curve and cap, integrating its pixels/second over time.
        // At most 50 ms is caught up after a busy main queue; resuming starts a new clock.
        let ticks = CGFloat(min(max(elapsed, 0), 0.05) * 60)
        scrollRemainder.y += clamp(curved(adjusted.y) * scrollScale * (reverseVertical ? -1 : 1)) * ticks
        scrollRemainder.x += clamp(-curved(adjusted.x) * scrollScale * (reverseHorizontal ? -1 : 1)) * ticks
        let vertical = Int32(scrollRemainder.y.rounded())
        let horizontal = Int32(scrollRemainder.x.rounded())
        scrollRemainder.y -= CGFloat(vertical)
        scrollRemainder.x -= CGFloat(horizontal)
        return vertical == 0 && horizontal == 0 ? nil : (vertical, horizontal)
    }

    private func applyDeadZone(_ value: CGFloat) -> CGFloat {
        if abs(value) <= deadZone {
            return 0
        }
        return value > 0 ? value - deadZone : value + deadZone
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, -maxDeltaPerTick), maxDeltaPerTick)
    }

    nonisolated private static func element(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
        return error == .success ? element : nil
    }

    nonisolated private static func parent(of element: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXParent" as CFString, &value) == .success else { return nil }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated private static func pid(of element: AXUIElement) -> pid_t? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var pid = pid_t()
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    nonisolated private static func focusTarget(at point: CGPoint, cancellation: FocusCancellation) {
        guard !cancellation.isCancelled, AXIsProcessTrusted(),
              !cancellation.isCancelled, let element = element(at: point),
              !cancellation.isCancelled, let pid = pid(of: element),
              !cancellation.isCancelled else { return }
        let application = NSRunningApplication(processIdentifier: pid)
        guard !cancellation.isCancelled else { return }
        application?.activate()
        var current: AXUIElement? = element
        for _ in 0..<10 {
            guard !cancellation.isCancelled, let candidate = current else { return }
            AXUIElementSetMessagingTimeout(candidate, 0.25)
            guard !cancellation.isCancelled else { return }
            let result = AXUIElementPerformAction(candidate, "AXRaise" as CFString)
            guard !cancellation.isCancelled, result != .success else { return }
            current = parent(of: candidate)
            guard !cancellation.isCancelled else { return }
        }
    }
}

@MainActor
private final class ScrollOverlayWindow {
    private let window: NSPanel
    private let content = ScrollOverlayView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    private var anchor: CGPoint?
    var isDarkMode: Bool { content.isDarkMode }
    var size: CGFloat { content.frame.width }

    init() {
        window = NSPanel(
            contentRect: content.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.contentView = content
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    func show(at point: CGPoint) {
        anchor = point
        move(to: point)
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }

    func setDarkMode(_ enabled: Bool) {
        content.isDarkMode = enabled
        content.needsDisplay = true
    }

    func setSize(_ size: CGFloat) {
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        content.frame = frame
        window.setContentSize(frame.size)
        content.needsDisplay = true
        if let anchor {
            move(to: anchor)
        }
    }

    private func move(to point: CGPoint) {
        let offset = content.frame.width / 2
        window.setFrameOrigin(NSPoint(x: point.x - offset, y: point.y - offset))
    }
}

private final class ScrollOverlayView: NSView {
    var isDarkMode = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let inset = max(1, side * 0.0625)
        let circle = bounds.insetBy(dx: inset, dy: inset)
        let mid = side / 2

        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: circle.offsetBy(dx: 0, dy: max(1, side * 0.03125))).fill()

        let fill = isDarkMode
            ? NSColor.black.withAlphaComponent(0.88)
            : NSColor(calibratedWhite: 0.94, alpha: 0.96)
        let stroke = isDarkMode
            ? NSColor.white.withAlphaComponent(0.72)
            : NSColor(calibratedWhite: 0.42, alpha: 0.9)
        let symbol = isDarkMode
            ? NSColor.white.withAlphaComponent(0.78)
            : NSColor(calibratedWhite: 0.24, alpha: 0.9)

        fill.setFill()
        NSBezierPath(ovalIn: circle).fill()

        stroke.setStroke()
        let ring = NSBezierPath(ovalIn: circle)
        ring.lineWidth = max(1, side * 0.03125)
        ring.stroke()

        symbol.setFill()
        let dot = side * 0.125
        NSBezierPath(ovalIn: NSRect(x: mid - dot / 2, y: mid - dot / 2, width: dot, height: dot)).fill()

        drawArrow(from: NSPoint(x: mid, y: side * 0.375), to: NSPoint(x: mid, y: side * 0.15625), color: symbol, side: side)
        drawArrow(from: NSPoint(x: mid, y: side * 0.625), to: NSPoint(x: mid, y: side * 0.84375), color: symbol, side: side)
        drawArrow(from: NSPoint(x: side * 0.375, y: mid), to: NSPoint(x: side * 0.15625, y: mid), color: symbol, side: side)
        drawArrow(from: NSPoint(x: side * 0.625, y: mid), to: NSPoint(x: side * 0.84375, y: mid), color: symbol, side: side)
    }

    private func drawArrow(from start: NSPoint, to end: NSPoint, color: NSColor, side: CGFloat) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = max(1.5, side * 0.0625)
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = side * 0.11
        let spread: CGFloat = .pi / 6

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: NSPoint(
            x: end.x - cos(angle - spread) * headLength,
            y: end.y - sin(angle - spread) * headLength
        ))
        head.move(to: end)
        head.line(to: NSPoint(
            x: end.x - cos(angle + spread) * headLength,
            y: end.y - sin(angle + spread) * headLength
        ))
        head.lineWidth = max(1.5, side * 0.0625)
        head.lineCapStyle = .round
        head.stroke()
    }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--install-update" {
    exit(UpdateInstaller.runHelper(URL(fileURLWithPath: CommandLine.arguments[2])))
}

let app = NSApplication.shared
private let delegate = VectorScrollApp()
app.delegate = delegate
app.run()
