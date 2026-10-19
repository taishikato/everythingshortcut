# Research: Vimium for the whole screen on macOS

This page collects the source-backed research behind `docs/design.md`.
Every claim cites a pinned source file, an issue, or a changelog.
Claims marked unconfirmed had no source.

## Summary

- No tool we could verify labels elements in background windows of other apps.
  Cross-app occlusion is new work.
- Vimac batches role, position, and size into one `AXUIElementCopyMultipleAttributeValues` call per element.
  It prunes by the clipped parent frame, reads `AXVisibleRows` for tables, and asks web areas for their controls with one search-predicate query.
- Reading the app element's `AXRole` turns on Chromium's basic web accessibility.
  Chrome also honors `AXEnhancedUserInterface` after a 2 s quiet window, Electron honors `AXManualAccessibility`, and setting either back to false destroys the web tree.
- `_AXUIElementGetWindow` maps an AX window to its `CGWindowID`.
  It is private, and yabai, AltTab, and Rectangle still use it on macOS 26.6.2.
- AX calls block on Mach IPC into the target app.
  AltTab and Vimac call AX off the main thread and in parallel across apps, with bounded queues and short per-app timeouts such as Vimac's 50 ms for menu bar extras.
- A synthesized click on an inactive window may only activate it, while `AXPress` acts in place.
- The design departs from this research in one place.
  It decides hintability by role from one table instead of Vimac's action-name rule, which would double the IPC count per node.

## Sources

Pinned blob bases (paths below are relative to these; add `#L<n>` for lines).
- Vimac `ViMac-Swift/`: https://github.com/dexterleng/vimac/blob/ea8409cf032d110f69446b1a2950f2910c3d46fd/ViMac-Swift/
- AXSwift: https://github.com/tmandry/AXSwift/blob/e18a18453d135ad45809a384ee5139e05ea52def/
- Rectangle: https://github.com/rxhanson/Rectangle/blob/ed1bcf7d62ad08014bb051b7ee894c511c8e2a46/
- yabai: https://github.com/koekeishiya/yabai/blob/dd845723416f5fe92af49fad5ebab00369e07edd/
- AltTab: https://github.com/lwouis/alt-tab-macos/blob/240e3fff4db30c943a68ee0ec1399fe1c1301a94/
- Chromium (main when fetched): https://github.com/chromium/chromium/blob/37f6c4b5eddba9bc3a25b0ac6c951783dc5ffbad/
- Electron (main when fetched): https://github.com/electron/electron/blob/37d0d2b4cee4ecc07571e0546b20990a449f66f5/

### Headline
No tool I could verify labels elements in background apps' windows.
Vimac scans the frontmost app's focused window only.
Homerow and Shortcat are unconfirmed but evidence says the same.
Cross-app z-order occlusion is original work for us.

### 1. Vimac
**Scope.** Frontmost app's focused window, that app's menu bar, every app's `AXExtrasMenuBar`, and Notification Center (`Accessibility/HintMode/HintModeQueryService.swift:35-55`; `ModeCoordinator.swift:132-133,171-182`).
README says "frontmost window".
Open issues: #379 (other apps' windows ignored), #309 (multi-display), #339 (Dock PR unmerged); #436 notes AX element-at-position was too slow for window visibility.
Own process is skipped as it crashes (`ModeCoordinator.swift:135-141`).

**(a) Enumeration.** One `AXUIElementCopyMultipleAttributeValues` per element for size, position, role (options 0) plus a separate action-names call (`Accessibility/Element.swift:20-36`; AXSwift `Sources/UIElement.swift:229-249,490-492`).
Depth-first walk over `AXChildren`, pruning children outside the parent's clipped frame (`Accessibility/HintMode/TraverseGenericElementService.swift:29-65`).
`AXVisibleRows` replaces children for AXTable/AXOutline (same file, 67-73).
For `AXWebArea` advertising `AXUIElementsForSearchPredicate`, one query returns all Button/CheckBox/Control/Graphic/Link/RadioGroup/TextField descendants with `AXVisibleOnly`; per-key fallback for old Chromium (`TraverseSearchPredicateCompatibleWebAreaElementService.swift:75-120`, Chromium CL 2773520).
Four queries (window, menu bar, extras, notification center) run on four concurrent `Thread`s, merged in fixed order (`HintModeQueryService.swift:57-111`); one thread per window.
Timeouts: global 1s (`AppDelegate.swift:82`), 0.05s on every app for extras (`QueryMenuBarExtrasService.swift:14-22`, wraps `AXUIElementSetMessagingTimeout`, AXSwift `Sources/UIElement.swift:566-569`).

**(b) Hintable.** Any element with at least one action besides AXShowMenu, AXScrollToVisible, AXShowDefaultUI, AXShowAlternateUI; never AXWindow/AXScrollArea; AXRow with no hintable descendants also qualifies (`Accessibility/ElementTree.swift:86-107`).
No role allowlist.

