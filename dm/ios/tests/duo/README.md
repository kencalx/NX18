# iOS layout and input harness (Duo harness)

This XCTest app compiles the production iOS gamepad, layout and hosting-controller code with inert host-runtime stubs. Its fixture `game_profile.h` supplies no game data, so the harness does not generate or require a game profile or extracted files.

The Simulator unit tests cover portrait and landscape layout, safe areas, valid and invalid division regions, 16:9 fitting and the Fill picture, touch hit ownership (the menu button against − / +), multitouch and video coordinates, pose-change input release, the in-game menu's layout pick and its live settings (picture, console mode, rumble, frame-rate counter) on the production root view controller, the menu button's showing and hiding (a double tap off the drawn controls and in Tap, not on a key; the start hint; VoiceOver or Switch Control turning on), touches while an offline HTML page is shown over the picture (a stub stands in for web_apple.m), the Picture row shown disabled at Stretch with its reason while Ultrawide holds Stretch (the saved choice kept), the home screen shortcuts (the start each gives against DM_LAUNCHER, the program record and the player's skip; a cold start's Guide opening the real settings screen with the manual, Launcher, Guide and Game on that screen, Guide while About this game or the iCloud Drive folder picker is up, driven by a hidden virtual controller, and Game, Launcher and Guide while the game runs, the in-game menu opening for them), the controller hints' button glyphs (which glyph a Nintendo, Xbox-style or PlayStation pad shows for a Switch button, and each glyph drawn as a disc with its label cut out in the colour given) and the launchers' flowing rails (a Core Animation slide only in a window, none under Reduce Motion), the in-game menu's rows and their reasons (a launcher model, the running game's notes and options a rule greys), the drawable's pixel cap and its size at the picture's render size where MetalFX does not run, the screen's size, rate and brightness cached when the scene connects, controller-to-player slots, stale controller callbacks, and preservation of a seeded controller-motion sample across layout changes. The optional virtual-controller case runs when Simulator exposes one. They use synthetic touches, controller snapshots, hinge statuses and division callbacks; they do not exercise UIKit's own hit-testing of real touches, the menu's presentation or system touch cancellation.

The harness uses synthetic host state and does not validate an installed game, physical hinge sensors or device motion.

From the repository root:

```sh
cd dm/ios/tests/duo
xcodegen generate --spec project.yml
xcodebuild test -project DuoHarness.xcodeproj -scheme DuoHarness \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

To build and install the harness app for a simulator:

```sh
DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/duo-harness.XXXXXX")"
xcodebuild build-for-testing -project DuoHarness.xcodeproj -scheme DuoHarness \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO
DEVICE=<simulator-udid>
APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/DuoHarness.app"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" org.nxnative.DuoHarness
```

## The settings screen

The harness compiles the real settings screen (Launcher.swift and its files). Without a launcher list it returns at once, as in an app without one, so the tests above start the game straight away. To show it, put a `launcher.json` (from `dm/games/settings.py`) in a folder, with an optional `art.jpg`, `logo.png` (shown in place of the name), `about.json` and `manual.pdf`, and launch with that folder as `DM_APP_DM`; `DM_HTML` points at a folder of offline guide pages:

```sh
SIMCTL_CHILD_DM_APP_DM=/path/to/sample SIMCTL_CHILD_DM_HTML=/path/to/html \
  xcrun simctl launch "$DEVICE" org.nxnative.DuoHarness
xcrun simctl io "$DEVICE" screenshot launcher.png
```

`SIMCTL_CHILD_DUO_PAD_SCRIPT=down,down,a,right` drives the screen with a hidden virtual controller (steps every 0.35 s after `DUO_PAD_DELAY` seconds, default 2: up, down, left, right, a, b, y, plus, l, r, wait; Switch buttons, so `a` is the pad's right button). The harness's app icon is the NX 18 icon (Resources, a link to docs/images/nx18), the screen's backdrop when there is no art.

## The in-game menu

`SIMCTL_CHILD_DUO_MENU_OPEN=<seconds>` opens the in-game menu that many seconds after the start, as a home screen shortcut does while the game runs: NX 18's panel (GameMenuPanel.swift), or the UIMenu with `SIMCTL_CHILD_DM_GAME_MENU=system`. With a launcher list and `SIMCTL_CHILD_DM_LAUNCHER=0` the game view starts at once and the panel has the live settings; a `DUO_PAD_SCRIPT` then drives the panel (it starts after `DUO_PAD_DELAY`, so give it a delay past the menu's), the virtual controller hiding the touch controls as a real one does.

For screenshots of the menu and its button over a picture: `SIMCTL_CHILD_DUO_BACKDROP=<file>` (placeholder art) or `=#RRGGBB` puts that picture over the empty game view, below the touch controls; `SIMCTL_CHILD_DUO_CHEATS=1` gives the harness a placeholder cheat file (made-up names in two sections, one that runs once, one that cannot run here, an always-on master), so the Cheats page shows; `SIMCTL_CHILD_DUO_PAD_KIND=nintendo` makes every controller present itself as a Switch Pro Controller, so the hints show a Nintendo pad's labels and the script's `a` / `b` / `x` / `y` are the pad's buttons of those names (without it the hidden virtual pad is an Xbox-style one).
