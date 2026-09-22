"""Record the website demo from the real app on macOS.

Builds a copy of the app with a driver appended, like check-hold.py. The driver opens the
menu bar menu, opens Settings, switches to toggle mode, drags the speed slider, closes the
window, then scrolls the GitHub README in Safari through the production scroll path with the indicator.
Time is the frame index, not the clock: every frame moves the real pointer, advances the
app one tick, and takes a still of the screen, so the result is an exact 60 fps however
slowly the machine paints. screencapture -R leaves the cursor out, so the driver draws it.

Run on macOS: python3 scripts/record-demo.py
Writes dist/demo/demo.mp4, demo.webm and poster.jpg for site/.
"""

from pathlib import Path
import shutil
import subprocess
import time

T0 = time.time()


def log(*a):
    print(f"[{time.time() - T0:6.1f}s]", *a, flush=True)


root = Path(__file__).resolve().parent.parent
out = root / "dist/demo"
out.mkdir(parents=True, exist_ok=True)
build = root / ".build/record-demo"
build.mkdir(parents=True, exist_ok=True)

source = (root / "Sources/VectorScroll/main.swift").read_text()
entry = "let app = NSApplication.shared\n"
assert source.count(entry) == 1, "Application entry point changed; update the driver"

driver = r'''
// Private members are only reachable from an extension in the same file, so this shim
// hands the driver what it needs.
extension VectorScrollApp {
    func demoPrepare() { eventTapInstalled = true; configureMenu(); overlay.setSize(40) }
    var demoStatusButton: NSStatusBarButton { statusItem.button! }
    func demoShowSettings() { showSettings() }
    var demoToggleButton: NSView { holdToLockItem }
    func demoSelectToggle() { holdToLockItem.performClick(nil) }
    var demoSlider: NSSlider { speedSlider }
    func demoSetSpeed(_ value: Double) { speedSlider.doubleValue = value; changeScrollSpeed(speedSlider) }
    var demoCloseButton: NSView? { settingsWindow.contentView!.subviews.compactMap { $0 as? SettingsButton }.first { $0.title == "Close settings" } }
    func demoCloseSettings() { settingsWindow.performClose(nil) }
    func demoPress(at point: CGPoint, target: CGPoint) { startScrolling(at: point, target: target); timer?.cancel(); timer = nil }
    func demoRelease() { stopScrolling() }
    func demoTick() { if isActive { emitScrollTick() } }
}
@MainActor
private final class Driver: NSObject {
    struct Phase {
        let end: Int
        let target: () -> CGPoint
        let hold: Bool
        let start: () -> Void
    }
    let subject = VectorScrollApp()
    let frames: String
    let screen = NSScreen.screens[0].frame
    let cursor = NSCursor.arrow
    var phases: [Phase] = []
    var n = 0
    var phase = 0
    var from = CGPoint(x: 700, y: 500)
    var pointer = CGPoint(x: 700, y: 500)
    var safari = CGRect(x: 0, y: 25, width: 1024, height: 700)

    init(frames: String) {
        self.frames = frames
        super.init()
    }

    func cg(_ ns: NSPoint) -> CGPoint { CGPoint(x: ns.x, y: screen.height - ns.y) }
    func center(_ view: NSView) -> CGPoint {
        view.scrollToVisible(view.bounds)
        view.window?.contentView?.layoutSubtreeIfNeeded()
        let r = view.window!.convertToScreen(view.convert(view.bounds, to: nil))
        return cg(NSPoint(x: r.midX, y: r.midY))
    }
    func knob(_ value: Double) -> CGPoint {
        let s = subject.demoSlider
        let r = s.window!.convertToScreen(s.convert(s.bounds, to: nil))
        let t = (value - s.minValue) / (s.maxValue - s.minValue)
        return cg(NSPoint(x: r.minX + 8 + t * (r.width - 16), y: r.midY))
    }
    func statusItem() -> CGPoint {
        let r = subject.demoStatusButton.window!.frame
        return cg(NSPoint(x: r.midX, y: r.midY))
    }

    func run() {
        subject.demoPrepare()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Safari" && (w[kCGWindowLayer as String] as? Int) == 0 {
            let b = w[kCGWindowBounds as String] as! [String: CGFloat]
            if b["Width"]! > 400 { safari = CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!); break }
        }
        let origin = CGPoint(x: safari.midX + safari.width * 0.06, y: safari.minY + safari.height * 0.5)
        let still: () -> CGPoint = { [unowned self] in pointer }
        var speed = 100.0
        phases = [
            Phase(end: 80, target: statusItem, hold: false) {},
            // Status bar menu tracking stalls every timer, so the menu itself is not popped.
            // The pointer reaches the icon, pauses, and Settings opens as it would from the menu.
            Phase(end: 100, target: still, hold: false) {},
            Phase(end: 115, target: still, hold: false) { [unowned self] in subject.demoShowSettings() },
            Phase(end: 250, target: { [unowned self] in center(subject.demoToggleButton) }, hold: false) {},
            Phase(end: 275, target: still, hold: false) { [unowned self] in subject.demoSelectToggle() },
            Phase(end: 350, target: { [unowned self] in knob(100) }, hold: false) {},
            Phase(end: 440, target: { [unowned self] in
                speed = min(150, speed + 0.6)
                subject.demoSetSpeed(speed)
                return knob(speed)
            }, hold: false) {},
            Phase(end: 470, target: still, hold: false) {},
            Phase(end: 540, target: { [unowned self] in
                return subject.demoCloseButton.map(center) ?? pointer
            }, hold: false) {},
            Phase(end: 560, target: still, hold: false) { [unowned self] in subject.demoCloseSettings() },
            Phase(end: 640, target: { origin }, hold: false) {},
            Phase(end: 660, target: { origin }, hold: true) {},
            Phase(end: 840, target: { CGPoint(x: origin.x + 12, y: origin.y + 45) }, hold: true) {},
            Phase(end: 960, target: { CGPoint(x: origin.x + 9, y: origin.y + 18) }, hold: true) {},
            Phase(end: 1140, target: { CGPoint(x: origin.x - 6, y: origin.y - 70) }, hold: true) {},
            Phase(end: 1230, target: { CGPoint(x: origin.x + 2, y: origin.y + 3) }, hold: true) {},
            Phase(end: 1260, target: still, hold: false) {},
            Phase(end: 1320, target: { CGPoint(x: origin.x + 40, y: origin.y + 25) }, hold: false) {},
        ]
        // 40 ms between ticks gives Safari and the app windows time to paint. Common modes keep it firing while the menu tracks.
        let timer = Timer(timeInterval: 0.04, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
    }

    var wasDown = false
    var lastStart = 0

    @objc func tick(_ timer: Timer) {
        if phase >= phases.count { timer.invalidate(); subject.demoRelease(); exit(0) }
        let p = phases[phase]
        if n == lastStart {
            from = pointer
            p.start()
        }
        let t = Double(n - lastStart) / Double(max(1, p.end - lastStart))
        let e = t < 0.5 ? 8 * pow(t, 4) : 1 - 8 * pow(1 - t, 4)   // quartic: slow start, quick middle, soft landing
        let goal = p.target()
        let s = Double(n) / 60
        pointer = CGPoint(x: from.x + (goal.x - from.x) * e + 0.6 * sin(s * 8.1) + 0.3 * sin(s * 13.7),
                          y: from.y + (goal.y - from.y) * e + 0.5 * sin(s * 9.3 + 1) + 0.3 * sin(s * 15.1))
        CGWarpMouseCursorPosition(pointer)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pointer, mouseButton: .left)?.post(tap: .cgSessionEventTap)
        if p.hold != wasDown {
            wasDown = p.hold
            if p.hold {
                subject.demoPress(at: CGPoint(x: pointer.x, y: screen.height - pointer.y), target: pointer)
            } else {
                subject.demoRelease()
            }
        }
        subject.demoTick()
        capture()
        if n % 60 == 0 { print("frame \(n)") }
        n += 1
        if n >= p.end { phase += 1; lastStart = n }
    }

    func capture() {
        let file = frames + "/" + String(format: "%04d.png", n)
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-R", "0,0,\(Int(screen.width)),\(Int(screen.height))", file]
        try! shot.run()
        shot.waitUntilExit()
        let image = NSImage(contentsOfFile: file)!
        let rep = image.representations[0]
        let scale = CGFloat(rep.pixelsWide) / screen.width
        let canvas = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        canvas.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: canvas.size))
        let hot = cursor.hotSpot, size = cursor.image.size
        cursor.image.draw(in: NSRect(x: (pointer.x - hot.x) * scale, y: (screen.height - pointer.y - (size.height - hot.y)) * scale,
                                     width: size.width * scale, height: size.height * scale))
        canvas.unlockFocus()
        try! NSBitmapImageRep(data: canvas.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: file))
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .aqua)
app.finishLaunching()
private let driver = Driver(frames: CommandLine.arguments[1])
driver.run()
app.run()
'''

