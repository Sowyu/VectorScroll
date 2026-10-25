"""Check hold/release handlers and click controls in a foreground probe window.

This inserts a same-file Swift extension into a generated copy of main.swift.
Production source stays unchanged. The main queue deliberately does not drain
between press and release, reproducing delayed delivery deterministically.
UI checks post mouse clicks and require Accessibility access on the test Mac.
Run on macOS with: python3 scripts/check-hold.py
"""

from pathlib import Path
import subprocess
import plistlib
import shutil
import uuid
import threading

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
    static func checkScrollingSettings() {
        let subject = VectorScrollApp()
        let saved = Dictionary(uniqueKeysWithValues: Self.restorableDefaultsKeys.map { ($0, subject.defaults.object(forKey: $0)) })
        let accessKeys = ["openSettingsOnLaunch", "showMenuBarIcon", "onboardingCompleted"]
        let savedAccess = Dictionary(uniqueKeysWithValues: accessKeys.map { ($0, subject.defaults.object(forKey: $0)) })
        defer {
            for key in Self.restorableDefaultsKeys { subject.defaults.set(saved[key]!, forKey: key) }
            for key in accessKeys { subject.defaults.set(savedAccess[key]!, forKey: key) }
        }
        for key in Self.restorableDefaultsKeys { subject.defaults.removeObject(forKey: key) }
        subject.defaults.set(true, forKey: "reverseDirection")
        subject.restoreSettings()
        assert(subject.reverseVertical && subject.reverseHorizontal)
        assert(subject.defaults.bool(forKey: "reverseVertical") && subject.defaults.bool(forKey: "reverseHorizontal"))
        assert(subject.defaults.bool(forKey: "reverseDirection"))
        subject.defaults.set(false, forKey: "reverseVertical")
        subject.defaults.removeObject(forKey: "reverseHorizontal")
        subject.restoreSettings()
        assert(!subject.reverseVertical && !subject.reverseHorizontal, "A partial migration must not overwrite new settings")
        print("PASS: migration from reverseDirection preserves legacy and existing axis settings")
        subject.configureMenu()
        let offset = CGPoint(x: 120, y: 120)
        subject.scrollRemainder = .zero
        let forward = subject.nextScrollDelta(for: offset)!
        for vertical in [false, true] {
            for horizontal in [false, true] {
                subject.reverseVerticalItem.state = vertical ? .on : .off
                subject.toggleReverseVertical()
                subject.reverseHorizontalItem.state = horizontal ? .on : .off
                subject.toggleReverseHorizontal()
                let restored = VectorScrollApp()
                restored.restoreSettings()
                assert(restored.reverseVertical == vertical && restored.reverseHorizontal == horizontal)
                let delta = restored.nextScrollDelta(for: offset)!
                assert(delta.vertical == (vertical ? -forward.vertical : forward.vertical))
                assert(delta.horizontal == (horizontal ? -forward.horizontal : forward.horizontal))
            }
        }
        print("PASS: each reverse switch persists and affects only its axis")
        assert(subject.speedSlider.minValue == 20 && subject.speedSlider.maxValue == 300)
        assert(subject.speedSlider.numberOfTickMarks == 29)
        // Use an unrestricted sender to exercise clamping beyond the UI slider limits.
        let sender = NSSlider(value: 100, minValue: -100, maxValue: 500, target: nil, action: nil)
        for (input, expected) in [(19.0, 20), (24, 20), (26, 30), (-100, 20), (294, 290), (296, 300), (301, 300), (500, 300)] {
            sender.doubleValue = input
            subject.changeScrollSpeed(sender)
            assert(subject.scrollSpeedPercent == expected)
            let restored = VectorScrollApp()
            restored.restoreSettings()
            assert(restored.scrollSpeedPercent == expected)
        }
        for invalid in [10, 310, 25] {
            subject.defaults.set(invalid, forKey: "scrollSpeedPercent")
            let restored = VectorScrollApp()
            restored.restoreSettings()
            assert(restored.scrollSpeedPercent == 100)
        }
        print("PASS: speed slider rounding and clamping at 20 and 300, saved-value validation")
        let curve = VectorScrollApp()
        var previous: Int32 = 0
        for distance in [10.0, 30, 60, 120, 180] {
            curve.scrollRemainder = .zero
            let delta = curve.nextScrollDelta(for: CGPoint(x: distance, y: distance))!
            assert(delta.vertical > previous && delta.horizontal == -delta.vertical)
            if distance == 120 { assert(delta.vertical == Int32((120 * curve.scrollScale).rounded())) }
            if distance < 120 { assert(CGFloat(delta.vertical) < distance * curve.scrollScale) }
            if distance > 120 { assert(CGFloat(delta.vertical) > distance * curve.scrollScale) }
            previous = delta.vertical
        }
        print("PASS: scroll curve is monotonic and equals linear speed at 120 points")
        for enabled in [false, true] {
            subject.raiseWindowItem.state = enabled ? .on : .off
            subject.toggleRaiseWindow()
            let restored = VectorScrollApp()
            restored.restoreSettings()
            assert(restored.raiseWindowOnScroll == enabled)
        }
        print("PASS: bring window to front switch persists")
        subject.selectHoldToLock()
        subject.holdDelayEnabled = false
        subject.holdDelayMilliseconds = 950
        subject.scrollSpeedPercent = 300
        subject.reverseVertical = true
        subject.reverseHorizontal = true
        subject.raiseWindowOnScroll = false
        subject.selectDarkMode()
        subject.sizePicker.selectItem(withTag: 48)
        subject.selectMarkerSize(subject.sizePicker)
        for key in Self.restorableDefaultsKeys { subject.defaults.set(999, forKey: key) }
        subject.setAccessPreferences(showMenuBar: false, openSettings: true)
        subject.defaults.set(true, forKey: "onboardingCompleted")
        subject.tapState = .filtering
        subject.startScrolling(at: .zero, target: .zero)
        assert(subject.isActive)
        assert(subject.restoreDefaultsButton.action == #selector(restoreDefaults))
        subject.restoreDefaultsButton.performClick(nil)
        assert(!subject.isActive && subject.timer == nil && subject.engageWorkItem == nil)
        for key in Self.restorableDefaultsKeys { assert(subject.defaults.object(forKey: key) == nil, "Reset must remove \(key)") }
        assert(!subject.holdToLockMode && subject.holdDelayEnabled && subject.holdDelayMilliseconds == 200)
        assert(subject.scrollSpeedPercent == 100 && !subject.reverseVertical && !subject.reverseHorizontal && subject.raiseWindowOnScroll)
        assert(!subject.overlay.isDarkMode && subject.overlay.size == 32)
        assert(subject.holdScrollItem.state == .on && subject.holdToLockItem.state == .off && subject.holdOrClickItem.state == .off && subject.delayItem.isHidden)
        assert(subject.delayToggle.state == .on && subject.delaySlider.isEnabled && subject.delaySlider.doubleValue == 200)
        assert(subject.delayLabel.stringValue == "200 ms" && subject.speedLabel.stringValue == "100%" && subject.speedSlider.doubleValue == 100)
        assert(subject.reverseVerticalItem.state == .off && subject.reverseHorizontalItem.state == .off && subject.raiseWindowItem.state == .on)
        assert(subject.indicatorAppearance.selectedSegment == 0 && subject.sizePicker.selectedItem?.tag == 32)
        assert(!subject.markerPreview.isDarkMode && subject.markerPreview.frame.width == 32)
        assert(subject.defaults.bool(forKey: "openSettingsOnLaunch") && !subject.defaults.bool(forKey: "showMenuBarIcon"))
        assert(subject.openSettingsOnLaunch && subject.menuBarIconHidden && subject.openSettingsButton.state == .on && subject.hideIconItem.state == .off)
        assert(subject.defaults.bool(forKey: "onboardingCompleted"))
        let restored = VectorScrollApp()
        restored.restoreSettings()
        assert(restored.scrollSpeedPercent == 100 && !restored.reverseVertical && !restored.reverseHorizontal && restored.raiseWindowOnScroll)
        print("PASS: Restore Defaults resets scrolling and indicator settings and controls, preserves app access and onboarding")
        subject.settingsWindow.close()
    }

    static func checkDelaySettings() -> Bool {
        let suite = "local.vectorscroll.exclusions.\(UUID().uuidString)"
        let featureDefaults = UserDefaults(suiteName: suite)!
        defer { featureDefaults.removePersistentDomain(forName: suite) }
        assert(!ExcludedApps.isExcluded(at: .zero, defaults: featureDefaults))
        ExcludedApps.add(["com.example.one", "com.example.one", "com.example.two"], to: featureDefaults)
        ExcludedApps.add(["com.example.two"], to: featureDefaults)
        assert(ExcludedApps.bundleIDs(in: featureDefaults) == ["com.example.one", "com.example.two"])
        ExcludedApps.remove("com.example.one", from: featureDefaults)
        assert(ExcludedApps.bundleIDs(in: featureDefaults) == ["com.example.two"])
        assert(!ExcludedApps.makeSettingsSection(defaults: featureDefaults).subviews.isEmpty)
        ExcludedApps.remove("com.example.two", from: featureDefaults)
        assert(!ExcludedApps.makeSettingsSection(defaults: featureDefaults).subviews.isEmpty)
        print("PASS: exclusion storage, empty-list fast path, and settings section")
        let subject = VectorScrollApp()
        subject.configureMenu()
        let titles = subject.menu.items.filter { !$0.isHidden }.map(\.title)
        assert(titles.filter { !$0.isEmpty } == ["Settings…", "Donate on Ko-fi", "Quit VectorScroll"])
        assert(subject.menu.items.first?.action == #selector(showSettings))
        assert(subject.holdScrollItem.action == #selector(selectHoldToScroll))
        assert(subject.holdToLockItem.action == #selector(selectHoldToLock))
        assert(subject.holdOrClickItem.action == #selector(selectBoth))
        assert(subject.sizePicker.numberOfItems == 4)
        print("PASS: minimal menu and native settings controls")
        assert(subject.updateItem.action == #selector(checkUpdatesFromMenu))
        assert(subject.downloadItem.isHidden)
        assert(subject.updateStatusLabel.stringValue.isEmpty)
        assert(subject.updateProgress.isHidden)
        subject.setUpdateStatus("Checking for updates…", busy: true)
        assert(!subject.updateProgress.isHidden)
        assert(!subject.updateItem.isEnabled && !subject.downloadItem.isEnabled)
        subject.setUpdateStatus("VectorScroll is up to date.", busy: false)
        assert(subject.updateProgress.isHidden)
        assert(subject.updateItem.isEnabled && subject.downloadItem.isEnabled)
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
        assert(subject.delaySlider.accessibilityValueDescription() == "750 milliseconds")
        assert(subject.scrollScale == 0.42 && !subject.reverseVertical && !subject.reverseHorizontal)
        subject.speedSlider.doubleValue = 83
        subject.changeScrollSpeed(subject.speedSlider)
        assert(subject.scrollSpeedPercent == 80 && subject.speedLabel.stringValue == "80%")
        assert(subject.speedSlider.accessibilityValueDescription() == "80 percent")
        assert(abs(subject.scrollScale - 0.336) < 0.0001)
        subject.reverseVerticalItem.state = .on
        subject.toggleReverseVertical()
        let speedRestored = VectorScrollApp()
        speedRestored.restoreSettings()
        assert(speedRestored.scrollSpeedPercent == 80 && speedRestored.reverseVertical && !speedRestored.reverseHorizontal)
        subject.tapState = .filtering
        subject.startScrolling(at: .zero, target: .zero) // Hold mode: no indicator until the pointer leaves the dead zone.
        assert(subject.isActive && !subject.engaged)
        subject.stopScrolling()
        subject.tapState = .none
        print("PASS: speed slider rounding and scale, vertical reversal persistence, deferred hold-mode engagement")
        let scrolling = VectorScrollApp()
        scrolling.scrollSpeedPercent = 50
        let adjusted = CGPoint(x: 1, y: 1)
        assert(scrolling.nextScrollDelta(for: adjusted) == nil)
        var verticalTotal: Int32 = 0
        var horizontalTotal: Int32 = 0
        for _ in 1..<40 {
            if let delta = scrolling.nextScrollDelta(for: adjusted) {
                assert(abs(delta.vertical) <= 1 && abs(delta.horizontal) <= 1)
                verticalTotal += delta.vertical
                horizontalTotal += delta.horizontal
            }
        }
        assert(verticalTotal > 0 && horizontalTotal < 0)
        assert(scrolling.nextScrollDelta(for: .zero) == nil)
        scrolling.scrollRemainder = .zero
        let forward = scrolling.nextScrollDelta(for: CGPoint(x: 10, y: 20))!
        scrolling.scrollRemainder = .zero
        scrolling.reverseVertical = true
        let verticalReverse = scrolling.nextScrollDelta(for: CGPoint(x: 10, y: 20))!
        assert(verticalReverse.vertical == -forward.vertical && verticalReverse.horizontal == forward.horizontal)
        scrolling.scrollRemainder = .zero
        scrolling.reverseVertical = false
        scrolling.reverseHorizontal = true
        let horizontalReverse = scrolling.nextScrollDelta(for: CGPoint(x: 10, y: 20))!
        assert(horizontalReverse.vertical == forward.vertical && horizontalReverse.horizontal == -forward.horizontal)
        print("PASS: sub-pixel scroll carry at 50% speed, zero-delta suppression, and per-axis reversal")
        for dark in [false, true] {
            if dark { subject.selectDarkMode() } else { subject.selectLightMode() }
            assert(subject.indicatorAppearance.selectedSegment == (dark ? 1 : 0))
            for size in subject.markerSizes {
                subject.sizePicker.selectItem(withTag: size)
                subject.selectMarkerSize(subject.sizePicker)
                assert(subject.markerPreview.isDarkMode == dark)
                assert(subject.markerPreview.frame.size == NSSize(width: CGFloat(size), height: CGFloat(size)))
                assert(subject.markerPreview.accessibilityValue() as? String == "\(dark ? "Dark" : "Light"), \(size) points")
            }
        }
        subject.selectLightMode()
        subject.sizePicker.selectItem(withTag: 32)
        subject.selectMarkerSize(subject.sizePicker)
        assert(subject.reverseVerticalItem.toolTip != nil && subject.speedSlider.accessibilityHelp() != nil)
        print("PASS: live indicator preview at all sizes and appearances, spoken slider units, and contextual help")
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
        assert(subject.launchAtStartupItem.isEnabled)
        assert(!subject.launchAtStartupStatusLabel.isHidden)
        assert(subject.launchAtStartupStatusLabel.stringValue.contains("Login Items"))
        // notFound only means the app has never been registered, so the switch stays usable.
        subject.applyLaunchAtStartupStatus(.notFound)
        assert(subject.launchAtStartupItem.isEnabled && subject.launchAtStartupItem.state == .off)
        assert(subject.launchAtStartupStatusLabel.isHidden)
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
        assert(subject.holdToLockItem.accessibilityHelp() == "Click to start, click to stop")
        assert(subject.holdToLockItem.title == "Toggle scrolling")
        subject.tapState = .filtering
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
        // Reopening the app always shows Settings, even with launch-time opening off.
        _ = subject.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        assert(subject.settingsWindow.isVisible)
        subject.settingsWindow.close()
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
        let setup = Onboarding()
        for window in [subject.settingsWindow!, setup.window] {
            let views = descendants(window.contentView!)
            assert(!views.contains { $0 is NSVisualEffectView }, "Settings and setup must have solid content")
            #if compiler(>=6.2)
            if #available(macOS 26, *), window === subject.settingsWindow {
                assert(views.contains { $0 is NSGlassEffectView }, "Settings groups must be Liquid Glass")
            }
            #endif
            assert(window.isOpaque && window.backgroundColor == .windowBackgroundColor, "Window backgrounds must be solid")
            for button in views.compactMap({ $0 as? NSButton }) where button.isBordered && !(button is NSPopUpButton) {
                if button === subject.holdScrollItem || button === subject.holdToLockItem || button === subject.holdOrClickItem { continue }
                assert(button.bezelStyle == .push && button.image == nil, "Action buttons must use plain push bezels")
            }
            for control in views.compactMap({ $0 as? NSSwitch }) {
                assert(control.controlSize == .mini, "Settings switches must be mini")
            }
        }
        assert(setup.primary.keyEquivalent == "\r", "Setup must keep its default action")
        print("PASS: solid windows, glass groups, plain push actions, and mini switches")
        assert(subject.settingsWindow.standardWindowButton(.closeButton)?.isHidden == false)
        assert(subject.settingsWindow.standardWindowButton(.closeButton)?.isEnabled == true)
        assert(subject.settingsWindow.standardWindowButton(.miniaturizeButton)?.isEnabled == true)
        assert(subject.settingsWindow.standardWindowButton(.zoomButton)?.isEnabled == true)
        let originalFrame = subject.settingsWindow.frame
        subject.settingsWindow.setContentSize(NSSize(width: 520, height: 500))
        subject.applyPermissionStatus(canListen: false, canAccess: false)
        subject.downloadItem.isHidden = false
        subject.setUpdateStatus("Checking for updates…", busy: true)
        content.layoutSubtreeIfNeeded()
        assert(scroll.contentView.bounds.width <= 520, "Visible update and permission actions must not widen the window")
        assert(stack.bounds.width <= scroll.contentView.bounds.width, "Narrow settings must fit horizontally")
        for control in [subject.speedSlider!, subject.delaySlider!, subject.indicatorAppearance!, subject.sizePicker!,
                        subject.reverseVerticalItem!, subject.reverseHorizontalItem!, subject.raiseWindowItem!, subject.restoreDefaultsButton!, subject.openSettingsButton!, subject.hideIconItem!,
                        subject.launchAtStartupItem!, subject.permissionItem!, subject.updateItem!, subject.downloadItem!, subject.updateProgress!] as [NSView] {
            let bounds = control.convert(control.bounds, to: scroll.documentView)
            assert(bounds.minX >= 0 && bounds.maxX <= scroll.contentView.bounds.width,
                   "Native settings controls must fit the narrow window: \(control)")
        }
        subject.updateItem.scrollToVisible(subject.updateItem.bounds)
        content.layoutSubtreeIfNeeded()
        let updateBounds = subject.updateItem.convert(subject.updateItem.bounds, to: scroll.documentView)
        assert(scroll.contentView.documentVisibleRect.intersects(updateBounds), "Updates must remain reachable in a short window")
        subject.downloadItem.isHidden = true
        subject.setUpdateStatus("", busy: false)
        subject.updatePermissionMenuItem()
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
                if canListen && canAccess {
                    assert(subject.permissionStatusLabel.stringValue == Self.permissionStatusText(
                        canListen: true, canAccess: true, tapState: subject.tapState,
                        tapEnabled: subject.eventTap.map { (tap: CFMachPort) -> Bool in CGEvent.tapIsEnabled(tap: tap) } ?? false))
                } else {
                    if !canListen { assert(subject.permissionStatusLabel.stringValue.contains("Input Monitoring")) }
                    if !canAccess { assert(subject.permissionStatusLabel.stringValue.contains("Accessibility")) }
                }
                assert(subject.permissionItem.title == (canListen ? "Accessibility Settings…" : "Input Monitoring Settings…"))
            }
        }
        subject.updatePermissionMenuItem()
        print("PASS: native close control, Command-W close/reopen, and permission status transitions")
        assert(type(of: subject.holdScrollItem!) == NSButton.self)
        assert(type(of: subject.holdToLockItem!) == NSButton.self)
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
            // The runner captures outside the probe app so its Screen Recording
            // permission covers WindowServer composition, including Liquid Glass.
            let request = URL(fileURLWithPath: CommandLine.arguments[3])
                .appendingPathComponent(UUID().uuidString)
            let completion = request.appendingPathExtension("done")
            try! "\(window.windowNumber)\n\(output.path)".write(to: request.appendingPathExtension("request"), atomically: true, encoding: .utf8)
            let deadline = Date(timeIntervalSinceNow: 7)
            while !FileManager.default.fileExists(atPath: completion.path) && Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            let captured = (try? String(contentsOf: completion, encoding: .utf8)) == "0"
            if !captured {
                let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: output)
                print("Preview \(name) uses bitmap fallback; compositor effects are not captured")
            }
            scroll.hasVerticalScroller = true
            window.appearance = nil
        }
        savePreview(subject.settingsWindow, "settings-preview")
        func mouseClick(_ button: NSControl, at point: NSPoint) {
            content.layoutSubtreeIfNeeded()
            button.scrollToVisible(button.bounds)
            content.layoutSubtreeIfNeeded()
            let location = button.convert(point, to: nil)
            let hit = content.hitTest(content.convert(location, from: nil))
            print("APP: running \(NSApp.isRunning), active \(NSApp.isActive), key \(subject.settingsWindow.isKeyWindow), main \(subject.settingsWindow.isMainWindow), movable \(button.mouseDownCanMoveWindow)")
            print("CLICK: \(button.accessibilityLabel() ?? String(describing: type(of: button))), bounds \(button.bounds), hit \(String(describing: hit))")
            let screenPoint = subject.settingsWindow.convertPoint(toScreen: location)
            let pointer = CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.maxY - screenPoint.y)
            let request = URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent(UUID().uuidString)
            let completion = request.appendingPathExtension("done")
            try! "\(pointer.x)\n\(pointer.y)".write(to: request.appendingPathExtension("click"), atomically: true, encoding: .utf8)
            let minimum = Date(timeIntervalSinceNow: 0.3)
            let deadline = Date(timeIntervalSinceNow: 5)
            repeat {
                if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                if Date() >= minimum && FileManager.default.fileExists(atPath: completion.path) { break }
            } while Date() < deadline
            assert((try? String(contentsOf: completion, encoding: .utf8)) == "0", "The runner must deliver a real pointer click")
        }
        // Native radio buttons track their glyph and title, tested at their real frames.
        for button in [subject.holdScrollItem!, subject.holdToLockItem!, subject.holdOrClickItem!] {
            content.layoutSubtreeIfNeeded()
            button.scrollToVisible(button.bounds)
            content.layoutSubtreeIfNeeded()
            for point in [NSPoint(x: 7, y: button.bounds.midY), NSPoint(x: 60, y: button.bounds.midY)] {
                let location = button.convert(point, to: nil)
                let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: subject.settingsWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                let hit = button.cell!.hitTest(for: event, in: button.bounds, of: button)
                let target = content.hitTest(content.convert(location, from: nil))
                assert(target === button, "Visible button must receive pointer events")
                assert(hit.contains(.trackableArea), "Native radio glyph and title must be clickable")
            }
        }
        mouseClick(subject.hideIconItem, at: NSPoint(x: subject.hideIconItem.bounds.midX, y: subject.hideIconItem.bounds.midY))
        assert(subject.hideIconItem.state == .on && subject.statusItem != nil, "Native switch clicks must update menu bar access")
        mouseClick(subject.indicatorAppearance, at: NSPoint(x: subject.indicatorAppearance.bounds.width * 0.75, y: subject.indicatorAppearance.bounds.midY))
        assert(subject.overlay.isDarkMode && subject.markerPreview.isDarkMode)
        mouseClick(subject.indicatorAppearance, at: NSPoint(x: subject.indicatorAppearance.bounds.width * 0.25, y: subject.indicatorAppearance.bounds.midY))
        assert(!subject.overlay.isDarkMode && !subject.markerPreview.isDarkMode)
        mouseClick(subject.holdScrollItem, at: NSPoint(x: 7, y: subject.holdScrollItem.bounds.midY))
        assert(!subject.holdToLockMode && subject.holdScrollItem.state == .on)
        mouseClick(subject.holdToLockItem, at: NSPoint(x: 60, y: subject.holdToLockItem.bounds.midY))
        assert(subject.holdToLockMode && subject.holdToLockItem.state == .on)
        mouseClick(subject.holdOrClickItem, at: NSPoint(x: 60, y: subject.holdOrClickItem.bounds.midY))
        assert(subject.scrollMode == .both && subject.holdOrClickItem.state == .on && subject.delayItem.isHidden)
        assert(subject.holdScrollItem.state == .off && subject.holdToLockItem.state == .off)
        let bothRestored = VectorScrollApp()
        bothRestored.restoreSettings()
        assert(bothRestored.scrollMode == .both)
        subject.selectHoldToLock()
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
        print("PASS: pointer clicks on switches, radio glyphs and titles, and actions; disabled controls")
        // Test mutations above should not leak into the presentational previews.
        subject.scrollSpeedPercent = 100
        subject.reverseVertical = false
        subject.reverseHorizontal = false
        subject.updateSpeedControls()
        subject.applyLaunchAtStartupStatus(.notRegistered)
        subject.applyPermissionStatus(canListen: true, canAccess: true)
        subject.setUpdateStatus("", busy: false)
        content.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        savePreview(subject.settingsWindow, "settings-delay-preview")
        subject.selectHoldToScroll()
        content.layoutSubtreeIfNeeded()
        // Let the radios redraw before capturing, or the old selection shows too.
        subject.settingsWindow.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        savePreview(subject.settingsWindow, "settings-preview")
        savePreview(subject.settingsWindow, "settings-light-preview", appearance: .aqua)
        subject.setUpdateStatus("Checking for updates…", busy: true)
        savePreview(subject.settingsWindow, "settings-update-preview")
        subject.setUpdateStatus("", busy: false)
        subject.applyLaunchAtStartupStatus(.requiresApproval)
        savePreview(subject.settingsWindow, "settings-login-preview")
        subject.applyLaunchAtStartupStatus(.notRegistered)
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
        subject.tapState = .filtering
        var replays: [CGPoint] = []
        subject.postClick = { replays.append($0) }
        let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                           mouseCursorPosition: .zero, mouseButton: .center)!
        let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp,
                         mouseCursorPosition: .zero, mouseButton: .center)!
        down.timestamp = 1_000_000_000
        up.timestamp = down.timestamp + 100_000_000 // Physical press lasts 100 ms.
        // Drive the real handler with event coordinates; no live tap is needed.
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.engageWorkItem != nil)
        Thread.sleep(forTimeInterval: delay)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        let canceled = subject.engageWorkItem == nil && !subject.isActive && replays == [down.location]
        subject.cancelArmedHoldToLock()
        print("\(canceled ? "PASS" : "FAIL"): 100 ms click, release handled after \(Int(delay * 1000)) ms")
        return canceled
    }

    static func checkClickFiltering() -> Bool {
        func mouse(_ type: CGEventType, button: CGMouseButton = .center,
                   at point: CGPoint = CGPoint(x: 123, y: 234)) -> CGEvent {
            let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                mouseCursorPosition: point, mouseButton: button)!
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            return event
        }
        let subject = VectorScrollApp()
        subject.tapState = .filtering
        var replays: [CGPoint] = []
        subject.postClick = { replays.append($0) }
        let down = mouse(.otherMouseDown)
        let up = mouse(.otherMouseUp)
        let drag = mouse(.otherMouseDragged)
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.isActive && !subject.engaged)
        // Drags pass through, because holding them back stops macOS updating its pointer position,
        // and the held pointer comes from the drags themselves.
        assert(subject.handleEvent(type: .otherMouseDragged, event: drag)?.takeUnretainedValue() === drag)
        assert(subject.heldPointer == drag.unflippedLocation)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(!subject.isActive && subject.swallowedButtonUps.isEmpty && subject.heldMiddleClick == nil && subject.heldPointer == nil)
        assert(replays == [down.location], "Plain clicks must replay at the original press point")
        print("PASS: hold-mode down and up swallowed, drags passed through and tracked; plain click replayed once at the press point")

        // An excluded app gets the middle button untouched: no scrolling, no swallowing, no replay.
        subject.appIsExcluded = { _ in true }
        replays.removeAll()
        assert(subject.handleEvent(type: .otherMouseDown, event: down)?.takeUnretainedValue() === down)
        assert(!subject.isActive && subject.swallowedButtonUps.isEmpty)
        assert(subject.handleEvent(type: .otherMouseDragged, event: drag)?.takeUnretainedValue() === drag)
        assert(subject.handleEvent(type: .otherMouseUp, event: up)?.takeUnretainedValue() === up)
        assert(!subject.isActive && replays.isEmpty && !subject.excludedMiddleClick)
        subject.appIsExcluded = { _ in false }
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil && subject.isActive)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        replays.removeAll()
        print("PASS: excluded apps get middle down, drag, and up untouched, and other apps are filtered again afterwards")

        replays.removeAll()
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        let movedUp = mouse(.otherMouseUp, at: CGPoint(x: 456, y: 567))
        assert(subject.handleEvent(type: .otherMouseUp, event: movedUp) == nil)
        assert(replays.isEmpty, "A release outside the dead zone is a drag, not a click")

        replays.removeAll()
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        subject.engaged = true // Visual engagement alone does not classify the gesture.
        subject.leftDeadZone = true
        assert(subject.handleEvent(type: .otherMouseDragged, event: drag)?.takeUnretainedValue() === drag)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(!subject.isActive && replays.isEmpty)
        assert(subject.handleEvent(type: .otherMouseUp, event: up)?.takeUnretainedValue() === up)
        assert(subject.handleEvent(type: .otherMouseDragged, event: drag)?.takeUnretainedValue() === drag)
        print("PASS: engaged hold-mode down and up swallowed without replay; unrelated up and drag pass through")

        subject.holdToLockMode = true
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.engageWorkItem != nil && !subject.isActive)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(subject.engageWorkItem == nil && !subject.isActive && replays == [down.location])
        print("PASS: toggle-with-delay early release swallowed and replayed")

        replays.removeAll()
        subject.middleButtonIsDown = { true }
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        subject.engageWorkItem!.perform() // Elapse the delay deterministically while the button is held.
        assert(subject.isActive && subject.engageWorkItem == nil && !subject.engaged,
               "Toggle engagement must be deferred out of the filtering callback")
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(subject.isActive && replays.isEmpty)
        subject.stopScrolling()
        print("PASS: toggle-with-delay held press starts scrolling, swallows release, and never replays")

        // A physical release can precede delivery of its event on a busy main queue.
        subject.middleButtonIsDown = { false }
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        subject.engageWorkItem!.perform()
        assert(!subject.isActive && subject.engageWorkItem == nil)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(replays == [down.location])
        replays.removeAll()
        print("PASS: delayed toggle timer cannot start scrolling after physical release")

        subject.holdDelayEnabled = false
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.isActive && !subject.engaged && subject.engageWorkItem == nil)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(subject.isActive && replays.isEmpty)
        subject.stopScrolling()
        print("PASS: toggle without delay swallows its starting down and up, with engagement deferred")

        let stopButtons: [(CGEventType, CGEventType, CGMouseButton)] = [
            (.leftMouseDown, .leftMouseUp, .left),
            (.rightMouseDown, .rightMouseUp, .right),
            (.otherMouseDown, .otherMouseUp, .center),
            (.otherMouseDown, .otherMouseUp, CGMouseButton(rawValue: 3)!)
        ]
        for (downType, upType, button) in stopButtons {
            assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
            assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
            assert(subject.isActive)
            assert(subject.handleEvent(type: downType, event: mouse(downType, button: button)) == nil)
            assert(!subject.isActive)
            let unrelatedUp = mouse(.otherMouseUp, button: CGMouseButton(rawValue: 4)!)
            assert(subject.handleEvent(type: .otherMouseUp, event: unrelatedUp)?.takeUnretainedValue() === unrelatedUp)
            assert(subject.handleEvent(type: upType, event: mouse(upType, button: button)) == nil)
            assert(subject.swallowedButtonUps.isEmpty && replays.isEmpty)
        }
        // Stopping with a second button before releasing the start button must swallow both releases.
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.handleEvent(type: .leftMouseDown, event: mouse(.leftMouseDown, button: .left)) == nil)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(subject.handleEvent(type: .leftMouseUp, event: mouse(.leftMouseUp, button: .left)) == nil)
        assert(subject.swallowedButtonUps.isEmpty && replays.isEmpty)
        print("PASS: left, right, middle, and extra-button stop clicks and matching ups swallowed")

        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        for type in [CGEventType.otherMouseDown, .otherMouseDragged, .otherMouseUp, .leftMouseDown, .leftMouseUp] {
            let marked = mouse(type)
            marked.setIntegerValueField(.eventSourceUserData, value: replayEventMarker)
            assert(subject.handleEvent(type: type, event: marked)?.takeUnretainedValue() === marked)
            assert(subject.isActive && subject.heldMiddleClick == down.location && subject.swallowedButtonUps == [2])
        }
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        subject.stopScrolling()
        assert(replays.isEmpty)
        print("PASS: marked replay events pass through unchanged without altering click or scroll state")

        subject.holdToLockMode = false
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        subject.stopScrolling() // Settings changes or sleep discard replay eligibility but still pair the up.
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(replays.isEmpty)
        let extraDown = mouse(.otherMouseDown, button: CGMouseButton(rawValue: 3)!)
        assert(subject.handleEvent(type: .otherMouseDown, event: extraDown)?.takeUnretainedValue() === extraDown)
        print("PASS: external scrolling cancellation discards replay; unused mouse buttons pass through")
        return true
    }

    static func checkScrollModesAndTapStatus() -> Bool {
        let subject = VectorScrollApp()
        let keys = ["scrollMode", "holdToLockMode"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { (key: String) -> (String, Any?) in
            (key, subject.defaults.object(forKey: key))
        })
        defer { for key in keys { subject.defaults.set(saved[key]!, forKey: key) } }
        for legacy in [false, true] {
            subject.defaults.removeObject(forKey: "scrollMode")
            subject.defaults.set(legacy, forKey: "holdToLockMode")
            subject.restoreSettings()
            assert(subject.scrollMode == (legacy ? .toggle : .hold))
            assert(subject.defaults.string(forKey: "scrollMode") == (legacy ? "toggle" : "hold"))
        }
        subject.defaults.removeObject(forKey: "scrollMode")
        subject.defaults.removeObject(forKey: "holdToLockMode")
        subject.restoreSettings()
        assert(subject.scrollMode == .hold)
        for mode in [ScrollMode.hold, .toggle, .both] {
            subject.defaults.set(mode.rawValue, forKey: "scrollMode")
            subject.defaults.set(mode != .toggle, forKey: "holdToLockMode")
            subject.restoreSettings()
            assert(subject.scrollMode == mode, "New mode must override the legacy value")
        }
        subject.holdToLockMode = true
        assert(subject.scrollMode == .toggle)
        subject.holdToLockMode = false
        assert(subject.scrollMode == .hold)
        print("PASS: scroll-mode migration, default hold, persisted-mode precedence, and compatibility property")

        func mouse(_ type: CGEventType, button: CGMouseButton = .center,
                   at point: CGPoint = CGPoint(x: 123, y: 234)) -> CGEvent {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
        }
        subject.tapState = .filtering
        subject.raiseWindowOnScroll = false
        subject.scrollMode = .both
        subject.holdDelayEnabled = true
        subject.holdDelayMilliseconds = 1000
        var replays: [CGPoint] = []
        subject.postClick = { (point: CGPoint) -> Void in replays.append(point) }
        let down = mouse(.otherMouseDown)
        let up = mouse(.otherMouseUp)
        let leftDown = mouse(.leftMouseDown, button: .left)
        let leftUp = mouse(.leftMouseUp, button: .left)
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.isActive && !subject.engaged && subject.engageWorkItem == nil)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(subject.isActive && subject.engaged && subject.heldMiddleClick == nil && replays.isEmpty)
        assert(subject.handleEvent(type: .leftMouseDown, event: leftDown) == nil)
        assert(!subject.isActive && subject.swallowedButtonUps == [0])
        assert(subject.handleEvent(type: .leftMouseUp, event: leftUp) == nil)
        assert(subject.swallowedButtonUps.isEmpty && replays.isEmpty)
        print("PASS: both-mode click ignores toggle delay, engages, never replays, and swallows the next left down/up")

        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        subject.engaged = true // Simulate leaving the dead zone, as in the hold-mode checks.
        subject.leftDeadZone = true
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(!subject.isActive && !subject.engaged && replays.isEmpty)
        // A long press that showed the indicator but never left the dead zone still counts as a click.
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        subject.engaged = true
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(subject.isActive && replays.isEmpty)
        assert(subject.handleEvent(type: .leftMouseDown, event: leftDown) == nil)
        assert(subject.handleEvent(type: .leftMouseUp, event: leftUp) == nil)
        assert(!subject.isActive && subject.swallowedButtonUps.isEmpty)
        // A release outside the dead zone stops even if the timer has not engaged yet.
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.handleEvent(type: .otherMouseUp, event: mouse(.otherMouseUp, at: CGPoint(x: 200, y: 300))) == nil)
        assert(!subject.isActive && replays.isEmpty)
        // Observe a brief drag out and back between timer ticks.
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        let farDrag = mouse(.otherMouseDragged, at: CGPoint(x: 200, y: 300))
        assert(subject.handleEvent(type: .otherMouseDragged, event: farDrag)?.takeUnretainedValue() === farDrag)
        assert(subject.engaged)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(!subject.isActive && replays.isEmpty)
        print("PASS: both-mode engaged hold, moved release, and drag out/back stop without replay")

        subject.scrollMode = .hold
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(!subject.isActive && !subject.engaged && replays == [down.location])
        assert(subject.handleEvent(type: .leftMouseDown, event: leftDown)?.takeUnretainedValue() === leftDown)
        replays.removeAll()
        // Holding still shows the indicator after 0.2 s, and that long press is not replayed as a click.
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(!subject.engaged && subject.timer == nil)
        subject.middleButtonIsDown = { true }
        up.timestamp = down.timestamp + 300_000_000
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
        assert(subject.engaged && subject.timer == nil, "Holding still must show the indicator without starting ticks")
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        assert(!subject.isActive && replays.isEmpty, "A long press is not a click")
        print("PASS: hold mode releases to stop, shows the indicator after a 0.2 s hold, and never enters toggle-style scrolling")
        up.timestamp = down.timestamp + 100_000_000

        subject.tapState = .listenOnly
        for mode in [ScrollMode.hold, .toggle, .both] {
            subject.scrollMode = mode
            subject.holdDelayEnabled = mode == .toggle
            assert(subject.handleEvent(type: .otherMouseDown, event: down)?.takeUnretainedValue() === down)
            assert(subject.handleEvent(type: .otherMouseUp, event: up)?.takeUnretainedValue() === up)
            assert(replays.isEmpty && subject.swallowedButtonUps.isEmpty)
            assert(subject.isActive == (mode == .both))
            if subject.isActive {
                assert(subject.handleEvent(type: .leftMouseDown, event: leftDown)?.takeUnretainedValue() === leftDown)
                assert(subject.handleEvent(type: .leftMouseUp, event: leftUp)?.takeUnretainedValue() === leftUp)
                assert(!subject.isActive && subject.swallowedButtonUps.isEmpty)
            }
        }
        subject.scrollMode = .hold
        _ = subject.handleEvent(type: .otherMouseDown, event: down)
        subject.engaged = true
        _ = subject.handleEvent(type: .otherMouseUp, event: up)
        assert(!subject.isActive && replays.isEmpty)
        print("PASS: listen-only never replays or swallows clicks in any mode, and hold release still stops")

        let failure = "VectorScroll can't watch the mouse. Quit and reopen it. If that doesn't help, remove it from Accessibility and Input Monitoring in System Settings and add it again."
        for state in [TapState.none, .filtering, .listenOnly] {
            let expected = state == .none ? failure : state == .filtering ? "Ready to scroll"
                : "Ready to scroll. macOS didn't allow holding back clicks, so middle-clicks also reach apps."
            assert(Self.permissionStatusText(canListen: true, canAccess: true, tapState: state, tapEnabled: true) == expected)
            assert(Self.permissionStatusText(canListen: true, canAccess: true, tapState: state, tapEnabled: false) == failure)
            assert(Self.permissionStatusText(canListen: false, canAccess: false, tapState: state, tapEnabled: true)
                   == "Input Monitoring and Accessibility are required")
            assert(Self.permissionStatusText(canListen: false, canAccess: true, tapState: state, tapEnabled: true)
                   == "Input Monitoring is required")
            assert(Self.permissionStatusText(canListen: true, canAccess: false, tapState: state, tapEnabled: true)
                   == "Accessibility is required")
        }
        print("PASS: status text for all tap states, disabled taps, and unchanged missing-permission messages")

        subject.tapState = .filtering
        subject.scrollMode = .both
        for revoke in [false, true] {
            _ = subject.handleEvent(type: .otherMouseDown, event: down)
            _ = subject.handleEvent(type: .otherMouseUp, event: up)
            assert(subject.isActive && subject.engaged)
            if revoke { subject.tearDownEventTap() }
            else { _ = subject.handleEvent(type: .tapDisabledByTimeout, event: down) }
            assert(!subject.isActive && !subject.engaged && subject.heldMiddleClick == nil)
            assert(subject.swallowedButtonUps.isEmpty && replays.isEmpty)
        }
        assert(subject.tapState == .none)
        print("PASS: disabled-tap and permission teardown clear both-mode latch and click state")
        return true
    }

    static func checkHotPath() -> Bool {
        let suite = "local.vectorscroll.hot-path.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        assert(ExcludedApps.cachedBundleIDs(in: defaults).isEmpty)
        ExcludedApps.add(["com.example.one", "com.example.one"], to: defaults)
        assert(ExcludedApps.cachedBundleIDs(in: defaults) == ["com.example.one"])
        ExcludedApps.remove("com.example.one", from: defaults)
        assert(ExcludedApps.cachedBundleIDs(in: defaults).isEmpty)
        defaults.set(["com.example.external"], forKey: "excludedBundleIDs")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        assert(ExcludedApps.cachedBundleIDs(in: defaults) == ["com.example.external"])
        func window(_ pid: Int32, layer: Int = 0, alpha: Double = 1, x: CGFloat = 0) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
             kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: CGRect(x: x, y: 0, width: 100, height: 100).dictionaryRepresentation]
        }
        let point = CGPoint(x: 50, y: 50)
        let windows = [window(10, layer: 1), window(11, alpha: 0), window(12, x: 200),
                       window(ProcessInfo.processInfo.processIdentifier), window(13), window(14)]
        assert(ExcludedApps.ownerPID(at: point, in: windows) == 13, "Hit testing must use the frontmost visible normal window under the pointer")
        assert(ExcludedApps.ownerPID(at: CGPoint(x: 500, y: 500), in: windows) == nil)
        print("PASS: exclusion Set invalidation and front-to-back pointer targeting through overlays")

        func mouse(_ type: CGEventType, at point: CGPoint = CGPoint(x: 123, y: 234)) -> CGEvent {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .center)!
            event.timestamp = 1_000_000_000
            return event
        }
        let subject = VectorScrollApp()
        subject.tapState = .filtering
        subject.raiseWindowOnScroll = false
        subject.appIsExcluded = { _ in false }
        var replays = 0
        subject.postClick = { _ in replays += 1 }
        let down = mouse(.otherMouseDown)
        let up = mouse(.otherMouseUp)
        // The same physical duration gets the same result regardless of feedback delivery order.
        for milliseconds in [100, 200, 300] {
            for feedbackRan in [false, true] {
                let before = replays
                _ = subject.handleEvent(type: .otherMouseDown, event: down)
                subject.engaged = feedbackRan
                up.timestamp = down.timestamp + UInt64(milliseconds) * 1_000_000
                _ = subject.handleEvent(type: .otherMouseUp, event: up)
                assert(replays == before + (milliseconds < 200 ? 1 : 0))
                assert(!subject.isActive && subject.timer == nil)
            }
        }
        _ = subject.handleEvent(type: .otherMouseDown, event: down)
        subject.middleButtonIsDown = { false }
        subject.feedbackWorkItem!.perform()
        assert(!subject.engaged && subject.timer == nil, "Late hold feedback must check the physical button")
        subject.stopScrolling()
        print("PASS: 100/200/300 ms hold classification is independent of feedback ordering; physically released holds cannot engage")

        _ = subject.handleEvent(type: .otherMouseDown, event: down)
        let beforeDrag = replays
        let far = mouse(.otherMouseDragged, at: CGPoint(x: 200, y: 300))
        _ = subject.handleEvent(type: .otherMouseDragged, event: far)
        assert(subject.engaged && subject.leftDeadZone && subject.timer != nil && subject.lastScrollTime != nil)
        subject.lastScrollTime = -100 // A pause must discard this old clock.
        subject.scrollRemainder = CGPoint(x: 0.4, y: 0.4)
        let back = mouse(.otherMouseDragged)
        _ = subject.handleEvent(type: .otherMouseDragged, event: back)
        assert(subject.timer == nil && subject.lastScrollTime == nil && subject.scrollRemainder == .zero)
        _ = subject.handleEvent(type: .otherMouseDragged, event: far)
        assert(subject.timer != nil && subject.lastScrollTime! > 0)
        _ = subject.handleEvent(type: .otherMouseDragged, event: back)
        up.timestamp = down.timestamp + 100_000_000
        _ = subject.handleEvent(type: .otherMouseUp, event: up)
        assert(replays == beforeDrag, "A short out-and-back drag must never replay as a click")
        subject.scrollMode = .toggle
        subject.holdDelayEnabled = false
        _ = subject.handleEvent(type: .otherMouseDown, event: down)
        _ = subject.handleEvent(type: .otherMouseUp, event: up)
        assert(subject.isActive && subject.timer == nil)
        _ = subject.handleEvent(type: .mouseMoved, event: mouse(.mouseMoved, at: far.location))
        assert(subject.timer != nil)
        _ = subject.handleEvent(type: .mouseMoved, event: mouse(.mouseMoved))
        assert(subject.isActive && subject.timer == nil)
        subject.stopScrolling()
        print("PASS: hold drags and toggle motion start ticks outside the dead zone, stop inside it, and reset timing on resume")

        let offset = CGPoint(x: 120, y: 120)
        func total(ticks: Int) -> CGPoint {
            subject.scrollRemainder = .zero
            var sum = CGPoint.zero
            for _ in 0..<ticks {
                let delta = subject.nextScrollDelta(for: offset, elapsed: 1 / Double(ticks))!
                sum.x += CGFloat(delta.horizontal)
                sum.y += CGFloat(delta.vertical)
            }
            return sum
        }
        let sixty = total(ticks: 60)
        let thirty = total(ticks: 30)
        assert(sixty == thirty && sixty == CGPoint(x: -3024, y: 3024))
        subject.scrollRemainder = .zero
        let stalled = subject.nextScrollDelta(for: offset, elapsed: 10)!
        subject.scrollRemainder = .zero
        let capped = subject.nextScrollDelta(for: offset, elapsed: 0.05)!
        assert(stalled == capped && abs(stalled.vertical) <= 152)
        subject.scrollRemainder = .zero
        assert(subject.nextScrollDelta(for: offset, elapsed: 0) == nil)
        assert(subject.nextScrollDelta(for: offset, elapsed: -1) == nil)
        print("PASS: 60 and 30 callbacks both integrate 3024 px/second; stalls catch up at most 50 ms")

        // Hold the AX queue so requests can be inspected and cancelled without raising real windows.
        subject.accessibilityQueue.suspend()
        subject.raiseWindowOnScroll = true
        subject.startScrolling(at: down.unflippedLocation, target: down.location)
        subject.engage()
        let firstToken = subject.focusCancellation!
        let firstWork = subject.focusWorkItem!
        subject.stopScrolling()
        assert(firstToken.isCancelled && firstWork.isCancelled)
        subject.startScrolling(at: down.unflippedLocation, target: down.location)
        subject.engage()
        let secondToken = subject.focusCancellation!
        assert(!secondToken.isCancelled && firstToken !== secondToken)
        subject.stopScrolling()
        assert(secondToken.isCancelled && subject.focusCancellation == nil && subject.focusWorkItem == nil)
        subject.accessibilityQueue.resume()
        subject.accessibilityQueue.sync {} // Cancelled requests must drain without doing AX work.
        print("PASS: stop invalidates thread-safe focus tokens and cancels pending work across sessions")

        // Overlay ordering happens only after the handler yields; stale generations cannot show.
        subject.raiseWindowOnScroll = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        assert(!subject.overlay.probeIsVisible)
        subject.scrollMode = .both
        _ = subject.handleEvent(type: .otherMouseDown, event: down)
        _ = subject.handleEvent(type: .otherMouseUp, event: up)
        assert(subject.engaged && !subject.overlay.probeIsVisible)
        subject.stopScrolling()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        assert(!subject.overlay.probeIsVisible, "A stopped generation must never show its queued overlay")
        _ = subject.handleEvent(type: .otherMouseDown, event: down)
        _ = subject.handleEvent(type: .otherMouseUp, event: up)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        assert(subject.overlay.probeIsVisible)
        subject.stopScrolling()
        assert(subject.overlay.probeIsVisible, "Hiding must also wait until after the tap callback")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        assert(!subject.overlay.probeIsVisible)
        print("PASS: overlay show/hide is deferred and guarded by the session generation")
        return true
    }

    static func checkEventRecovery() -> Bool {
        let subject = VectorScrollApp()
        subject.tapState = .filtering
        var replays: [CGPoint] = []
        subject.postClick = { replays.append($0) }
        let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                           mouseCursorPosition: CGPoint(x: 123, y: 234), mouseButton: .center)!
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.isActive && subject.timer == nil, "A stationary press must not start ticks")
        assert(subject.anchor == down.unflippedLocation, "Anchor must come from the press event")
        assert(subject.pendingTarget == down.location, "AX targeting must retain CoreGraphics coordinates")
        _ = subject.handleEvent(type: .tapDisabledByTimeout, event: down)
        assert(!subject.isActive && subject.timer == nil && subject.anchor == nil && subject.pendingTarget == nil)
        assert(subject.heldMiddleClick == nil && subject.swallowedButtonUps.isEmpty && replays.isEmpty)
        let up = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp,
                         mouseCursorPosition: down.location, mouseButton: .center)!
        assert(subject.handleEvent(type: .otherMouseUp, event: up)?.takeUnretainedValue() === up)
        subject.holdToLockMode = true
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.engageWorkItem != nil)
        _ = subject.handleEvent(type: .tapDisabledByUserInput, event: down)
        assert(subject.engageWorkItem == nil && !subject.isActive)
        assert(subject.heldMiddleClick == nil && subject.swallowedButtonUps.isEmpty && replays.isEmpty)
        assert(subject.handleEvent(type: .otherMouseUp, event: up)?.takeUnretainedValue() === up)
        subject.holdDelayEnabled = false
        assert(subject.handleEvent(type: .otherMouseDown, event: down) == nil)
        assert(subject.handleEvent(type: .otherMouseUp, event: up) == nil)
        let left = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: down.location, mouseButton: .left)!
        assert(subject.handleEvent(type: .leftMouseDown, event: left) == nil)
        assert(subject.swallowedButtonUps == [0])
        _ = subject.handleEvent(type: .tapDisabledByTimeout, event: down)
        assert(subject.swallowedButtonUps.isEmpty && replays.isEmpty)
        print("PASS: press-event anchoring and disabled-tap cancellation of scrolling and delayed holds")
        print("PASS: tap-disabled events clear held clicks and stop-button releases without replay")
        return true
    }
}

