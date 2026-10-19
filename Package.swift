// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EverythingShortcut",
    platforms: [.macOS(.v15)],
    targets: [
        // Imports nothing beyond the Swift standard library, so the core cannot reach AppKit, AX or Carbon.
        .target(name: "HintCore"),
        .testTarget(name: "HintCoreTests", dependencies: ["HintCore"]),
    ]
)
