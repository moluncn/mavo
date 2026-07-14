#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/caches/clang" "$ROOT/.build/caches/swiftpm"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/caches/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/caches/swiftpm}"
mkdir -p "$ROOT/.build/self-tests"

swiftc \
  -swift-version 5 \
  "$ROOT/Sources/MaVo/CallModels.swift" \
  "$ROOT/Sources/MaVo/CallATParser.swift" \
  "$ROOT/Sources/MaVo/ATConsoleModels.swift" \
  "$ROOT/Sources/MaVo/VoiceSignalProcessor.swift" \
  "$ROOT/Sources/MaVo/CarrierNameFormatter.swift" \
  "$ROOT/Sources/MaVo/NotificationRouting.swift" \
  "$ROOT/Sources/MaVo/LaunchAtLoginController.swift" \
  "$ROOT/Sources/MaVo/ADBProtocol.swift" \
  "$ROOT/Sources/MaVo/Models.swift" \
  "$ROOT/Sources/MaVo/CellularLinkRecovery.swift" \
  "$ROOT/Sources/MaVo/DeletedMessageRegistry.swift" \
  "$ROOT/Sources/MaVo/ATResponseParser.swift" \
  "$ROOT/Sources/MaVo/SMSPDUDecoder.swift" \
  "$ROOT/Sources/MaVo/SMSPDUEncoder.swift" \
  "$ROOT/Sources/MaVo/SMSVerificationCode.swift" \
  "$ROOT/Sources/MaVo/VerificationMessageAutoDelete.swift" \
  "$ROOT/Tests/SelfTests/main.swift" \
  -o "$ROOT/.build/self-tests/MaVoSelfTests"

"$ROOT/.build/self-tests/MaVoSelfTests"

xcrun clang \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -I "$ROOT/Sources/CUACProbe/include" \
  "$ROOT/Tests/CUACProbeSelfTests.c" \
  -framework CoreAudio \
  -framework CoreFoundation \
  -framework IOKit \
  -o "$ROOT/.build/self-tests/CUACProbeSelfTests"

"$ROOT/.build/self-tests/CUACProbeSelfTests"

xcrun clang \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -I "$ROOT/Sources/CModemBridge/include" \
  "$ROOT/Sources/CModemBridge/ModemBridge.c" \
  "$ROOT/Tests/CModemBridgeSelfTests.c" \
  -framework CoreFoundation \
  -framework IOKit \
  -o "$ROOT/.build/self-tests/CModemBridgeSelfTests"

"$ROOT/.build/self-tests/CModemBridgeSelfTests"