extension ScrollOverlayWindow {
    var probeIsVisible: Bool { window.isVisible }
}

setvbuf(stdout, nil, _IONBF, 0)
if CommandLine.arguments[1] == "--click" {
    precondition(CGPreflightPostEventAccess(), "UI checks require Accessibility access")
    let point = CGPoint(x: Double(CommandLine.arguments[2])!, y: Double(CommandLine.arguments[3])!)
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cgSessionEventTap)
        usleep(50_000)
    }
    exit(0)
}
precondition(FileManager.default.changeCurrentDirectoryPath(CommandLine.arguments[1]))
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: .aqua)
app.applicationIconImage = NSImage(contentsOfFile: "docs/icon.png")
@MainActor
final class AuditAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // RunLoop callbacks allow native controls to drain work on the main
        // queue while their mouse tracking loop runs. DispatchQueue callbacks
        // cannot re-enter that queue on macOS 26.
        perform(#selector(runChecks), with: nil, afterDelay: 0)
    }

    @objc private func runChecks() {
        NSApp.activate()
        let promptRelease = VectorScrollApp.checkRelease(delay: 0.1)
        let delayedRelease = VectorScrollApp.checkRelease(delay: 0.3)
        let filtering = VectorScrollApp.checkClickFiltering()
        let recovery = VectorScrollApp.checkEventRecovery()
        let hotPath = VectorScrollApp.checkHotPath()
        let modes = VectorScrollApp.checkScrollModesAndTapStatus()
        VectorScrollApp.checkScrollingSettings()
        let settings = VectorScrollApp.checkDelaySettings()
        let passed = promptRelease && delayedRelease && filtering && recovery && hotPath && modes && settings
        if passed {
            try! "PASS".write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
        }
        exit(passed ? 0 : 1)
    }
}
let auditDelegate = AuditAppDelegate()
app.delegate = auditDelegate
app.run()
'''

output = root / ".build/audit-hold"
output.mkdir(parents=True, exist_ok=True)
generated = output / "main.swift"
generated.write_text(source.split(entry)[0] + harness)
binary = output / "check-hold"
subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors",
                str(generated), str(root / "Sources/VectorScroll/Localization.swift"), str(root / "Sources/VectorScroll/ExcludedApps.swift"), str(root / "Sources/VectorScroll/SettingsStyle.swift"), str(root / "Sources/VectorScroll/Onboarding.swift"), str(root / "Sources/VectorScroll/Updates.swift"), str(root / "Sources/VectorScroll/UpdateInstaller.swift"), "-o", str(binary), "-framework", "AppKit",
                "-framework", "ApplicationServices", "-framework", "ServiceManagement"], check=True)
# LaunchServices registers the probe as a real foreground app. macOS 26 will
# not activate an unbundled command-line process for native control tracking.
run_id = uuid.uuid4().hex
bundle = output / f"VectorScrollAudit-{run_id}.app"
macos = bundle / "Contents/MacOS"
macos.mkdir(parents=True)
shutil.copy2(binary, macos / "check-hold")
(bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": f"local.vectorscroll.audit.{run_id}",
    "CFBundleName": "VectorScroll UI Audit",
    "CFBundleExecutable": "check-hold",
    "CFBundlePackageType": "APPL",
    "NSHighResolutionCapable": True,
}))
result = output / f"{run_id}.passed"
stdout = output / f"{run_id}.stdout"
stderr = output / f"{run_id}.stderr"
captures = output / f"{run_id}-captures"
captures.mkdir()
stop_capture = threading.Event()
def capture_windows():
    while not stop_capture.wait(0.05):
        for request in list(captures.glob("*.request")) + list(captures.glob("*.click")):
            completion = request.with_suffix(".done")
            if completion.exists():
                continue
            first, second = request.read_text().splitlines()
            command = ([str(binary), "--click", first, second] if request.suffix == ".click" else
                       ["/usr/sbin/screencapture", "-x", "-o", "-l", first, second])
            try:
                capture = subprocess.run(command, timeout=5, capture_output=True)
                if capture.returncode:
                    print(capture.stderr.decode(errors="replace"), flush=True)
                completion.write_text(str(capture.returncode))
            except subprocess.TimeoutExpired:
                completion.write_text("timeout")
capture_thread = threading.Thread(target=capture_windows, daemon=True)
capture_thread.start()
try:
    # A failed assertion must not leave the next probe behind a restore-windows dialog.
    subprocess.run(["open", "-n", "-F", "-W", "--stdout", str(stdout), "--stderr", str(stderr),
                    str(bundle), "--args", str(root), str(result), str(captures)], check=True, timeout=60, cwd=root)
finally:
    stop_capture.set()
    capture_thread.join(timeout=6)
    for log in [stdout, stderr]:
        if log.exists():
            print(log.read_text(), end="", flush=True)
assert result.exists() and result.read_text() == "PASS", "The UI app did not finish all assertions"
