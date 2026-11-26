#!/bin/bash
set -euo pipefail

app="${1:?usage: package-release-app.sh APP FFMPEG_BUILD_DIR}"
ffmpeg_build="${2:?usage: package-release-app.sh APP FFMPEG_BUILD_DIR}"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
helper="$app/Contents/Helpers/ffmpeg"

install -d "$app/Contents/Helpers" "$app/Contents/Resources/FFmpeg"
install -m 755 "$ffmpeg_build/ffmpeg" "$helper"
install -m 644 "$ffmpeg_build/COPYING.LGPLv2.1" "$app/Contents/Resources/FFmpeg/COPYING.LGPLv2.1"
cat > "$app/Contents/Resources/FFmpeg/NOTICE.txt" <<'EOF'
BeepBar uses FFmpeg (https://ffmpeg.org/), copyright the FFmpeg developers,
under the GNU Lesser General Public License version 2.1 or later.
The corresponding source and build script are in the ffmpeg-source.tar.gz
asset for this version of BeepBar at https://github.com/tommaso-vaccari/BeepBar/releases.
EOF

# Xcode strips Sparkle's headers and modules when embedding it, so reseal the framework.
codesign --force --deep --sign - "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --identifier "$identifier.ffmpeg" "$helper"
codesign --force --sign - --identifier "$identifier" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
test "$(lipo -archs "$helper")" = arm64
"$helper" -version
