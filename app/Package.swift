// swift-tools-version:5.9
// Safe.app, see docs/safe-app/building-plan.md. Build only with a scratch path
// outside the repository, for example
//   swift build --scratch-path "$HOME/Library/Caches/SafeDocker-build/dev"
//   swift run --scratch-path "$HOME/Library/Caches/SafeDocker-build/dev" SafeTests
// and the app bundle with scripts/build-app.sh.

import PackageDescription

let package = Package(
    name: "Safe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Safe", targets: ["SafeApp"]),
        .executable(name: "SafeTests", targets: ["SafeTests"]),
    ],
    targets: [
        // C shim around sandbox_init, which Swift cannot call directly
        .target(name: "CSandbox"),
        // everything that can be tested without a window; no AppKit here
        .target(
            name: "SafeCore",
            dependencies: ["CSandbox"]
        ),
        // the app itself
        .executableTarget(
            name: "SafeApp",
            dependencies: ["SafeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
            ]
        ),
        // the test runner: XCTest does not run without Xcode; AppKit and PDFKit
        // for the leak test, which draws PDFs and pictures as the viewer does
        .executableTarget(
            name: "SafeTests",
            dependencies: ["SafeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
            ]
        ),
    ]
)
