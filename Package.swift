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
// Swift Testing lives outside the default search path under CLT. scripts/test.sh
// passes the -F flags that make `swift test` find it.

import PackageDescription

let package = Package(
    name: "OpenWhisperSwift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenWhisperSwift", targets: ["OpenWhisperSwift"]),
        .library(name: "OpenWhisperCore", targets: ["OpenWhisperCore"]),
        // A product, not just a target, so the Xcode app target can depend on
        // it. project.yml consumes this package rather than re-listing its
        // sources, which is what stops the two builds disagreeing about what
        // the modules are.
        .library(name: "OpenWhisperSpeech", targets: ["OpenWhisperSpeech"]),
    ],
    dependencies: [
        // WhisperKit. `argmaxinc/argmax-oss-swift` and `argmaxinc/WhisperKit`
        // are the same repository -- identical tags and commit SHAs -- which
        // resolves the open question in plan §4. Pinned rather than ranged:
        // the model-name mapping in TranscriptionEngine is tied to what a
        // specific release publishes.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.0"),
    ],
    targets: [
        // All logic lives here so the test target can reach it. The plan's
        // dependency seams (§3) are declared in this module.
        //
        // Deliberately dependency-free: the recovery tests exercise this
        // module and must stay fast to build and run. Nothing here should
        // ever import WhisperKit.
        .target(name: "OpenWhisperCore"),

        // The WhisperKit adapter, isolated so the heavy dependency stays out
        // of the logic module and its test cycle.
        .target(
            name: "OpenWhisperSpeech",
            dependencies: [
                "OpenWhisperCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),

        // Thin shell: lifecycle, wiring, and the AppKit surface.
        .executableTarget(
            name: "OpenWhisperSwift",
            dependencies: ["OpenWhisperCore", "OpenWhisperSpeech"]
        ),

        .testTarget(
            name: "OpenWhisperCoreTests",
            dependencies: ["OpenWhisperCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
