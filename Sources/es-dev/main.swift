import AppKit
import Desktop
import HintCore

/// es-dev runs from an untrusted shell. Nothing here calls AX or posts events.
///
///     es-dev windows              window stack, exposure and scan plan as the app would compute them
///     es-dev fixture              show the fixture windows until killed, printing every press
///     es-dev e2e [--out <dir>]    host the fixture and drive the running DEBUG app through AutomationWire
setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "windows":
    print(WindowsDump.render(snapshot: Desktop.windowSnapshot(), displays: Desktop.displays(), running: Desktop.runningApps()))
    exit(0)
case "fixture":
    NSApplication.shared.setActivationPolicy(.regular)
    let fixture = Fixture()
    fixture.onPress = { print("press \($0.name) active=\($0.appWasActive)") }
    Task { @MainActor in
        fixture.show()
        print(fixture.describe())
    }
    NSApplication.shared.run()
case "e2e":
    let out = arguments.firstIndex(of: "--out").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "build/e2e"
    NSApplication.shared.setActivationPolicy(.regular)
    let fixture = Fixture()
    Task { @MainActor in
        fixture.show()
        exit(await EndToEnd(fixture: fixture, outDirectory: URL(fileURLWithPath: out)).run())
    }
    NSApplication.shared.run()
default:
    FileHandle.standardError.write(Data("usage: es-dev windows | fixture | e2e [--out <dir>]\n".utf8))
    exit(64)
}
