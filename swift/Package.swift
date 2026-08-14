// swift-tools-version: 6.0
//
// Open Whisper (Swift). See ../swift_migration_plan.md.
//
// SwiftPM rather than an .xcodeproj is deliberate: this machine has only the
// Command Line Tools, so `xcodebuild` does not exist. Everything the app needs
// -- AppKit, SwiftUI, AVFoundation, CoreGraphics, codesign, Swift Testing --
// is available under CLT, so the package builds, tests, signs, and sandboxes
// without Xcode. `project.yml` regenerates an equivalent .xcodeproj for anyone
// who does have Xcode; it is not required to build.
//
// Swift Testing lives outside the default search path under CLT. Scripts/test.sh
// passes the -F flags that make `swift test` find it.

import PackageDescription

let package = Package(
    name: "OpenWhisperSwift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenWhisperSwift", targets: ["OpenWhisperSwift"]),
        .library(name: "OpenWhisperCore", targets: ["OpenWhisperCore"]),
    ],
    targets: [
        // All logic lives here so the test target can reach it. The plan's
        // dependency seams (§3) are declared in this module.
        .target(name: "OpenWhisperCore"),

        // Thin shell: lifecycle, wiring, and the AppKit surface.
        .executableTarget(
            name: "OpenWhisperSwift",
            dependencies: ["OpenWhisperCore"]
        ),

        .testTarget(
            name: "OpenWhisperCoreTests",
            dependencies: ["OpenWhisperCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
