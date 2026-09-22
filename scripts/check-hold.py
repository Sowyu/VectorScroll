"""Run the real hold/release handlers without posting input or requesting permissions.

This inserts a same-file Swift extension into a generated copy of main.swift.
Production source stays unchanged. The main queue deliberately does not drain
between press and release, reproducing delayed delivery deterministically.
Run on macOS with: python3 scripts/check-hold.py
"""

from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
source = (root / "Sources/VectorScroll/main.swift").read_text()
entry = "let app = NSApplication.shared\n"
assert source.count(entry) == 1, "Application entry point changed; update the probe"
harness = r'''
@MainActor
final class PointerActionProbe: NSObject {
    var calls = 0
    @objc func clicked(_ sender: NSButton) { calls += 1 }
}

extension VectorScrollApp {
    static func checkDelaySettings() -> Bool {
        let subject = VectorScrollApp()
        subject.configureMenu()
        let titles = subject.menu.items.filter { !$0.isHidden }.map(\.title)
        assert(titles.filter { !$0.isEmpty } == ["Settings…", "Quit VectorScroll"])
        assert(subject.menu.items.first?.action == #selector(showSettings))
        assert(subject.holdScrollItem.action == #selector(selectHoldToScroll))
        assert(subject.holdToLockItem.action == #selector(selectHoldToLock))
        assert(subject.sizePicker.numberOfItems == 4)
        print("PASS: minimal menu and native settings controls")
        assert(subject.updateItem.action == #selector(checkUpdatesFromMenu))
        assert(subject.downloadItem.isHidden)
        let downloadURL = URL(string: "https://github.com/Sowyu/VectorScroll/releases/download/9.0.0/VectorScroll.dmg")!
        subject.applyUpdate(AppUpdate(version: "9.0.0", downloadURL: downloadURL, sha256: String(repeating: "a", count: 64), downloadSize: 123))
        assert(!subject.downloadItem.isHidden)
        assert(subject.downloadItem.action == #selector(installUpdate))
        assert(subject.downloadItem.title == "Install Update 9.0.0…")
        subject.applyUpdate(nil)
        assert(subject.downloadItem.isHidden)
        print("PASS: check/update menu wiring, update visibility, and install action wiring")
        assert(subject.holdToLockThreshold == 0.2)
        subject.delaySlider.doubleValue = 743
        subject.changeHoldDelay(subject.delaySlider)
        assert(subject.holdDelayMilliseconds == 750)
        assert(subject.holdToLockThreshold == 0.75)
        assert(subject.delayLabel.stringValue == "750 ms")
        assert(subject.scrollScale == 0.42 && !subject.reverseDirection)
        subject.speedSlider.doubleValue = 83
        subject.changeScrollSpeed(subject.speedSlider)
        assert(subject.scrollSpeedPercent == 80 && subject.speedLabel.stringValue == "80%")
        assert(abs(subject.scrollScale - 0.336) < 0.0001)
        subject.reverseItem.state = .on
        subject.toggleReverseDirection()
        let speedRestored = VectorScrollApp()
        speedRestored.restoreSettings()
        assert(speedRestored.scrollSpeedPercent == 80 && speedRestored.reverseDirection)
        subject.eventTapInstalled = true
        subject.startScrolling(at: .zero, target: .zero) // Hold mode: no indicator until the pointer leaves the dead zone.
        assert(subject.isActive && !subject.engaged)
        subject.stopScrolling()
        subject.eventTapInstalled = false
        print("PASS: speed slider rounding and scale, reverse direction persistence, deferred hold-mode engagement")
        subject.defaults.removeObject(forKey: "onboardingCompleted")
        subject.showOnboarding()
        let guide = subject.onboarding!
        assert(guide.window.isVisible && guide.step == .welcome)
        guide.refresh(canListen: false, canAccess: false) // Independent of the runner's real TCC state.
        guide.primary.performClick(nil)
        assert(guide.step == .inputMonitoring, "Welcome must lead to Input Monitoring, got \(guide.step)")
        subject.applyPermissionStatus(canListen: true, canAccess: false)
        assert(guide.step == .accessibility, "Granting Input Monitoring must advance the guide")
        guide.secondary.performClick(nil)
        assert(!guide.window.isVisible && subject.onboarding == nil)
        assert(!subject.defaults.bool(forKey: "onboardingCompleted"), "Later must not claim that setup is complete")
        subject.startPermissionStatusTimer()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        subject.permissionStatusTimer?.cancel()
        subject.permissionStatusTimer = nil
        assert(subject.onboarding == nil && !subject.defaults.bool(forKey: "onboardingCompleted"))
        subject.showOnboarding()
        let completedGuide = subject.onboarding!
        completedGuide.refresh(canListen: false, canAccess: false)
        completedGuide.primary.performClick(nil)
        completedGuide.refresh(canListen: true, canAccess: false)
        var permissionRequests = 0
        completedGuide.promptAccessibility = { permissionRequests += 1 }
        completedGuide.primary.performClick(nil)
        assert(permissionRequests == 1, "The setup button must request permission explicitly")
        completedGuide.refresh(canListen: true, canAccess: true)
        assert(completedGuide.step == .done)
        completedGuide.refresh(canListen: false, canAccess: true)
        assert(completedGuide.step == .inputMonitoring, "Revoking a permission must leave the completed step")
        completedGuide.refresh(canListen: true, canAccess: true)
        completedGuide.refresh(canListen: true, canAccess: false)
        assert(completedGuide.step == .accessibility)
        completedGuide.refresh(canListen: true, canAccess: true)
        completedGuide.primary.performClick(nil)
        assert(subject.onboarding == nil && subject.defaults.bool(forKey: "onboardingCompleted"))
        let closedGuide = Onboarding()
        var finishes = 0
        closedGuide.finish = { completed in assert(!completed); finishes += 1 }
        closedGuide.show()
        closedGuide.window.performClose(nil)
        assert(finishes == 1, "The standard close button must defer setup exactly once")
        subject.applyLaunchAtStartupStatus(.requiresApproval)
        assert(subject.launchAtStartupItem.state == .mixed && subject.launchAtStartupItem.isEnabled)
        assert(subject.launchAtStartupItem.title.contains("needs approval"))
        subject.applyLaunchAtStartupStatus(.notFound)
        assert(!subject.launchAtStartupItem.isEnabled)
        subject.applyLaunchAtStartupStatus(.enabled)
        assert(subject.launchAtStartupItem.state == .on && subject.launchAtStartupItem.isEnabled)
        subject.applyLaunchAtStartupStatus(.notRegistered)
        assert(subject.launchAtStartupItem.state == .off)
        print("PASS: setup deferral, explicit permission action, completion, window close, and login approval states")
        assert(subject.delayItem.isHidden)
        subject.selectHoldToLock()
        assert(!subject.delayItem.isHidden)
        subject.armHoldToLock(at: .zero, target: .zero)
        assert(subject.engageWorkItem != nil)
        subject.toggleHoldDelay()
        assert(subject.engageWorkItem == nil)
        assert(subject.holdToLockThreshold == 0)
        assert(!subject.delaySlider.isEnabled)
        assert(subject.holdToLockItem.title == "Keep scrolling until the next click")
        subject.eventTapInstalled = true
        subject.armHoldToLock(at: .zero, target: .zero)
        assert(subject.isActive && subject.engageWorkItem == nil)
        subject.stopScrolling() // Cancel before the main queue can post any input.
        let restored = VectorScrollApp()
        restored.restoreSettings()
        assert(!restored.holdDelayEnabled && restored.holdDelayMilliseconds == 750)
        subject.toggleHoldDelay()
        assert(subject.delaySlider.isEnabled && subject.holdToLockThreshold == 0.75)
        subject.armHoldToLock(at: .zero, target: .zero)
        subject.selectHoldToScroll()
        assert(subject.delayItem.isHidden)
        assert(subject.engageWorkItem == nil && !subject.isActive)
        subject.openSettingsButton.state = .off
        subject.toggleOpenSettings()
        assert(!subject.openSettingsOnLaunch && subject.statusItem != nil)
        subject.hideIconItem.state = .off
        subject.toggleMenuBarIcon()
        assert(subject.openSettingsOnLaunch && subject.statusItem == nil)
        assert(subject.openSettingsButton.state == .on)
        _ = subject.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        assert(subject.settingsWindow.isVisible)
        subject.settingsWindow.close()
        _ = subject.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        assert(subject.settingsWindow.isVisible)
        subject.openSettingsButton.state = .off
        subject.toggleOpenSettings()
        assert(!subject.openSettingsOnLaunch && subject.statusItem != nil)
        assert(subject.hideIconItem.state == .on)
        subject.settingsWindow.close()
        _ = subject.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        assert(!subject.settingsWindow.isVisible)
        subject.defaults.set(false, forKey: "showMenuBarIcon")
        subject.defaults.set(false, forKey: "openSettingsOnLaunch")
        let repaired = VectorScrollApp()
        repaired.restoreSettings()
        assert(!repaired.menuBarIconHidden)
        assert(subject.defaults.bool(forKey: "showMenuBarIcon"))
        subject.setAccessPreferences(showMenuBar: false, openSettings: true)
        let persisted = VectorScrollApp()
        persisted.restoreSettings()
        assert(persisted.menuBarIconHidden && persisted.openSettingsOnLaunch)
        subject.showSettings()
        subject.selectHoldToLock()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        subject.settingsWindow.contentView!.layoutSubtreeIfNeeded()
        let content = subject.settingsWindow.contentView!
        print("screen \(NSScreen.main?.frame ?? .zero) window \(subject.settingsWindow.frame)")
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let scroll = descendants(content).compactMap { $0 as? NSScrollView }.first!
        let stack = descendants(scroll.documentView!).compactMap { $0 as? NSStackView }.first!
        assert(stack.bounds.width <= scroll.contentView.bounds.width, "Settings must fit horizontally")
        assert(scroll.hasVerticalScroller, "All settings must remain reachable on smaller screens")
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            assert(descendants(content).contains { $0 is NSGlassEffectView }, "Modern settings must use native Liquid Glass")
            assert(subject.updateItem.bezelStyle == .glass, "Modern actions must use the native glass bezel")
            print("PASS: native Liquid Glass content and actions on macOS 26")
        }
        #endif
        assert(subject.settingsWindow.standardWindowButton(.closeButton)?.isHidden == false)
        assert(subject.settingsWindow.standardWindowButton(.closeButton)?.isEnabled == true)
        assert(subject.settingsWindow.standardWindowButton(.miniaturizeButton)?.isEnabled == true)
        assert(subject.settingsWindow.standardWindowButton(.zoomButton)?.isEnabled == true)
        let originalFrame = subject.settingsWindow.frame
        subject.settingsWindow.setContentSize(NSSize(width: 520, height: 500))
        content.layoutSubtreeIfNeeded()
        assert(stack.bounds.width <= scroll.contentView.bounds.width, "Narrow settings must fit horizontally")
        subject.updateItem.scrollToVisible(subject.updateItem.bounds)
        content.layoutSubtreeIfNeeded()
        let updateBounds = subject.updateItem.convert(subject.updateItem.bounds, to: scroll.documentView)
        assert(scroll.contentView.documentVisibleRect.intersects(updateBounds), "Updates must remain reachable in a short window")
        subject.settingsWindow.setFrame(originalFrame, display: true)
        content.layoutSubtreeIfNeeded()
        let closeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: subject.settingsWindow.windowNumber,
                                         context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        assert(subject.settingsWindow.performKeyEquivalent(with: closeEvent))
        assert(!subject.settingsWindow.isVisible, "Command-W must close settings")
        assert(subject.openSettingsOnLaunch, "Closing must preserve app access preferences")
        subject.showSettings()
        for canListen in [false, true] {
            for canAccess in [false, true] {
                subject.applyPermissionStatus(canListen: canListen, canAccess: canAccess)
                assert(subject.permissionItem.isHidden == (canListen && canAccess))
                assert(subject.permissionStatusLabel.stringValue.contains("Input Monitoring: \(canListen ? "Allowed" : "Needed")"))
                assert(subject.permissionStatusLabel.stringValue.contains("Accessibility: \(canAccess ? "Allowed" : "Needed")"))
                assert(subject.permissionItem.title == (canListen ? "Accessibility Settings…" : "Input Monitoring Settings…"))
            }
        }
        subject.updatePermissionMenuItem()
        print("PASS: native close control, Command-W close/reopen, and permission status transitions")
        assert(subject.holdScrollItem is SettingsButton)
        assert(subject.openSettingsButton is SettingsButton)
        func mouseClick(_ button: NSButton, at point: NSPoint) {
            content.layoutSubtreeIfNeeded()
            button.scrollToVisible(button.bounds)
            content.layoutSubtreeIfNeeded()
            let location = button.convert(point, to: nil)
            func event(_ type: NSEvent.EventType, at location: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: subject.settingsWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            }
            // NSButton consumes mouse-up in its native tracking loop. Send the
            // down through NSWindow rather than bypassing tracking with performClick.
            NSApp.postEvent(event(.leftMouseUp, at: location), atStart: true)
            subject.settingsWindow.sendEvent(event(.leftMouseDown, at: location))
            // A disabled control does not enter tracking and leaves mouse-up queued.
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
        }
        // The custom cards promise a full-surface target. Standard controls use
        // their native glyph/title or bezel, tested through real mouse tracking.
        for button in [subject.holdScrollItem!, subject.holdToLockItem!] {
            content.layoutSubtreeIfNeeded()
            button.scrollToVisible(button.bounds)
            content.layoutSubtreeIfNeeded()
            for point in [NSPoint(x: 8, y: 8), NSPoint(x: button.bounds.midX, y: button.bounds.midY), NSPoint(x: button.bounds.maxX - 20, y: button.bounds.midY)] {
                let location = button.convert(point, to: nil)
                let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: subject.settingsWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                let hit = button.cell!.hitTest(for: event, in: button.bounds, of: button)
                let target = content.hitTest(content.convert(location, from: nil))
                assert(target === button, "Visible button must receive pointer events")
                assert(hit.contains(.trackableArea), "Entire drawn button must be clickable")
            }
        }
        // AppKit 26 changed checkbox glyph metrics. Click the visible label,
        // which is a native activation target across supported system versions.
        mouseClick(subject.hideIconItem, at: NSPoint(x: 80, y: subject.hideIconItem.bounds.midY))
        assert(subject.hideIconItem.state == .on && subject.statusItem != nil, "Checkbox must use native click tracking")
        mouseClick(subject.holdScrollItem, at: NSPoint(x: 8, y: 8))
        assert(!subject.holdToLockMode && subject.holdScrollItem.state == .on)
        mouseClick(subject.holdToLockItem, at: NSPoint(x: 80, y: 48))
        assert(subject.holdToLockMode && subject.holdToLockItem.state == .on)
        let probe = PointerActionProbe()
        // Synthetic drag-out events hang even an unmodified NSButton in this
        // runner. Clicks use the real window routing; native drag tracking is unchanged.
        for button in [subject.updateItem!] {
            let originalTarget = button.target
            let originalAction = button.action
            button.target = probe
            button.action = #selector(PointerActionProbe.clicked(_:))
            let before = probe.calls
            let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
            mouseClick(button, at: center)
            assert(probe.calls == before + 1, "Mouse click must fire action exactly once")
            button.isEnabled = false
            mouseClick(button, at: center)
            assert(probe.calls == before + 1, "Disabled buttons must ignore clicks")
            button.isEnabled = true
            button.target = originalTarget
            button.action = originalAction
        }
        print("PASS: pointer clicks on switch, icon, subtitle, and action areas; disabled controls")
        // Test mutations above should not leak into the presentational previews.
        subject.scrollSpeedPercent = 100
        subject.reverseDirection = false
        subject.updateSpeedControls()
        subject.applyLaunchAtStartupStatus(.notRegistered)
        content.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        func savePreview(_ window: NSWindow, _ name: String, appearance: NSAppearance.Name = .darkAqua) {
            // Scrolling to the top flashes the overlay scroller, so hide it for the capture.
            scroll.hasVerticalScroller = false
            window.appearance = NSAppearance(named: appearance)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            let frame = window.contentView!.superview!
            frame.layoutSubtreeIfNeeded()
            frame.needsDisplay = true
            window.displayIfNeeded()
            let output = URL(fileURLWithPath: ".build/\(name).png")
            // Glass and vibrancy are composed by WindowServer, outside cacheDisplay.
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.path]
            var captured = false
            do {
                try capture.run()
                let deadline = Date(timeIntervalSinceNow: 5)
                while capture.isRunning && Date() < deadline {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
                }
                if capture.isRunning { capture.terminate() }
                else { captured = capture.terminationStatus == 0 && FileManager.default.fileExists(atPath: output.path) }
            } catch {
                print("Window capture unavailable: \(error.localizedDescription)")
            }
            if !captured {
                let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
                print("Preview \(name) uses bitmap fallback; compositor effects are not captured")
            }
            scroll.hasVerticalScroller = true
            window.appearance = nil
        }
        savePreview(subject.settingsWindow, "settings-delay-preview")
        subject.selectHoldToScroll()
        content.layoutSubtreeIfNeeded()
        savePreview(subject.settingsWindow, "settings-preview")
        savePreview(subject.settingsWindow, "settings-light-preview", appearance: .aqua)
        subject.defaults.removeObject(forKey: "onboardingCompleted")
        subject.showOnboarding()
        subject.onboarding!.refresh(canListen: false, canAccess: false)
        subject.onboarding!.primary.performClick(nil)
        savePreview(subject.onboarding!.window, "onboarding-preview")
        savePreview(subject.onboarding!.window, "onboarding-light-preview", appearance: .aqua)
        subject.onboarding!.secondary.performClick(nil)
        subject.settingsWindow.standardWindowButton(.closeButton)!.performClick(nil)
        assert(!subject.settingsWindow.isVisible, "The standard close button must close only the window")
        print("PASS: both access-toggle directions, persistence, invalid settings repair, window reopen, and layout fit")
        print("PASS: delay toggle, slider rounding, immediate start, persistence, and mode cancellation")
        return true
    }
    static func checkRelease(delay: TimeInterval) -> Bool {
        let subject = VectorScrollApp()
        subject.holdToLockMode = true
        let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                           mouseCursorPosition: .zero, mouseButton: .center)!
        let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp,
                         mouseCursorPosition: .zero, mouseButton: .center)!
        down.timestamp = 1_000_000_000
        up.timestamp = down.timestamp + 100_000_000 // Physical press lasts 100 ms.
        // Drive the real handler with event coordinates; no live tap is needed.
        _ = subject.handleEvent(type: .otherMouseDown, event: down)
        assert(subject.engageWorkItem != nil)
        Thread.sleep(forTimeInterval: delay)
        _ = subject.handleEvent(type: .otherMouseUp, event: up)
        let canceled = subject.engageWorkItem == nil && !subject.isActive
        subject.cancelArmedHoldToLock()
        print("\(canceled ? "PASS" : "FAIL"): 100 ms click, release handled after \(Int(delay * 1000)) ms")
        return canceled
    }

    static func checkEventRecovery() -> Bool {
        let subject = VectorScrollApp()
        subject.eventTapInstalled = true
        let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                           mouseCursorPosition: CGPoint(x: 123, y: 234), mouseButton: .center)!
        _ = subject.handleEvent(type: .otherMouseDown, event: down)
        assert(subject.isActive && subject.timer != nil)
        assert(subject.anchor == down.unflippedLocation, "Anchor must come from the press event")
        assert(subject.pendingTarget == down.location, "AX targeting must retain CoreGraphics coordinates")
        _ = subject.handleEvent(type: .tapDisabledByTimeout, event: down)
        assert(!subject.isActive && subject.timer == nil && subject.anchor == nil && subject.pendingTarget == nil)
        subject.holdToLockMode = true
        _ = subject.handleEvent(type: .otherMouseDown, event: down)
        assert(subject.engageWorkItem != nil)
        _ = subject.handleEvent(type: .tapDisabledByUserInput, event: down)
        assert(subject.engageWorkItem == nil && !subject.isActive)
        print("PASS: press-event anchoring and disabled-tap cancellation of scrolling and delayed holds")
        return true
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: .aqua)
app.applicationIconImage = NSImage(contentsOfFile: "docs/icon.png")
app.finishLaunching()
let promptRelease = VectorScrollApp.checkRelease(delay: 0.1)
let delayedRelease = VectorScrollApp.checkRelease(delay: 0.3)
let recovery = VectorScrollApp.checkEventRecovery()
let settings = VectorScrollApp.checkDelaySettings()
exit(promptRelease && delayedRelease && recovery && settings ? 0 : 1)
'''

output = root / ".build/audit-hold"
output.mkdir(parents=True, exist_ok=True)
generated = output / "main.swift"
generated.write_text(source.split(entry)[0] + harness)
binary = output / "check-hold"
subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors",
                str(generated), str(root / "Sources/VectorScroll/SettingsStyle.swift"), str(root / "Sources/VectorScroll/Onboarding.swift"), str(root / "Sources/VectorScroll/Updates.swift"), str(root / "Sources/VectorScroll/UpdateInstaller.swift"), "-o", str(binary), "-framework", "AppKit",
                "-framework", "ApplicationServices", "-framework", "ServiceManagement"], check=True)
subprocess.run([str(binary)], check=True, timeout=45, cwd=root)
