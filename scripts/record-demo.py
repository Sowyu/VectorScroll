"""Record the real app scrolling a real browser window and write the website demo video.

Builds a copy of the app with a driver appended, like check-hold.py. The driver runs the
production scroll path (startScrolling, the tick timer, the indicator overlay, posted scroll
events) while it moves the real pointer the way a hand would. screencapture records the
screen and ffmpeg crops to the browser window. No event tap and no permission prompts.

Run on macOS with Google Chrome installed: python3 scripts/record-demo.py
Writes dist/demo/demo.mp4, demo.webm and poster.jpg for site/.
"""

from pathlib import Path
import json
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
    static func demo(window: CGRect) {
        let subject = VectorScrollApp()
        subject.eventTapInstalled = true
        subject.overlay.setSize(40)
        let screenHeight = NSScreen.screens[0].frame.height  // mouseLocation is bottom-left on the primary screen
        let origin = CGPoint(x: window.midX + window.width * 0.06, y: window.minY + window.height * 0.5)
        let seg: (Double, Double, Double) -> Double = { ms, a, b in min(1, max(0, (ms - a) / (b - a))) }
        let ease: (Double) -> Double = { t in t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
        let lerp: (Double, Double, Double) -> Double = { a, b, t in a + (b - a) * t }
        var seed: UInt64 = 11
        let tremor: () -> Double = { seed = (seed &* 6364136223846793005) &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
        let start = CGPoint(x: window.maxX - 120, y: window.maxY - 80)
        func pose(_ ms: Double) -> (CGPoint, Bool) {
            let o = origin
            if ms < 900 { return (CGPoint(x: lerp(start.x, o.x + 30, ease(seg(ms, 0, 900))), y: lerp(start.y, o.y + 15, ease(seg(ms, 0, 900)))), false) }
            if ms < 1500 { return (CGPoint(x: lerp(o.x + 30, o.x, ease(seg(ms, 900, 1400))), y: lerp(o.y + 15, o.y, ease(seg(ms, 900, 1400)))), false) }
            if ms < 1800 { return (o, true) }
            if ms < 4800 { return (CGPoint(x: o.x + 14 * seg(ms, 1800, 4800), y: o.y + 95 * ease(seg(ms, 1800, 3200))), true) }
            if ms < 6000 { return (CGPoint(x: o.x + lerp(14, 9, seg(ms, 4800, 6000)), y: o.y + lerp(95, 40, ease(seg(ms, 4800, 6000)))), true) }
            if ms < 9200 { return (CGPoint(x: o.x + lerp(9, -6, seg(ms, 6000, 9200)), y: o.y + lerp(40, -150, ease(seg(ms, 6000, 7600)))), true) }
            if ms < 10200 { return (CGPoint(x: o.x + lerp(-6, 2, seg(ms, 9200, 10200)), y: o.y + lerp(-150, 3, ease(seg(ms, 9200, 10000)))), ms < 10000) }
            return (CGPoint(x: lerp(o.x + 2, start.x, ease(seg(ms, 10400, 12000))), y: lerp(o.y + 3, start.y, ease(seg(ms, 10400, 12000)))), false)
        }
        // Pump the main run loop by hand. That services the app's tick timer and the overlay
        // window without any closures, which keeps this simple under Swift 6 isolation rules.
        let t0 = Date()
        var wasDown = false
        while true {
            let ms = Date().timeIntervalSince(t0) * 1000
            if ms > 12500 { break }
            let (p, down) = pose(ms)
            let cg = CGPoint(x: p.x + tremor() * 1.2, y: p.y + tremor() * 1.2)
            CGWarpMouseCursorPosition(cg)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cg, mouseButton: .left)?.post(tap: .cgSessionEventTap)
            if down != wasDown {
                wasDown = down
                if down { subject.startScrolling(at: CGPoint(x: cg.x, y: screenHeight - cg.y), target: cg) } else { subject.stopScrolling() }
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.008))
        }
        subject.stopScrolling()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    }
}

setvbuf(stdout, nil, _IONBF, 0)
if CommandLine.arguments.contains("--screen") {
    let f = NSScreen.screens[0].frame
    print("\(Int(f.width)) \(Int(f.height))")
    exit(0)
}
let g = CommandLine.arguments.dropFirst().compactMap { Double($0) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
VectorScrollApp.demo(window: CGRect(x: g[0], y: g[1], width: g[2], height: g[3]))
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

chrome = "/Applications/Google Chrome.app"
if not Path(chrome).exists():
    sys.exit("Google Chrome is required for a browser window with a known position")
sw, sh = map(int, subprocess.check_output([str(binary), "--screen"], timeout=60).split())
log("screen", sw, sh)
w, h = min(1440, sw - 40), min(900, sh - 120)
x, y = (sw - w) // 2, max(40, (sh - h) // 2)
subprocess.run(["open", "-na", chrome, "--args", "--no-first-run", "--no-default-browser-check", "--disable-features=TranslateUI",
                f"--window-position={x},{y}", f"--window-size={w},{h}", "--new-window", "https://en.wikipedia.org/wiki/Scrolling"], check=True, timeout=60)
log("chrome opened")
time.sleep(10)

raw = build / "raw.mov"
raw.unlink(missing_ok=True)
recorder = subprocess.Popen(["screencapture", "-v", "-C", "-x", "-V", "15", str(raw)])
log("recording")
time.sleep(1.5)
subprocess.run([str(binary), str(x), str(y), str(w), str(h)], check=True, timeout=30)
log("driver finished")
recorder.wait(timeout=30)
log("recorder finished", raw.stat().st_size if raw.exists() else "no file")
subprocess.run(["pkill", "-x", "Google Chrome"])
assert raw.exists() and raw.stat().st_size > 100_000, "screencapture wrote nothing"

probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", str(raw)]))
scale = probe["streams"][0]["width"] / sw  # Retina runners record at 2x
crop = f"crop={int(w * scale)}:{int(h * scale)}:{int(x * scale)}:{int(y * scale)},scale=1440:-2,fps=60"
common = ["ffmpeg", "-y", "-v", "error", "-ss", "1.5", "-t", "12", "-i", str(raw), "-vf", crop, "-pix_fmt", "yuv420p", "-an"]
subprocess.run([*common, "-c:v", "libx264", "-preset", "slow", "-crf", "19", "-movflags", "+faststart", str(out / "demo.mp4")], check=True)
subprocess.run([*common, "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "30", "-row-mt", "1", str(out / "demo.webm")], check=True)
subprocess.run(["ffmpeg", "-y", "-v", "error", "-ss", "4", "-i", str(raw), "-vf", crop, "-frames:v", "1", "-q:v", "3", str(out / "poster.jpg")], check=True)
shutil.copy(raw, out / "raw.mov")
log("wrote", *sorted(p.name for p in out.iterdir()))
