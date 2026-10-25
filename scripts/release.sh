#!/bin/sh
# Build, sign, verify and publish the version already set in build-app.sh.
# Bump the version first in build-app.sh, check-bundle.py, README.md,
# site/download.html and Updates.swift, then commit and push.
# Needs the VectorScroll identity in ~/Library/Keychains/vectorscroll-release.keychain-db,
# whose password is in ~/.vs-kc-pass.
set -eu

cd "$(dirname "$0")/.."
VERSION=$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' scripts/build-app.sh)
NOTES=${1:?usage: scripts/release.sh <release-notes.md>}
# The official signing cert. The in-app updater only accepts builds signed by it.
IDENTITY=D2010A9E36CA13792393C15E621B0C63AAE7001B
KEYCHAIN="$HOME/Library/Keychains/vectorscroll-release.keychain-db"
GH=${GH:-$(command -v gh || echo "$HOME/CandyWrapper-research/tools/gh/gh")}

[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first." >&2; exit 1; }
git fetch -q --tags origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Push main first." >&2; exit 1; }

security unlock-keychain -p "$(cat "$HOME/.vs-kc-pass")" "$KEYCHAIN"
trap 'security lock-keychain "$KEYCHAIN"' EXIT
rm -rf dist/VectorScroll.app dist/VectorScroll-icons.* dist/installer dist/VectorScroll.dmg
CODESIGN_IDENTITY=$IDENTITY CODESIGN_KEYCHAIN=$KEYCHAIN ./scripts/build-app.sh
codesign --verify --deep --strict dist/VectorScroll.app
python3 scripts/check-bundle.py

mkdir dist/installer
cp -R dist/VectorScroll.app dist/installer/
ln -s /Applications dist/installer/Applications
hdiutil create -volname VectorScroll -srcfolder dist/installer -format UDZO dist/VectorScroll.dmg -quiet
hdiutil verify dist/VectorScroll.dmg -quiet

# Ask the current release's own installer code whether it accepts this build.
WORK=$(mktemp -d)
"$GH" release download -R Sowyu/VectorScroll -p VectorScroll.dmg -D "$WORK"
MOUNT=$(hdiutil attach -nobrowse -readonly "$WORK/VectorScroll.dmg" | tail -1 | awk -F'\t' '{print $NF}')
cp -R "$MOUNT/VectorScroll.app" "$WORK/Old.app"
hdiutil detach -quiet "$MOUNT"
PREVIOUS=$("$GH" release view -R Sowyu/VectorScroll --json tagName --jq .tagName)
git show "$PREVIOUS:Sources/VectorScroll/Updates.swift" > "$WORK/Updates.swift"
git show "$PREVIOUS:Sources/VectorScroll/UpdateInstaller.swift" > "$WORK/UpdateInstaller.swift"
cat > "$WORK/check.swift" <<SWIFT
import Foundation
@main struct Check { static func main() throws {
    try UpdateInstaller.validateCandidate(URL(fileURLWithPath: "$PWD/dist/VectorScroll.app"), version: "$VERSION",
                                          matching: URL(fileURLWithPath: "$WORK/Old.app"))
}}
SWIFT
swiftc -parse-as-library "$WORK/Updates.swift" "$WORK/UpdateInstaller.swift" "$WORK/check.swift" -o "$WORK/check" 2>/dev/null
"$WORK/check"
echo "The $PREVIOUS updater accepts $VERSION."
rm -rf "$WORK"

"$GH" release create "$VERSION" dist/VectorScroll.dmg --target "$(git rev-parse HEAD)" \
    --title "VectorScroll $VERSION" --notes-file "$NOTES" --latest
"$GH" release view "$VERSION" --json assets --jq '.assets[] | "\(.name) \(.size) \(.digest)"'
shasum -a 256 dist/VectorScroll.dmg