**(c) Web AX enablement.** Two default-off prefs: set `AXEnhancedUserInterface` ("Emulate VoiceOver") or `AXManualAccessibility` ("Electron Support") on the frontmost app at each app switch (`Accessibility/AXEnhancedUserInterfaceActivator.swift:35-38`, `AXManualAccessibilityActivator.swift:35-38`, `AppDelegate.swift:175-223`).
Preferred path: read `AXRole` of the app element, flagged as a Chromium trigger hack (`ModeCoordinator.swift:175-176`).
`docs/state-of-non-native-support.md` (2021-04-22): Chrome and Electron 12+ need no flags; Firefox and CEF (Spotify) still do.
Documented side effects: VoiceOver emulation "breaks window managers", the Electron flag causes slow performance and high CPU (same doc; `Preferences/ExperimentalPreferenceViewController.swift`).
Re-enabling on focus change froze Chrome/VS Code about a second, so PR #343 stopped disabling on focus loss.

**(d) Click.** Synthesized CGEvent only, never AXPress: mouseMoved, then leftMouseDown/Up with clickState 1 and cleared flags, via `.cghidEventTap` (`Utils.swift:16-36`; `Modes/HintModeController.swift:318-345`).
AXLink clicks at (x+5, maxY-5).
Cursor hidden via private CGS `SetsCursorInBackground` + `CGDisplayHideCursor` (`HideCursorGlobally.m:13-28`).
Cursor is not restored (issue #412; #193).
No inactive-window handling.

**(e) Keys.** Not an event tap: key `NSPanel` (`.nonactivatingPanel`, `.statusBar`, `ignoresMouseEvents`, `canBecomeKey`) plus `NSEvent.addLocalMonitorForEvents(.keyDown)` returning nil (`OverlayWindow.swift:11-27`; `HintModeController.swift:14-30,309-316`).
Space rotates overlapping hints.
`GlobalEventTap` (session, head-insert, default tap, re-enabled on timeout) is constructed only in `KeySequenceListener.swift:59` and `Activation/HoldKeyListener.swift:33`, i.e. activation (`GlobalEventTap.swift:66-100`).
Default shortcut Ctrl-F (`Bindings/KeyboardShortcuts.swift:17`); README default is hold Space.

**(f) Labels.** Port of Vimium's `AlphabetHints`: BFS prefix expansion, prefix-free, sorted, uppercased (`AlphabetHints.swift:14-29`).
Default alphabet `sadfjklewcmpgh` (`UserPreferences.swift:41`).
Assigned in discovery order.

**(g) Performance.** Maintainer: typical traversal about 0.1s (issue #221).
Mail with large inbox, Preview with 3000 pages: seconds, due to huge `AXChildren` (#221).
Reports of 2s (#449) and 10s on one machine (#236, unreproduced).
PR #190 (search predicate) was the big web win.

### 2. Homerow and Shortcat
**Homerow** (Vimac's successor).
Default Cmd-Shift-Space, scroll Shift-Cmd-J (README at https://github.com/nchudleigh/homerow).
Search-first; a labels-only mode shows labels for all elements.
Background-app labelling: unconfirmed, likely no.
Issue #81 lists what it highlights as the app's UI, app menus, menu bar icons, Dock; #127 and #69 request window-switch labels as missing (https://github.com/nchudleigh/homerow/issues/81).
Changelog 1.5.0 adds Mission Control and better menu bar detection (https://homerow.app/changelog); #195 reports missing menu bar items on macOS 26.2.
Click method undocumented; #93 asks cursor restore, implying a real cursor move.
Issue #108: its activation closes open context menus.
Electron: 0.21 Alpha supports all Electron apps with a per-app Exceptions list that stops it enabling accessibility (https://mac.softpedia.com/progChangelog/Homerow-Changelog-143288.html); 1.5.3 fixes Chromium accessibility being auto-disabled.
Issue #124: Arc drops its AX tree after inactivity, so re-assert per scan.
Issue #189: huge trees freeze the target.
No Rectangle/yabai side-effect docs found.

**Shortcat.** Default Cmd-Shift-Space since v0.10.1 (https://shortcat.app/changelog-raw).
Search model: windows and apps of all open applications are searchable by title (v0.9.0); elements are the frontmost app plus menu bar (v0.8.0) and Dock (v0.7.4); background-window element labelling unconfirmed.
v0.9.0 states it forces apps to expose accessibility, can affect performance, and makes VS Code emit audio cues.
v0.10.2 improves some window-manager compatibility.
Checkboxes and radios are pressed, other things clicked (v0.6.2).
Exact attributes unconfirmed (closed source).

### 3. Chromium and Electron enablement
- **Electron: set `AXManualAccessibility` true** (docs: `docs/tutorial/accessibility.md:25-57`).
  Added by commit 94dd068e1 (PR #10305, merged 2017-09-11) because `AXEnhancedUserInterface` was reserved for VoiceOver.
  Contained in v1.8.1 and v2.0.0-beta.1, not v1.8.0; first release unconfirmed.
  Handler: `shell/browser/mac/electron_application.mm:222-268` (also accepts `AXEnhancedUserInterface`, debounced, line 328+).
- **Chrome: set `AXEnhancedUserInterface` true.** Chromium ignores `AXManualAccessibility`.
  It waits for a 2-second quiet window before enabling full mode; set-false disables immediately (`chrome/browser/chrome_browser_application_mac.mm:428-481`).
  So set-then-scan sees an empty web tree for about 2s.
- **Newer: read the app element's `AXRole`.** Enables `kAXModeBasic` (native APIs + web contents) when no mode is active (`chrome_browser_application_mac.mm:488-505`; `ui/accessibility/ax_mode.h:238-239`).
  Feature `kSonomaAccessibilityActivationRefinements` (`content/public/common/content_features.cc:1559-1565`, off by default) would reduce this to native APIs only, which leaves web content inaccessible (`ax_mode.h:34-39`).
  Origin: Chromium CL 2680102 (Feb 2021); Electron 12+.
- **Side effects of `AXEnhancedUserInterface`.** Animated window moves/resizes yield wrong frames, so Rectangle clears it around adjustments and restores it only for non-Chromium apps (`Rectangle/AccessibilityElement.swift:212-226,690-723`; `TerminalCommands.md:583-585`), yabai clears and always restores (`src/misc/helpers.h:511-530`).
  Resetting is established practice for window managers, not for scanners; for Chrome, setting false destroys the web tree.

### 4. `_AXUIElementGetWindow`
Signature `AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *)` (uint32).
Declared in Rectangle `Rectangle/Rectangle-Bridging-Header.h:7`, yabai `src/misc/extern.h:8`, AltTab `src/macos/api-wrappers/ApplicationServices.HIServices.framework.swift:1-5` (via `@_silgen_name`).
Used at Rectangle `Rectangle/Utilities/AXExtension.swift:95`, yabai `src/misc/helpers.h:499-504`, AltTab `src/macos/api-wrappers/AXUIElement.swift:96-99`.
All three had commits in Jun-Oct 2026 and AltTab's `src/main-thread-ipc.md` audit is on macOS 26.6.2, so it works today.
Private API.
Caveat: for a descendant it returns the containing window's id (AltTab `src/switcher/state/Applications.swift:770-780`).

### 5. Traversal performance and threading
No published benchmark for `AXUIElementCopyMultipleAttributeValues` found; it is used by Vimac and AltTab (`AXUIElement.swift:120-122`); the batching benefit (fewer Mach round trips) is inferred.
Frame pruning and `AXVisibleRows` are Vimac's techniques (see 1a).
`AXChildrenInNavigationOrder` exists in Chromium (`ui/accessibility/platform/ax_platform_node_cocoa.mm:313-314`), no measured benefit or user found; `AXVisibleChildren` unused by Vimac (benefit unconfirmed).
Thread safety: Apple states nothing I could find (unconfirmed).
Empirically safe: Vimac calls from plain threads, concurrently across apps; AltTab runs every AX call off-main on bounded queues of 8/6/6 workers with at most 3 in flight per pid, one call per key, 1s global timeout (default 6s) and 0.25s per-app timeouts, retrying timeouts in a quarantine pool because a stuck app pins a worker (~64-thread limit); caller QoS is donated to the target app (`src/macos/AXCallScheduler.swift:1-70`, `AXUIElement.swift:11-15`, `Window.swift:500`).
AX calls on elements in our own process must run on main (`AXUIElement.swift:73-80`).

### 6. Click on a background window
Apple's Event Handling Guide says a first mouse-down in a non-key window activates it rather than reaching the view, unless the view opts in via `acceptsFirstMouse:` (https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingMouseEvents/HandlingMouseEvents.html).
Which stock controls opt in: unconfirmed.
Vimac avoids the case (frontmost only); Shortcat uses a press action for checkboxes; Homerow undocumented.
`CGEventPostToPid` behaviour on background windows: unconfirmed.
A forum thread reports HID-tap clicks needing prior focus after Big Sur (https://developer.apple.com/forums/thread/685618), a lead only.

### Decisions this evidence supports
1. Batch `size, position, role` in one `AXUIElementCopyMultipleAttributeValues`; read actions separately; reuse Vimac's hintable rule.
2. Prune by parent-clipped frame and by the window's visible rect; `AXVisibleRows` for tables; search predicate for web areas with per-key fallback.
3. Build cross-app occlusion ourselves: map hits to CGWindowIDs with `_AXUIElementGetWindow` and test against `CGWindowListCopyWindowInfo` z-order.
4. AltTab-style bounded per-pid queues, 1s global timeout, 0.05-0.25s for background apps, skip own pid.
5. Read `AXRole` first; set `AXManualAccessibility` / `AXEnhancedUserInterface` only for apps with an empty web area, per-app exception list, leave on rather than toggling, tolerate 2s Chrome delay and Arc tree expiry.
6. Own the keyboard with an active CGEventTap, not a key panel (key panels close menus, Homerow #108); keep Vimac's non-activating overlay recipe.
7. Prefer `AXPress` when advertised; else CGEvent via HID tap; for non-key windows raise first and test per app.
   Restore the cursor.
8. Vimium-style prefix-free labels; consider position-sorted assignment.
9. Verify menu bar extras on macOS 26 and Dock via the `com.apple.dock` AX tree (both unconfirmed).
