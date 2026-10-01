#!/bin/zsh
set -euo pipefail

app_path="${1:-build/Release/Beepbar.app}"
output_path="${2:-build/Beepbar.dmg}"
staging_path="$(mktemp -d /tmp/beepbar-dmg.XXXXXX)"
volume_name="BeepBar"

cleanup() {
    rm -rf "$staging_path"
}
trap cleanup EXIT

[[ -d "$app_path" ]] || { print -u2 "App non trovata: $app_path"; exit 1; }

mkdir -p "$(dirname "$output_path")"
rm -f "$output_path"
ditto "$app_path" "$staging_path/Beepbar.app"
ln -s /Applications "$staging_path/Applications"

hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$staging_path" \
    -ov \
    -format UDZO \
    "$output_path"
