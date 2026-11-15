#!/bin/zsh
# Builds Zippy without an Apple team and signs it ad hoc (local testing only).
#   ./build.sh         FUSE variant
#   ./build.sh fskit   additionally the FSKit variant
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
echo "Done: $APP"

if [[ "${1:-}" == "fskit" ]]; then
  xcodebuild -project Zippy.xcodeproj -scheme Zippy-FSKit -configuration Debug \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | grep -E "error|BUILD" || true
  FSAPP=$PWD/build/Build/Products/Debug/Zippy-FSKit.app
  codesign -f -s - --options runtime --entitlements ZippyFS/ZippyFS.entitlements "$FSAPP/Contents/Extensions/ZippyFS.appex"
  codesign -f -s - --options runtime --entitlements Zippy/Zippy-FSKit.entitlements "$FSAPP"
  echo "Done: $FSAPP"
fi
