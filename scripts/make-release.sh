#!/bin/zsh
# Builds Zippy for distribution: Release, universal (Apple Silicon + Intel), signed ad hoc,
# packaged as a DMG with an Applications link and installation notes.
#
#   ./scripts/make-release.sh            → build/release/Zippy-<version>.dmg (+ .sha256)
#
# Without a paid Developer account there is no Developer ID signature or notarization:
# Gatekeeper blocks the app on first launch until it is allowed in System Settings >
# Privacy & Security (explained in "Read Me First.txt" inside the DMG).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
[[ -n "$VERSION" ]] || { echo "MARKETING_VERSION not found in project.yml"; exit 1 }
OUT="$ROOT/build/release"
DERIVED="$ROOT/build/release-derived"
STAGE="$OUT/stage"
DMG="$OUT/Zippy-$VERSION.dmg"

[[ -d ArchiveCore/Vendor/CArchive.xcframework ]] || ./scripts/build-libarchive.sh
xcodegen generate --quiet

echo "Building Zippy $VERSION (Release, arm64 + x86_64) …"
xcodebuild -project Zippy.xcodeproj -scheme Zippy -configuration Release \
  -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build -quiet
APP="$DERIVED/Build/Products/Release/Zippy.app"

# Ad hoc, with hardened runtime. Inside out: first the Quick Look extension (sandboxed,
# or Finder doesn't load it), then the app (disable-library-validation because Zippy
# loads libfuse-t).
codesign -f -s - --options runtime --entitlements ZippyThumbnails/ZippyThumbnails.entitlements \
  "$APP/Contents/PlugIns/ZippyThumbnails.appex"
codesign -f -s - --options runtime --entitlements Zippy/Zippy.entitlements "$APP"
codesign --verify --strict --deep "$APP"
lipo -info "$APP/Contents/MacOS/Zippy"

rm -rf "$OUT" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Zippy.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<EOF
Zippy $VERSION
Opens ZIP, TAR, 7z and RAR archives as drives in Finder, and SQLite
databases as folders of CSV, JSON and SQL files.
https://github.com/mojo2012/zippy

1. Install FUSE-T (free for personal use): https://www.fuse-t.org
   or with Homebrew:  brew install macos-fuse-t/cask/fuse-t
   On macOS 26 or later: afterwards turn on "fuse-t" in System Settings >
   General > Login Items & Extensions > File System Extensions.

2. Drag Zippy into the Applications folder.

3. Open Zippy once from the Applications folder. Zippy is not notarized by
   Apple, so macOS blocks it the first time. Then go to System Settings >
   Privacy & Security, scroll down and click "Open Anyway" next to Zippy.
   (Or in Terminal:  xattr -dr com.apple.quarantine /Applications/Zippy.app)

4. Right-click an archive and choose Open With > Zippy. To use Zippy for all
   archives of a type: select one, press Cmd-I, pick Zippy under "Open with"
   and click "Change All...".

Passwords: right-click a ZIP or 7z and choose Services > Password Protection
with Zippy to add or remove a password. Password-protected archives show a lock
on their icon.

Settings: open Zippy itself (without an archive) to choose how archives are
mounted and to see whether FUSE-T is set up.

On macOS 26 or later, Zippy asks once for an administrator password to set up
the folder /Volumes/Zippy, so archives appear as drives in the Finder sidebar.
EOF

# DMG with the app icon as volume icon: create read-write first, then compress
RW="$OUT/rw.dmg"
hdiutil create -quiet -volname "Zippy $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$RW"
MOUNT=$(hdiutil attach -nobrowse -noautoopen "$RW" | sed -n 's|^/dev/[^[:space:]]*[[:space:]]*Apple_HFS[[:space:]]*||p')
cp Zippy/Resources/Icons/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
# Set the "has custom icon" Finder flag on the volume root
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$MOUNT"
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"
rm -rf "$STAGE"

(cd "$OUT" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
echo "Done: $DMG"
cat "$DMG.sha256"
