#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
mkdir -p "$ROOT/.build/caches/clang" "$ROOT/.build/caches/swiftpm"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/caches/clang}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT/.build/caches/swiftpm}"

if (( $# == 0 )) || [[ " $* " != *" --number "* ]] || \
   [[ " $* " != *" --confirm-live-call "* ]]; then
  print -u2 "Usage: ${0:t} --number NUMBER --confirm-live-call [MaVoDialProbe options]"
  exit 64
fi

for mode in --probe-voice-interface --full-flow --full-flow-after-connect \
            --qdc-external-pcm-flow --uac-flow --uac-flow-no-qpcmv; do
  if [[ " $* " == *" $mode "* ]]; then
    print -u2 "Do not pass $mode; this wrapper selects --uac-flow-no-qpcmv itself."
    exit 64
  fi
done

if pgrep -x MaVo >/dev/null 2>&1; then
  print -u2 "MaVo is running and may own the AT/UAC interfaces. Quit it before this code-level probe."
  exit 20
fi

zsh "$ROOT/scripts/build_adb_module_probe.sh" >/dev/null
swift build --disable-sandbox --package-path "$ROOT" --product MaVoDialProbe >/dev/null

ADB_PROBE="$ROOT/.build/tools/adb_module_probe"
BIN_PATH="$(swift build --disable-sandbox --package-path "$ROOT" --show-bin-path)"
DIAL_PROBE="$BIN_PATH/MaVoDialProbe"

# Clear a helper/route left by a previous interrupted probe before selecting
# route-only UAC. This remains reversible and does not unload or flash anything.
exec "$ADB_PROBE" run-with-route -- \
  "$DIAL_PROBE" "$@" --uac-flow-no-qpcmv
