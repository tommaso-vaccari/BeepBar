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
parser.add_argument("--mutate-cap", action="store_true")
parser.add_argument("--probe-disk", action="store_true", help="Measure synthetic 32-character IDs, disk bytes and synchronous operation cost")
options = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="beepbar-seen-fixture-") as scratch:
    fixture = Path(scratch)
    for name in ("Sources/CSQLite", "Sources/BeepbarCore"):
        shutil.copytree(root / name, fixture / name)
    app = fixture / "Sources/BeepbarApp"
    app.mkdir(parents=True)
    for name in ("RecordingsController.swift", "RecordingsSessionStore.swift", "RecmanWebSession.swift", "RecmanScripts.swift"):
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
    if frameworks.is_dir():
        args += ["-Xswiftc", "-F", "-Xswiftc", str(frameworks), "-Xlinker", "-rpath", "-Xlinker", str(frameworks)]
    if options.probe_disk:
        args += ["--filter", "DiskCostProbe"]
    raise SystemExit(subprocess.run(args, check=False).returncode)
