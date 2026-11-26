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
# each log is checked too: every run that started must have printed its passing summary (#243).
# One run per test target: the folders under Tests/.
test_log=$(mktemp)
trap 'rm -f "$test_log"' EXIT
test_targets=$(find Tests -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
# The tests are run in two passes (#267). Suites that drive a real WKWebView load the main thread
# so heavily that, in one parallel queue of ~1000 tests, time-sensitive tests (theirs and other
# suites') failed now and then; `.serialized` only orders tests inside one suite, so it cannot
# isolate them. They run alone, one at a time, in the second pass; everything else stays parallel.
# ONE regex feeds both passes (`--skip` in the first, `--filter` in the second), so no test can
# fall between them. It matches the Swift Testing id, "Target.Suite/test()" followed on this
# toolchain by "/File.swift:line:column": name a suite whose tests are only web-view tests as
# "Suite/", or single tests as "Suite/(testA|testB)\(\)(/|$)" (a bare "\(\)$" never matches,
# because of the location suffix). Adding a suite or test that creates a web view (a WKWebView,
# `RecmanWebSession.open`, `LoginWindowController`...)? Add it here and raise the minimum. Only the
# targets with a matching test start a run in the second pass, hence its minimum of one run: a
# pattern that matches nothing starts none and fails there. A pattern that loses one suite (a
# typo, a rename) would still be green, with that suite back in the parallel pass unnoticed, so
# the second pass also states a minimum number of tests (the check's third argument): the exact
# number that runs today, so losing even one test fails. New tests pass it; lower it deliberately
# when a web-view test is removed.
webview_tests='^BeepbarAppTests\.(RecmanScriptsTests|RecmanWebSessionTests|RecmanWebSessionScriptTests|WebexSignInWebViewTests)/|^BeepbarAppTests\.WebexStreamResolverTests/(sessionRecoversFromThePlayerWithoutLoadingRecman|rejectedPlayerFindsAReplacementInTheArchive|rejectedPlayerRemainsAvailableWhenArchiveFails)\(\)(/|$)|^BeepbarAppTests\.WebBeepLoginSessionHandoverTests/(theLoginWindowUsesTheWebViewWithEditingShortcuts|aWindowClosedWhileTheCookiesAreReadCompletesTheLogin)\(\)(/|$)'
swift test --skip "$webview_tests" 2>&1 | tee "$test_log"
bash scripts/check-test-run-complete.sh "$test_log" "$test_targets"
swift test --no-parallel --filter "$webview_tests" 2>&1 | tee "$test_log"
bash scripts/check-test-run-complete.sh "$test_log" 1 70
python3 scripts/recordings-seen-isolated-tests.py
bash scripts/test-release-notes.sh
bash scripts/test-build-version.sh
xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release -clonedSourcePackagesDirPath build/SourcePackages build CODE_SIGNING_ALLOWED=NO
file build/Release/Beepbar.app/Contents/MacOS/Beepbar | grep -q 'arm64'
plutil -lint build/Release/Beepbar.app/Contents/Info.plist
test -f build/Release/Beepbar.app/Contents/Resources/Assets.car
test -d build/Release/Beepbar.app/Contents/Frameworks/Sparkle.framework
bash scripts/build-ffmpeg.sh --output build/FFmpeg
bash scripts/package-release-app.sh build/Release/Beepbar.app build/FFmpeg
