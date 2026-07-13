#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/caches/clang" "$ROOT/.build/caches/swiftpm"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/caches/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/caches/swiftpm}"
TOOLS_DIR="$ROOT/.build/tools"
PROBE_BINARY="$TOOLS_DIR/mavo_production_call_probe"
PROBE_APP="$TOOLS_DIR/MaVo Production Call Probe.app"

swift build --disable-sandbox --package-path "$ROOT" --target CModemBridge >/dev/null
swift build --disable-sandbox --package-path "$ROOT" --target CUACProbe >/dev/null
BIN_PATH="$(swift build --disable-sandbox --package-path "$ROOT" --show-bin-path)"
C_MODEM_BUILD="$BIN_PATH/CModemBridge.build"
C_UAC_BUILD="$BIN_PATH/CUACProbe.build"

mkdir -p "$TOOLS_DIR"
swiftc \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -I "$BIN_PATH" \
  -Xcc "-fmodule-map-file=$C_MODEM_BUILD/module.modulemap" \
  -Xcc "-fmodule-map-file=$C_UAC_BUILD/module.modulemap" \
  "$ROOT/Sources/MaVo/ADBProtocol.swift" \
  "$ROOT/Sources/MaVo/ADBModuleController.swift" \
  "$ROOT/Sources/MaVo/ATResponseParser.swift" \
  "$ROOT/Sources/MaVo/CallATParser.swift" \
  "$ROOT/Sources/MaVo/CallModels.swift" \
  "$ROOT/Sources/MaVo/Models.swift" \
  "$ROOT/Sources/MaVo/SMSPDUDecoder.swift" \
  "$ROOT/Sources/MaVo/ModuleVoiceRuntime.swift" \
  "$ROOT/Sources/MaVo/VoiceAudioService.swift" \
  "$ROOT/Sources/MaVo/ModemService.swift" \
  "$ROOT/tools/production_call_probe.swift" \
  "$C_MODEM_BUILD/ModemBridge.c.o" \
  "$C_UAC_BUILD/CUACProbe.c.o" \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework CoreFoundation \
  -framework IOKit \
  -o "$PROBE_BINARY"

rm -rf -- "$PROBE_APP"
mkdir -p "$PROBE_APP/Contents/MacOS" "$PROBE_APP/Contents/Resources"
cp "$ROOT/Resources/ProductionCallProbe-Info.plist" "$PROBE_APP/Contents/Info.plist"
cp "$PROBE_BINARY" "$PROBE_APP/Contents/MacOS/mavo_production_call_probe"
cp -R "$ROOT/Resources/ModuleVoice" "$PROBE_APP/Contents/Resources/ModuleVoice"
xattr -cr "$PROBE_APP"
codesign --force --deep --sign - "$PROBE_APP"
codesign --verify --deep --strict --verbose=2 "$PROBE_APP"
plutil -lint "$PROBE_APP/Contents/Info.plist" >/dev/null
diff -qr \
  "$ROOT/Resources/ModuleVoice" \
  "$PROBE_APP/Contents/Resources/ModuleVoice" >/dev/null

print "$PROBE_APP"
