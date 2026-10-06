#!/bin/bash
# Live check of the Recordings feature against Polimi's real sign-on and lecture archive (see
# scripts/recman-probe/main.swift). Run it yourself, with your own Polimi account:
#
#   scripts/recman-probe.sh cold [course code] [academic year]   sign in, save the session
#   scripts/recman-probe.sh warm [course code] [academic year]   get back in from the saved session
#   scripts/recman-probe.sh clean                                delete the saved session
#
# e.g. scripts/recman-probe.sh cold 058167 2026, then scripts/recman-probe.sh warm 058167 2026.
#
# It builds a throwaway probe app with its own bundle id in a temporary folder and never touches
# BeepBar, its preferences or its data. The Polimi session it saves lives in
# $TMPDIR/beepbar-recman-probe (folder 0700, file 0600) until `clean`. The output carries no
# tickets, cookie values or recording titles, so it can be pasted as is.
set -euo pipefail

mode="${1:-}"
state="${TMPDIR:-/tmp}/beepbar-recman-probe"
case "$mode" in
  cold|warm) ;;
  clean) rm -rf "$state"; echo "deleted $state"; exit 0 ;;
  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
shift

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/beepbar-recman-probe-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT
app="$work/RecmanProbe.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.beepbar.recmanprobe</string>
<key>CFBundleExecutable</key><string>RecmanProbe</string>
<key>CFBundleName</key><string>RecmanProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

# Core's Recordings folder is Foundation-only by design, so it compiles here without the rest of
# Core; the one file that maps WeBeep courses (and needs Core's course type) is left out.
core_files=()
for file in "$root"/Sources/BeepbarCore/Recordings/*.swift; do
  [ "$(basename "$file")" = "RecmanCourseKey+Course.swift" ] || core_files+=("$file")
done
echo "building the probe…"
swiftc -swift-version 6 -O \
  "$here/recman-probe/main.swift" \
  "${core_files[@]}" \
  "$root/Sources/BeepbarCore/Localization/AppLanguage.swift" \
  "$root/Sources/BeepbarApp/RecmanScripts.swift" \
  "$root/Sources/BeepbarApp/RecmanWebSession.swift" \
  -framework WebKit -o "$app/Contents/MacOS/RecmanProbe"
codesign --force --sign - "$app" >/dev/null 2>&1

mkdir -p "$state"
chmod 700 "$state"
echo "commit $(git -C "$root" rev-parse --short HEAD) · $(sw_vers -productVersion) · $(date '+%Y-%m-%d %H:%M')"
"$app/Contents/MacOS/RecmanProbe" "$mode" "$state" "$@"
