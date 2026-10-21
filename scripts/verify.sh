#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -version
swift --version
test "$(xcrun --sdk macosx --show-sdk-version)" = "27.0"
python3 scripts/test_benchmark_compare.py
python3 scripts/test_ui_benchmark.py
bash scripts/test-linux-core-tests.sh
swift test
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
