#!/bin/bash
# Live check of the Recordings feature against Polimi's real sign-on and lecture archive (see
# scripts/recman-probe/main.swift). Run it yourself, with your own Polimi account:
#
#   scripts/recman-probe.sh cold [course code] [academic year]   sign in, save the session
#   scripts/recman-probe.sh warm [course code] [academic year]   get back in from the saved session
#   scripts/recman-probe.sh play <course code> <academic year> [n]
#                                   open the n-th newest recording's Webex player (default the
#                                   newest) in a window, report the way to the stream and whether
#                                   AVPlayer plays it; run warm or cold first
#                                   (RECMAN_PROBE_WINDOW_SECONDS limits the window, default 300)
#   scripts/recman-probe.sh lab <course code> <academic year> [n]
#                                   unattended, no window, nothing typed: stream API cookie
#                                   needs and Webex re-login (RECMAN_PROBE_LAB_WAIT_MINUTES, default 10)
#   scripts/recman-probe.sh sync <course code> <academic year> [<course code> <academic year> ...] [--dry-run]
#                                   ONE background refresh as the app does at a sync (one entry from
#                                   the saved session, then each listing in turn), measured: times,
#                                   page loads, recordings counted, WebKit memory, whether the
#                                   session cookies changed. Numbers only; never shows a window.
#                                   CONTACTS POLIMI: only with the owner's go. --dry-run: no network.
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
  cold|warm|play|lab|sync) ;;
  clean) rm -rf "$state"; echo "deleted $state"; exit 0 ;;
  *) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
shift

# sync: reject bad arguments before anything is built, so a typo costs nothing and never reaches Polimi.
if [ "$mode" = sync ]; then
  sync_usage() { sed -n '/^#   scripts\/recman-probe.sh sync/,/^#   scripts\/recman-probe.sh clean/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; echo "  --help      this text"; }
  args=()
  for a in "$@"; do
    case "$a" in
      --help|-h) sync_usage; exit 0 ;;
      --dry-run) ;;
      -*) echo "unknown option: $a" >&2; sync_usage >&2; exit 2 ;;
      *) args+=("$a") ;;
    esac
  done
  if [ "${#args[@]}" -eq 0 ] || [ $(( ${#args[@]} % 2 )) -ne 0 ]; then
    echo "sync needs one or more <course code> <academic year> pairs" >&2; sync_usage >&2; exit 2
  fi
  i=0
  while [ "$i" -lt "${#args[@]}" ]; do
    if ! [[ "${args[$i]}" =~ ^[0-9]{6}$ ]]; then echo "not a 6-digit course code (value withheld)" >&2; sync_usage >&2; exit 2; fi
    if ! [[ "${args[$((i+1))]}" =~ ^[0-9]{4}$ ]]; then echo "not a 4-digit academic year (value withheld)" >&2; sync_usage >&2; exit 2; fi
    i=$((i+2))
  done
fi

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
  "$here/recman-probe/webex.swift" \
  "$here/recman-probe/lab.swift" \
  "$here/recman-probe/sync.swift" \
  "${core_files[@]}" \
  "$root/Sources/BeepbarCore/Localization/AppLanguage.swift" \
  "$root/Sources/BeepbarApp/RecmanScripts.swift" \
  "$root/Sources/BeepbarApp/RecmanWebSession.swift" \
  "$root/Sources/BeepbarApp/WebexStreamResolver.swift" \
  -framework WebKit -framework AVFoundation -o "$app/Contents/MacOS/RecmanProbe"
codesign --force --sign - "$app" >/dev/null 2>&1

mkdir -p "$state"
chmod 700 "$state"
echo "commit $(git -C "$root" rev-parse --short HEAD) · $(sw_vers -productVersion) · $(date '+%Y-%m-%d %H:%M')"
"$app/Contents/MacOS/RecmanProbe" "$mode" "$state" "$@"
