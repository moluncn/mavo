#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/caches/clang" "$ROOT/.build/caches/swiftpm"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/caches/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/caches/swiftpm}"
swift build --disable-sandbox --package-path "$ROOT" --target CModemBridge
BIN_PATH="$(swift build --disable-sandbox --package-path "$ROOT" --show-bin-path)"
BUILD_ROOT="$BIN_PATH"
C_BUILD="$BUILD_ROOT/CModemBridge.build"

mkdir -p "$ROOT/.build/tools"
swiftc \
  -swift-version 5 \
  -I "$BUILD_ROOT" \
  -Xcc "-fmodule-map-file=$C_BUILD/module.modulemap" \
  "$ROOT/Sources/MaVo/ADBProtocol.swift" \
  "$ROOT/Sources/MaVo/ADBModuleController.swift" \
  "$ROOT/Sources/MaVo/ModuleVoiceRuntime.swift" \
  "$ROOT/tools/adb_module_probe.swift" \
  "$C_BUILD/ModemBridge.c.o" \
  -framework IOKit \
  -framework CoreFoundation \
  -o "$ROOT/.build/tools/adb_module_probe"

print "$ROOT/.build/tools/adb_module_probe"
