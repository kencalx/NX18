# NX 18 Beam

Beam is NX 18's Mac app. It builds your legally owned and acquired games into apps for your iPhone, iPad and Mac. It includes no games, keys or firmware.

Beam is a front end in the sense of [docs/frontends.md](../docs/frontends.md): it runs NX 18's build script (`scripts/build_ipa_from_nsp.py`) and relies only on what that page promises.

**Status:** B1, the app's first form. It can do the following:

- **Find NX 18:** it finds the NX 18 folder and a Python 3.12 or newer that has the build's modules.
- **Add games:** you can drop a folder, a `.nup` or an `.nx` on the window or the Dock icon, or choose one.
- **Identify games:** for each game it shows what `--identify` says: name, system, versions with their build IDs, DLC, and whether NX 18 has tested it.
- **Build:** it builds for iPhone and iPad or for Mac, with the stages, progress and messages from the script's events, and a Stop button.

From B2 (first part):

- **Before a build:** Beam checks the space (twice the game plus 10 GB where the build folder goes). On battery, a first build asks: build now, or when plugged in.
- **During a build:** the Dock icon shows its progress, a notification says when it ends, and known failures are explained in a sentence. Show Details opens the build's `logs/`.
- **Play:** a game built for Mac starts at once (`DM_LAUNCHER=0`: the settings window is skipped). While it plays, running builds move to background priority, the script and its tools alike, and come back after. A game that ends because macOS took the GPU away (70), or by a crash, says so.

From B2 (second part):

- **Settings:** a game built for Mac shows its settings in Beam: the app's own `dm/launcher.json`, drawn by NX 18's Gate panel with the same rules as the game's window. Choices are kept in the app's own preferences, as the window keeps them, so the game starts with them from Beam or from Finder. Beam never puts them into its own environment.
- **Beam Home** (View > Beam Home, ⌃⌘H): the library full screen. Use a controller or the arrow keys: the D-pad moves, A plays, Y opens the settings, B leaves.
- **Storage** (Window > Storage): per game, its files, its build folder and its app. A build folder can go to the Trash; the game's own files are never touched.

From B3 (first part):

- **Install on iPhone and iPad** with the Apple Developer account in Xcode (Xcode > Settings > Apple Accounts; Beam never asks for a password and never shows the team ID). Beam prepares the game's Xcode project in its build folder, Xcode signs it, and `devicectl` installs it. Each game keeps its bundle ID across reinstalls; an NX Play install of the same game is replaced, not doubled.
- **Memory entitlements are mandatory.** Every NX 18 app asks for the Increased Memory Limit and Extended Virtual Addressing. Beam never lets a build drop them (`DM_ENTITLEMENTS` is removed from the build's environment), and installs a game only when its signature and profile carry both. A free Apple account (Personal Team) cannot have them, so Beam does not install with one; the IPA and the GetMoreRam steps are the way there.
- **The game page** lists each install with its days left, offers Renew within 2 days of expiry, and opens the game on the device. For other sideloading tools it shows the IPA (Show in Finder, AirDrop).
- **Slots and swaps** for free accounts (3 apps per device, the least recently played game swapped out after its save is copied to the Mac, the save put back at its next install) are in the code; with the memory entitlements mandatory, a free account does not install, so they wait for a free route that can carry them.

- **Your own certificate** (Settings > Signing for iPhone and iPad): add your Apple Developer certificate (`.p12`) and a provisioning profile made for it, then choose them under Sign with. macOS asks for the certificate's password in its own window; Beam never sees it. The certificate goes into Beam's own keychain (`~/Library/Application Support/NX 18 Beam/Signing/`, its password in the login keychain), never the login keychain, and the keychain search list is left as it was. Beam reads each profile and says plainly when it has expired, was made for another certificate, does not list the device, or does not grant both memory entitlements. It then re-signs the built IPA's app (bundle ID, embedded profile, the profile's entitlements, nested code first) and installs it as above.

From B4 (first part):

- **Mods** on a game's page: frame-rate and Ultrawide code patches only, from sources you add in Settings ([docs/beam-sources.md](../docs/beam-sources.md); Beam ships none) or a mod file you got yourself. Each is checked before it is kept: the game's exact build, the SHA-256 its source gives, patch files only. Kept in Beam's folder per game with its credit (`beam-mod.json`), passed to builds with `--mods`; the launcher's switches turn it on and off. Before the first Mac start after a mod change, Beam copies the save.
- **Manual:** the game's PDF, passed with `--manual`.

