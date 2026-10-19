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
        .executableTarget(
            name: "EverythingShortcut",
            dependencies: ["HintCore", "Desktop", "AutomationWire"],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ApplicationServices")]
        ),
        // Developer tool for an untrusted shell: the window dump, the fixture, and the e2e driver.
        .executableTarget(name: "es-dev", dependencies: ["HintCore", "Desktop", "AutomationWire"]),
        .testTarget(name: "HintCoreTests", dependencies: ["HintCore"]),
    ]
)
