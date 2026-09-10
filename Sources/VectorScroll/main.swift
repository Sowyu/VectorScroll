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
    private var updateTimer: DispatchSourceTimer?
    private var showUpdateResult = false
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var permissionItem: NSButton!
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
    private var permissionRetryTimer: DispatchSourceTimer?
    private var permissionStatusTimer: DispatchSourceTimer?
    private var accessibilityPromptedThisRun = false
    private var anchor: CGPoint?
    private var isActive = false
    private var eventTapInstalled = false
    private var holdToLockMode = false
    private var engageWorkItem: DispatchWorkItem?
    private var menuBarIconHidden = false
    private let overlay = ScrollOverlayWindow()

    private let scrollScale: CGFloat = 0.42
    private let deadZone: CGFloat = 10
    private let maxDeltaPerTick: CGFloat = 120
    private var holdDelayEnabled = true
    private var holdDelayMilliseconds = 200
    private var holdToLockThreshold: TimeInterval {
        holdDelayEnabled ? Double(holdDelayMilliseconds) / 1000 : 0
    }
    private var delayItem: NSStackView!
    private var delayToggle: NSButton!
    private var delaySlider: NSSlider!
    private var delayLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        restoreSettings()
        configureMenu()
        if openSettingsOnLaunch { showSettings() }
        requestPermissions()
        installEventTap()
        startPermissionStatusTimer()
        checkForUpdates(manual: false)
        let updateTimer = DispatchSource.makeTimerSource(queue: .main)
        updateTimer.schedule(deadline: .now() + .seconds(86400), repeating: .seconds(86400), leeway: .seconds(60))
        updateTimer.setEventHandler { [weak self] in self?.checkForUpdates(manual: false) }
        self.updateTimer = updateTimer
        updateTimer.resume()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopScrolling()
        permissionRetryTimer?.cancel()
        permissionStatusTimer?.cancel()
        updateTask?.cancel()
        updateTimer?.cancel()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    private func configureMenu() {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
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
        settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        settingsWindow.title = "VectorScroll Settings"
        settingsWindow.isReleasedWhenClosed = false
        if !settingsWindow.setFrameUsingName("VectorScrollSettings") { settingsWindow.center() }
        settingsWindow.setFrameAutosaveName("VectorScrollSettings")

        func label(_ text: String, secondary: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: secondary ? 11 : 13)
            field.preferredMaxLayoutWidth = 472
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            return field
        }
        func row(_ views: NSView...) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 12
            return stack
        }
        func button(_ title: String, _ action: Selector) -> NSButton {
            NSButton(title: title, target: self, action: action)
        }
        func checkbox(_ title: String, _ action: Selector) -> NSButton {
            NSButton(checkboxWithTitle: title, target: self, action: action)
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        func section(_ title: String) {
            if !stack.arrangedSubviews.isEmpty {
                let divider = NSBox()
                divider.boxType = .separator
                stack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let heading = label(title)
            heading.font = .boldSystemFont(ofSize: 13)
            stack.addArrangedSubview(heading)
        }
        section("Scrolling")
        holdScrollItem = NSButton(radioButtonWithTitle: "Scroll while holding the middle button", target: self, action: #selector(selectHoldToScroll))
        holdToLockItem = NSButton(radioButtonWithTitle: "Keep scrolling until the next click", target: self, action: #selector(selectHoldToLock))
        stack.addArrangedSubview(holdScrollItem)
        stack.addArrangedSubview(holdToLockItem)
        stack.addArrangedSubview(label("Move the pointer away from the starting point to control direction and speed.", secondary: true))
        delayToggle = checkbox("Require a hold before starting", #selector(toggleHoldDelay))
        delaySlider = NSSlider(value: Double(holdDelayMilliseconds), minValue: 50, maxValue: 1000,
                               target: self, action: #selector(changeHoldDelay(_:)))
        delaySlider.numberOfTickMarks = 20
        delaySlider.allowsTickMarkValuesOnly = true
        delaySlider.isContinuous = true
        delaySlider.setAccessibilityLabel("Hold duration in milliseconds")
        delaySlider.widthAnchor.constraint(equalToConstant: 210).isActive = true
        delayLabel = label("")
        delayItem = NSStackView(views: [delayToggle, row(delaySlider, delayLabel)])
        delayItem.orientation = .vertical
        delayItem.alignment = .leading
        delayItem.spacing = 6
        stack.addArrangedSubview(delayItem)

        section("Indicator")
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
        stack.addArrangedSubview(row(lightModeItem, darkModeItem, label("Size"), sizePicker))

        section("App")
        openSettingsButton = checkbox("Open settings whenever VectorScroll opens", #selector(toggleOpenSettings))
        hideIconItem = checkbox("Show menu bar icon", #selector(toggleMenuBarIcon))
        launchAtStartupItem = checkbox("Launch at login", #selector(toggleLaunchAtStartup))
        stack.addArrangedSubview(openSettingsButton)
        stack.addArrangedSubview(hideIconItem)
        stack.addArrangedSubview(label("At least one of these stays on. With the icon hidden, reopen VectorScroll to access settings.", secondary: true))
        stack.addArrangedSubview(launchAtStartupItem)
        permissionItem = button("Request Permissions", #selector(requestPermissions))
        stack.addArrangedSubview(permissionItem)

        section("Updates")
        stack.addArrangedSubview(label("VectorScroll \(AppUpdate.installedVersion) · Checks GitHub at launch and daily.", secondary: true))
        updateItem = button("Check for Updates…", #selector(checkUpdatesFromMenu))
        downloadItem = button("Download Update…", #selector(downloadUpdate))
        downloadItem.isHidden = true
        stack.addArrangedSubview(row(updateItem, downloadItem))
        stack.addArrangedSubview(label("Downloads open in your browser. Quit the app and replace it in Applications.", secondary: true))
        let quit = NSButton(title: "Quit VectorScroll", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        stack.addArrangedSubview(quit)

        let content = settingsWindow.contentView!
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        updateMarkerMenuItem()
        updateSizeMenuItems()
        updateScrollModeMenuItems()
        updateLaunchAtStartupItem()
        updatePermissionMenuItem()
        refreshAccessControls()
    }

    @objc private func checkUpdatesFromMenu() {
        checkForUpdates(manual: true)
    }

    private func checkForUpdates(manual: Bool) {
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
                        alert.informativeText = "Download the DMG, quit VectorScroll, and replace the app in Applications."
                        alert.addButton(withTitle: "Download Update")
                        alert.addButton(withTitle: "Later")
                    } else {
                        alert.messageText = "You're up to date"
                        alert.informativeText = "VectorScroll \(AppUpdate.installedVersion) is installed."
                        alert.addButton(withTitle: "OK")
                    }
                    NSApp.activate()
                    if alert.runModal() == .alertFirstButtonReturn, update != nil {
                        self.downloadUpdate()
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
        availableUpdate = update
        downloadItem.isHidden = update == nil
        downloadItem.title = update.map { "Download Update \($0.version)…" } ?? "Download Update…"
    }

    @objc private func downloadUpdate() {
        openUpdate { NSWorkspace.shared.open($0) }
    }

    private func openUpdate(using open: (URL) -> Bool) {
        guard let update = availableUpdate else { return }
        stopScrolling()
        if !open(update.downloadURL) {
            showUpdateError("The browser could not open the download. Try again.")
        }
    }

    private func showUpdateError(_ message: String) {
        stopScrolling()
        let alert = NSAlert()
        alert.messageText = "Couldn't check or open the update"
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
        if openSettingsOnLaunch { showSettings() }
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
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
        updateLaunchAtStartupItem()
    }

    @objc private func requestPermissions() {
        if CGPreflightListenEventAccess(), !AXIsProcessTrusted(), accessibilityPromptedThisRun {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
                guard CGPreflightListenEventAccess() else {
                    self?.updatePermissionMenuItem()
                    return
                }
                self?.requestAccessibilityPermission()
            }
        } else {
            requestAccessibilityPermission()
        }

        installEventTap()
        updatePermissionMenuItem()
    }

    private func requestAccessibilityPermission() {
        guard !AXIsProcessTrusted() else { return }
        guard !accessibilityPromptedThisRun else { return }
        accessibilityPromptedThisRun = true
        let axOptions = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(axOptions)
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
        let canListen = CGPreflightListenEventAccess()
        permissionItem.isHidden = canListen && AXIsProcessTrusted()
        if !canListen {
            permissionItem.title = "Request Input Monitoring"
        } else {
            permissionItem.title = "Accessibility Settings…"
        }
    }

    private func updateSizeMenuItems() {
        sizePicker.selectItem(withTag: Int(overlay.size))
    }

    private func updateLaunchAtStartupItem() {
        launchAtStartupItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
    }

    private func installEventTap() {
        if eventTapInstalled && CGPreflightListenEventAccess() {
            updatePermissionMenuItem()
            return
        }

        let events: [CGEventType] = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .otherMouseUp,
            .tapDisabledByTimeout,
            .tapDisabledByUserInput
        ]

        let mask = events.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << CGEventMask(type.rawValue))
        }

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<VectorScrollApp>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated {
                app.handleEvent(proxy: proxy, type: type, event: event)
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
            updatePermissionMenuItem()
            schedulePermissionRetry()
            return
        }

        eventTapInstalled = true
        permissionRetryTimer?.cancel()
        permissionRetryTimer = nil
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        updatePermissionMenuItem()
    }

    private func schedulePermissionRetry() {
        guard permissionRetryTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.installEventTap()
        }
        permissionRetryTimer = timer
        timer.resume()
    }

    private func startPermissionStatusTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            if CGPreflightListenEventAccess() {
                self?.requestAccessibilityPermission()
            }
            self?.installEventTap()
            self?.updatePermissionMenuItem()
        }
        permissionStatusTimer = timer
        timer.resume()
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
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
                    armHoldToLock(at: currentPointerLocation(), target: event.location)
                } else {
                    startScrolling(at: currentPointerLocation(), target: event.location)
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
        if !AXIsProcessTrusted() {
            updatePermissionMenuItem()
        }
        if AXIsProcessTrusted(), let element = element(at: target) {
            focusTarget(element)
        }

        anchor = point
        isActive = true
        overlay.show(at: point)

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
        overlay.hide()
    }

    private func emitScrollTick() {
        guard let anchor else { return }

        let pointer = currentPointerLocation()
        let offset = CGPoint(x: pointer.x - anchor.x, y: pointer.y - anchor.y)
        let adjusted = CGPoint(
            x: applyDeadZone(offset.x),
            y: applyDeadZone(offset.y)
        )

        guard adjusted.x != 0 || adjusted.y != 0 else { return }

        let vertical = clamp(adjusted.y * scrollScale)
        let horizontal = clamp(-adjusted.x * scrollScale)

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

    private func currentPointerLocation() -> CGPoint {
        NSEvent.mouseLocation
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

let app = NSApplication.shared
private let delegate = VectorScrollApp()
app.delegate = delegate
app.run()
