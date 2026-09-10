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
        let scroll = content.subviews.first as! NSScrollView
        let stack = scroll.documentView!.subviews.first as! NSStackView
        assert(stack.bounds.width <= scroll.contentView.bounds.width, "Settings must fit horizontally")
        assert(scroll.hasVerticalScroller, "All settings must remain reachable on smaller screens")
        assert(subject.holdScrollItem is SettingsButton)
        assert(subject.openSettingsButton is SettingsButton)
        subject.hideIconItem.performClick(nil)
        assert(subject.hideIconItem.state == .on && subject.statusItem != nil, "Styled toggle must use native click tracking")
        subject.holdScrollItem.performClick(nil)
        assert(!subject.holdToLockMode && subject.holdScrollItem.state == .on)
        subject.holdToLockItem.performClick(nil)
        assert(subject.holdToLockMode && subject.holdToLockItem.state == .on)
        content.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        func savePreview(_ name: String) {
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: bitmap)
        // The window supplies its background outside the content view. Include
        // that native background when exporting the view for visual review.
        let preview = NSImage(size: content.bounds.size)
        preview.lockFocus()
        SettingsStyle.background.setFill()
        NSBezierPath(rect: content.bounds).fill()
        bitmap.draw(in: content.bounds, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
        preview.unlockFocus()
        let opaque = NSBitmapImageRep(data: preview.tiffRepresentation!)!
        try! opaque.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/\(name).png"))
        }
        savePreview("settings-delay-preview")
        subject.selectHoldToScroll()
        content.layoutSubtreeIfNeeded()
        savePreview("settings-preview")
        subject.settingsWindow.close()
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
        // armHoldToLock is the exact path used by the middle-down handler.
        // Calling it directly avoids needing a live CGEventTapProxy or TCC access.
        subject.armHoldToLock(at: .zero, target: .zero)
        Thread.sleep(forTimeInterval: delay)
        _ = subject.handleEvent(type: .otherMouseUp, event: up)
        let canceled = subject.engageWorkItem == nil && !subject.isActive
        subject.cancelArmedHoldToLock()
        print("\(canceled ? "PASS" : "FAIL"): 100 ms click, release handled after \(Int(delay * 1000)) ms")
        return canceled
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .aqua)
app.finishLaunching()
let promptRelease = VectorScrollApp.checkRelease(delay: 0.1)
let delayedRelease = VectorScrollApp.checkRelease(delay: 0.3)
let settings = VectorScrollApp.checkDelaySettings()
exit(promptRelease && delayedRelease && settings ? 0 : 1)
'''

# The proxy is unused by handleEvent. Remove that parameter only in the generated
# copy so the test can invoke the actual handler without an installed event tap.
signature = "private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent)"
assert source.count(signature) == 1, "Event handler signature changed; update the probe"
source = source.replace(signature, "private func handleEvent(type: CGEventType, event: CGEvent)")
source = source.replace("app.handleEvent(proxy: proxy, type: type, event: event)",
                        "app.handleEvent(type: type, event: event)")
output = root / ".build/audit-hold"
output.mkdir(parents=True, exist_ok=True)
generated = output / "main.swift"
generated.write_text(source.split(entry)[0] + harness)
binary = output / "check-hold"
subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors",
                str(generated), str(root / "Sources/VectorScroll/SettingsStyle.swift"), str(root / "Sources/VectorScroll/Updates.swift"), str(root / "Sources/VectorScroll/UpdateInstaller.swift"), "-o", str(binary), "-framework", "AppKit",
                "-framework", "ApplicationServices", "-framework", "ServiceManagement"], check=True)
subprocess.run([str(binary)], check=True)
