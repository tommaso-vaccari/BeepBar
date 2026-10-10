#!/usr/bin/env python3
"""Run the recordings history fixtures when the local CLT lacks SwiftUI macros.

The copied recordings implementation and tests are unchanged. Only app-global settings
providers are substitutes. This is a targeted runtime check, not the full app/CI gate.
--mutate-cap reintroduces global eviction only in a disposable source copy (expected red).
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
mutations = parser.add_mutually_exclusive_group()
mutations.add_argument("--mutate-cap", action="store_true")
mutations.add_argument("--mutate-main-actor", action="store_true", help="Run the history worker on main; expected off-main regression failure")
mutations.add_argument("--mutate-reset", action="store_true", help="Remove the persisted reset namespace; expected same-account reset regression failure")
mutations.add_argument("--mutate-snapshot", action="store_true", help="Publish the fresh list when history fails; expected previous-snapshot regression failure")
mutations.add_argument("--mutate-revision", action="store_true", help="Skip acknowledgement revision validation; expected stale-read regression failure")
mutations.add_argument("--mutate-coalescing", action="store_true", help="Queue duplicate acknowledgements; expected slow-disk repetition failure")
mutations.add_argument("--mutate-cleanup-kind", action="store_true", help="Restore recursive file removal; expected unexpected-directory preservation failure")
parser.add_argument("--probe-disk", action="store_true", help="Measure synthetic 32-character IDs, disk bytes and synchronous operation cost")
options = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="beepbar-seen-fixture-") as scratch:
    fixture = Path(scratch)
    for name in ("Sources/CSQLite", "Sources/BeepbarCore"):
        shutil.copytree(root / name, fixture / name)
    app = fixture / "Sources/BeepbarApp"
    app.mkdir(parents=True)
    for name in ("RecordingsController.swift", "RecordingsSessionStore.swift", "RecordingsStudyState.swift", "RecmanWebSession.swift", "RecmanScripts.swift"):
        shutil.copy(root / "Sources/BeepbarApp" / name, app / name)
    (app / "FixtureSupport.swift").write_text('''import Foundation
// App settings providers only: fixtures never use installed data or UI.
enum PreviewMode { static let isActive = true }
enum FileTokenStore { static let directoryName = "isolated-never-production" }
enum WeBeepAuthenticationController {
    static func throwawayDefaultsSuite() -> String { "seen-fixture-\\(UUID().uuidString)" }
}
''')
    tests = fixture / "Tests/BeepbarAppTests"
    tests.mkdir(parents=True)
    text = (root / "Tests/BeepbarAppTests/RecordingsControllerTests.swift").read_text()
    text = text.split("/// Recordings through the real account controller:", 1)[0]
    (tests / "RecordingsControllerTests.swift").write_text(text)
    core = fixture / "Tests/BeepbarCoreTests"
    core.mkdir(parents=True)
    shutil.copy(root / "Tests/BeepbarCoreTests/RecordingsSeenStoreTests.swift", core)
    (fixture / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SeenValidation", platforms: [.macOS(.v14)], targets: [
.target(name: "CSQLite", linkerSettings: [.linkedLibrary("sqlite3")]),
.target(name: "BeepbarCore", dependencies: ["CSQLite"]),
.target(name: "BeepbarApp", dependencies: ["BeepbarCore"], linkerSettings: [.linkedFramework("WebKit")]),
.testTarget(name: "BeepbarAppTests", dependencies: ["BeepbarApp"]),
.testTarget(name: "BeepbarCoreTests", dependencies: ["BeepbarCore"])
])
''')
    if options.mutate_cap:
        source = fixture / "Sources/BeepbarCore/Persistence/RecordingsSeenStore.swift"
        text = source.read_text()
        anchor = "for id in ids { try bind(scope + [id], to: statement); _ = try hasRow(statement) }"
        if text.count(anchor) != 1:
            raise SystemExit("Mutation anchor changed; update the controlled fixture mutation")
        text = text.replace(anchor, anchor + '''
        try run("DELETE FROM seen WHERE (owner,course,year,id) IN (SELECT owner,course,year,id FROM seen ORDER BY owner,course,year,id LIMIT max(0,(SELECT count(*) FROM seen)-5000))", [], db: db)''')
        source.write_text(text)
    filters = []
    if options.mutate_main_actor:
        source = fixture / "Sources/BeepbarCore/Persistence/RecordingsSeenStore.swift"
        text = source.read_text()
        assert text.count("public actor RecordingsSeenHistory {") == 1
        source.write_text(text.replace("public actor RecordingsSeenHistory {", "@MainActor public final class RecordingsSeenHistory {"))
        filters = ["--filter", "historyRunsOffMainAndLateResultCannotReviveClosedPage"]
    if options.mutate_reset:
        source = fixture / "Sources/BeepbarApp/RecordingsController.swift"
        text = source.read_text()
        anchor = "defaults.set(namespace.uuidString, forKey: Self.historyNamespaceKey)"
        assert text.count(anchor) == 1
        text = text.replace(anchor, "defaults.removeObject(forKey: Self.historyNamespaceKey)")
        text = text.replace("seenHistory = makeSeenHistory(namespace)", "seenHistory = makeSeenHistory(nil)")
        source.write_text(text)
        filters = ["--filter", "failedCleanupNeverReusesOldBaselineAfterReenableAndRelaunch"]
    if options.mutate_snapshot:
        source = fixture / "Sources/BeepbarApp/RecordingsController.swift"
        text = source.read_text()
        anchor = "listings[key, default: RecordingsListing()].isLoading = queue.contains(.list(key))"
        assert text.count(anchor) == 1
        source.write_text(text.replace(anchor, "listings[key, default: RecordingsListing()].recordings = recordings\n            " + anchor))
        filters = ["--filter", "transientHistoryFailureRetainsPreviousListAndRetries"]
    if options.mutate_revision:
        source = fixture / "Sources/BeepbarApp/RecordingsController.swift"
        text = source.read_text()
        anchor = "if historyRevision[key, default: 0] == revision { break }"
        assert text.count(anchor) == 1
        source.write_text(text.replace(anchor, "break"))
        filters = ["--filter", "delayedReadCannotOverwriteNewerAcknowledgement"]
    if options.mutate_coalescing:
        source = fixture / "Sources/BeepbarApp/RecordingsController.swift"
        text = source.read_text()
        anchor = " && !pending.contains($0)"
        assert text.count(anchor) == 1
        source.write_text(text.replace(anchor, ""))
        filters = ["--filter", "repeatedAcknowledgementsAreCoalescedWhileDiskIsSlow"]
    if options.mutate_cleanup_kind:
        source = fixture / "Sources/BeepbarCore/Persistence/RecordingsSeenStore.swift"
        text = source.read_text()
        anchor = "removeFile: Self.unlinkFile"
        assert text.count(anchor) == 1
        source.write_text(text.replace(anchor, "removeFile: { try FileManager.default.removeItem(at: $0) }"))
        filters = ["--filter", "cleanupDoesNotRecursivelyDeleteUnexpectedDatabaseDirectory"]
    if options.probe_disk:
        (core / "DiskCostProbe.swift").write_text('''import Foundation
import Testing
@testable import BeepbarCore
struct DiskCostProbe {
    @Test func syntheticDiskCost() throws {
        let key = RecmanCourseKey(courseCode: "058167", academicYear: 2026)!
        for count in [1, 5_001, 10_000] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("seen-cost-\\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = RecordingsSeenStore { folder }
            let ids = (0..<count).map { String(repeating: "0", count: 26) + String(format: "%06d", $0) }
            let start = ContinuousClock.now
            _ = try store.seen(owner: 42, key: key, ids: ids, establishBaseline: true, legacy: .init(ids: [], baselines: []))
            let write = start.duration(to: .now)
            let readStart = ContinuousClock.now
            _ = try store.seen(owner: 42, key: key, ids: ids, establishBaseline: false, legacy: .init(ids: [], baselines: []))
            let read = readStart.duration(to: .now)
            let bytes = (try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(RecordingsSeenStore.fileName).path))[.size] as! Int
            print("SEEN_COST ids=\\(count) bytes=\\(bytes) baseline=\\(write) lookup=\\(read)")
        }
    }
}
''')
    args = ["swift", "test", "--package-path", str(fixture), "--build-system", "native"]
    frameworks = Path("/Library/Developer/CommandLineTools/Library/Developer/Frameworks")
    developer = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True, check=False).stdout.strip()
    if developer.endswith("/CommandLineTools") and frameworks.is_dir():
        args += ["-Xswiftc", "-F", "-Xswiftc", str(frameworks), "-Xlinker", "-rpath", "-Xlinker", str(frameworks)]
    args += filters
    if options.probe_disk:
        args += ["--filter", "DiskCostProbe"]
    raise SystemExit(subprocess.run(args, check=False).returncode)
