@preconcurrency import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import ServiceManagement

@MainActor
private final class VectorScrollApp: NSObject, NSApplicationDelegate {
    private let markerSizes = [28, 32, 40, 48]
    private let defaults = UserDefaults.standard
    private var updateItem: NSButton!
    private var downloadItem: NSButton!
    private var availableUpdate: AppUpdate?
    private var updateTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var updateTimer: DispatchSourceTimer?
    private var showUpdateResult = false
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var permissionItem: NSButton!
    private var permissionStatusLabel: NSTextField!
    private var lightModeItem: NSButton!
    private var darkModeItem: NSButton!
    private var holdScrollItem: NSButton!
    private var holdToLockItem: NSButton!
    private var launchAtStartupItem: NSButton!
    private var hideIconItem: NSButton!
    private var sizePicker: NSPopUpButton!
    private var settingsWindow: NSWindow!
    private var openSettingsButton: NSButton!
    private var openSettingsOnLaunch = true
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: DispatchSourceTimer?
    private var permissionStatusTimer: DispatchSourceTimer?
    private var anchor: CGPoint?
    private var isActive = false
    private var eventTapInstalled = false
    private var holdToLockMode = false
    private var engageWorkItem: DispatchWorkItem?
    private var menuBarIconHidden = false
    private let overlay = ScrollOverlayWindow()

