@preconcurrency import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import ServiceManagement

@MainActor
private final class VectorScrollApp: NSObject, NSApplicationDelegate {
    private let markerSizes = [28, 32, 40, 48]
    private let defaults = UserDefaults.standard
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var permissionItem: NSMenuItem!
    private var lightModeItem: NSMenuItem!
    private var darkModeItem: NSMenuItem!
    private var launchAtStartupItem: NSMenuItem!
    private var sizeItems: [NSMenuItem] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: DispatchSourceTimer?
    private var permissionRetryTimer: DispatchSourceTimer?
    private var permissionStatusTimer: DispatchSourceTimer?
    private var accessibilityPromptedThisRun = false
    private var anchor: CGPoint?
    private var isActive = false
    private var eventTapInstalled = false
    private let overlay = ScrollOverlayWindow()

    private let scrollScale: CGFloat = 0.42
    private let deadZone: CGFloat = 10
    private let maxDeltaPerTick: CGFloat = 120

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        restoreSettings()
        configureMenu()
        requestPermissions()
        installEventTap()
        startPermissionStatusTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopScrolling()
        permissionRetryTimer?.cancel()
        permissionStatusTimer?.cancel()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }

    private func configureMenu() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.up.and.down.circle.fill", accessibilityDescription: "Vector Scroll")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        permissionItem = NSMenuItem(title: "Request Permissions", action: #selector(requestPermissions), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        lightModeItem = NSMenuItem(title: "Light Mode", action: #selector(selectLightMode), keyEquivalent: "")
        lightModeItem.target = self
        menu.addItem(lightModeItem)

        darkModeItem = NSMenuItem(title: "Dark Mode", action: #selector(selectDarkMode), keyEquivalent: "")
        darkModeItem.target = self
        menu.addItem(darkModeItem)
        updateMarkerMenuItem()

        let sizeMenu = NSMenu()
        for size in markerSizes {
            let item = NSMenuItem(title: "\(size) px", action: #selector(selectMarkerSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            sizeMenu.addItem(item)
            sizeItems.append(item)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        updateSizeMenuItems()

        launchAtStartupItem = NSMenuItem(title: "Launch at Startup", action: #selector(toggleLaunchAtStartup), keyEquivalent: "")
        launchAtStartupItem.target = self
        menu.addItem(launchAtStartupItem)
        updateLaunchAtStartupItem()

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))

        statusItem.menu = menu
        updatePermissionMenuItem()
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

    @objc private func selectMarkerSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Int else { return }
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

    private func updatePermissionMenuItem() {
        let canListen = CGPreflightListenEventAccess()
        permissionItem.isHidden = canListen
        if !canListen {
            permissionItem.title = "Request Input Monitoring"
        }
    }

    private func updateSizeMenuItems() {
        for item in sizeItems {
            let size = item.representedObject as? Int
            item.state = size == Int(overlay.size) ? .on : .off
        }
    }

    private func updateLaunchAtStartupItem() {
        launchAtStartupItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func restoreSettings() {
        overlay.setDarkMode(defaults.bool(forKey: "darkMode"))
        let savedSize = defaults.integer(forKey: "markerSize")
        if markerSizes.contains(savedSize) {
            overlay.setSize(CGFloat(savedSize))
        }
    }

    private func installEventTap() {
        if eventTapInstalled && CGPreflightListenEventAccess() {
            updatePermissionMenuItem()
            return
        }

        let events: [CGEventType] = [
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
            if type == .otherMouseUp {
                let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
                if buttonNumber == 2 {
                    stopScrolling()
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .otherMouseDown {
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            if buttonNumber == 2 {
                startScrolling(at: currentPointerLocation(), target: event.location)
            }
        }

        return Unmanaged.passUnretained(event)
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
