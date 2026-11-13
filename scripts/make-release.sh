#!/bin/zsh
# Baut Zippy für die Weitergabe: Release, universal (Apple Silicon + Intel), ad hoc signiert,
# verpackt als DMG mit Programme-Verknüpfung und Installationshinweisen.
#
#   ./scripts/make-release.sh            → build/release/Zippy-<version>.dmg (+ .sha256)
#
# Ohne bezahlten Developer-Account gibt es weder Developer-ID-Signatur noch Notarisierung:
# Gatekeeper blockiert die App beim ersten Start, bis man sie in den Systemeinstellungen
# unter „Datenschutz & Sicherheit“ freigibt (steht in „Read Me First.txt“ im DMG).
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
[[ -n "$VERSION" ]] || { echo "MARKETING_VERSION nicht gefunden"; exit 1 }
OUT="$ROOT/build/release"
DERIVED="$ROOT/build/release-derived"
STAGE="$OUT/stage"
DMG="$OUT/Zippy-$VERSION.dmg"

[[ -d ArchiveCore/Vendor/CArchive.xcframework ]] || ./scripts/build-libarchive.sh
xcodegen generate --quiet

echo "Baue Zippy $VERSION (Release, arm64 + x86_64) …"
xcodebuild -project Zippy.xcodeproj -scheme Zippy -configuration Release \
  -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build -quiet
APP="$DERIVED/Build/Products/Release/Zippy.app"

# Ad hoc, mit Hardened Runtime; disable-library-validation, weil Zippy libfuse-t lädt
codesign -f -s - --options runtime --entitlements Zippy/Zippy.entitlements "$APP"
codesign --verify --strict "$APP"
lipo -info "$APP/Contents/MacOS/Zippy"

rm -rf "$OUT" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Zippy.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<EOF
Zippy $VERSION
Opens ZIP, TAR, 7z and RAR archives as drives in Finder.
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

On macOS 26 or later, Zippy asks once for an administrator password to set up
the folder /Volumes/Zippy, so archives appear as drives in the Finder sidebar.
EOF

# DMG mit dem App-Symbol als Volume-Symbol: erst beschreibbar, dann komprimiert
RW="$OUT/rw.dmg"
hdiutil create -quiet -volname "Zippy $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$RW"
MOUNT=$(hdiutil attach -nobrowse -noautoopen "$RW" | sed -n 's|^/dev/[^[:space:]]*[[:space:]]*Apple_HFS[[:space:]]*||p')
cp Zippy/Resources/Icons/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$MOUNT"
hdiutil detach -quiet "$MOUNT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"
rm -rf "$STAGE"

(cd "$OUT" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
echo "Fertig: $DMG"
cat "$DMG.sha256"
