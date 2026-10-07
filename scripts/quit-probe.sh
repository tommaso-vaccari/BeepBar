#!/bin/bash
# Checks BeepBar's quit paths against real AppKit (see scripts/quit-probe/main.swift).
# Builds a throwaway probe app with its own bundle id in a temporary folder: it never touches
# BeepBar, its preferences or its data. Exits non-zero if any mode doesn't behave as expected.
#
# Rerun it after changing StatusItemController.quit(), applicationShouldTerminate or
# prepareForMenuQuit(). The two "HUNG" modes document the bug "Esci" used to have; if one of them
# starts quitting, AppKit changed and the comments on prepareForMenuQuit() need another look.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/beepbar-quit-probe.XXXXXX")"
trap 'rm -rf "$work"' EXIT
bundle_id="local.beepbar.quitprobe"
app="$work/QuitProbe.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>QuitProbe</string>
<key>CFBundleName</key><string>QuitProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
swiftc -swift-version 6 -O "$here/quit-probe/main.swift" -o "$app/Contents/MacOS/QuitProbe"
codesign --force --sign - "$app" >/dev/null 2>&1

failures=0
check() {
  local mode="$1" expected="$2" output
  if [ "$mode" = external ]; then
    "$app/Contents/MacOS/QuitProbe" external > "$work/external.log" 2>&1 &
    local pid=$!
    for _ in $(seq 1 50); do grep -q READY "$work/external.log" 2>/dev/null && break; sleep 0.1; done
    osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
    wait "$pid" || true
    output="$(cat "$work/external.log")"
  else
    output="$("$app/Contents/MacOS/QuitProbe" "$mode" 2>&1 || true)"
  fi
  if grep -q "RESULT $mode $expected" <<<"$output"; then
    echo "ok   $mode: $expected"
  else
    echo "FAIL $mode: expected $expected, got: $(grep RESULT <<<"$output" || echo 'no result')"
    failures=$((failures + 1))
  fi
}

check menu-legacy HUNG
check menu-dispatch HUNG
check menu QUIT
check external QUIT
exit "$failures"
