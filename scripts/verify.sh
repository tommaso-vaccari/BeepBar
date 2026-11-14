#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -version
swift --version
# The GitHub runner (`xcode-27`) has the 27.0 SDK; local machines updated to Xcode 27.2 must still
# pass the same gate. Any other SDK fails, so a toolchain change is a deliberate edit here.
case "$(xcrun --sdk macosx --show-sdk-version)" in
    27.0|27.2) ;;
    *) echo "Unsupported macOS SDK $(xcrun --sdk macosx --show-sdk-version)" >&2; exit 1 ;;
esac
python3 scripts/test_benchmark_compare.py
python3 scripts/test_ui_benchmark.py
bash scripts/test-linux-core-tests.sh
bash scripts/test-check-test-run-complete.sh
# The exit status of `swift test` does not show a test process that ended early (it exits 0), so
# the log is checked too: every run that started must have printed its passing summary (#243).
test_log=$(mktemp)
swift test 2>&1 | tee "$test_log"
bash scripts/check-test-run-complete.sh "$test_log"
rm -f "$test_log"
python3 scripts/recordings-seen-isolated-tests.py
bash scripts/test-release-notes.sh
bash scripts/test-build-version.sh
xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release -clonedSourcePackagesDirPath build/SourcePackages build CODE_SIGNING_ALLOWED=NO
file build/Release/Beepbar.app/Contents/MacOS/Beepbar | grep -q 'arm64'
plutil -lint build/Release/Beepbar.app/Contents/Info.plist
test -f build/Release/Beepbar.app/Contents/Resources/Assets.car
test -d build/Release/Beepbar.app/Contents/Frameworks/Sparkle.framework
codesign --force --deep --sign - --identifier io.github.tvaccari.beepbar build/Release/Beepbar.app
codesign --verify --deep --strict --verbose=2 build/Release/Beepbar.app
