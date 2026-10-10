#!/usr/bin/env bash
# Runs the BeepbarCore test suite on Linux, where no Mac is available (docs/team-workflow.md,
# "Linux Core checks"). This is fast feedback for Core logic, never the gate: green means what CI
# runs on macOS (`swift test` and the Release build), which this script cannot replace.
#
# Skipped here, and only here:
# - Suites that mock the network with URLProtocol subclasses: swift-corelibs-foundation's
#   URLSession never calls startLoading on them, so every such test hangs.
# - Tests that rely on a permission denial, which cannot happen when the container runs as root.
set -euo pipefail
cd "$(dirname "$0")/.."
# The Linux manifest resolves swift-crypto instead of Sparkle, which rewrites Package.resolved;
# the committed file belongs to the macOS build, so it is put back afterwards.
trap 'git checkout -q -- Package.resolved' EXIT
skip='RemoteDownloaderTests|WeBeepAPIClientTests|ManualSyncEngineIntegrationTests|SyncCoordinatorEndToEndTests|FileHashCancellationTests/cancelledRecoveryStillPreservesEditedLocalCopy'
if [ "$(id -u)" = 0 ]; then
    skip="$skip|rollsBackThePendingMoveWhenTheDirectoryRenameFails|recoveryLeavesReplacementAtOldPathUnresolved|recoveryDoesNotCommitReplacementAtNewPath"
fi
swift test --skip "$skip" "$@"
