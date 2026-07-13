#!/bin/zsh
set -euo pipefail

print "USB device"
system_profiler SPUSBDataType 2>/dev/null | \
  grep -i -A 12 -B 2 -E 'QDC507|Baiwang|Quectel|2c7c|0125' || true

print "\nPersisted macOS network service"
/usr/sbin/networksetup -listallhardwareports | \
  grep -i -A 3 -B 1 -E 'Baiwang|QDC507|Quectel|EC25|EG25' || true

print "\nMaVo process"
pgrep -lf 'MaVo' || true
