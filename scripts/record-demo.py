"""Record the real app scrolling a real browser window and write the website demo video.

Builds a copy of the app with a driver appended, like check-hold.py. The driver runs the
production scroll path (startScrolling, the tick timer, the indicator overlay, posted scroll
events) while it moves the real pointer the way a hand would, one app tick per frame, and
grabs a still of the Safari window after each tick. ffmpeg encodes the stills at 60 fps.
No event tap and no permission prompts.

Run on macOS: python3 scripts/record-demo.py
Writes dist/demo/demo.mp4, demo.webm and poster.jpg for site/.
"""

from pathlib import Path
import shutil
import subprocess
import sys
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
extension VectorScrollApp {
    static func demo(window: CGRect, frames: String) {
        let subject = VectorScrollApp()
        subject.eventTapInstalled = true
        subject.overlay.setSize(40)
        let screen = NSScreen.screens[0].frame
        let origin = CGPoint(x: window.midX + window.width * 0.06, y: window.minY + window.height * 0.5)
        let seg: (Double, Double, Double) -> Double = { ms, a, b in min(1, max(0, (ms - a) / (b - a))) }
        let ease: (Double) -> Double = { t in t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
        let lerp: (Double, Double, Double) -> Double = { a, b, t in a + (b - a) * t }
        let start = CGPoint(x: window.maxX - 120, y: window.maxY - 80)
        func pose(_ ms: Double) -> (CGPoint, Bool) {
            let o = origin
            if ms < 900 { return (CGPoint(x: lerp(start.x, o.x + 30, ease(seg(ms, 0, 900))), y: lerp(start.y, o.y + 15, ease(seg(ms, 0, 900)))), false) }
            if ms < 1500 { return (CGPoint(x: lerp(o.x + 30, o.x, ease(seg(ms, 900, 1400))), y: lerp(o.y + 15, o.y, ease(seg(ms, 900, 1400)))), false) }
            if ms < 1800 { return (o, true) }
            if ms < 4800 { return (CGPoint(x: o.x + 14 * seg(ms, 1800, 4800), y: o.y + 60 * ease(seg(ms, 1800, 3200))), true) }
            if ms < 6000 { return (CGPoint(x: o.x + lerp(14, 9, seg(ms, 4800, 6000)), y: o.y + lerp(60, 25, ease(seg(ms, 4800, 6000)))), true) }
            if ms < 9200 { return (CGPoint(x: o.x + lerp(9, -6, seg(ms, 6000, 9200)), y: o.y + lerp(25, -90, ease(seg(ms, 6000, 7600)))), true) }
            if ms < 10200 { return (CGPoint(x: o.x + lerp(-6, 2, seg(ms, 9200, 10200)), y: o.y + lerp(-90, 3, ease(seg(ms, 9200, 10000)))), ms < 10000) }
            return (CGPoint(x: lerp(o.x + 2, start.x, ease(seg(ms, 10400, 12000))), y: lerp(o.y + 3, start.y, ease(seg(ms, 10400, 12000)))), false)
        }
        var wasDown = false
        // One app tick per frame, then a still of the window. The app's own 16 ms timer is
        // replaced by a direct tick so the result is an exact 60 fps regardless of how fast
        // the runner can actually paint.
        for n in 0..<720 {
            let ms = Double(n) * 1000 / 60
            let (p, down) = pose(ms)
            let t = ms / 1000
            let cg = CGPoint(x: p.x + 0.7 * sin(t * 8.1) + 0.4 * sin(t * 13.7), y: p.y + 0.6 * sin(t * 9.3 + 1) + 0.4 * sin(t * 15.1))
            CGWarpMouseCursorPosition(cg)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left)?.post(tap: .cgSessionEventTap)
            if down != wasDown {
                wasDown = down
                if down {
                    subject.startScrolling(at: CGPoint(x: cg.x, y: screen.height - cg.y), target: cg)
                    subject.timer?.cancel()
                    subject.timer = nil
                } else {
                    subject.stopScrolling()
                }
            }
            if subject.isActive { subject.emitScrollTick() }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.045))
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-C", "-R", "\(Int(window.minX)),\(Int(window.minY)),\(Int(window.width)),\(Int(window.height))",
                              frames + "/" + String(format: "%04d.png", n)]
            try! shot.run()
            shot.waitUntilExit()
            if n % 60 == 0 { print("frame \(n)") }
        }
        subject.stopScrolling()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    }
}

setvbuf(stdout, nil, _IONBF, 0)
if CommandLine.arguments.contains("--window") {
    // Front Safari window bounds, in CG coordinates. Bounds need no permission.
    let name = CommandLine.arguments.last!
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    for w in list where (w[kCGWindowOwnerName as String] as? String) == name && (w[kCGWindowLayer as String] as? Int) == 0 {
        let b = w[kCGWindowBounds as String] as! [String: CGFloat]
        if b["Width"]! > 400 { print("\(Int(b["X"]!)) \(Int(b["Y"]!)) \(Int(b["Width"]!)) \(Int(b["Height"]!))"); exit(0) }
    }
    exit(1)
}
let g = CommandLine.arguments.dropFirst().compactMap { Double($0) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
VectorScrollApp.demo(window: CGRect(x: g[0], y: g[1], width: g[2], height: g[3]), frames: CommandLine.arguments.last!)
exit(0)
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
subprocess.run(["open", "-a", "Safari", "https://en.wikipedia.org/wiki/Scrolling"], check=True, timeout=60)
log("safari opened")
time.sleep(12)
x, y, w, h = map(int, subprocess.check_output([str(binary), "--window", "Safari"], timeout=60).split())
log("safari window", x, y, w, h)
subprocess.run([str(binary), str(x), str(y), str(w), str(h), str(frames)], check=True, timeout=600)
log("frames captured", len(list(frames.iterdir())))
subprocess.run(["osascript", "-e", 'tell application "Safari" to quit'], timeout=30)

common = ["ffmpeg", "-y", "-v", "error", "-framerate", "60", "-i", str(frames / "%04d.png"), "-pix_fmt", "yuv420p", "-vf", "crop=trunc(iw/2)*2:trunc(ih/2)*2"]
subprocess.run([*common, "-c:v", "libx264", "-preset", "slow", "-crf", "19", "-movflags", "+faststart", str(out / "demo.mp4")], check=True)
subprocess.run([*common, "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "30", "-row-mt", "1", str(out / "demo.webm")], check=True)
shutil.copy(frames / "0240.png", out / "poster.png")
subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(frames / "0240.png"), "-q:v", "3", str(out / "poster.jpg")], check=True)
log("wrote", *sorted(p.name for p in out.iterdir()))
