"""Check the built installer payload without launching the app."""
from pathlib import Path
import plistlib
import struct

root = Path(__file__).resolve().parent.parent
contents = root / "dist/VectorScroll.app/Contents"
info = plistlib.loads((contents / "Info.plist").read_bytes())
assert info["CFBundleShortVersionString"] == "1.8.0"
assert info["CFBundleVersion"] == "15"
assert info["LSMinimumSystemVersion"] == "14.0"
assert (contents / "MacOS" / info["CFBundleExecutable"]).stat().st_size > 0
# check-hold.py checks real menu items. Optimized Swift short strings need not
# appear as contiguous text in the executable, so binary string scans are invalid.
icon_data = (contents / "Resources/VectorScroll.icns").read_bytes()
assert icon_data[:4] == b"icns", "Packaged icon is not an ICNS file"
assert struct.unpack(">I", icon_data[4:8])[0] == len(icon_data), "ICNS length header is invalid"
icon_types = []
offset = 8
while offset < len(icon_data):
    icon_type = icon_data[offset:offset + 4]
    chunk_size = struct.unpack(">I", icon_data[offset + 4:offset + 8])[0]
    assert chunk_size >= 8 and offset + chunk_size <= len(icon_data), "Invalid ICNS chunk"
    icon_types.append(icon_type)
    offset += chunk_size
assert offset == len(icon_data), "ICNS chunks do not fill the container"
assert b"ic10" in icon_types, "Packaged icon has no 1024 px representation"
print("PASS: version, executable, and packaged ICNS resource")

print(f"Universal executable: {(contents / 'MacOS' / info['CFBundleExecutable']).stat().st_size:,} bytes")
