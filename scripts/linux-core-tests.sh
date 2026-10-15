#!/usr/bin/env bash
# Runs the BeepbarCore test suite on Linux, where no Mac is available (docs/team-workflow.md,
# "Linux Core checks"). This is fast feedback for Core logic, never the gate: green means what CI
# runs on macOS (`swift test` and the Release build), which this script cannot replace.
#
# Skipped here, and only here:
# - Suites that mock the network with URLProtocol subclasses: swift-corelibs-foundation's
#   URLSession never calls startLoading on them, so every such test hangs.
# - Tests that rely on a permission denial, which cannot happen when the container runs as root.
# - `RecmanSessionVaultTests/anUnchangedSessionIsNotRewritten`: swift-corelibs-foundation's
#   `HTTPCookie.properties` reports `Secure` as a Bool, while `HTTPCookie(properties:)` only reads
#   it as a String, so a cookie reloaded from the saved session loses `Secure` there and its
#   fingerprint changes. Apple's Foundation keeps the string, which is what the product runs on.
set -euo pipefail
cd "$(dirname "$0")/.."
# The Linux manifest resolves swift-crypto instead of Sparkle, which rewrites Package.resolved;
# preserve the original working-tree bytes and absence without touching the Git index.
if [ -L Package.resolved ] || { [ -e Package.resolved ] && [ ! -f Package.resolved ]; }; then
    printf 'Package.resolved must be a regular file or absent.\n' >&2
    exit 1
fi
lockfile_backup=$(mktemp -d "${TMPDIR:-/tmp}/beepbar-linux-lockfile.XXXXXX")
lockfile_present=false
if [ -f Package.resolved ]; then
    lockfile_present=true
    cp -p Package.resolved "$lockfile_backup/Package.resolved" || { rmdir "$lockfile_backup"; exit 1; }
fi
restore_lockfile() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$lockfile_present" = true ]; then
        cp -p "$lockfile_backup/Package.resolved" Package.resolved || {
            printf 'Cannot restore Package.resolved; backup retained at %s\n' "$lockfile_backup" >&2
            exit 1
        }
    else
        rm -f Package.resolved || { rmdir "$lockfile_backup"; exit 1; }
    fi
    rm -rf "$lockfile_backup"
    exit "$status"
}
trap restore_lockfile EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
skip='MetadataResponseTests|RemoteDownloaderTests|WeBeepAPIClientTests|ManualSyncEngineIntegrationTests|SyncCoordinatorEndToEndTests|FileHashCancellationTests/cancelledRecoveryStillPreservesEditedLocalCopy|RecmanSessionVaultTests/anUnchangedSessionIsNotRewritten'
skip="$skip|CourseImageTests/(theCourseListCarriesThePicture|anOddPictureFieldNeverBreaksTheList|thePictureIsFetchedWithTheToken|badAnswersAreErrors)"
if [ "$(id -u)" = 0 ]; then
    skip="$skip|rollsBackThePendingMoveWhenTheDirectoryRenameFails|recoveryLeavesReplacementAtOldPathUnresolved|recoveryDoesNotCommitReplacementAtNewPath"
fi
swift test --skip "$skip" "$@"
