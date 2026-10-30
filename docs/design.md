# everything-shortcut design

## Problem

The app labels every visible clickable element on the whole screen and clicks the one whose label the user types.
"Whole screen" covers background windows, the frontmost app's menu bar, menu bar extras, and the Dock.
Research found no existing tool that labels background windows, so cross-app occlusion is new work (`docs/research.md`).
Four constraints shape the design.
AX calls are blocking Mach IPC into each target app, so the scan must run off the main thread, in parallel across apps, and survive a hung app.
`AXUIElement` is a non-Sendable CF type under Swift 6 strict concurrency, so something must own each handle.
AX, CGWindowList, CGEvent and CGDisplayBounds use top-left global coordinates, while `NSWindow` frames use bottom-left AppKit coordinates.
The development shell is not Accessibility-trusted, so end-to-end checks have to run through the signed app.

One fact measured during design changes the plan.
On macOS 26.6.2, all 14 status-level windows (layer 25) on the development machine belong to Control Center.
Amphetamine, CleanShot X, Clipy, KeepingYouAwake and Docker ran at the same time and owned none.
So the window list cannot say which app's `AXExtrasMenuBar` holds a given extra (measured with `es-dev windows` and `lsappinfo`).

## Usage

### The person at the keyboard

Press Cmd-Shift-Space.
Yellow badges appear at the top-left corner of every visible clickable element, in every app.
Type a label.
Badges that stop matching disappear, and the typed letters dim on the ones that still match.
Typing a whole label clicks its element.
If the element is in a background window, that window comes forward first, as with a real click.
Escape cancels, Cmd-Shift-Space cancels, and so does a mouse click anywhere.
The click itself still reaches whatever is under the pointer.
Backspace removes one letter.
A letter that matches no label beeps and changes nothing.
Hint mode does not start while a password field holds Secure Event Input, because typed labels would reach the field.
It beeps and shows a short notice near the top of the screen instead.
It also does not start before Accessibility is allowed, and the app window opens at its Accessibility step instead.

The menu bar icon, a filled label with "ES" cut out, opens a menu.
The first line says "Accessibility: allowed", or is "Allow Accessibility…", which opens the app window at that step.
The second shows the shortcut and whether it registered.
If another app already holds the chord, the menu says so, and "Show Labels" is still there.
While Secure Event Input is on, a line says labels are paused.
"Show Labels" starts hint mode from the menu, "Settings…" opens the app window, and "Quit" ends the app.

The app has one window.
It is first-run setup until setup was finished or skipped once, titled "Welcome to Everything Shortcut", and Settings after that, titled "Everything Shortcut Settings".
Below the app's name and version it lists two steps: Accessibility and the shortcut.
"First launch and the app window" below covers the steps.
The window also holds the "Launch at login" switch and says where the menu bar icon is.
The switch registers the app with `SMAppService.mainApp`, and when macOS waits for the user's approval it says so and offers to open Login Items.
Opening the app again while it runs also shows the window, because macOS hides status items behind the notch when the menu bar is full.
While the window is open the app is a regular app, with a Dock icon, a ⌘Tab entry and a menu bar of its own, because macOS never treats an `.accessory` app as the selected app.
Closing the window makes it `.accessory` again.
Click the shortcut button and type a chord.
The chord needs Control, Option or Command, and Escape and Delete cannot be the key, so cancel and Backspace always work.
An invalid chord shows why under the button and recording continues, and Escape alone stops recording.
The chord is on the button, so the Shortcut row shows an orange line only when the chord failed to register or an enabled macOS shortcut takes it first.
After setup, "Restore Defaults" brings back ⇧⌘Space.
The badge letters are fixed to the home-row alphabet, because a user-chosen alphabet rarely beats it and easily makes every badge longer.
Changes persist in `UserDefaults` and take effect without a restart, but never in the middle of a hint session.

### The developer

```sh
swift test                         # the pure core, no permissions
scripts/check-invariants.sh        # single-source-of-truth rules, fails on a violation
.build/debug/es-dev windows        # the AX-free half of a scan on the live desktop, from any shell
.build/debug/es-dev fixture        # the e2e fixture windows, each press printed with NSApp.isActive
.build/debug/es-dev icon <dir>     # the app icon as an .iconset, the one bundle.sh ships
scripts/bundle.sh debug            # build/EverythingShortcut.app with that icon, signed with the stable identity
scripts/release.sh                 # the universal, notarized download zip under build/release/
scripts/e2e.sh                     # real hotkey, real tap, real AX press against the fixture
```

The first `scripts/e2e.sh` run needs one manual step.
Grant Accessibility to `build/EverythingShortcut.app` in System Settings.
The stable bundle id and signing identity keep the grant across rebuilds.

### Call sites

The hotkey reaches the reducer through one method, and the reducer is the only place that decides.

```swift
// HintController.init
hotKey.onPress = { [weak self] in self?.triggerPressed() }
triggerRegistration = hotKey.register(config.trigger)    // .registered or .failed(status), never a throw

func triggerPressed() {
    send(.trigger(Self.gate()))   // .ready, or .blocked(.needsAccessibility / .secureInputActive)
}
```

Settings reach the reducer the same way, and the reducer alone decides when they apply.

```swift
// AppDelegate
let config = HintConfig.standard.applying(SettingsStore.load())   // per-field fallback to .standard

// SettingsWindowController.apply
SettingsStore.save(settings)
controller.configure(settings)    // send(.configure(settings))

// HintController.run
case .applySettings(let settings):   // only ever emitted at idle
    triggerRegistration = hotKey.register(settings.trigger)
    keys.trigger = settings.trigger
    config = config.applying(settings)
    onSettingsApplied()
```

The reducer's contract reads as a test, because it is one (`Tests/HintCoreTests/HintMachineTests.swift`).

```swift
var m = HintMachine<Int>(settings: .standard)
m.send(.trigger(.ready))                // [.captureKeys(true), .startScan(1)]
m.send(.trigger(.ready))                // [.cancelScan, .captureKeys(false)]   trigger again cancels
m.send(.scanned(ScanID(raw: 1), cs))    // []                                    stale scan dropped
m.send(.trigger(.ready))                // [.captureKeys(true), .startScan(2)]
m.send(.scanned(ScanID(raw: 2), cs))    // [.render(board)]
m.send(.configure(s))                   // []                                    waits for idle
m.send(.mouseDown)                      // [.render(nil), .captureKeys(false), .applySettings(s)]
```

