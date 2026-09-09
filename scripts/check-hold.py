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
let promptRelease = VectorScrollApp.checkRelease(delay: 0.1)
let delayedRelease = VectorScrollApp.checkRelease(delay: 0.3)
exit(promptRelease && delayedRelease ? 0 : 1)
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
                str(generated), "-o", str(binary), "-framework", "AppKit",
                "-framework", "ApplicationServices", "-framework", "ServiceManagement"], check=True)
subprocess.run([str(binary)], check=True)
