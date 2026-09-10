"""Check the built installer payload without launching the app."""
from pathlib import Path
import plistlib
import struct

root = Path(__file__).resolve().parent.parent
contents = root / "dist/VectorScroll.app/Contents"
info = plistlib.loads((contents / "Info.plist").read_bytes())
assert info["CFBundleShortVersionString"] == "1.1.0"
assert info["CFBundleVersion"] == "2"
assert info["LSMinimumSystemVersion"] == "14.0"
binary = (contents / "MacOS" / info["CFBundleExecutable"]).read_bytes()
for title in (b"Hold to Scroll", b"Hold to Start", b"Hide Menu Bar Icon", b"Start Delay"):
    assert title in binary, f"Missing menu text in packaged binary: {title!r}"
assert (contents / "Resources/VectorScroll.icns").stat().st_size > 0

icons = list((root / "dist").glob("VectorScroll-icons.*/VectorScroll.iconset/*.png"))
assert len(icons) == 10, f"Expected ten icons, got {len(icons)}"
for icon in icons:
    size = int(icon.stem.split("_")[1].split("x")[0])
    expected = size * (2 if "@2x" in icon.stem else 1)
    png = icon.read_bytes()
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    assert struct.unpack(">II", png[16:24]) == (expected, expected), icon.name
print("PASS: version, packaged menu strings, icon resource, and all ten PNG dimensions")
