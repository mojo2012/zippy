#!/bin/zsh
# Baut Zippy ohne Apple-Team und signiert ad hoc (nur für lokale Tests).
set -e
cd "${0:A:h}"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
[[ -d ArchiveCore/Vendor/CArchive.xcframework ]] || ./scripts/build-libarchive.sh
xcodegen generate --quiet
xcodebuild -project Zippy.xcodeproj -scheme Zippy -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | grep -E "error|BUILD" || true
APP=$PWD/build/Build/Products/Debug/Zippy.app
codesign -f -s - --options runtime --entitlements Zippy/Zippy.entitlements "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$APP"
echo "Fertig: $APP"

# FSKit-Variante nur auf Wunsch: ./build.sh fskit
if [[ "${1:-}" == "fskit" ]]; then
  xcodebuild -project Zippy.xcodeproj -scheme Zippy-FSKit -configuration Debug \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | grep -E "error|BUILD" || true
  FSAPP=$PWD/build/Build/Products/Debug/Zippy-FSKit.app
  codesign -f -s - --options runtime --entitlements ZippyFS/ZippyFS.entitlements "$FSAPP/Contents/Extensions/ZippyFS.appex"
  codesign -f -s - --options runtime --entitlements ZippyFSKit/ZippyFSKit.entitlements "$FSAPP"
  echo "Fertig: $FSAPP"
fi
