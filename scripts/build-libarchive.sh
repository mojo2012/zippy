#!/bin/zsh
# Baut libarchive als statische, universelle Bibliothek (arm64 + x86_64)
# und verpackt sie als ArchiveCore/Vendor/CArchive.xcframework für Swift Package Manager.
#
# Nur Bibliotheken aus dem macOS-SDK: zlib, bzip2, iconv.
# (Das SDK hat keinen lzma.h-Header → LZMA/XZ-komprimierte ZIPs gehen vorerst nicht.)
# Kein OpenSSL → verschlüsselte ZIPs (AES) gehen damit vorerst nicht.
set -euo pipefail

VERSION=3.8.11
SHA256=a3dc0872b1b39da34dc18ef1b944f0f11ffd37425d70ae04be679279f1cf43d2   # aus Homebrews Formel
MIN_MACOS=15.4

ROOT="${0:A:h:h}"
WORK="$ROOT/build/libarchive"
OUT="$ROOT/ArchiveCore/Vendor/CArchive.xcframework"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$WORK" && mkdir -p "$WORK"
cd "$WORK"
curl -fsSL -o libarchive.tar.xz "https://www.libarchive.org/downloads/libarchive-$VERSION.tar.xz"
echo "$SHA256  libarchive.tar.xz" | shasum -a 256 -c -
tar xf libarchive.tar.xz
cd "libarchive-$VERSION"

CFLAGS="-arch arm64 -arch x86_64 -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O2" \
./configure --quiet \
  --disable-shared --enable-static --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
  --disable-acl --disable-xattr \
  --without-openssl --without-xml2 --without-expat --without-lz4 --without-zstd --without-cng --without-mbedtls --without-nettle \
  --with-zlib --with-bz2lib --without-lzma --with-iconv \
  --prefix="$WORK/install"
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null

HDR="$WORK/headers"
mkdir -p "$HDR"
cp "$WORK/install/include/archive.h" "$WORK/install/include/archive_entry.h" "$HDR/"
cat > "$HDR/module.modulemap" <<'MAP'
module CArchive {
    header "archive.h"
    header "archive_entry.h"
    link "z"
    link "bz2"
    link "iconv"
    export *
}
MAP

rm -rf "$OUT"
xcodebuild -create-xcframework -library "$WORK/install/lib/libarchive.a" -headers "$HDR" -output "$OUT" >/dev/null
lipo -info "$OUT"/*/libarchive.a
echo "Fertig: $OUT"
