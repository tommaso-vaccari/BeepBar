// swift-tools-version: 6.0
import PackageDescription

#if os(Linux)
// Linux builds exist only to run the BeepbarCore test suite where no Mac is available (see
// docs/team-workflow.md, "Linux Core checks"). The app, Sparkle and the benchmark harness need
// AppKit, WebKit and Mach APIs, so they are left out of the manifest here; macOS keeps the full
// package below, unchanged. CryptoKit is replaced by swift-crypto, which mirrors its API.
let package = Package(
    name: "Beepbar",
    products: [
        .library(name: "BeepbarCore", targets: ["BeepbarCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // `renameat2` and friends, which Glibc's Swift overlay does not expose.
        .target(name: "CLinuxCompat"),
        .target(
            name: "BeepbarCore",
            dependencies: ["CSQLite", "CLinuxCompat", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(name: "BeepbarCoreTests", dependencies: ["BeepbarCore"]),
    ]
)
#else
let package = Package(
    name: "Beepbar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BeepbarCore", targets: ["BeepbarCore"]),
        .executable(name: "Beepbar", targets: ["BeepbarApp"]),
        // On-demand benchmarks (docs/benchmarks.md); never part of the app.
        .executable(name: "beepbar-bench", targets: ["BeepbarBenchmarks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "BeepbarCore", dependencies: ["CSQLite"]),
        .executableTarget(
            name: "BeepbarApp",
            dependencies: ["BeepbarCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .target(name: "BeepbarBenchmarkKit", dependencies: ["BeepbarCore"]),
        .executableTarget(name: "BeepbarBenchmarks", dependencies: ["BeepbarBenchmarkKit"]),
        .testTarget(name: "BeepbarCoreTests", dependencies: ["BeepbarCore"]),
        .testTarget(name: "BeepbarBenchmarkKitTests", dependencies: ["BeepbarBenchmarkKit", "BeepbarCore"]),
        .testTarget(name: "BeepbarAppTests", dependencies: ["BeepbarApp"]),
    ]
)
#endif
