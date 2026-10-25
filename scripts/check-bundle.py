"""Check the built installer payload without launching the app."""
from pathlib import Path
import plistlib
import struct
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
contents = root / "dist/VectorScroll.app/Contents"
info = plistlib.loads((contents / "Info.plist").read_bytes())
assert info["CFBundleShortVersionString"] == "1.13.3"
assert info["CFBundleVersion"] == "28"
assert info["LSMinimumSystemVersion"] == "14.0"
localizations = {folder.name for folder in (root / "Localization").glob("*.lproj") if folder.is_dir()}
packaged = {folder.name for folder in (contents / "Resources").glob("*.lproj") if folder.is_dir()}
assert packaged == localizations, f"Packaged languages differ: {packaged} != {localizations}"
assert info["CFBundleDevelopmentRegion"] == "en"
assert info["CFBundleLocalizations"] == sorted(name[:-6] for name in localizations if name != "Base.lproj")
subprocess.run([sys.executable, str(root / "scripts/check-localization.py")], check=True)
print("PASS: packaged localization folders and Info.plist language metadata")
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

# An executable that records an old SDK runs in compatibility mode without full Liquid Glass.
import subprocess
executable = contents / "MacOS" / info["CFBundleExecutable"]
for arch in ["arm64", "x86_64"]:
    commands = subprocess.run(["otool", "-l", "-arch", arch, str(executable)], capture_output=True, text=True, check=True).stdout
    block = commands.split("LC_BUILD_VERSION", 1)[1]
    sdk = next(line.split()[1] for line in block.splitlines() if line.strip().startswith("sdk "))
    assert int(sdk.split(".")[0]) >= 26, f"{arch} slice records SDK {sdk}; Liquid Glass would run in compatibility mode"
print("PASS: both slices record a macOS 26 or later SDK")

print(f"Universal executable: {(contents / 'MacOS' / info['CFBundleExecutable']).stat().st_size:,} bytes")
