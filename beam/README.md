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
- **Play:** a game built for Mac starts at once (`DM_LAUNCHER=0` in the launch environment: the settings window is skipped, whatever the game's env.txt files or its "Show this window at launch" say), with `DM_STARTED_BY=beam`, so the game's in-game menu offers **Exit and return to Beam**, which quits the game and brings Beam back to the front. The Beam dashes sweep across the display Beam is on as it starts (`Views/LaunchSweep.swift`, about a second, started once the game's process runs so it never delays it; it fades as soon as the game comes to the front; Reduce Motion: a short fade). While it plays, running builds move to background priority, the script and its tools alike, and come back after. A game that ends because macOS took the GPU away (70), or by a crash, says so.

From B2 (second part):

- **Settings:** a game built for Mac shows its settings in Beam: the app's own `dm/launcher.json`, drawn by NX 18's Gate panel with the same rules as the game's window. Choices are kept in the app's own preferences, as the window keeps them, so the game starts with them from Beam or from Finder. Beam never puts them into its own environment. The Cloud saves door says "NX 18 folder" for a game whose saves go there (`NX18CloudSaves.place`, the rule `dm/mac/launcher.c` uses: the card's choice, else the NX 18 folder when one is connected and the game has no own folder), and the game's page has a **Cloud saves** line saying where the save lives; both read the app's preferences and the `nx18-folder` line, nothing else. A folder chosen on the Cloud saves page while the saves are in the NX 18 folder becomes the game's own (`nx18.cloud = own`) without a move: the game compares the saves at its next start, and the NX 18 folder's copy stays. A game's first sync through a folder on this Mac waits for iCloud in the game's own launcher (`dm/mac/MacFirstSync.swift`), also when Beam's Play starts it (`DM_LAUNCHER=0`: an alert only after half a second); Beam passes nothing for it.
- **Beam Home** (View > Beam Home, ⌃⌘H): the library full screen. Use a controller or the arrow keys: the D-pad moves, A plays, Y opens the settings, B leaves. − (or a click on the profile chip by the clock) opens the Profile, as in Settings; B or Done closes it. X renews what is about to expire (Renew All). The hints bar at the foot shows only the buttons that do something on the screen showing (Home, the Profile sheet, the Album, the viewer, a trim), drawn as the connected pad's own glyphs (`BeamHintsBar` in `Views/BeamLook.swift`, NX 18's `NXPadGlyphs`); with no controller the letter keys A, B, X, Y and − do what the hints say (Return, Space and Escape too). Menu sounds (Settings, off by default) also stay off while the Mac's "Play user interface sound effects" is off. The grid fades up once as Home opens (a fade only under Reduce Motion). The top bar's capsules, the hints bar and the viewer's buttons are Liquid Glass through NX 18's `nx18Surface`, solid under Reduce Transparency, Increase Contrast, Low Power Mode or heat. The controller arrives as GameController events, not a polling loop, and is read only while Home shows and Beam is in front; the clock ticks on the minute, only then too.
- **Album** (`Views/AlbumSection.swift`, `Views/AlbumBrowser.swift`, `Views/AlbumViewer.swift`, `Views/HomeAlbum.swift`, `Model/AlbumGallery.swift`): a game page's captures by day and Beam Home's all-games Album by game, a viewer (share, Show in Finder, Move to Trash, trim a recording into a copy beside it), thumbnails made off the main thread and cached by path, size and date. The folders are read on open and when Beam comes back to the front; no watching. In Home, Home's presses go to the Album while it is open, and the controller's capture button opens it.
- **Storage** (Window > Storage): per game, its files, its build folder and its app. A build folder can go to the Trash; the game's own files are never touched.

From B3 (first part):

- **Install on iPhone and iPad** with the Apple Developer account in Xcode (Xcode > Settings > Apple Accounts; Beam never asks for a password and never shows the team ID). Beam prepares the game's Xcode project in its build folder, Xcode signs it, and `devicectl` installs it. Each game keeps its bundle ID across reinstalls; an NX Play install of the same game is replaced, not doubled.
- **Memory entitlements are mandatory.** Every NX 18 app asks for the Increased Memory Limit and Extended Virtual Addressing. Beam never lets a build drop them (`DM_ENTITLEMENTS` is removed from the build's environment), and installs a game only when its signature and profile carry both. A free Apple account (Personal Team) cannot have them, so Beam does not install with one; the IPA and the GetMoreRam steps are the way there.
- **The game page** lists each install with its days left, offers Renew within 2 days of expiry, and opens the game on the device. For other sideloading tools it shows the IPA (Show in Finder, AirDrop).
- **Expiry reminders:** from 2 days before an install expires, the game's Home tile and library row say so ("Expires tomorrow on <device>", "Expired on <device>: renew"). One notification is scheduled for 10:00 the day before, when the install is recorded or renewed; it is replaced at a renewal and withdrawn when the install goes. Nothing polls. **Renew All** (the library's toolbar, View > Renew All, X or the button in Home) renews each due install on a connected device, one at a time, then says in plain words which devices were not connected.
- **Slots and swaps** for free accounts (3 apps per device, the least recently played game swapped out after its save is copied to the Mac, the save put back at its next install) are in the code; with the memory entitlements mandatory, a free account does not install, so they wait for a free route that can carry them.

- **Your own certificate** (Settings > Signing for iPhone and iPad): add your Apple Developer certificate (`.p12`) and a provisioning profile made for it, then choose them under Sign with. macOS asks for the certificate's password in its own window; Beam never sees it. The certificate goes into Beam's own keychain (`~/Library/Application Support/NX 18 Beam/Signing/`, its password in the login keychain), never the login keychain, and the keychain search list is left as it was. Beam reads each profile and says plainly when it has expired, was made for another certificate, does not list the device, or does not grant both memory entitlements. It then re-signs the built IPA's app (bundle ID, embedded profile, the profile's entitlements, nested code first) and installs it as above.

From B4 (first part):

- **Mods** on a game's page: frame-rate and Ultrawide code patches only, from sources you add in Settings ([docs/beam-sources.md](../docs/beam-sources.md); Beam ships none) or a mod file you got yourself. Each is checked before it is kept: the game's exact build, the SHA-256 its source gives, patch files only. Kept in Beam's folder per game with its credit (`beam-mod.json`), passed to builds with `--mods`; the launcher's switches turn it on and off. Before the first Mac start after a mod change, Beam copies the save.
- **Manual:** the game's PDF, passed with `--manual`.

From B4 (second part):

- **Cheats:** your own Atmosphère cheat file, named after the game's build (Beam never downloads cheats; one for another build is refused, naming both versions). Kept in the game's mods folder so an iPhone build packs it, and copied into the Mac app's cheats folder with switches per cheat and a master switch, written as the host reads them (`<build ID>.enabled`, `.cheats-off-<title ID>`) and never while the game runs.
- **Art:** with a SteamGridDB key (Settings > Art, kept in the Keychain on this Mac only), choose key art, a logo and an icon on a game's page. Beam calls SteamGridDB itself; the key is never given to the build (`STEAMGRIDDB_KEY` is removed from its environment). Picks are kept in Beam's folder and passed with `--art`, `--logo`, `--icon`.
- **My files:** your own guides and maps for a game, in Beam's folder (never packed into the app). Send to a device Beam installed on copies them into the app's `Documents/Companion`.
- **Keep My files in the NX 18 folder** (Settings > Profile, off until turned on; `MyFilesPlace.swift`): with an NX 18 folder connected, each game's My files live in `<NX 18 folder>/<TITLE ID>/Documents`, beside its `Captures`, so the game apps on every device connected to that folder list them while the game runs (`dm/ios/Sources/GameDocuments.swift`). Turning it on moves Beam's files there; turning it off moves back only the files Beam put there (noted in `My Files/.in-nx18-folder.json`), and leaves what another Mac or the player put in the folder for the other devices. Moves are coordinated and never overwrite: a name already taken gets " 2". Nothing is deleted. A file still in iCloud is asked for and moved when it arrives (the game's page settles its files each time it opens). With no folder connected, files stay in Beam until one is. Add Files writes to wherever My files are now; Send My Files still works, for a device whose game app has not connected the folder.

From B3 (rest):

- **Bring your NX Play library** (on the welcome screen, and File > Bring Your NX Play Library): Beam reads NX Play's games folder and keys path from its settings, adds each game folder where it is (nothing moved, copied or deleted; NX Play keeps working), and reads them one at a time. A game NX Play installed on a device keeps its bundle ID, so installing it from Beam replaces that app and keeps its save.
- **Step by step for other tools** (next to Show IPA): SideStore, AltStore Classic and Sideloadly, from Developer Mode to the Increased Memory Limit with GetMoreRam, the 7-day refresh and "never delete the game first". LiveContainer is not offered until NX 18's LiveContainer check passes on a device.

The Profile:

- **Profile** (on the welcome screen, and Settings > Profile): create the name and picture the games show, or use the one in the NX 18 folder in iCloud Drive. Beam edits the Mac's own Profile (`~/Library/Application Support/nxnative/Profile`), which every NX 18 Mac game reads at its start (`dm/mac/launcher.c`), so a Mac game Beam builds or plays has it with nothing passed. Connecting a folder writes the Mac games' `nxnative/nx18-folder`, then brings the folder's Profile here when it is newer, else sends this Mac's there. It is the one NX 18 folder: the Album reads captures from it too (an earlier Beam's own Album folder becomes it, when the Mac had none).
- **Every iPhone and iPad install carries the Profile:** before signing, Beam puts a copy in `<App>.app/NX18ProfileSeed` (Xcode signing: the `DM_PROFILE_SEED` build setting, which the project's Copy game resources phase reads; a certificate: the unpacked app). The app takes it on its first start, or when Beam's is newer; a change made on the device since is kept (`NX18Profile.applySeed`). It is not the NX 18 folder: each game app still asks for that once. Renew carries the Profile as it is then. The IPA for other tools (Show IPA, AirDrop, SideStore) carries it too: Beam passes `--profile-seed` and the build packs it into the app before the IPA is zipped (`build_ipa.sh` `DM_PROFILE_SEED`), so the tool's signature seals it. No Profile on the Mac: no seed.
- The name and picture are never logged (`profile in the install: on` / `off` only) and go nowhere but your own devices and iCloud Drive.

Rebuild only what changed (an idea from Cartouche; Beam's own code):

- **Update available: rebuild** on a game's Home tile, its library row and its page, when the NX 18 checkout Beam builds with changed since the game's last build. Each build records the checkout it was made from (`BuildRecord.nx18`: the git commit, a digest of uncommitted changes, `DMSH_CHAIN`). A new shader chain marks every game; else a changed file marks a game when it goes into its app: its own profile (`dm/games/<its title, profile or program ID>/`) or anything else (host, graphics, app code, build scripts, `dm/games`' shared files), which goes into every app. Left out: `docs/`, `beam/`, `.github/`, `.githooks/`, test folders, `scripts/release/` and the root's text files. When git cannot say, the game is marked. A build from before this records nothing: Beam takes the commit the checkout's reflog had at its time, or marks it.
- Checked when Beam comes to the front (at most once a minute) and after each build; no polling.
- **Rebuild Updated Games** (below the games, and in the File menu) builds the marked games three at a time, each group done before the next starts, with the target and version of each game's last build; the Mac is kept awake meanwhile (`ProcessInfo.beginActivity`, idle sleep only). **Rebuild Updated Games Tonight** runs it once at 1 AM, keeping the Mac from idle sleep until then; on battery the builds wait for the power adapter. Neither adds a settings row. Installs made from Beam (Xcode or certificate) are not marked: Renew rebuilds them.

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

### The app icon

`Resources/AppIcon.icon` is a layered Liquid Glass icon in Icon Composer's format: a charcoal fill and two glass groups, the NX 18 mark (the NX, the X's coral stroke, the 18 pill) and the beam (the B's stem and bowl, the dashes), one SVG each in `Assets/`. macOS draws its light, dark, clear and tinted looks from it, and Xcode compiles it into `Assets.car` and `AppIcon.icns`. It is generated, with no Icon Composer step: change the drawing in `docs/images/nx18/make_logo.py` (`beam_icon_layers`, `beam_icon_json`), then

```bash
python3 docs/images/nx18/make_logo.py   # the logos, and Resources/AppIcon.icon
swift beam/scripts/make_icons.swift     # the welcome title (BeamTitle)
```

To see it without building, Xcode's `ictool` renders any look, for example `"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" beam/Resources/AppIcon.icon --export-image --output-file icon.png --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1` (renditions: Default, Dark, ClearLight, ClearDark, TintedLight, TintedDark).

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

Releases are a Developer ID signed, notarized and stapled DMG on the NX 18 repository's GitHub releases, tagged `beam-<version>` (for example `beam-0.2`). Beam's update check reads those releases; **Install and Relaunch** downloads `NX18-Beam-<version>.dmg`, checks its SHA-256, checks that the app inside is Beam at that version, signed by the same team and notarized, then swaps it in. A local build has no team, so it only shows the release's link.

**One-time setup** (on the Mac that signs releases):

1. Put the **Developer ID Application** certificate in the login keychain (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application).
2. `cp Config/Local.xcconfig.example Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` (git ignores the file; the script never prints the team ID).
3. Store the notary credentials yourself: `xcrun notarytool store-credentials beam-notary --apple-id <Apple ID> --team-id <team ID>`. It asks for an app-specific password (account.apple.com) and keeps it in the keychain; the script only names the profile.
4. `gh auth login` with access to kencalx/NX18.
5. `scripts/release.sh --check` checks all of it.

**Each release:**

1. Raise `MARKETING_VERSION` (the tag's version) and `CURRENT_PROJECT_VERSION` in `Config/Beam.xcconfig`, commit, and push the commit.
2. `scripts/release.sh` builds Release from that clean commit, notarizes and staples the app and the DMG, and writes `build/release/NX18-Beam-<version>.dmg` and its `.sha256`. Keep `build/release/Beam.xcarchive` for its symbols.
3. `scripts/release.sh --publish` makes a **draft** release `beam-<version>` at that commit with both files. Check it on GitHub, then press Publish; players see it only then.

`scripts/release.sh --unsigned [--version V] [--out DIR]` is a dry run without the Developer ID: an ad hoc signed DMG, its `.sha256` and a local `releases.json` feed, with no notarization and no upload.

## Where Beam keeps things

- **The library:** `~/Library/Application Support/NX 18 Beam/library.json`.
- **Settings:** Beam's preferences hold the NX 18 folder, the keys file's location (never its contents) and the build space.
- **Builds:** each game's build folder is `build/` beside its files, unless you choose a build space in Settings. Beam never uses NX Play's `<title ID>_build` folders.
- **Removing a game:** this removes it from the library only. Its files are never touched.

## Credits

Beam's design drew on [NX Play](https://github.com/varyform/nx-native-wrapper) by Oleh Khomei (varyform), MIT licensed. Beam is written for NX 18 and carries none of NX Play's code.
