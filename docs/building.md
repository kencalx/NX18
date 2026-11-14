# Building

Every command and option for building a game on the command line. New to NX 18? Start with [Getting started](getting-started.md): it goes one step at a time, from a new Mac to playing.

NX 18 builds only from what you dump from your own Switch or Switch 2: your legally owned and acquired games, with their updates and DLC, and your own `prod.keys`. NX 18 includes no game files, keys or firmware.

- [Quick start with the release scripts](#quick-start-with-the-release-scripts)
- [Build from the command line](#build-from-the-command-line)
- [Switch 2 games](#switch-2-games)
- [Install](#install)
- [Xcode and the Metal compiler](#xcode-and-the-metal-compiler)
- [A game without a profile](#a-game-without-a-profile)

## Quick start with the release scripts

Each [release](https://github.com/kencalx/NX18/releases) comes with two scripts. They are also in [`scripts/release`](../scripts/release). Together they run the steps of [Build from the command line](#build-from-the-command-line) for you.

**`nx18-setup.sh` readies your Mac.**

- It checks macOS, Xcode 27.3 and its Metal toolchain. You download Xcode from Apple yourself; the script names the build and says how to select it.
- It installs xcodegen, zstd and the Python modules. The modules go into a virtualenv, `.venv` in the NX 18 folder.
- It clones NX 18 into `~/NX18`, or updates it.
- It asks before every install or download, and never runs `sudo`. A folder with your own changes in it is left alone.
- `--check` only reports what is missing. `--yes` answers yes to every question. `--dir <folder>` picks another folder, and `--ref <tag>` a given release.

**`nx18-build.sh` builds a game.**

- Set three things at its top: your game, your `prod.keys` and the target (`iphone`, `ipad` or `mac-app`). Then run it.
- The game is your legally owned and acquired game files: a folder of NSPs, a dump folder, or a `.nup` or `.nx` file.
- The keys are the ones dumped from your own Switch. Only NSPs and XCIs need them.
- It checks the settings, selects Xcode 27.3 by itself, builds, and says where the IPA or app is. It never prints or copies your keys.

```
bash ~/Downloads/nx18-setup.sh
cp -n ~/Downloads/nx18-build.sh ~/nx18-build.sh   # -n keeps a copy you already edited; then edit the settings at its top
bash ~/nx18-build.sh
```

Every setting also works as an environment variable (`NX18_GAME`, `NX18_KEYS`, `NX18_TARGET`, ...): the comment beside each setting names its variable. Other options of the packing script go after the script's name, as in `bash ~/nx18-build.sh --language ja`.

Keep your copy of `nx18-build.sh` outside the NX 18 folder. `nx18-setup.sh` won't update a folder that has changed files in it.

## Build from the command line

**You need:**

- your legally owned and acquired game files;
- an Apple silicon Mac on macOS 27.3 or later;
- [Xcode](https://developer.apple.com/download/all/?q=Xcode%2027.3) 27.3 ([which build](#xcode-and-the-metal-compiler)), with its iOS platform for an iPhone or iPad build (Xcode → Settings → Components);
- [Homebrew](https://brew.sh), and an arm64 Python, 3.12 or later (not one from an Intel Homebrew).

The shaders need Xcode 27.3's Metal compiler, so select that Xcode first: `sudo xcode-select -s /Applications/Xcode.app`. If you keep several Xcodes, give this one the name `Xcode-27.3.app`, then run `sudo xcode-select -s /Applications/Xcode-27.3.app`.

**1. Install the tools.** Once, in Terminal:

```
xcodebuild -downloadComponent MetalToolchain   # required: the build stops with an error without it
git clone https://github.com/kencalx/NX18.git && cd NX18   # NX 18's tree; NXNative's pins a different Xcode and Metal compiler
brew install xcodegen zstd
python3 -m pip install lz4 "capstone>=5,<6" fonttools nsz zbic "backports.zstd; python_version < '3.14'"
```

**2. Gather your game.** Make one folder for it, with your dump of the game and, if you own them, its update and DLC. `.nsp`, `.xci`, `.nsz` and `.xcz` files all work:

```
~/Games/MarioWonder/
  Super Mario Bros. Wonder [010015100B514000][v0].nsp
  Super Mario Bros. Wonder [010015100B514800][v327680].nsp
```

**3. Build.** Give it the game folder and the `prod.keys` dumped from your own Switch:

```
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys
```

The result is an unsigned IPA, in the game's folder, ready to [sideload](#install).

- Expect 30–60 minutes for a first build. Later builds are much faster.
- Keep about twice the game's size free on disk, plus 10 GB.
- For the Mac, add `--platform mac-app`. You then get the game as a Mac app: open it from Finder.

### Options

- **Mods and cheats.** Make a folder named `mods` in the game's folder, laid out as Atmosphère lays them out on your Switch's SD card. Cheats (`cheats` folders) are packed into the app. A High frame rate or Ultrawide mod (`.ips` or `.pchtxt` files, in a folder named for it, such as `60FPS` or `Ultrawide`) becomes a switch in the launcher. Other code patches and replacement files (`romfs` folders) stay out. [Mods and patches](playing.md#mods-and-patches)
- **Launcher art.** The build fetches the game's key art for the screen before the game. Set the `STEAMGRIDDB_KEY` environment variable to your SteamGridDB API key, and art can also come from SteamGridDB: its textless art, with the game's logo in place of the name. `--art <image>` uses your own art, and `--logo <image>` your own logo (a PNG or WebP with transparency). `--manual <file.pdf>` adds the game's manual. `--no-art-online` keeps the build off the network. [Launcher art](development.md#launcher-art-about-this-game-and-the-manual)
- **UI font.** `--ui-font <file.ttf>` puts one font of your own (a TTF, OTF or TTC) into the app, for all of NX 18's own text: the launcher, the in-game prompts and progress screens, and the Mac banner and Cheats window. The file goes only into the app built on your Mac, never into the repository, so keep that app to your own devices. Without it, the system font is used. [UI font](development.md#ui-font)
- **Spyder.** `build_ipa_from_nsp.py` also runs in Spyder: set the settings block at its top and press F5. Command-line options override those settings.
- **Everything else.** `-h` lists every option. [The packing script in detail](development.md#the-packing-script-in-detail) explains them.

## Switch 2 games

Switch 2 games don't use NSPs. Build one from your legally owned and acquired game files, in one of three forms:

- a [NUP](https://github.com/a55uka/nup) container, by a55uka (a `.nup` file);
- an [NX](https://github.com/fab918/nxformat) archive (a `.nx` file);
- a folder of the game's files.

None of them needs `prod.keys`. A Switch 2 game dumped from your own console is already unpacked to its files.

- You get an IPA, or a Mac app with `--platform mac-app`. iPad builds are untested.
- On iPhone and iPad the game starts in Handheld, its lighter mode. On the Mac it starts in Docked. **Console mode** in the settings switches it ([Console mode](settings.md#console-mode)).
- A game without an NX 18 profile gets a survey and a provisional profile, the same as with NSPs. It may not boot ([A game without a profile](#a-game-without-a-profile)).

### From a `.nup` file

A `.nup` is one file holding the base game plus its updates and DLC. Give the script that file, or the folder it's in:

```
python3 scripts/build_ipa_from_nsp.py ~/Games/DonkeyKongBananza.nup --platform mac-app
```

[Hyrule Warriors: Age of Imprisonment](../dm/games/04003F40232DE000/README.md) is played from a NUP, and all 47 GB take less than five minutes to unpack.

- **Name and icon.** If the NUP has the game's NACP and icon, the app takes the game's name and icon from it. If not, the app is named from the game's NX 18 profile, and its icon is the one [NX Play](https://github.com/varyform/nx-native-wrapper) saved for the game (`~/Library/Caches/com.varyform.nxplay/Banners/icons`, `NXPLAY_ICONS` in Spyder), if there is one, else the NX 18 icon (`docs/images/nx18/nx18-icon-square-1024.png`). `--icon <image>` sets your own: a JPEG or PNG, any size (`ICON` in Spyder).
- **Newer `nup` files.** Since 2026-11-04 (its PR #20), the `nup` tool numbers a NUP's metadata one too low. The script still reads such a NUP right, and says so.
- **No base game.** Some NUPs have an empty base package, or none, and mark their updates `standalone_update`. The script then builds the update as the full game and tells you so. If the game halts because files are missing, the update only holds what changed: pack a NUP that includes the base game.
- **Versions.** The script builds the newest update unless `--package v<N>` names another. A container with no base game has no `v0`.

### From a `.nx` file

An NX archive ([NXFormat](https://github.com/fab918/nxformat) 1.0.x, by fab918) also packs the base game, updates and DLC together, for Switch and Switch 2 games alike. NXFormat's NXConvert makes one from a NUP (`nxconvert pack-nup game.nup game.nx --platform switch2`) or from extracted folders (`nxconvert pack-tree`). Give the script that file, or the folder it's in:

```
python3 scripts/build_ipa_from_nsp.py ~/Games/DonkeyKongBananza.nx --platform mac-app
```

- **Versions.** Each version in an NX is the complete game, so a newer update needs no base game beside it. `--package v<N>` picks one. The newest is the default.
- **Name and icon.** Each version brings its own NACP and icon when the archive has them. DLC converted from a NUP or from folders comes along. A version without a NACP is named after the archive's title (the one given to `nxconvert --fallback-title` or typed in NXConvert's sidebar), else the profile's. An icon set in NXConvert's sidebar becomes the app's icon, also for an NX made from NSPs or XCIs. An NX without an icon gets NX Play's saved icon for the game, if there is one, else the NX 18 icon. `--icon <image>` sets another.
- **Checked as it unpacks.** Each file is checked against its SHA-256. A damaged archive stops the build and names the file it failed on. `python3 scripts/pack_nx.py game.nx --list` shows what an archive holds, and `--verify` checks all of it.
- **Several games.** An NX holding more than one game needs `--title-id`.
- **From your decrypted NSPs or XCIs.** An NX made from your NSPs or XCIs after you decrypted them with your own console's keys (`nxconvert pack game.dnsp`, Switch games) holds the decrypted NCA files, so it builds without giving `prod.keys` again. The repository's `nx_extract` reads them and lays an update over its base game, as it does for NSPs.
  - It needs temporary space for the NCA files of the version it extracts: an update's base and patch NCAs together, deleted after each.
  - A repeat build reuses the extraction and stages nothing again.
  - A sparse base game (the decrypting tool left out data its update carries) can't be packed alone: pack the update version.
- **Format versions.** NX 18 reads NX format 0.2 and 0.3. A newer format is refused, with a line saying a newer NX 18 is needed.
- Keep one `.nup` or `.nx` per folder.

### From a folder of files

Lay the folder out like this. You can leave out `updates` and `dlc`:

```
~/Games/DonkeyKongBananza/
  base/exefs/                     main, main.npdm, sdk, rtld
  base/romfs/
  updates/458752/exefs/           update version, in decimal
  updates/458752/romfs/           the full patched RomFS (not a delta)
  dlc/040074a01bf13001/0/romfs/   the DLC's title ID
```

```
python3 scripts/build_ipa_from_nsp.py ~/Games/DonkeyKongBananza --platform mac-app
```

- No `base/`? An update's folder builds by itself.
- `exefs/` and `romfs/` at the top of the folder, the way `nup extract` leaves them, are taken as `base/`.
- A folder holds no icon. The app gets NX Play's saved icon for the game, if there is one, else the NX 18 icon. `--icon <image>` (`ICON` in Spyder) sets your own.
- `nup pack ~/Games/DonkeyKongBananza game.nup` packs the folder into a NUP.

## Install

Sideload the IPA with a tool such as AltStore, SideStore, Sideloadly or LiveContainer. Then make sure the game gets the [Increased Memory Limit](../README.md#increased-memory-limit). Which tool and which Apple account suit you: [Choose how to install](getting-started.md#4-choose-how-to-install).

**Too big to install?** Build it again with `--romfs separate`. At the end the script prints a command. Run it once, and it copies the game files straight to your phone ([Quick reinstalls](development.md#quick-reinstalls)). Installing with AltServer? Add `--shader-files` too: AltServer can't install any single file of 2 GiB or larger.

Controls and saves: [Playing](playing.md). Every setting: [Settings](settings.md).

## Xcode and the Metal compiler

- **The chip.** NX 18's iOS app is built for the Apple A20 chip, on iOS 27.3: `dm/ios/project.yml` sets deployment target 27.3 and `-mcpu=apple-a20`. The app still declares the iPad family.
- **The system.** An IPA from this tree needs iOS or iPadOS 27.3 or later. It doesn't run on older systems or on chips before the A20.
- **Textures.** Switch games use BC-compressed textures, and older iPhones can't read them.
- **The compiler.** Xcode 27.3's Metal compiler (32023.925) is the one `dm/gfx/tools/dmsh_chain.lock` records, so `--allow-other-metal` isn't needed.
- **The exact build.** The lock names compiler 32023.925.6: the Xcode 27.3 beta's (build 27C5020n, Metal Toolchain 27C5020k). The shaders were tested with it.
- **Another compiler.** A released Xcode 27.3 whose Metal compiler reports another version is refused by the build check until the lock is raised. `--allow-other-metal` builds anyway, but untested shaders can render wrong pictures.
- **Shader language.** The game shaders are MSL 4.1 on both platforms (`-std=metal4.1`).

## A game without a profile

No NX 18 profile for your game yet? The script surveys the game and makes a first try at a build, with settings it guesses. That first try may well not start. To bring the game up properly: [Port another game](development.md#port-another-game).
