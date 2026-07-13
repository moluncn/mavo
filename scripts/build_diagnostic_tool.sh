#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/tools"
clang \
  -std=c11 \
  -Wall -Wextra -Werror \
  -mmacosx-version-min=14.0 \
  -I "$ROOT/Sources/CModemBridge/include" \
  "$ROOT/Sources/CModemBridge/ModemBridge.c" \
  "$ROOT/tools/qdc507_iokit_tool.c" \
  -framework IOKit \
  -framework CoreFoundation \
  -o "$ROOT/.build/tools/qdc507_iokit_tool"

print "$ROOT/.build/tools/qdc507_iokit_tool"
