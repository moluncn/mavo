#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/caches/clang" "$ROOT/.build/caches/swiftpm"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/caches/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/caches/swiftpm}"
VERSION="${MAVO_VERSION:-$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")}"
[[ -n "$VERSION" && "$VERSION" != */* ]] || {
  print -u2 "Invalid MaVo version: $VERSION"
  exit 1
}
OUTPUT_DIR="$ROOT/outputs"
APP="$OUTPUT_DIR/MaVo.app"
ZIP="$OUTPUT_DIR/MaVo-$VERSION-arm64.zip"
PUBLISH_ZIP="$OUTPUT_DIR/.MaVo-$VERSION-arm64.$$.zip"
STAGE_DIR="$(mktemp -d /tmp/MaVo-build.XXXXXX)"
STAGE_APP="$STAGE_DIR/MaVo.app"
STAGE_ZIP="$STAGE_DIR/MaVo-$VERSION-arm64.zip"
VERIFY_DIR="$STAGE_DIR/verify"
VERIFY_APP="$VERIFY_DIR/MaVo.app"
HELPER_RELATIVE="Contents/Library/PrivilegedHelperTools/MaVoNetworkHelper"
PLIST_RELATIVE="Contents/Library/LaunchDaemons/app.mavo.mac.network-helper.plist"
cleanup() {
  /bin/rm -rf -- "$STAGE_DIR"
  /bin/rm -f -- "$PUBLISH_ZIP"
}
trap cleanup EXIT

cd "$ROOT"
swift build --disable-sandbox -c release --arch arm64
BIN_DIR="$(swift build --disable-sandbox -c release --arch arm64 --show-bin-path)"

mkdir -p "$OUTPUT_DIR"
mkdir -p \
  "$STAGE_APP/Contents/MacOS" \
  "$STAGE_APP/Contents/Resources" \
  "$STAGE_APP/Contents/Library/PrivilegedHelperTools" \
  "$STAGE_APP/Contents/Library/LaunchDaemons"
cp "$ROOT/Resources/Info.plist" "$STAGE_APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$STAGE_APP/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$STAGE_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$ROOT/Resources/MaVo.icns" "$STAGE_APP/Contents/Resources/MaVo.icns"
if [[ -d "$ROOT/Resources/ModuleVoice" ]]; then
  cp -R "$ROOT/Resources/ModuleVoice" "$STAGE_APP/Contents/Resources/ModuleVoice"
fi
cp "$BIN_DIR/MaVo" "$STAGE_APP/Contents/MacOS/MaVo"
cp "$BIN_DIR/MaVoNetworkHelper" "$STAGE_APP/$HELPER_RELATIVE"
cp "$ROOT/Resources/app.mavo.mac.network-helper.plist" "$STAGE_APP/$PLIST_RELATIVE"

xattr -cr "$STAGE_APP"
codesign \
  --force \
  --sign - \
  --identifier app.mavo.mac.network-helper \
  "$STAGE_APP/$HELPER_RELATIVE"
codesign --force --sign - --identifier app.mavo.mac "$STAGE_APP"
codesign --verify --deep --strict --verbose=2 "$STAGE_APP"

ditto -c -k --sequesterRsrc --keepParent "$STAGE_APP" "$STAGE_ZIP"
mkdir -p "$VERIFY_DIR"
ditto -x -k "$STAGE_ZIP" "$VERIFY_DIR"

VERIFY_BINARY="$VERIFY_APP/Contents/MacOS/MaVo"
VERIFY_HELPER="$VERIFY_APP/$HELPER_RELATIVE"
VERIFY_PLIST="$VERIFY_APP/$PLIST_RELATIVE"
codesign --verify --deep --strict --verbose=2 "$VERIFY_APP"
codesign --verify --strict --verbose=2 "$VERIFY_HELPER"
plutil -lint "$VERIFY_APP/Contents/Info.plist"
plutil -lint "$VERIFY_PLIST"
[[ "$(plutil -extract CFBundleShortVersionString raw "$VERIFY_APP/Contents/Info.plist")" == "$VERSION" ]] || {
  print -u2 "Archive Info.plist version does not match $VERSION."
  exit 1
}
cmp "$ROOT/THIRD_PARTY_NOTICES.md" "$VERIFY_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -d "$ROOT/Resources/ModuleVoice" ]]; then
  [[ -d "$VERIFY_APP/Contents/Resources/ModuleVoice" ]] || {
    print -u2 "Archive is missing the QDC507 voice runtime."
    exit 1
  }
  diff -qr \
    "$ROOT/Resources/ModuleVoice" \
    "$VERIFY_APP/Contents/Resources/ModuleVoice"
fi

[[ "$(lipo -archs "$VERIFY_BINARY")" == "arm64" ]] || {
  print -u2 "Archive executable is not thin arm64."
  exit 1
}
[[ "$(lipo -archs "$VERIFY_HELPER")" == "arm64" ]] || {
  print -u2 "Archive helper is not thin arm64."
  exit 1
}
[[ "$(plutil -extract LSMinimumSystemVersion raw "$VERIFY_APP/Contents/Info.plist")" == "14.0" ]] || {
  print -u2 "Archive Info.plist does not require macOS 14.0."
  exit 1
}
[[ "$(vtool -show-build "$VERIFY_BINARY" | awk '$1 == "minos" { print $2; exit }')" == "14.0" ]] || {
  print -u2 "Archive executable minOS is not 14.0."
  exit 1
}
[[ "$(vtool -show-build "$VERIFY_HELPER" | awk '$1 == "minos" { print $2; exit }')" == "14.0" ]] || {
  print -u2 "Archive helper minOS is not 14.0."
  exit 1
}
[[ "$(codesign -dvv "$VERIFY_BINARY" 2>&1 | awk -F= '$1 == "Identifier" { print $2; exit }')" == "app.mavo.mac" ]] || {
  print -u2 "Archive executable signing identifier is incorrect."
  exit 1
}
[[ "$(codesign -dvv "$VERIFY_HELPER" 2>&1 | awk -F= '$1 == "Identifier" { print $2; exit }')" == "app.mavo.mac.network-helper" ]] || {
  print -u2 "Archive helper signing identifier is incorrect."
  exit 1
}
[[ "$(plutil -extract Label raw "$VERIFY_PLIST")" == "app.mavo.mac.network-helper" ]] || {
  print -u2 "LaunchDaemon label is incorrect."
  exit 1
}
[[ "$(plutil -extract ProgramArguments.0 raw "$VERIFY_PLIST")" == "/Library/PrivilegedHelperTools/MaVoNetworkHelper" ]] || {
  print -u2 "LaunchDaemon helper path is incorrect."
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:app.mavo.mac.network-helper' "$VERIFY_PLIST")" == "true" ]] || {
  print -u2 "LaunchDaemon Mach service is missing."
  exit 1
}

while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*) ;;
    *)
      print -u2 "Archive contains a non-system dynamic dependency: $dependency"
      exit 1
      ;;
  esac
done < <(otool -L "$VERIFY_BINARY" | tail -n +2 | awk '{ print $1 }')

while IFS= read -r dependency; do
  case "$dependency" in
    /System/Library/*|/usr/lib/*) ;;
    *)
      print -u2 "Archive helper contains a non-system dynamic dependency: $dependency"
      exit 1
      ;;
  esac
done < <(otool -L "$VERIFY_HELPER" | tail -n +2 | awk '{ print $1 }')

cp "$STAGE_ZIP" "$PUBLISH_ZIP"
cmp "$STAGE_ZIP" "$PUBLISH_ZIP"
mv -f "$PUBLISH_ZIP" "$ZIP"

# A loose app inside this FileProvider workspace receives FinderInfo after
# signing, invalidating strict verification. Keep the verified ZIP canonical.
rm -rf -- "$APP"
find "$OUTPUT_DIR" -maxdepth 1 -type d -name 'MaVo.previous.*.app' \
  -exec rm -rf -- {} +
find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'MaVo-*-arm64.zip.previous.*' \
  -exec rm -f -- {} +
print "Verified archive: $ZIP"
