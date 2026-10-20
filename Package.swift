// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EverythingShortcut",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "EverythingShortcut", targets: ["EverythingShortcut"]),
        .executable(name: "es-dev", targets: ["es-dev"]),
    ],
    targets: [
        // Imports nothing beyond the Swift standard library, so the core cannot reach AppKit, AX or Carbon.
        .target(name: "HintCore"),
        // Live desktop reads with no AX, shared so the app and es-dev see the same window stack.
        .target(name: "Desktop", dependencies: ["HintCore"]),
        .target(name: "AutomationWire"),
        // The hint badge's look and the app icon drawn from it, shared so es-dev renders the bundle's icon.
        .target(name: "Badge"),
        .executableTarget(
            name: "EverythingShortcut",
            dependencies: ["HintCore", "Desktop", "AutomationWire", "Badge"],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ApplicationServices")]
        ),
        // Developer tool for an untrusted shell: the window dump, the fixture, the e2e driver, and the app icon.
        .executableTarget(name: "es-dev", dependencies: ["HintCore", "Desktop", "AutomationWire", "Badge"]),
        .testTarget(name: "HintCoreTests", dependencies: ["HintCore"]),
    ]
)