From B4 (second part):

- **Cheats:** your own Atmosphère cheat file, named after the game's build (Beam never downloads cheats; one for another build is refused, naming both versions). Kept in the game's mods folder so an iPhone build packs it, and copied into the Mac app's cheats folder with switches per cheat and a master switch, written as the host reads them (`<build ID>.enabled`, `.cheats-off-<title ID>`) and never while the game runs.
- **Art:** with a SteamGridDB key (Settings > Art, kept in the Keychain on this Mac only), choose key art, a logo and an icon on a game's page. Beam calls SteamGridDB itself; the key is never given to the build (`STEAMGRIDDB_KEY` is removed from its environment). Picks are kept in Beam's folder and passed with `--art`, `--logo`, `--icon`.
- **My files:** your own guides and maps for a game, in Beam's folder (never packed into the app). Send to a device Beam installed on copies them into the app's `Documents/Companion`.

From B3 (rest):

- **Bring your NX Play library** (on the welcome screen, and File > Bring Your NX Play Library): Beam reads NX Play's games folder and keys path from its settings, adds each game folder where it is (nothing moved, copied or deleted; NX Play keeps working), and reads them one at a time. A game NX Play installed on a device keeps its bundle ID, so installing it from Beam replaces that app and keeps its save.
- **Step by step for other tools** (next to Show IPA): SideStore, AltStore Classic and Sideloadly, from Developer Mode to the Increased Memory Limit with GetMoreRam, the 7-day refresh and "never delete the game first". LiveContainer is not offered until NX 18's LiveContainer check passes on a device.

Still to come: polish and the showcase (B5).

## Building Beam

You need Xcode 27.2 or 27.3 and XcodeGen (`brew install xcodegen`).

```bash
cd beam
xcodegen generate
open Beam.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project Beam.xcodeproj -scheme Beam -derivedDataPath build/dd build
```

A local build is signed ad hoc. Beam needs macOS 27.2 or later and Apple silicon.

### Tests

```bash
xcodebuild -project Beam.xcodeproj -scheme Beam -derivedDataPath build/dd test
```

The tests cover the script's events, the runner (exit codes, stderr, output larger than a pipe holds, Stop), the command lines Beam passes, Play with a stand-in Mac app, the space check and build priority. They need no game, keys or NX 18 build.

Two tests use a real game and run only when asked:

- A real `--identify`, which reads the game and writes nothing beside it:

  ```bash
  TEST_RUNNER_BEAM_TEST_NX18=~/NX18 TEST_RUNNER_BEAM_TEST_GAME=<a folder, .nup or .nx> xcodebuild … test
  ```

- A real Mac build into a build folder of your choosing:

  ```bash
  TEST_RUNNER_BEAM_TEST_BUILD_GAME=<game> TEST_RUNNER_BEAM_TEST_BUILD_WORK=<build folder> TEST_RUNNER_BEAM_TEST_BUILD_OUT=<.app> xcodebuild … test -only-testing:BeamTests/LiveBuildTests
  ```

## Shared UI

Beam compiles NX 18's own SwiftUI files from `dm/ios/Sources` (the look, glass, font, button glyphs, the NX 18 card and Profile, and the Gate panel), the same set the Mac launcher compiles (`dm/mac/pack_app.py`). `Sources/Shims.swift` stands in for the one piece the Mac launcher provides. A change to those files reaches Beam at its next build.

## Releases

Releases are a Developer ID signed and notarized DMG. `scripts/release.sh` makes one. Its header has the one-time setup:

- a `Config/Local.xcconfig` with the team ID, which git ignores;
- a notarytool keychain profile.

Run `scripts/release.sh --check` to check the setup without building.

## Where Beam keeps things

- **The library:** `~/Library/Application Support/NX 18 Beam/library.json`.
- **Settings:** Beam's preferences hold the NX 18 folder, the keys file's location (never its contents) and the build space.
- **Builds:** each game's build folder is `build/` beside its files, unless you choose a build space in Settings. Beam never uses NX Play's `<title ID>_build` folders.
- **Removing a game:** this removes it from the library only. Its files are never touched.

## Credits

Beam's design drew on [NX Play](https://github.com/varyform/nx-native-wrapper) by Oleh Khomei (varyform), MIT licensed. Beam is written for NX 18 and carries none of NX Play's code.
