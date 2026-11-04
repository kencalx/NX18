# Nintanium

Nintanium is a fork of [NXNative](https://github.com/seedds/nxnative) (MIT License, kept in [LICENSE](LICENSE)), which turns your own Switch games into iPhone, iPad and Mac apps. It adds a Stretch picture option, cheats on iPhone and iPad, a mods folder for code patches, replacement files and cheats, and tuning for the iPhone 18 Pro Max and iPad Pro (M4) on iOS 27.

## Getting it

Build exactly as [NXNative's README](README.md#how-to-play) says, but clone this repository instead of NXNative:

```
git clone https://github.com/kencalx/Nintanium.git && cd Nintanium
python3 scripts/build_ipa_from_nsp.py ~/Games/MarioWonder -k ~/keys/prod.keys
```

To take in NXNative's newer changes later:

```
git remote add upstream https://github.com/seedds/nxnative.git   # once
git fetch upstream && git merge upstream/main
```

## What changes

### Picture: Stretch

The **Picture** setting (start screen and the in-game gear menu) now has **Fit**, **Fill** and **Stretch**:

- **Fit** (default): the whole 16:9 picture, black bars at the sides.
- **Fill**: covers the screen, top and bottom cropped.
- **Stretch** (new): covers the whole screen and crops nothing. The picture is stretched to the screen's shape, so it looks about a fifth wider on an iPhone. The whole HUD stays on screen.

The picture is drawn once, straight at the screen's resolution, so Stretch isn't blurrier than Fit. Touches on the game's touch screen line up with the stretched picture. In portrait and on a TV the picture keeps its shape. `DM_PICTURE_FIT=stretch` in the app's `Documents/env.txt` sets it from a file. MetalFX upscaling applies only to a picture that keeps its shape, so a stretched picture uses standard smooth scaling.

### Cheats on iPhone and iPad

- The app now has a `cheats` folder in the Files app, under the app's name, with a `README.txt` in it. Put an Atmosphère cheat file there, named after the game's build ID (`0123456789ABCDEF.txt`), or an SD card's `atmosphere/contents/<title ID>/cheats/` folder.
- The in-game gear menu has a new **Cheats** submenu. It lists the cheats by section; tap one to turn it on or off (remembered for the next start). It also has **Cheats on** (all off at once) and **Reload cheats**, so a file you copy in works without restarting. With no file, it shows the build ID the game is looking for.
- Cheats that rewrite the game's code can't run on iPhone or iPad, because the app's code is signed. They show greyed out with the reason. Pack such patches in as code patches instead (below).

### Mods folder (patches, replacement files, cheats)

Make a folder named `mods` inside your game's folder, beside the NSPs, and copy mods in as Atmosphère, yuzu or Ryujinx lay them out. A whole SD card's `atmosphere` folder works too.

```
~/Games/MarioWonder/
  Super Mario Bros. Wonder [010015100B514000][v0].nsp
  mods/
    atmosphere/exefs_patches/60fps/<build ID>.ips       code patch (IPS / IPS32)
    60fps/exefs/60fps.pchtxt                            code patch (IPSwitch text, its @enabled patches)
    atmosphere/contents/010015100B514000/romfs/...      replacement game files
    atmosphere/contents/010015100B514000/cheats/<build ID>.txt
```

The build applies it all:

- **Code patches** (`.ips`, `.ips32`, `.pchtxt`) for the version being packed are written into the game's code before NXNative's rewriter runs. This is how a 60 fps or resolution patch reaches an iPhone.
- **`romfs` folders**: their files replace or add game files in the packed game data. On a Mac's APFS drive this clones the game data instead of copying it.
- **`cheats` folders**: cheat files are packed into the app, which copies them into its `cheats` folder on first start. A cheat file not named after a build ID counts as the packed version's.

Mods for other games (folders named by another title ID) are skipped. To turn a mod off without deleting it, rename its folder to start with `-`. `--mods <folder>` uses another folder, and `--no-mods` builds without mods. The console lists what was applied, and `<title ID>_build/mods/<version>.txt` keeps that report. Your extracted game files are never modified: the modded copy is in `<title ID>_build/mods/<version>/`.

Limits:

- If a patch changes an instruction that NXNative's own fixes for that game also change, the rewrite stops with an error naming it. Turn that patch off.
- A `romfs` mod that replaces the game's shader files can fail NXNative's shader checks.

### Tuned for iPhone 18 Pro Max and iPad Pro (M4) on iOS 27

NXNative already requires an A17 Pro or M1 or later with Metal 4, already drives ProMotion's 120 Hz display link, and already asks for the Increased Memory Limit. On top of that:

- **iOS 27.0 is the minimum.** Support for iOS 26 is dropped.
- **Faster host code:** the app's own C and Objective-C (the NVN-to-Metal translator, the encode thread, audio) are built with `-O2` instead of Xcode's size-first `-Os`. The CPU target stays `apple-a18`: the compiler takes CPU names, not GPU names, and both of your devices support everything `apple-a18` turns on. A newer CPU name would gain little and could fail on an Xcode that doesn't know it.
- **Metal 4 pipelines on for every game.** This turns on the pipeline archive, hybrid "stand-in" pipelines and the one-time prebuild. Upstream had it on only for Breath of the Wild on iOS (it was already on for every game on the Mac). The result is fewer first-time stutters. On a device whose GPU the app has no archive for, the first start of each game (and after each update) waits a few minutes on **Preparing pipelines**, once; your two devices get an archive (below). If a game runs out of memory, turn **Metal 4 pipelines** off for it in the start screen's Performance section.
- **Unreal Engine games** (DRAGON QUEST VII Reimagined) get the larger texture streaming pool on iOS too, for sharper textures. `DM_UE_TEXTURE_POOL=0` in `Documents/env.txt` restores the game's own.

To get the most out of the two devices:

- **Pipelines made ahead of time for your two GPUs.** Every game's app carries a pipeline archive built for `g19p` (the A20 Pro of the iPhone 18 Pro Max) and `g16g` (the M4 of the iPad Pro), the `DEVICE_GPUS` setting at the top of `scripts/build_ipa_from_nsp.py`. Apple's `metal-tt` compiles each game's pipelines into GPU code for each of them on your Mac, so the first start skips **Preparing pipelines**. Each GPU adds minutes to a game's first build and several hundred MB to the app. For an iPhone-only app, pass `--gpu g19p`; to leave the archive out, pass `--gpu none`.
- **On the iPad Pro**, try **Upscaling: MetalFX** in the start screen. The M4 has the GPU time for it, and it sharpens the picture on the 13" screen.
- **Frame buffering** (Performance section) holds a steadier frame rate in heavy games, at the cost of about one frame of input latency. It stays a per-game choice.

## Testing status

These changes were written and checked on Linux, not on a Mac:

- **Tested:** the Python side (mods folder, patch formats, game-data overlay, cheat packing, the build script's new stage, settings and docs checks) passes NXNative's test suite and the new tests in `dm/tools/tests/test_game_mods.py`.
- **Not compiled here:** the Objective-C and Swift changes (Stretch, the Cheats menu, the default cheats folder, the Metal 4 and texture pool defaults) and the Xcode project changes (iOS 27 minimum, `-O2`), which need Xcode. Check them with a build on your Mac before relying on them.
- **Not measured:** the speed-ups. They follow from what the code does, but no frame times were taken on an iPhone 18 Pro Max or an M4 iPad.