generated = build / "main.swift"
generated.write_text(source.split(entry)[0] + driver)
binary = build / "record-demo"
sources = [str(root / "Sources/VectorScroll" / f) for f in ["SettingsStyle.swift", "Onboarding.swift", "Updates.swift", "UpdateInstaller.swift"]]
log("compiling driver")
subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors", str(generated), *sources, "-o", str(binary),
                "-framework", "AppKit", "-framework", "ApplicationServices", "-framework", "ServiceManagement"], check=True, timeout=600)
log("compiled")

frames = build / "frames"
shutil.rmtree(frames, ignore_errors=True)
frames.mkdir()
subprocess.run(["defaults", "write", "com.apple.dock", "autohide", "-bool", "true"], check=True)
subprocess.run(["killall", "Dock"])
# The runner boots at 1024x768. Ask for a larger mode if the virtual display has one, so the
# 620x820 Settings window does not fill the frame.
modes = subprocess.run(["displayplacer", "list"], capture_output=True, text=True).stdout
screen_id = next((line.split(":", 1)[1].strip() for line in modes.splitlines() if line.startswith("Persistent screen id")), None)
for res in ("1920x1080", "1680x1050", "1600x900", "1440x900"):
    if screen_id and f"res:{res}" in modes:
        r = subprocess.run(["displayplacer", f"id:{screen_id} res:{res}"], capture_output=True, text=True)
        log("display", res, "ok" if r.returncode == 0 else r.stderr.strip())
        if r.returncode == 0:
            break
else:
    log("display unchanged; modes:", " ".join(sorted({m for m in modes.split() if m.startswith("res:")})))
time.sleep(2)
subprocess.run(["open", "-a", "Safari", "https://github.com/Sowyu/VectorScroll"], check=True, timeout=60)
log("safari opened")
time.sleep(12)
subprocess.run([str(binary), str(frames)], check=True, timeout=600)
log("frames captured", len(list(frames.iterdir())))
subprocess.run(["osascript", "-e", 'tell application "Safari" to quit'], timeout=30)

common = ["ffmpeg", "-y", "-v", "error", "-framerate", "60", "-i", str(frames / "%04d.png"), "-pix_fmt", "yuv420p", "-vf", "crop=trunc(iw/2)*2:trunc(ih/2)*2"]
subprocess.run([*common, "-c:v", "libx264", "-preset", "slow", "-crf", "19", "-movflags", "+faststart", str(out / "demo.mp4")], check=True)
subprocess.run([*common, "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "30", "-row-mt", "1", str(out / "demo.webm")], check=True)
subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(frames / "0300.png"), "-q:v", "3", str(out / "poster.jpg")], check=True)
log("wrote", *sorted(p.name for p in out.iterdir()))