The controller runs effects and nothing else.
The scan and the click are one call each, and both run off the main actor.

```swift
case .startScan(let id):
    let running = Desktop.runningApps()
    scanTask = Task { [weak self] in
        let report = await scanner.scan(running)          // @concurrent, probes on AX queues
        self?.send(.scanned(id, report.candidates))
    }
case .perform(let target):
    Task { [weak self] in
        let report = await target.perform(policy: policy) // runs on the element's own probe actor
        self?.lastPerform = report
        self?.send(.performed)
    }
```

The user edits only the trigger in Settings.
Every other tunable is one value in code.
Choosing press or click is one word, and adding a hintable role is one line.

```swift
// Sources/HintCore/Config.swift
clickPolicy: .pressWhenAdvertised,      // or .alwaysClick
// Sources/HintCore/RoleTable.swift
"AXDisclosureTriangle": .hint,
```

## Shape

### Module map

| Path | Owns |
| --- | --- |
| `Package.swift` | Seven targets, tools 6.2, macOS 15, Swift 6 language mode. |
| `Sources/HintCore/Geometry.swift` | `GlobalPoint`, `GlobalRect`, `AppKitRect`, the only AppKit conversion, `Display`, `LocalPoint`. |
| `Sources/HintCore/Config.swift` | `HintConfig.standard`, the one source of tunables. |
| `Sources/HintCore/Settings.swift` | `UserSettings`, `StoredSettings` and its per-field parse, `HintConfig.applying`. |
| `Sources/HintCore/Labels.swift` | `Alphabet` and `LabelGenerator.labels(count:alphabet:)`. |
| `Sources/HintCore/Keys.swift` | `Modifiers`, `VirtualKey` and its key-name table, `HotKey`, `HotKey.validated` with `TriggerError`, `KeyInput`, `KeyRouting.route`. |
| `Sources/HintCore/HintMachine.swift` | `Candidate`, `Hint`, `Board`, `Phase`, `Event`, `Effect`, and the `HintMachine` reducer. |
| `Sources/HintCore/RoleTable.swift` | `RoleRule`, `ChildrenSource`, `RoleTable.standard`, and the web search keys. |
| `Sources/HintCore/Traversal.swift` | `ElementReader`, `NodeFacts`, and `Traversal.harvest`. |
| `Sources/HintCore/WindowStack.swift` | `WindowSnapshot`, `RunningApps`, `ScanPlan`, `Surface`, and `Visibility`. |
| `Sources/HintCore/Setup.swift` | `SetupFacts`, the `SetupGuide` reducer, and `MenuBarIcon.judge`. |
| `Sources/HintCore/ActionPlan.swift` | `ClickPolicy` and `ActionPlan.make`. |
| `Sources/HintCore/BadgeLayout.swift` | `BadgeLayout.layout(board, displays)` into display-local badges. |
| `Sources/Desktop/Desktop.swift` | Window snapshot, displays, and running apps from CoreGraphics and NSWorkspace, with no AX. |
| `Sources/AutomationWire/AutomationWire.swift` | DEBUG wire types shared by the app and es-dev. |
| `Sources/Badge/Badge.swift` | `BadgeStyle` (the hint badge's font, colors, padding, corner radius, and gradient), `AppIcon` (the badge as an "ES" keycap with ⌘), and `NSImage.statusItemIcon` (the badge as a menu bar template with "ES" cut out). |
| `Sources/EverythingShortcut/HintController.swift` | The single owner of session state, and the one read of Secure Event Input. |
| `Sources/EverythingShortcut/Scan.swift` | `Scanner`, `ProbeQueues`, `AppProbe`, `ElementRef`, `AXReader`, and every AX IPC call. |
| `Sources/EverythingShortcut/KeyCapture.swift` | The event tap and its C callback. |
| `Sources/EverythingShortcut/HotKey.swift` | Carbon `RegisterEventHotKey` and `UnregisterEventHotKey`, and `ShortcutStatus`. |
| `Sources/EverythingShortcut/KeyboardLayout.swift` | Key code to character through the ASCII-capable layout, and the name every chord is shown with. |
| `Sources/EverythingShortcut/SettingsStore.swift` | `UserSettings` in `UserDefaults.standard`, read through `StoredSettings`, and the two setup flags. |
| `Sources/EverythingShortcut/SettingsWindow.swift` | `SettingsWindowController` (the AppKit window, the trust watch, coming forward), `SettingsModel` (the guide, the one prompt call, recorder, login item, apply), and the SwiftUI checklist. |
| `Sources/EverythingShortcut/Overlay.swift` | One panel per display, `BadgeCanvas`, and the secure input `Notice`. |
| `Sources/EverythingShortcut/Automation.swift` | The `#if DEBUG` hook that posts real keystrokes and writes `SessionSnapshot`. |
| `Sources/EverythingShortcut/AppDelegate.swift` | Process wiring, the persisted settings at launch, the launch decision, session note routing, and the status item menu. |
| `Sources/es-dev/` | `windows`, `fixture`, `e2e`, and `icon`. |
| `Tests/HintCoreTests/` | Tests over the pure core. |
| `scripts/` | `check-invariants.sh`, `bundle.sh`, `e2e.sh`, `release.sh`. |

`HintCore` has no import lines at all, only the Swift standard library.
`scripts/check-invariants.sh` fails when that changes.

### Data structures

Every core type is a value type and Sendable.

- `WindowSnapshot` is the on-screen window stack, front to back.
  One snapshot per scan feeds the plan, the in-traversal cover test, and the occlusion filter, so they cannot disagree.
- `RunningApps` is what the window list cannot say.
  It holds the frontmost pid, the Dock pid, the Control Center pid (found by bundle id `com.apple.controlcenter`), and every app that may own a menu bar extra.
- `ScanPlan` is `[AppScan]`.
  Each `AppScan` names one pid and its roots, which are exposed windows, the menu bar, extras, and the Dock.
  `AppScan.isExtrasOnly` is the single definition of a job that reads only `AXExtrasMenuBar`.
- `NodeFacts` is one node's role, optional frame, and enabled flag, read in one IPC.
  A missing frame is a legal state, so the type says so.
- `Candidate<Target>` is a target handle, a pid, a `Surface`, and a visible frame.
  `hitPoint` and `anchor` derive from the frame.
- `Hint<Target>` pairs a label with a candidate, and `Board<Target>` holds the hints and the typed prefix.
- `Phase<Target>` is `idle`, `scanning(ScanID)`, `showing(Board)`, or `performing(Target)`.
  No booleans sit beside it.
- `Effect<Target>` is the full command set for the shell.
  It has `startScan`, `cancelScan`, `captureKeys`, `render`, `perform`, `alert`, and `applySettings`.
- `UserSettings` is the trigger, the part of `HintConfig` the user edits.
  `HintMachine` holds at most one pending value, which waits for idle.
- `StoredSettings` is the persisted form, two optional raw fields.
  `UserSettings(stored:)` parses it, so a missing or invalid trigger falls back to the standard trigger.
- `RoleTable` maps role strings to `.hint`, `.container(ChildrenSource, clips:)`, or `.skip`, plus a fallback.
- `SetupGuide` is the app window's checklist: the facts read from macOS, whether setup is complete, and whether Accessibility was requested.
  Every row, the Return action and the launch decision derive from those three.

The core is generic over `Target`.
The app instantiates it with `ElementRef`, and tests use `Int`.
That generic parameter keeps AX handles out of the core without an ID registry.

### Data flow from hotkey press to click

1. Carbon delivers the hotkey on the main thread.
   `HotKeyCenter` calls `HintController.triggerPressed`, which reads `AXIsProcessTrusted` and `IsSecureEventInputEnabled` into a `TriggerGate` and sends `.trigger`.
2. `HintMachine` moves idle to `scanning(id)` and returns `captureKeys(true)` then `startScan(id)`.
3. `KeyCapture` enables the session tap.
   From here on, letters never reach the frontmost app, and a mouse-down anywhere sends `.mouseDown`.
4. The controller reads `RunningApps` from NSWorkspace on main and starts a task that awaits `Scanner.scan`, which is `@concurrent` and leaves the main actor.
5. `Scanner` takes one `WindowSnapshot` and the displays, computes the `ScanPlan`, and assigns each job a lane from `ProbeQueues`.
   A task group runs one `AppProbe.scan` per app.
6. Each probe sets a 50 ms messaging timeout on its app element when the job is extras-only.
   A job that walks a window, the menu bar or the Dock first reads the app element's `AXRole`, which is a liveness check and also wakes Chromium's web accessibility.
   An extras-only job skips that read, and its one `AXExtrasMenuBar` read is the liveness check.
   It then walks its roots with `Traversal.harvest` over `AXReader`.
   For each root it passes a cover test built from the windows in front of that root's surface, so a subtree hidden behind one window costs one IPC.
   It stores each found `AXUIElement` in its own `slots` and returns `Candidate<ElementRef>` values.
7. `Scanner` sorts the harvests by pid and applies `Visibility.filter` against the same snapshot.
   The filter drops covered and off-display candidates and deduplicates, then `Scanner` returns a `ScanReport`.
8. Back on main, the controller sends `.scanned(id, candidates)`.
   A mismatched id is dropped.
   Otherwise the reducer sorts candidates into reading order, assigns labels, and returns `render(board)`.
9. `BadgeLayout.layout` projects the board onto displays.
   `Overlay.render` reconciles one panel per display and hands each `BadgeCanvas` its badges.
10. Each keyDown hits the tap callback on main.
    `KeyRouting.route` turns it into a `KeyInput`, and the controller sends `.key`.
    The reducer narrows the board or, on an exact label, returns `render(nil)`, `captureKeys(false)`, `perform(ref)`.
11. `ElementRef.perform` hops to the owning probe's queue.
    The probe reads the element's action names, builds an `ActionPlan`, raises the window if the plan says so, and presses or clicks.
    It returns a `PerformReport`, the controller keeps it for the DEBUG snapshot and sends `.performed`, and the phase returns to idle.
    Dropping the board releases every probe and its elements.

Tracing that flow takes three files: `HintController.swift`, `HintMachine.swift`, and `Scan.swift`.
`HotKey.swift`, `KeyCapture.swift` and `Overlay.swift` are leaf adapters, and the effect switch in `HintController` states their contracts.

### Load-bearing decisions

- `AXUIElement` handles never leave the actor that created them.
  The design removes shared mutable state instead of locking it.
- The pure core contains the real traversal and visibility algorithms behind the `ElementReader` protocol.
  The shell only does I/O, so pruning, occlusion, and IPC cost are unit-tested with a fake tree and the window stack observed on the development machine.
- One `WindowSnapshot` drives the plan, the cover test, and the occlusion filter.
  One `RoleTable` drives pruning, hintability, and the filtering of search results.
- The session is a reducer with an explicit transition table.
  The controller is a run-to-completion effect interpreter, so it cannot re-enter, and no flag can drift from the phase.
- `render` and `captureKeys` are declarative and idempotent.
  The overlay keys panels by display id, so stacked overlays cannot exist.
- The scan is bounded by construction, with no watchdog.
  A per-call messaging timeout, a deadline check before every IPC, and a stop on the first unresponsive answer give a worst case of `scanBudget + axMessagingTimeout`, 300 + 150 ms.
- Coordinates stay in the top-left global space end to end.
  Overlay views are flipped and displays come from `CGDisplayBounds`, so placing a badge is a subtraction.
  The single AppKit conversion in `Geometry.swift` is used only for panel frames and by es-dev.
  `AppKitRect` and `GlobalRect` are distinct types, so the two spaces cannot mix silently.

### Interface depth

`HintMachine` exposes one method, `send(_:)`, over the whole session policy.
`Scanner` exposes one method, `scan(_:)`.
It hides the snapshot, the plan, the queue lanes, the per-app fan-out, AX error classification, web accessibility enablement, and occlusion.
`AppProbe` exposes `scan` and `perform`, and `ElementRef.perform` is the only way to act on an element.
`HintController` exposes `triggerPressed`, `send`, `configure`, `suspendTrigger` and `resumeTrigger`, the applied settings and the trigger registration, and read-only diagnostics for the DEBUG hook.
It also exposes `onNeedsAccessibility`, called when a trigger was refused for lack of Accessibility, and `secureInputActive`, the one read of Secure Event Input.
No AX or CG type appears on any of those signatures.

## AXUIElement across threads under Swift 6

Every `AXUIElement` is created, used and released inside one `AppProbe` actor.
That is the whole rule.
The probe's executor is its `ProbeLane`, set through `nonisolated var unownedExecutor`.
For another app that is a `DispatchSerialQueue` from a fixed pool, and for our own process it is the main actor's executor.
Swift isolation therefore confines each element to one serial executor, and the compiler checks it.
The values that leave a probe are Sendable by construction.
`Candidate<ElementRef>` carries an `ElementRef`, which is the owning actor plus an `Int` slot.
To act on an element, a caller asks its owner, and `perform(slot:policy:)` runs on the owner's queue.
The codebase has no `@unchecked Sendable`, and `scripts/check-invariants.sh` keeps it that way.

AX calls block for up to the messaging timeout, so probes run on dispatch queues and not on the cooperative pool.
The cooperative pool has one thread per core, and a few hung apps would starve every other task.
Dispatch queues may block without starving the pool.
`ProbeQueues` caps blocked threads at 8, with 2 light lanes for extras-only jobs and 6 heavy lanes for window, menu bar, and Dock traversals.
The cap matters because 71 running apps may own menu bar extras on the development machine (measured with `es-dev windows`).
One queue per app would allow up to 71 blocked threads, close to the GCD limit that AltTab's scheduler documents.

The process-wide messaging timeout is 150 ms, set once at launch through the system-wide element.
An extras-only job sets 50 ms on its own app element, the value Vimac uses for extras.
So a hung app that owns no visible window costs its lane 50 ms, not 150 ms.

A single `@unchecked Sendable` box around `AXUIElement` would make a handle reachable from any actor.
The next contributor could then call AX on the main actor and the build would still pass.
With the actor, a main-actor AX call on a scanned element does not compile.

Elements are not re-resolved at perform time.
AX has no stable element identity across trees, so re-resolution would have to re-walk and match frames, and a UI that changed in between would fool it.

No watchdog task races the scan.
`withTaskGroup` waits for every child even after `cancelAll`, so a race cannot return before a blocked AX call returns.
The bound comes from the timeout and the per-IPC deadline check instead.

Our own windows are planned like any other app's, and their probe runs on the main lane.
AX calls into our own process are not IPC: AppKit answers them on the calling thread, and SwiftUI asserts the main queue.
A press on our own SwiftUI button from a global queue crashed in `dispatch_assert_queue`, and on the main queue it read our windows in 13 ms and pressed the button with its action already run when the press returned.
`ProbeQueues.assign` gives our job `ProbeLane.main` and every other job a queue.
Our own menu bar and status item are never planned, because pressing either opens a menu whose tracking loop would run inside the press, on main.

## Click policy

The policy is `ClickPolicy.pressWhenAdvertised`, set once in `HintConfig.standard`.
`ActionPlan.make` turns the policy, the surface, the hit point, the element's advertised actions and its content kind into steps.
The traversal marks every element found under a `.searchPredicate` container as `.web` content, whether it came from the search or from the `.children` fallback, and every other element as `.native`.
The probe reads `AXUIElementCopyActionNames` for the chosen element only, one IPC.

1. Raise, for `.window` surfaces only.
   The probe performs `AXRaise` and sets `AXMain` on the element's window, then sets `AXFrontmost` on its app.
   Activation goes through AX because cooperative activation lets macOS 14 and later ignore an agent app's `activate` request.
   For our own window the probe skips `AXFrontmost`.
   Set in-process, it switched to another Space while our window showed over a full-screen app, and the window was gone from the screen right after a successful try (measured).
   A window of ours that got a label is in front of the user already, so the press needs no activation.
   The shortcut recorder needs key focus, so it starts only while the app is active, and otherwise only asks for activation.
2. Act.
   Web content is always clicked, after the same raise.
   Chrome answers `AXPress` on web elements with `kAXErrorSuccess` and performs nothing, so a successful press does not mean the link was activated.
   If a native element advertises `AXPress`, the probe presses it.
   `kAXErrorCannotComplete` counts as done on purpose.
   The request reached the app and only the reply timed out, or a menu bar item blocked the reply until its menu closed, so a fallback click could press twice.
   Any other failure falls back to a click.
3. Click, for web content, when there is no `AXPress`, or when the press failed.
   After a raise, the probe waits up to 150 ms for the app to report frontmost, so the click lands on an active window instead of only activating it.
   It posts mouseMoved, leftMouseDown and leftMouseUp through the HID tap with click state 1 and cleared flags, then warps the cursor back.

Background windows therefore come forward and the action fires, as with a real click.
For native elements, AXPress is first because it acts on the first attempt even where a view ignores first mouse, and it never moves the cursor.
Menu bar items, extras and Dock items are never raised.
Text fields advertise no `AXPress`, so they get a click, which focuses them and places the caret with no special case.
The policy chooses press versus click only.
`.alwaysClick` makes every act a synthesized click, as Vimac does, but `.window` surfaces still raise first, because `ActionPlan.make` decides the raise from the surface alone.
Vimac never raises, so matching it fully would also need a change to the raise rule.

Every perform returns a `PerformReport` with the plan, the `AXError` that `AXPress` returned or the fact that a click ran, and whether the app was frontmost before and after.
The DEBUG snapshot carries the last report, so the first trusted run shows which path each surface takes.

## Hintable-role table

`RoleTable.standard` in `Sources/HintCore/RoleTable.swift` is a dictionary literal from role string to `RoleRule`, plus a fallback.
There are three rules.
`.hint` makes an enabled, visible node a candidate and never reads its children.
`.container(source, clips:)` reads children from `.children`, `.visibleRows` or `.searchPredicate(keys:)`, and `clips` limits descendants to the node's visible frame.
`.skip` neither hints nor descends.
Roles missing from the table, `AXGroup` among them, use the fallback `.container(.children, clips: false)`.
The traversal reads only this table, so a role cannot be hintable in one place and pruned in another.
`scripts/check-invariants.sh` fails on a role string literal anywhere else in `Sources`.

### Frames that are missing or empty

Many containers report no frame or a zero frame.
The Dock's `AXApplication` root has no frame, and SwiftUI and web content use zero-size groups.
A container with a missing or empty frame passes its parent's clip through to its children instead of pruning them.
A container whose frame lies outside the clip is still pruned, so an off-screen subtree costs one IPC.
A hint with a missing or empty visible frame is never a candidate, because there is nowhere to draw or click.

### Hintability by role

Hintability is decided by role alone.
Vimac reads action names for every node, which doubles the IPC count per node (`docs/research.md`, section 1a).
This design reads action names once, for the element being clicked.
The cost is that a custom-drawn native control exposed as `AXGroup` or `AXImage` with `AXPress` gets no hint.

### Web areas

Web areas use `AXUIElementsForSearchPredicate` with `AXVisibleOnly`, which returns visible interactive descendants in one IPC.
Each result goes back through `RoleTable.rule(for:)`, and only `.hint` roles become candidates.
Results are terminal and are never descended into.
If a web area does not answer the search, the traversal falls back to `.children`.

Every scan that walks an app's windows, menu bar or Dock first reads the app element's `AXRole`, which turns on Chromium's basic web accessibility.
Extras-only jobs skip it, so a Chromium app whose windows are all hidden is never woken.
If a web area's search then returns no results, the probe reads `AXEnhancedUserInterface` (Chromium) and `AXManualAccessibility` (Electron) on that app.
It sets each one to true only if it is not already true, and never sets either back to false.
Reading before writing keeps repeated scans from restarting Chromium's 2 s timer, and setting false would destroy Chromium's web tree.

### Tables and depth

Tables and outlines read `AXVisibleRows`, so a 10,000-row Mail list costs its visible rows, not every row.
`AXRow` is a leaf hint, so Finder lists and sidebars get one badge per row.
The traversal is breadth-first, so a walk cut short by the 300 ms budget or the 6,000-node cap still has the toolbar and sidebar controls.
`TraversalTests` assert both results and IPC cost, for example that an off-screen subtree costs exactly one call.

## Visibility and occlusion

Visibility is decided in three passes over the same `WindowSnapshot`.
Each pass is a pure function in `WindowStack.swift`.

1. Before the scan, `WindowSnapshot.exposed` drops windows that lie entirely inside one occluding window in front of them.
   A lock screen or screensaver shield hides everything, so the plan is empty.
2. During the traversal, `Visibility.coverTest` gives `Traversal.harvest` an `isFullyCovered` closure for each root.
   The closure knows the occluding windows in front of the root's surface.
   A node whose clipped frame lies entirely inside one of them is skipped with its subtree, before its children are read.
3. After the scan, `Visibility.filter` keeps a candidate only if a click at its hit point would land on its own surface.
   The hit point is the center of the visible frame.
   Alpha-0 windows and our own overlay never occlude.
   Our other windows occlude like any app's, so badges for what is behind them are dropped.

The filter then removes duplicates.
Menu bar extras deduplicate by frame alone, because on macOS 26 an extra may appear under both its owner app's `AXExtrasMenuBar` and Control Center's.
The owner app's element wins over Control Center's, whichever arrives first, and Control Center is identified by bundle id, not by name.
Every other surface deduplicates by pid and frame.
The filter reports each dropped extra with both pids, and the DEBUG snapshot carries the list.

## Keys, mouse, and the trigger

The trigger is a Carbon `RegisterEventHotKey` registration, which needs no permission.
Registration failure is a state, not a crash.
`HotKeyCenter.register` returns `.registered` or `.failed(status)`, the controller keeps it, and the status menu and Settings show it.
A chord that fails to register stays chosen and persisted, as at launch, and "Show hints" in the menu still works.
Registration does not see other processes, so "Registered" can be wrong.
On macOS 26.6.2, a second process holding ⌃⌥⌘K with `kEventHotKeyExclusive` left our registration of ⌃⌥⌘K at `noErr`, Settings showed "Registered", and a posted ⌃⌥⌘K reached only the other process.
Without the exclusive flag both registrations succeeded and our app received the chord.
The recorder does not see such a chord either: with the same holder running, a posted ⌃⌥⌘K left it at "Type a shortcut…" with nothing applied.
macOS shortcuts are the one conflict the app can see, through `CopySymbolicHotKeys`.
The recorder cannot catch them, because macOS handles an enabled one first: a posted ⌘Space opened Spotlight and a posted ⌥⌘Space opened a Finder search, and neither reached the recorder.
So the menu and Settings check the applied chord against the enabled macOS shortcuts and say "not usable" when one takes it, which covers a chord saved before the user turned that shortcut on.

The user picks the trigger in Settings, and `HotKey.validated` decides which chords are allowed.
`KeyRouting.route` passes the trigger through before anything else, so a chord needs Control, Option or Command.
A bare or Shift-only chord would shadow label typing, and an Escape or Delete chord would shadow cancel or Backspace, so both are rejected.
Carbon fires a registered chord even while our own window is key.
So the recorder suspends the trigger while it records, and every way out of recording registers the applied chord again.

A settings change is an event, `.configure`, and the reducer applies it only at idle.
Mid-session it waits as pending, the last one wins, and every transition into idle emits `.applySettings` after its other effects.
So the chord that ends a session is the one that started it.
The controller then registers the new chord, retunes `KeyCapture`, which is disabled at idle, and redraws the Settings window.

Chords are shown through `KeyboardLayout.name(of:)`.
Keys that type nothing printable, such as Space, Return, the arrows and F1 to F20, come from the core's `VirtualKey.name(for:)` table.
Other keys show their character in the ASCII-capable layout, uppercased.

While hint mode is active, a session-level event tap at the head of the queue owns typing.
It listens for keyDown and for left, right, and other mouse-down.
`KeyRouting.route` classifies each keyDown.
The trigger chord passes through, so Carbon stays the single source of trigger presses.
Escape, Backspace and alphabet letters are swallowed and forwarded, and every other key is swallowed and dropped.
A mouse-down passes through to its target and sends `.mouseDown`, which ends hint mode.
When macOS disables the tap on a timeout, the callback enables it again.
If that fails, the controller sends `.keyCaptureLost`.

Letters come from the ASCII-capable keyboard layout through `TISCopyCurrentASCIICapableKeyboardLayoutInputSource` and `UCKeyTranslate`.
So labels type the same under Dvorak or under a Japanese IME in kana mode.

## Overlay and badges

The overlay is one borderless, transparent, non-activating `NSPanel` per display, at the `.screenSaver` level.
That level sits above menus, the menu bar, status items and the Dock.
Each panel ignores the mouse, can never become key, and has the collection behavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`.
It never takes focus from the user's app.

Each panel holds one flipped `BadgeCanvas` that draws every badge of its display in one `draw(_:)`.
There are no per-badge views, so several hundred badges cost one view and one pass.
The badge follows Vimium.
It is a yellow rounded rectangle with a top-to-bottom gradient, a darker amber border, and a light shadow.
The letters are dark, bold, and uppercase, and the typed prefix is dimmed.
A badge's top-left corner sits on its element's top-left corner, clamped inside the display.
The canvas caches the attributed string and size of each label and typed count, so a keystroke redraws without new text layout.

## First launch and the app window

Setup is the first state of the one app window, not a second window.
So `SettingsWindowController` stays the only owner of the activation policy, `SettingsModel` stays the only recorder, and reopening the app always lands on the one place that says what needs the user.

### The checklist

The window lists two steps, and the first step that is not done is current.

1. Accessibility is done when `AXIsProcessTrusted()` says so.
2. The shortcut is done when it registered and no enabled macOS shortcut takes it first.
   A chord another app holds exclusively still reads done, because nothing can see it.

Steps the Mac can answer check themselves, so a working ⇧⌘Space is already checked on first launch.
Return does the current step: Open System Settings, or start recording the shortcut, and Done once both steps are done.
Once both steps are done, a Next row, which is not a step, tells the user to press the chord in any app and type a label's letters.
Escape only stops recording, because Escape also closes labels, and a stray one must not skip setup.
A done step is a green checkmark, the current one an amber number, and a later one a gray number.
No yellow badge with letters appears in the window, because on screen that means "type me".

`SetupGuide` in `Sources/HintCore/Setup.swift` decides all of it.
It is a reducer with a written transition table, like `HintMachine`, and `SetupTests` is its contract.
The shell reads the facts in one function, `SettingsModel.facts(of:)`, on show, on key, after settings apply, and every 0.5 s while the window is open without Accessibility.
When the grant lands, the guide emits `comeForward`, and the window orders itself above System Settings and requests activation, which macOS may refuse.
The next step does not need focus, because the shortcut works from any app.

### When the window opens

The window opens at launch until setup was finished or skipped once.
After that it opens at launch only while Accessibility is off, so a login launch never nags about the shortcut.
The status menu and the window still show a broken shortcut.
A launch with `--automation` in DEBUG never opens it, so the e2e run starts with no window of ours on screen.
A trigger refused for lack of Accessibility opens the window at that step.
Closing the window in any way (Skip Setup, Done, Command-W, the close button) completes setup, stored once as `setupComplete`.
Quitting does not, so a quit mid-setup shows setup again at the next launch.

The window moves to the user's Space instead of pulling the user to its own (`.moveToActiveSpace`), and it can show over a full-screen app (`.fullScreenAuxiliary`).
Opening the app from a full-screen app's Space still switches to a desktop Space, after `show` ordered the window, and the window stayed behind on the full-screen Space, measured with a reopen.
So while the app is active, a change of the active Space brings the window along.

### The system prompt

The Accessibility button is the only caller of `AXIsProcessTrustedWithOptions`, and `scripts/check-invariants.sh` fails on any other.
macOS shows the prompt only while it has no entry for the app, and the call creates the entry that the pane lists.
From the second request on, recorded as `accessibilityPrompted`, the prompt stays silent, so the button opens the pane as well.
Neither launch nor a refused trigger shows the prompt any more.

### The menu bar icon and secure input

A new status item on a full menu bar can sit under the notch with its window still `isVisible` (measured at x 721, width 38, against the gap from 663 to 848).
`MenuBarIcon.judge` calls the icon hidden when its window does not report `.visible` in `occlusionState`, or when it overlaps the notch gap of its screen.
No visible icon has been measured, so every doubt reads hidden, whose copy (open the app again) is right either way.
When the icon is visible, Show Me opens its menu.

A trigger refused by Secure Event Input beeps and shows a notice in the badge style near the top of the display that holds the mouse, for 2.5 s.
The app holding secure input is not named, because `kCGSSessionSecureInputPID` named the frontmost app, not the holder, in a measured run.
The notice panel sits at the overlay's level, so the scan treats it like the badge panels.

## End-to-end verification without a trusted shell

Verification has five layers, and only the last needs a person once.

1. `swift test` covers the core.
   The tests cover prefix-free shortest labels for every count from 1 to 600, the full transition table including deferred settings, settings parsing and fallback, trigger validation, the observed window stack with its alpha-0 window and lock-screen shield, traversal IPC cost, frame pass-through, occlusion pruning, extras deduplication, the AppKit conversion, key routing, and badge layout.
2. `scripts/check-invariants.sh` fails on any `@unchecked`, any import in `HintCore`, a role string outside `RoleTable.swift`, the AppKit conversion outside `Geometry.swift`, AX IPC calls outside `Scan.swift`, and the system Accessibility prompt outside `SettingsWindow.swift`.
3. `es-dev windows` prints the window stack, each window's exposure, and the scan plan, using the same `Desktop` reads and `ScanPlan` as the app.
   It needs no Accessibility.
   The unit tests feed native Swift values to the CGWindowList parser, so this live run is what proves the parser's casts through bridged `NSNumber` values.
4. `scripts/e2e.sh` bundles and signs the DEBUG app, starts it with `open` and `--automation` so it is its own TCC-responsible process, and runs `es-dev e2e`.
   es-dev hosts the fixture windows in its own process with the regular activation policy, so it needs no permission.
   It drives the app over `DistributedNotificationCenter`, and the app writes each reply atomically to the path named in the request.
   The app's DEBUG hook posts real keystrokes with `CGEventPost(.cghidEventTap)`, so they pass through Carbon hotkey matching and our own session tap.
   The hook never sends a key, trigger or mouse event to the reducer, so a passing run exercises the real hotkey, tap, scan and press path.
   Its one direct call is `configure`, which applies settings without persisting them, so a run never rewrites the user's saved settings.
   Before anything else, es-dev stops with exit 2 when the screen is locked or the fixture windows are not on screen after 2 s, which a full-screen Space causes, because every fixture check would then fail for a reason outside the app.
   One check switches to ⌃⌥⌘J, proves the old chord no longer starts a session and the new one shows hints, then restores the settings the run started with, on the failure path too.
   A later check relaunches the app with stored settings in the argument domain, which UserDefaults reads before the user's own and never writes.
   The stored trigger is ⌃⌥⌘J, so the check proves the parse at launch, then relaunches the app plainly.
   A launch with `--automation` never opens the app window, so every check before the last one runs with no window of ours on screen.
   The last check hides the fixture, opens the app window through `openWindow`, and waits until the snapshot has the window's frame.
   It then shows labels and requires at least one label of the app whose center lies inside our window.
   It also requires that no label of another app's window behind ours, in a window list es-dev takes while the labels show, has its center inside our window.
   Windows in front of ours are left out, so what happens to be on screen cannot make it flake.
   It then presses Escape and never closes the window, because closing stores setup completion, and `scripts/e2e.sh` ends the app with `pkill`.
   It presses nothing in our window, so the main-lane probe's in-process `AXPress` on our own controls is no longer covered by e2e.
   No control in the window passes both constraints: Skip Setup, Done and closing store setup completion, the login switch writes the login item through `SMAppService`, and the rest leave no trace in the snapshot.
   Beyond the fixture, it requires at least one `statusItem`, `menuBar` or `dock` hint whenever the live window stack exposes a status-level, main-menu or Dock window, so the run also proves the surfaces outside the fixture.
   es-dev prints `VERIFIED` or `NOT VERIFIED` for each check and saves a `screencapture -x` of the badges under `build/e2e/`.
5. The one manual step is granting Accessibility to `build/EverythingShortcut.app`.

The fixture has a Back window and a Front window.
Both float above normal windows, so another app's windows cannot cover them when the run moves activation away from es-dev.
Front fully covers one Back button, so that button must get no hint.
Another Back button stays exposed, so pressing it tests the background-window policy.
Front also has a text field, which advertises no `AXPress` and so tests the click path.
Each press records its name and `NSApp.isActive` at press time, so a run can tell "pressed in place" from "raised, then pressed".

The DEBUG snapshot also answers the open questions below without another build.
For each pid it reports scan duration, stop reason, and nodes read.
For each web area it reports how many results the search returned on that scan, which always follows the `AXRole` read, and which enablement flags the probe wrote.
For the last perform it reports the plan, the press result or click, and the frontmost state before and after.
For extras it reports both pids of every dropped duplicate.

The hook compiles only under `#if DEBUG` and starts only with `--automation`.
`swift build -c release --product EverythingShortcut` compiles it out.

## Synthesis decision

Two runners sketched the design independently, and a cross-judge scored both against a six-criterion rubric.
The criteria were concurrency, state machine, interface depth, single source of truth, verifiability, and visibility and performance.
Candidate B became the base, 27 points to 23, and the cross-judge and the orchestrator agreed on the pick.

### Why B

- AX handles are confined by the compiler.
  Each app's `AXUIElement` values live inside one `AppProbe` actor whose executor is a serial dispatch queue from a bounded pool.
  Only `ElementRef` (actor plus slot) leaves the actor, so the build has no `@unchecked Sendable`, and an AX call on a scanned element from the main actor does not compile.
- The traversal and visibility algorithms are pure and live in `HintCore` behind the `ElementReader` protocol, so pruning, budgets, and IPC cost are unit-tested against a fake tree.
- The session is a reducer with a written transition table, and the controller drains events run-to-completion, so it cannot re-enter.
- B measured a fact the grounding missed.
  On macOS 26.6.2 every status-level window (layer 25) is owned by Control Center, including third-party menu bar extras.
  B plans `AXExtrasMenuBar` reads for every regular and accessory app and anchors status items to any status-level window.
  A planned extras by window owner and would miss every third-party extra.
- B's automation hook posts the trigger as a real keystroke, so the Carbon hotkey path is exercised end to end.

### Grafted from A

1. Frames that are missing or empty never prune a container.
   A container with no frame (the Dock's `AXApplication` root, zero-size SwiftUI and web groups) passes its parent's clip through.
   A hint candidate still needs a non-empty visible frame.
2. Occlusion pruning inside the traversal.
   A subtree is skipped when one occluding window in front of its surface fully contains its clipped frame.
   It is injected into `Traversal.harvest` as a pure `isFullyCovered` closure built per root.
3. `scripts/check-invariants.sh`, adapted to B's files.
   It fails the build on any `@unchecked`, on role strings outside `RoleTable.swift`, on the AppKit conversion outside `Geometry.swift`, on AX IPC calls outside `Scan.swift`, and on any import in `HintCore`.
4. A mouse-down anywhere cancels hint mode, and the fixture records whether its app was active at press time, so the end-to-end run can tell "pressed in place" from "raised then pressed".

### Defects in B fixed during synthesis

- The Dock produced no hints because its root has no frame (fixed by graft 1).
- Status items were deduplicated by pid and frame, so an extra exposed by both its owner app and Control Center would get two stacked badges.
  Status items now deduplicate by frame alone, keeping the owner app's element before Control Center's.
- Search-predicate results bypassed the role table.
  They now go back through `RoleTable.rule(for:)`, and only `.hint` roles become candidates.
- Extras-only jobs shared two lanes with a 150 ms timeout across about 71 apps.
  They now get their own 50 ms messaging timeout (Vimac's number), set per application element.

### Rejected from A

- Planning `AXExtrasMenuBar` reads by status window owner, because Control Center owns every status window on macOS 26.
- One audited `@unchecked Sendable` box around `AXUIElement`, because the actor confinement gives the same parallelism with compiler enforcement.
- An automation hook that calls the controller's trigger method directly, because it skips the Carbon hotkey path.
- AXPress without raising the window.
  B's policy raises a background window first, as a physical click would, and that matches what the user asked for ("click").

## Tradeoffs accepted

- We accept no hints on custom-drawn native controls exposed as `AXGroup` or `AXImage`, in exchange for half the IPCs per node during the scan.
- We accept one `AXExtrasMenuBar` read for each of about 71 apps per scan, in exchange for finding third-party extras on macOS 26, where Control Center owns every status window.
- We accept that clicking a background element raises its window and changes the window order, in exchange for real-click parity and a visible result.
- We accept that the `AXRole` read turns on Chromium basic accessibility for the life of each Chromium or Electron app that has an exposed window, in exchange for web hints without `AXEnhancedUserInterface`.
- We accept that a Chromium app's first scan after launch may lack web hints, because Chromium waits 2 s before enabling full accessibility.
  In exchange, apps without web content never get the flag and its window-manager side effects.
- We accept judging partial occlusion at one point, the center of the visible frame.
  This keeps the cost at O(windows) per candidate, but a badge can sit over a covering window when an element's center is exposed and its corner is not.
- We accept conservative cover tests before and during the scan, where a rect counts as covered only when one front window contains it.
  Rects hidden by a union of several windows are still read, and the per-candidate test drops what they yield.
- We accept fresh probes and a fresh `AXUIElementCreateApplication` per scan, with no cache, in exchange for no state that outlives a session.
- We accept a generic `Target` parameter in the core, which can look like over-abstraction.
  It is what keeps AX handles out of the core and lets tests use `Int`.
- We accept losing disclosure triangles inside outline rows, because `AXRow` is a leaf hint.
- We accept Vimium's mixed-length labels, so a 100-hint screen has 7 one-letter labels and 93 two-letter labels.
- We accept one window that is both setup and Settings, with a title that changes after the first close.
  In exchange there is one activation-policy owner, one recorder, and one place that always says what needs the user.
- We accept scanning our own window on the main thread, 7 to 13 ms per scan in the e2e runs, while it is open.
  In exchange our own controls get labels, and badges for apps behind the window no longer draw over it.
- We accept no labels on our own menu bar and status item, in exchange for never running a menu's tracking loop inside a press on main.
- We accept that closing the window counts as skipping, and that a quit before closing shows setup again.
  In exchange the title and footer never change while the user reads them, and anything that still matters reopens the window by itself.
- We accept that coming forward may not take focus, in exchange for not depending on activation that macOS may refuse.
- We accept that the e2e run leaves the app window open until the script ends the app, in exchange for never writing the user's settings.

## Alternatives considered

- One `@unchecked Sendable` box around `AXUIElement` with traversal on the cooperative pool.
  It hides more of the concurrency story behind a smaller type, but it lets any actor call AX on any handle, and the blocking IPC starves the pool.
  It lost on enforceability.
- Occlusion through `AXUIElementCopyElementAtPosition` per candidate.
  That is exact, because the window server answers it, but it costs one IPC per candidate, and Vimac issue #436 reports it as too slow for visibility.
  It lost on cost.
- Vimac's hintable rule (any action other than a short ignore list) instead of a role table.
  That shape catches custom controls, but it doubles IPC, and hintability would live in action lists instead of one table.
  It lost on cost and on the single-table requirement.
- A key `NSPanel` with a local event monitor instead of an event tap, as Vimac does.
  It needs no tap lifecycle, but taking key focus closes open menus (Homerow #108) and moves focus away from the user's app.
  It lost on experience.
- An imperative overlay that adds and removes badge views per keystroke.
  It redraws less, but the overlay would keep a second copy of the board, which can drift from the reducer.
  It lost on single ownership.

## Open questions for the first trusted run

The DEBUG snapshot of one `scripts/e2e.sh` run answers each of these.

- On macOS 26, do third-party extras appear under their own app's `AXExtrasMenuBar`, under Control Center's, or under both?
  The plan asks every app and the filter dedupes by frame, so all three answers work.
  The dropped-duplicate list and the per-pid `statusItem` hints answer it.
- Does reading `AXRole` alone give Chrome's web areas search results on the first scan, or does Chrome need `AXEnhancedUserInterface`?
  The per-web-area result counts and the recorded flag writes answer it.
- Does the 50 ms timeout set on an app element bound the calls on elements derived from it, or only the calls on the app element itself?
  Per-pid durations of extras-only jobs answer it.
- Does `AXPress` on a background window's button act after the raise, and is the app active at press time?
  For web content the answer is no, and the raise is not the cause.
  A link in a visible, not frontmost Chrome window, whose onclick sets `document.title`, was tested three ways through the DEBUG perform report.
  The plan `raise, press` reported `press: success` and the title did not change.
  The plan `press` with the raise disabled reported `press: success` and the title did not change.
  The plan `raise, click` reported `frontmostAfter` true and the title changed.
  Web content is therefore always clicked.
  Native controls are not implicated by this evidence, and the fixture's press log still answers the question for them.
- Is a 300 ms budget enough for Chrome with many tabs open?
  Per-pid durations and stop reasons answer it.
- Does a ⇧⌘Space posted at the HID tap fire the Carbon hotkey at all?
  If it does not, the check "trigger shows hints" fails with "phase stayed idle", and that is the first suspect, before the scan.
- Does Carbon match the hotkey before session taps run?
  The design works with either order, because the tap passes the chord through, and the trigger-toggle check confirms it.

These need a product decision rather than a measurement.

- Should a background window be raised before pressing, or should the press act in place?
  Today `.window` surfaces always raise, under either policy.
- Are `AXGroup` controls that advertise `AXPress` common enough to justify a `.hintIfPressable` rule that reads action names for selected roles only?
- Should a display change while hints are showing cancel the session?
  Today each render lays out against the current displays.
- Should open context menus and pop-up menus (window layer 101) get hints?
  Today they occlude but are not scanned.
- Reading order gives the menu bar the one-letter labels.
  Should the frontmost window get them instead?
