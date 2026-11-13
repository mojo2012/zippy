#!/bin/zsh
# Baut libarchive als statische, universelle Bibliothek (arm64 + x86_64)
# und verpackt sie als ArchiveCore/Vendor/CArchive.xcframework für Swift Package Manager.
#
# Aus dem macOS-SDK: zlib, bzip2, iconv. Dazu liblzma aus xz-utils, ebenfalls statisch
# gebaut und mit in die Bibliothek gepackt (für 7z, .tar.xz und LZMA in ZIPs).
# Kein OpenSSL nötig: AES für ZIPs und 7z kommt auf macOS aus CommonCrypto.
set -euo pipefail

VERSION=3.8.11
SHA256=a3dc0872b1b39da34dc18ef1b944f0f11ffd37425d70ae04be679279f1cf43d2   # aus Homebrews Formel
XZ_VERSION=5.8.4
XZ_SHA256=0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9  # aus Homebrews Formel
MIN_MACOS=15.4

ROOT="${0:A:h:h}"
WORK="$ROOT/build/libarchive"
OUT="$ROOT/ArchiveCore/Vendor/CArchive.xcframework"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$WORK" && mkdir -p "$WORK"
cd "$WORK"
CFLAGS_UNIVERSAL="-arch arm64 -arch x86_64 -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O2"

# liblzma (nur die Bibliothek, keine Werkzeuge)
curl -fsSL -o xz.tar.gz "https://github.com/tukaani-project/xz/releases/download/v$XZ_VERSION/xz-$XZ_VERSION.tar.gz"
echo "$XZ_SHA256  xz.tar.gz" | shasum -a 256 -c -
tar xf xz.tar.gz
(
  cd "xz-$XZ_VERSION"
  CFLAGS="$CFLAGS_UNIVERSAL" ./configure --quiet \
    --disable-shared --enable-static --disable-xz --disable-xzdec --disable-lzmadec \
    --disable-lzmainfo --disable-scripts --disable-doc --disable-nls \
    --prefix="$WORK/xz-install"
  make -j"$(sysctl -n hw.ncpu)" >/dev/null
  make install >/dev/null
)

curl -fsSL -o libarchive.tar.xz "https://www.libarchive.org/downloads/libarchive-$VERSION.tar.xz"
echo "$SHA256  libarchive.tar.xz" | shasum -a 256 -c -
tar xf libarchive.tar.xz
cd "libarchive-$VERSION"
# 7z-Entschlüsselung (AES-256) aus libarchive-PR #3388, noch nicht offiziell übernommen
patch -p1 --quiet < "$ROOT/scripts/patches/libarchive-7zip-aes.patch"

CFLAGS="$CFLAGS_UNIVERSAL" CPPFLAGS="-I$WORK/xz-install/include" LDFLAGS="-L$WORK/xz-install/lib" \
./configure --quiet \
  --disable-shared --enable-static --disable-bsdtar --disable-bsdcpio --disable-bsdcat --disable-bsdunzip \
  --disable-acl --disable-xattr \
  --without-openssl --without-xml2 --without-expat --without-lz4 --without-zstd --without-cng --without-mbedtls --without-nettle \
  --with-zlib --with-bz2lib --with-lzma --with-iconv \
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

# libarchive und liblzma zu einer Bibliothek zusammenfassen
mkdir -p "$WORK/full" && libtool -static -o "$WORK/full/libarchive.a" "$WORK/install/lib/libarchive.a" "$WORK/xz-install/lib/liblzma.a"

rm -rf "$OUT"
xcodebuild -create-xcframework -library "$WORK/full/libarchive.a" -headers "$HDR" -output "$OUT" >/dev/null
lipo -info "$OUT"/*/libarchive.a
echo "Fertig: $OUT"
