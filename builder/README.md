# Nintanium Builder

A Mac app for building, installing and updating your Nintanium games without the terminal. It runs this repository's `scripts/build_ipa_from_nsp.py` for you, keeps each game's patches and cheats, installs the app and its game files on your iPhone or iPad, and keeps the repository up to date.

## Getting it

You need a Mac with Apple silicon, macOS 26 or later, and Xcode 27.2 (the version README's step 1 names for the shaders). Install the build tools from [README step 1](../README.md#build-from-the-command-line) once. Then, in Terminal:

```
git clone https://github.com/kencalx/Nintanium.git ~/Nintanium
~/Nintanium/builder/make_app.sh
open ~/Nintanium/builder/build
```

Drag **Nintanium Builder.app** to Applications. It is signed ad-hoc, so the first time you open it, Control-click it and choose **Open**. In **Nintanium Builder › Settings**, check where your `prod.keys` is, and click **Check Tools**.

## Using it

1. **Add a game.** Click **Add Game**, choose the folder holding its NSPs, and pick **iPhone** or **iPad**. The name and title ID are read from the file names.
2. **Choose the build.**
   - **Device:** builds an iPhone-only or an iPad-only app (the NSP script's `--device`). When the build makes pre-compiled GPU shaders, it makes them for that device's GPU alone: the A20 Pro (`g19p`) or the M4 (`g16g`). The shader libraries are the same for every iOS device, so there is nothing else to leave out. An iPad build has no Ultrawide toggle.
   - **Game files:** *Copied to the device separately* keeps the app small, and a reinstall doesn't send the game again. Copy the files once per game version with **Copy Game Data**. *Inside the app* puts them in the app.
   - **Install:** see below.
   - **Pre-compile GPU shaders:** off by default. It saves the first start's shader work but adds minutes and about 650 MB, and a bundled archive once crashed at boot on another iPhone ([NX2Apple#640](https://github.com/LNPANDY/NX2Apple/issues/640)). Try it on one game first.
3. **Add patches and cheats.** Under **Patches & Cheats**, add or drop files for this game, and they go into each of its builds:
   - patch files (`.pchtxt`, `.ips`, `.ips32`);
   - mod folders, or `.zip` packs such as those of [Switch-Emulator-Ultrawide-FPS-Mods](https://github.com/Fl4sh9174/Switch-Emulator-Ultrawide-FPS-Mods);
   - Atmosphère cheat files (`.txt`).

   Each one has an on/off switch. A mod named for a frame rate or a wide shape (`60FPS`, `Ultrawide`, `21.9`) becomes a **High frame rate** or **Ultrawide** toggle in the game's launcher ([NINTANIUM.md](../NINTANIUM.md#high-frame-rate-and-ultrawide-toggles)); other patches are built in. The files are kept in `~/Library/Application Support/Nintanium Builder/Games/<title ID>/mods`, in the layout `dm/tools/game_mods.py` reads.
4. **Build.** The window shows the build's stages and its log. A second build reuses what the first one made.

## Installing

- **Sign with my Apple account and install (Xcode)**, the default. Sign in to your Apple account once in **Xcode › Settings › Apple Accounts**. The app reads your team ID from your Apple Development certificate; **Settings › Detect** reads it again. The app then:
  1. prepares the game's Xcode project (`--prepare-xcode`);
  2. builds and signs it with `xcodebuild -allowProvisioningUpdates`;
  3. installs it on the device chosen in the toolbar (`devicectl device install app`);
  4. copies the game files (`scripts/push_romfs.sh`) and the cheats that are on.

  The device must be connected and unlocked, trust this Mac, and have **Developer Mode** on.

  With **Apple Developer Program account** on (the default):
  - The chosen device is registered on your account as the app is signed (`-allowProvisioningDeviceRegistration`).
  - Signed apps ask for **Extended Virtual Addressing** as well as **Increased Memory Limit**. Without it, iOS caps the app's address space at about 5 to 6 GB ([memory reference](../docs/reference/memory.md)); games that reserve a larger block need it, and it changes nothing for the others.
  - Apps stay installable for a year.

  With a free Personal Team, turn the setting off: apps then expire after 7 days, and you trust the certificate on the device the first time (**Settings › General › VPN & Device Management**).
- **Unsigned IPA for a sideloading tool.** Builds the IPA, then **Open in Sideloader** opens it in Sideloadly or AltServer if you have one. Otherwise it shows the IPA in Finder. With the game files kept separate, **Copy Game Data** then copies them. This uses `devicectl`, which can reach the app's files only when the tool signed it for development, as Sideloadly does with your Apple account.

**Copy Cheats** copies the cheat files that are on into the installed app's `cheats` folder, replacing ones of the same name. In the game, open the gear menu, then **Cheats › Reload cheats**.

## Updates

The **Repository** page shows the commit you have and any new ones on GitHub. With **Pull new commits automatically** on (the default), the app checks every 30 minutes and pulls new commits as they are added, but never while a build runs. It only fast-forwards, so it never overwrites changes of your own; while you have some, it waits and says so. **Pull** does it now. The next build of each game uses the new code: a change to the shader chain rebuilds that game's shaders, and the log says so. If a pulled commit has a `Front-ends:` line ([Following main](../docs/frontends.md#following-main)), the page shows it. To pick up changes to Nintanium Builder itself, run `builder/make_app.sh` again.

## Status

This app was written without a Mac to build it on. Its Swift was not compiled with the macOS SDK here, and nothing in it has run. Build it with `make_app.sh` and expect first-build fixes. The Python side it drives (`--device`, the mods folder, the switchable mods) passes the repository's tests.