    private let baseScrollScale: CGFloat = 0.42
    private var scrollSpeedPercent = 100
    private var scrollScale: CGFloat { baseScrollScale * CGFloat(scrollSpeedPercent) / 100 }
    private var reverseDirection = false
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
    private var reverseItem: NSButton!
    private var onboarding: Onboarding?
    private var speedSlider: NSSlider!
    private var speedLabel: NSTextField!
    private var delayToggle: NSButton!
    private var delaySlider: NSSlider!
    private var delayLabel: NSTextField!
    private var hasAccessibilityAccess: Bool { CGPreflightPostEventAccess() && AXIsProcessTrusted() }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            showUpdateError(error)
        }
        installEventTap()
        startPermissionStatusTimer()
        checkForUpdates(manual: false)
        let updateTimer = DispatchSource.makeTimerSource(queue: .main)
        updateTimer.schedule(deadline: .now() + .seconds(86400), repeating: .seconds(86400), leeway: .seconds(60))
        updateTimer.setEventHandler { [weak self] in self?.checkForUpdates(manual: false) }
        self.updateTimer = updateTimer
        updateTimer.resume()
        _ = try? UpdateInstaller.acknowledgeLaunch()
    }

    private func configureMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit VectorScroll", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        self.menu = menu
        configureSettingsWindow()
        if !menuBarIconHidden { installStatusItem() }
    }

    @objc private func showSettings() {
        stopScrolling()
        updateLaunchAtStartupItem()
        updatePermissionMenuItem()
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func configureSettingsWindow() {
        settingsWindow = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        settingsWindow.title = "VectorScroll Settings"
        SettingsStyle.prepareWindow(settingsWindow)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.minSize = NSSize(width: 520, height: 500)
        if !settingsWindow.setFrameUsingName("VectorScrollSettingsV4") { settingsWindow.center() }
        settingsWindow.setFrameAutosaveName("VectorScrollSettingsV4")

        func label(_ text: String, secondary: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: secondary ? 12 : 14)
            field.preferredMaxLayoutWidth = 556
            field.textColor = secondary ? SettingsStyle.secondary : SettingsStyle.text
            return field
        }
        func row(_ views: NSView...) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 12
            return stack
        }
        func button(_ title: String, _ symbol: String, _ action: Selector) -> SettingsButton {
            SettingsButton(title, symbol: symbol, target: self, action: action)
        }
        func checkbox(_ title: String, _ symbol: String, _ action: Selector) -> SettingsButton {
            SettingsButton(title, symbol: symbol, kind: .toggle, target: self, action: action)
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        func fullWidth(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        func section(_ title: String, _ symbol: String) {
            // 24 above the rule, 16 below, 12 under the heading. Same on every section.
            if let previous = stack.arrangedSubviews.last { stack.setCustomSpacing(24, after: previous) }
            let divider = NSBox()
            divider.boxType = .custom
            divider.fillColor = SettingsStyle.border
            divider.borderWidth = 0
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            fullWidth(divider)
            stack.setCustomSpacing(16, after: divider)
            let icon = NSImageView(image: SettingsStyle.symbol(symbol)!)
            icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 17).isActive = true
            let heading = label(title)
            heading.font = .systemFont(ofSize: 14, weight: .semibold)
            let headingRow = row(icon, heading)
            stack.addArrangedSubview(headingRow)
            stack.setCustomSpacing(12, after: headingRow)
        }
        let appIcon = NSImageView(image: NSApp.applicationIconImage)
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            appIcon.widthAnchor.constraint(equalToConstant: 48),
            appIcon.heightAnchor.constraint(equalToConstant: 48)
        ])
        let title = label("VectorScroll")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let guideButton = button("Setup Guide", "questionmark.circle", #selector(showOnboarding))
        guideButton.setContentHuggingPriority(.required, for: .horizontal)
        fullWidth(row(appIcon, title, spacer, guideButton))

        section("Scrolling", "computermouse")
        let hold = SettingsButton("Scroll while holding the middle button", symbol: "hand.point.up.left", kind: .choice, target: self, action: #selector(selectHoldToScroll))
        hold.displayTitle = "Hold to scroll"
        hold.detail = "Release the middle button to stop"
        holdScrollItem = hold
        let click = SettingsButton("Keep scrolling until the next click", symbol: "cursorarrow.click", kind: .choice, target: self, action: #selector(selectHoldToLock))
        click.displayTitle = "Toggle scrolling"
        holdToLockItem = click
        // Cards must not outrank the window's stay-put priority (500), or the
        // window widens to fit their full accessibility titles.
        for card in [hold, click] { card.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let modes = row(hold, click)
        modes.distribution = .fillEqually
        modes.translatesAutoresizingMaskIntoConstraints = false
        let modesPadding = NSView()
        modesPadding.translatesAutoresizingMaskIntoConstraints = false
        modesPadding.addSubview(modes)
        NSLayoutConstraint.activate([
            modes.leadingAnchor.constraint(equalTo: modesPadding.leadingAnchor, constant: 8),
            modes.trailingAnchor.constraint(equalTo: modesPadding.trailingAnchor, constant: -8),
            modes.topAnchor.constraint(equalTo: modesPadding.topAnchor, constant: 8),
            modes.bottomAnchor.constraint(equalTo: modesPadding.bottomAnchor, constant: -8),
            modes.heightAnchor.constraint(equalToConstant: 64)
        ])
        let modesGlass = SettingsStyle.glassContainer(for: modesPadding, cornerRadius: 12)
        modesGlass.heightAnchor.constraint(equalToConstant: 80).isActive = true
        fullWidth(modesGlass)
        reverseItem = checkbox("Reverse direction", "arrow.up.arrow.down", #selector(toggleReverseDirection))
        fullWidth(reverseItem)
        speedSlider = NSSlider(value: Double(scrollSpeedPercent), minValue: 50, maxValue: 200,
                               target: self, action: #selector(changeScrollSpeed(_:)))
        speedSlider.numberOfTickMarks = 16
        speedSlider.tickMarkPosition = .below
        speedSlider.allowsTickMarkValuesOnly = true
        speedSlider.isContinuous = true
        speedSlider.setAccessibilityLabel("Scroll speed in percent")
        speedSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        speedLabel = label("")
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let speedRow = row(label("Speed", secondary: true), speedSlider, speedLabel)
        stack.addArrangedSubview(speedRow)
        delayToggle = checkbox("Delay before scrolling starts", "timer", #selector(toggleHoldDelay))
        delaySlider = NSSlider(value: Double(holdDelayMilliseconds), minValue: 50, maxValue: 1000,
                               target: self, action: #selector(changeHoldDelay(_:)))
        delaySlider.numberOfTickMarks = 20
        delaySlider.tickMarkPosition = .below
        delaySlider.allowsTickMarkValuesOnly = true
        delaySlider.isContinuous = true
        delaySlider.setAccessibilityLabel("Hold duration in milliseconds")
        delaySlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        delayLabel = label("")
        delayLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        delayItem = NSStackView(views: [delayToggle, row(delaySlider, delayLabel)])
        delayItem.orientation = .vertical
        delayItem.alignment = .leading
        delayItem.spacing = 4
        fullWidth(delayItem)
        stack.setCustomSpacing(24, after: speedRow) // delayItem hides in hold mode

        section("Indicator", "scope")
        lightModeItem = NSButton(radioButtonWithTitle: "Light", target: self, action: #selector(selectLightMode))
        darkModeItem = NSButton(radioButtonWithTitle: "Dark", target: self, action: #selector(selectDarkMode))
        sizePicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for size in markerSizes {
            sizePicker.addItem(withTitle: "\(size) pt")
            sizePicker.lastItem?.tag = size
        }
        sizePicker.target = self
        sizePicker.action = #selector(selectMarkerSize(_:))
        sizePicker.setAccessibilityLabel("Indicator size")
        stack.addArrangedSubview(row(lightModeItem, darkModeItem, label("Size", secondary: true), sizePicker))

        section("App", "slider.horizontal.3")
        openSettingsButton = checkbox("Open settings on launch", "macwindow", #selector(toggleOpenSettings))
        hideIconItem = checkbox("Show menu bar icon", "menubar.rectangle", #selector(toggleMenuBarIcon))
        launchAtStartupItem = checkbox("Launch at login", "power", #selector(toggleLaunchAtStartup))
        launchAtStartupItem.allowsMixedState = true
        fullWidth(openSettingsButton)
        stack.setCustomSpacing(0, after: openSettingsButton)
        fullWidth(hideIconItem)
        stack.setCustomSpacing(0, after: hideIconItem)
        fullWidth(label("One stays on so settings are always within reach.", secondary: true))
        fullWidth(launchAtStartupItem)
        permissionStatusLabel = label("", secondary: true)
        fullWidth(permissionStatusLabel)
        permissionItem = button("", "hand.raised", #selector(openPermissionSettings))
        stack.addArrangedSubview(permissionItem)

        section("Updates", "arrow.down.circle")
        fullWidth(label("Version \(AppUpdate.installedVersion) · Checks daily. Installs when you choose.", secondary: true))
        updateItem = button("Check for Updates…", "arrow.clockwise", #selector(checkUpdatesFromMenu))
        downloadItem = button("Install Update…", "arrow.down", #selector(installUpdate))
        downloadItem.isHidden = true
        stack.addArrangedSubview(row(updateItem, downloadItem))

        let content = settingsWindow.contentView!
        let backdrop = SettingsStyle.backdrop()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backdrop)
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
        backdrop.addSubview(scroll)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        updateMarkerMenuItem()
        updateSizeMenuItems()
        updateScrollModeMenuItems()
        updateSpeedControls()
        updateLaunchAtStartupItem()
        updatePermissionMenuItem()
        refreshAccessControls()
    }

    @objc private func toggleReverseDirection() {
        reverseDirection = reverseItem.state == .on
        defaults.set(reverseDirection, forKey: "reverseDirection")
    }

    @objc private func changeScrollSpeed(_ sender: NSSlider) {
        scrollSpeedPercent = min(200, max(50, Int((sender.doubleValue / 10).rounded()) * 10))
        defaults.set(scrollSpeedPercent, forKey: "scrollSpeedPercent")
        updateSpeedControls()
    }

    private func updateSpeedControls() {
        reverseItem.state = reverseDirection ? .on : .off
        speedSlider.doubleValue = Double(scrollSpeedPercent)
        speedLabel.stringValue = "\(scrollSpeedPercent)%"
    }

    @objc private func checkUpdatesFromMenu() {
        checkForUpdates(manual: true)
    }

    private func checkForUpdates(manual: Bool) {
        guard installTask == nil else { return }
        showUpdateResult = showUpdateResult || manual
        guard updateTask == nil else { return }
        updateItem.title = "Checking for Updates…"
        updateTask = Task { [weak self] in
            do {
                let update = try await AppUpdate.check()
                guard let self, !Task.isCancelled else { return }
                self.applyUpdate(update)
                if self.showUpdateResult {
                    self.stopScrolling()
                    let alert = NSAlert()
                    if let update {
                        alert.messageText = "VectorScroll \(update.version) is available"
                        alert.informativeText = "VectorScroll will download and verify the update, install it, and restart."
                        alert.addButton(withTitle: "Install Update")
                        alert.addButton(withTitle: "Later")
                    } else {
                        alert.messageText = "You're up to date"
                        alert.informativeText = "VectorScroll \(AppUpdate.installedVersion) is installed."
                        alert.addButton(withTitle: "OK")
                    }
                    NSApp.activate()
                    if alert.runModal() == .alertFirstButtonReturn, update != nil {
                        self.installUpdate()
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                if self.showUpdateResult {
                    self.showUpdateError(error.localizedDescription)
                }
            }
            self?.updateTask = nil
            self?.showUpdateResult = false
            self?.updateItem.title = "Check for Updates…"
        }
    }

    private func applyUpdate(_ update: AppUpdate?) {
        guard installTask == nil else { return }
        availableUpdate = update
        downloadItem.isHidden = update == nil
        downloadItem.title = update.map { "Install Update \($0.version)…" } ?? "Install Update…"
    }

    @objc private func installUpdate() {
        guard let update = availableUpdate, installTask == nil else { return }
        let destination = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard let helper = Bundle.main.executableURL else { return }
        do { _ = try UpdateInstaller.validateDestination(destination) }
        catch { showUpdateError(error.localizedDescription); return }
        showSettings()
        defaults.set("", forKey: "updateInstallError")
        updateItem.isEnabled = false
        downloadItem.isEnabled = false
        downloadItem.title = "Downloading…"
        installTask = Task { [weak self] in
            do {
                let data = try await UpdateInstaller.download(update)
                guard let self, !Task.isCancelled else { return }
                self.downloadItem.title = "Verifying…"
                let pid = ProcessInfo.processInfo.processIdentifier
                let plan = try await Task.detached {
                    try UpdateInstaller.prepare(update, image: data, destination: destination,
                                                helperSource: helper, parentPID: pid)
                }.value
                guard !Task.isCancelled else { return }
                self.downloadItem.title = "Restarting…"
                try await Task.detached { try UpdateInstaller.launchHelper(plan) }.value
                self.installTask = nil
                NSApp.terminate(nil)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.installTask = nil
                self.updateItem.isEnabled = true
                self.downloadItem.isEnabled = true
                self.applyUpdate(self.availableUpdate)
                self.showUpdateError(error.localizedDescription)
            }
        }
    }

    private func showUpdateError(_ message: String) {
        stopScrolling()
        let alert = NSAlert()
        alert.messageText = "Update could not be completed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
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
        delayToggle.state = holdDelayEnabled ? .on : .off
        delaySlider.isEnabled = holdDelayEnabled
        delaySlider.doubleValue = Double(holdDelayMilliseconds)
        delayLabel.stringValue = "\(holdDelayMilliseconds) ms"
        delayLabel.textColor = holdDelayEnabled ? .labelColor : .secondaryLabelColor
        delayItem.isHidden = !holdToLockMode
        (holdToLockItem as? SettingsButton)?.detail = holdDelayEnabled ? "Hold to start, click to stop" : "Click to start, click to stop"

    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.up.and.down.circle.fill", accessibilityDescription: "Vector Scroll")
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
        if onboarding != nil { showOnboarding() } else if openSettingsOnLaunch { showSettings() }
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

    @objc private func selectHoldToScroll() {
        stopScrolling()
        holdToLockMode = false
        defaults.set(false, forKey: "holdToLockMode")
        updateScrollModeMenuItems()
    }

    @objc private func selectHoldToLock() {
        stopScrolling()
        holdToLockMode = true
        defaults.set(true, forKey: "holdToLockMode")
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
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()
            case .notRegistered:
                try SMAppService.mainApp.register()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notFound:
                break
            @unknown default:
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Launch at login could not be changed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Cancel")
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
                if self.openSettingsOnLaunch, !self.settingsWindow.isVisible,
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
        lightModeItem.state = overlay.isDarkMode ? .off : .on
        darkModeItem.state = overlay.isDarkMode ? .on : .off
    }

    private func updateScrollModeMenuItems() {
        holdScrollItem.state = holdToLockMode ? .off : .on
        holdToLockItem.state = holdToLockMode ? .on : .off
        updateDelayMenu()
    }

    private func updatePermissionMenuItem() {
        applyPermissionStatus(canListen: CGPreflightListenEventAccess(), canAccess: hasAccessibilityAccess)
    }

    private func applyPermissionStatus(canListen: Bool, canAccess: Bool) {
        permissionStatusLabel.stringValue = "Input Monitoring: \(canListen ? "Allowed" : "Needed") · Accessibility: \(canAccess ? "Allowed" : "Needed")"
        permissionItem.isHidden = canListen && canAccess
        permissionItem.title = canListen ? "Accessibility Settings…" : "Input Monitoring Settings…"
        onboarding?.refresh(canListen: canListen, canAccess: canAccess)
    }

    private func updateSizeMenuItems() {
        sizePicker.selectItem(withTag: Int(overlay.size))
    }

    private func updateLaunchAtStartupItem() {
        applyLaunchAtStartupStatus(SMAppService.mainApp.status)
    }

    private func applyLaunchAtStartupStatus(_ status: SMAppService.Status) {
        launchAtStartupItem.isEnabled = true
        launchAtStartupItem.title = "Launch at login"
        launchAtStartupItem.toolTip = nil
        switch status {
        case .enabled:
            launchAtStartupItem.state = .on
        case .notRegistered:
            launchAtStartupItem.state = .off
        case .requiresApproval:
            launchAtStartupItem.state = .mixed
            launchAtStartupItem.title = "Launch at login: needs approval"
            launchAtStartupItem.toolTip = "Open Login Items to allow VectorScroll."
        case .notFound:
            launchAtStartupItem.state = .off
            launchAtStartupItem.isEnabled = false
            launchAtStartupItem.title = "Launch at login unavailable"
            launchAtStartupItem.toolTip = "Run the installed VectorScroll app from Applications."
        @unknown default:
            launchAtStartupItem.state = .mixed
            launchAtStartupItem.title = "Review Login Items"
        }
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
        if let stored = defaults.object(forKey: "holdToLockMode") as? Bool {
            holdToLockMode = stored
        }
        reverseDirection = defaults.bool(forKey: "reverseDirection")
        let savedSpeed = defaults.integer(forKey: "scrollSpeedPercent")
        if (50...200).contains(savedSpeed), savedSpeed.isMultiple(of: 10) {
            scrollSpeedPercent = savedSpeed
        }
    }

    private func installEventTap() {
        updatePermissionMenuItem()
        guard CGPreflightListenEventAccess(), hasAccessibilityAccess else {
            // Permission can be revoked while running. Retire the old tap before
            // retrying, instead of overwriting a still-registered run-loop source.
            stopScrolling()
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                self.runLoopSource = nil
            }
            if let eventTap {
                CFMachPortInvalidate(eventTap)
                self.eventTap = nil
            }
            eventTapInstalled = false
            return
        }
        if eventTapInstalled { return }

        let events: [CGEventType] = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .otherMouseUp
        ]

        let mask = events.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<VectorScrollApp>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated {
                app.handleEvent(type: type, event: event)
            }
        }

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            eventTapInstalled = false
            return
        }

        eventTapInstalled = true
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func startPermissionStatusTimer() {
        permissionStatusTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            self?.installEventTap()
            self?.updateLaunchAtStartupItem()
        }
        permissionStatusTimer = timer
        timer.resume()
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The release may have happened while input delivery was disabled.
            stopScrolling()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if isActive {
            if holdToLockMode {
                if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                    stopScrolling()
                }
            } else if type == .otherMouseUp {
                if event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                    stopScrolling()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseDown {
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            if buttonNumber == 2 {
                if holdToLockMode {
                    armHoldToLock(at: event.unflippedLocation, target: event.location)
                } else {
                    startScrolling(at: event.unflippedLocation, target: event.location)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if holdToLockMode, type == .otherMouseUp {
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            if buttonNumber == 2 {
                cancelArmedHoldToLock()
            }
        }

        return Unmanaged.passUnretained(event)
    }

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
            guard CGEventSource.buttonState(.combinedSessionState, button: .center) else { return }
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
        guard eventTapInstalled else { return }
        anchor = point
        isActive = true
        // Hold mode engages once the pointer leaves the dead zone, so a plain
        // middle-click never raises a window or flashes the indicator.
        // Toggle mode already filtered clicks with the delay, so show feedback now.
        engaged = false
        pendingTarget = target
        if holdToLockMode { engage() }

        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.emitScrollTick()
        }
        self.timer = timer
        timer.resume()
    }

    private func stopScrolling() {
        cancelArmedHoldToLock()
        guard isActive else { return }
        timer?.cancel()
        timer = nil
        anchor = nil
        isActive = false
        engaged = false
        pendingTarget = nil
        overlay.hide()
    }

    private func engage() {
        guard !engaged, let anchor else { return }
        engaged = true
        if let target = pendingTarget, AXIsProcessTrusted(), let element = element(at: target) {
            focusTarget(element)
        }
        overlay.show(at: anchor)
    }

    private func emitScrollTick() {
        guard let anchor else { return }

        let pointer = NSEvent.mouseLocation
        let offset = CGPoint(x: pointer.x - anchor.x, y: pointer.y - anchor.y)
        let adjusted = CGPoint(
            x: applyDeadZone(offset.x),
            y: applyDeadZone(offset.y)
        )

        guard adjusted.x != 0 || adjusted.y != 0 else { return }
        engage()

        let direction: CGFloat = reverseDirection ? -1 : 1
        let vertical = clamp(adjusted.y * scrollScale * direction)
        let horizontal = clamp(-adjusted.x * scrollScale * direction)

        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(vertical.rounded()),
            wheel2: Int32(horizontal.rounded()),
            wheel3: 0
        ) else {
            return
        }

        scrollEvent.post(tap: .cgSessionEventTap)
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

    private func element(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
        return error == .success ? element : nil
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXParent" as CFString, &value) == .success else { return nil }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var pid = pid_t()
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private func focusTarget(_ element: AXUIElement) {
        guard let pid = pid(of: element) else { return }
        NSRunningApplication(processIdentifier: pid)?.activate()
        var current: AXUIElement? = element
        for _ in 0..<10 {
            guard let candidate = current else { return }
            if AXUIElementPerformAction(candidate, "AXRaise" as CFString) == .success {
                return
            }
            current = parent(of: candidate)
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
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
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
