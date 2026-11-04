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

- **iOS 27.0 is the minimum, everywhere:** the app, its C and Objective-C, the host's own Metal shaders, every game's shaders (NVN, Vulkan, OpenGL) and the pipeline archives. Support for iOS 26 is dropped.
- **The M4's and A20's CPU:** the app's code is compiled with `-mcpu=apple-m4`. One app runs on both devices, so it can only use instructions both chips have: the M4's, which the newer A20 has in full. In LLVM, the compiler Xcode is built on, `apple-a18` (NXNative's setting) is another name for `apple-m4`, so this produces the same code as before; it names your device. `apple-a20` is another name for the newer `apple-m6` core, which adds instructions the M4 lacks (FP8, PAuth_LR, CPA), and LLVM support for it was only proposed on November 4, 2026, so Xcode 27.2 is unlikely to have it. Older iPhones and iPads (A17 Pro, M1–M3) are no longer a target.
- **The newest Metal Shading Language:** every game's shaders are compiled for iOS 27 in Metal 4.1 (`-std=metal4.1`), which Apple's Metal Shading Language Specification (version 4.1) gives as the language for iOS 27. Upstream named no version, with an iOS 18 minimum, where the language follows the deployment target (Metal 3.2). A shader Metal 4.1 rejects is compiled in Metal 3.2 instead, and the build log names it. This changes NXNative's shader chain version (`dm/gfx/nvn/dmsh_chain.h`), so every game's shaders are compiled again on its next build. The Metal API was already the newest: Metal 4 command queues, compiler, pipeline archives and MetalFX. The translator still writes the same Metal source (MSL 2.3, or 3.1 for image atomics), the version NXNative tests its output in.
- **Swift 6:** the app's Swift (the start screen, the in-game menu) builds in the Swift 6 language mode, with its complete concurrency checks, using the Swift compiler of your Xcode. If a newer compiler finds fault with it, `DM_SWIFT_VERSION=5 python3 scripts/build_ipa_from_nsp.py …` builds in Swift 5 mode.
- **Faster host code:** the app's own C and Objective-C (the NVN-to-Metal translator, the encode thread, audio) are built with `-O2` instead of Xcode's size-first `-Os`.
- **Metal 4 pipelines on for every game.** This turns on the pipeline archive, hybrid "stand-in" pipelines and the one-time prebuild. Upstream had it on only for Breath of the Wild on iOS (it was already on for every game on the Mac). The result is fewer first-time stutters. The first start of each game (and after each update) waits a few minutes on **Preparing pipelines**, once, unless the app carries an archive for the device's GPU (below). If a game runs out of memory, turn **Metal 4 pipelines** off for it in the start screen's Performance section.
- **Unreal Engine games** (DRAGON QUEST VII Reimagined) get the larger texture streaming pool on iOS too, for sharper textures. `DM_UE_TEXTURE_POOL=0` in `Documents/env.txt` restores the game's own.

To get the most out of the two devices:

- **Pipelines made ahead of time for your two GPUs (opt-in).** `--gpu g19p,g16g` builds a game's pipelines into GPU code for the A20 Pro (`g19p`) and the M4 (`g16g`) on your Mac (Apple's `metal-tt`), so its first start skips **Preparing pipelines**. Setting `DEVICE_GPUS = 'g19p,g16g'` at the top of `scripts/build_ipa_from_nsp.py` does it for every game. It is off by default: a bundled archive for the A19 Pro (`g18p`) crashed Metal at boot on an iPhone Air with iOS 27.0, and the cause is still open ([NX2Apple#640](https://github.com/LNPANDY/NX2Apple/issues/640)), while the same games started without one. Try it on one game first; if that game crashes right after starting, build it again without `--gpu`. Each GPU adds minutes to a game's first build and several hundred MB to the app. Each device prints its GPU's name in `log.txt` at first start, if you want to confirm the names (an M4 reports `applegpu_g16g`).
- **Upscaling: Automatic** (new) uses MetalFX only when the game's picture is smaller than 1920x1080, such as handheld mode's 1280x720, and smooth scaling at 1080p or more (MetalFX starts after 60 frames below 1080p, and a 1080p picture is scaled smoothly at once: a switch to docked prepares nothing, and a switch back to handheld reuses MetalFX's setup once it has been made). It is a good fit for both devices: the sharpness where the picture is smallest, without MetalFX's GPU cost on a picture that is already 1080p. On the iPad Pro, plain **MetalFX** is also worth trying: the M4 has the GPU time for it on the 13" screen. Both step back to smooth scaling while the device is hot or in Low Power Mode.
- **Frame buffering** (Performance section) holds a steadier frame rate in heavy games, at the cost of about one frame of input latency. It stays a per-game choice.

### Memory, CPU/GPU scheduling and heat

A check of these areas found NXNative already well tuned: Metal 4 residency sets, upload staging capped per batch, unmapped guest memory released at once, textures kept lossless-compressed unless a view needs otherwise, ProMotion asked for 60 Hz (30 for a 30 fps target) rather than 120, pipeline building on background (utility) queues, the game's and audio's threads at user-interactive priority, and a 30 fps hold for games whose speed the host controls while iOS reports serious heat. Added, none of which changes what a game sees or how fast it runs:

- **MetalFX steps aside when hot.** With **Upscaling: MetalFX** or **Automatic** on, the app scales smoothly instead while the device is thermally serious or in Low Power Mode, and MetalFX comes back after 30 s of calm. This is for every game, including those whose frame rate the host does not control. `DM_THERMAL_CAP=0` keeps MetalFX.
- **Memory warnings are logged and acted on.** iOS's memory warning, the last notice before it ends an app for memory, now writes the footprint and the room left to `log.txt`, and the app hands its allocators' free pages back to the system.
- **The larger Unreal texture pool only with room to spare:** on iOS it applies when at least the pool plus 2 GB is left before the memory limit at the game's start; otherwise the game keeps its own pool.

Left alone, because each could change how a game runs and needs a measurement on your devices first:

- **`DM_QOS_MAP=1`** lets low-priority game threads run on the efficiency cores, which could save power. NXNative keeps it off until a phone test shows it drops no frames. Try it per game in `Documents/env.txt` and compare the `[nvn] on-screen` lines in `log.txt`.
- **Freeing compiled shaders and pipelines under memory pressure:** in-flight pipelines point at them directly, and rebuilding them would bring back stutters.
- **A 30 Hz display for every 30 fps game:** games that time themselves on vsync would run at half speed.
- **Frame buffering** for every game: steadier frame rates for one frame of input latency. It stays a per-game choice in the start screen.

### Privacy: nothing leaves the device

The app sends no telemetry: no analytics, no crash reporting, and no network code but the web viewer of a game's offline pages (manuals, help). Games' own reports to Nintendo (`nn::prepo` play reports) are answered by the host, which sends nothing (`hle_offline.c`). The one path left open is closed here: a game's offline page could load an image, a script or a fetch from the internet (a tracking pixel, an analytics script); a WebKit content rule list now blocks every `http(s)` and `ws(s)` load of such a page, as navigations away from it already were.

Kept, because they stay on the device and help when something goes wrong:
- **`log.txt`:** every 5 seconds a few lines on frame times, memory, power and pipelines. It is written in the app's Documents folder, replaced at each start (the previous one is `log.prev.txt`) and never sent anywhere. The sampling is a few system queries every 5 seconds, and part of it feeds the frame-rate statistics.
- **The notification prompt:** only for games of several programs (Super Mario 3D All-Stars), for the local "Tap to start" note when one program starts another.

## Testing status

These changes were written and checked on Linux, not on a Mac:

- **Tested:** the Python side (mods folder, patch formats, game-data overlay, cheat packing, the build script's new stage, settings and docs checks) passes NXNative's test suite and the new tests in `dm/tools/tests/test_game_mods.py`.
- **Not compiled here:** the Objective-C and Swift changes (Stretch, the Cheats menu, the default cheats folder, the Metal 4 and texture pool defaults, the Swift 6 language mode), the Xcode project changes (iOS 27 minimum, `-O2`, `-mcpu=apple-m4`) and the shaders compiled for iOS 27 in Metal 4.1, all of which need Xcode. Check them with a build on your Mac before relying on them.
- **Not measured:** the speed-ups. They follow from what the code does, but no frame times were taken on an iPhone 18 Pro Max or an M4 iPad.

## Sources checked

- Apple, [Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf), version 4.1 (2026-06-04), section 1.6.10 "Compiler Options Controlling the Language Version": `metal3.2` for iOS 18, `metal4.0` for iOS 26, `metal4.1` for iOS 27.
- Apple Developer Forums: [the Metal language version follows the deployment target](https://developer.apple.com/forums/thread/704212); [a command-line Metal compile takes the SDK's version unless given a minimum](https://developer.apple.com/forums/thread/105719); [`MTL_LANGUAGE_REVISION` Metal41 in Xcode 27](https://developer.apple.com/forums/thread/842123).
- Apple documentation: [`MainActor.assumeIsolated`](https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:)) (its result must be `Sendable`), [`Binding.init(get:set:)`](https://developer.apple.com/documentation/swiftui/binding/init(get:set:)) (`@isolated(any) @Sendable` closures), [`UIActionHandler`](https://developer.apple.com/documentation/uikit/uiactionhandler), [`dismiss(animated:completion:)`](https://developer.apple.com/documentation/uikit/uiviewcontroller/dismiss(animated:completion:)), [`MTLDevice.architecture`](https://developer.apple.com/documentation/metal/mtldevice/architecture).
- LLVM: [apple-m4 and apple-a18 as one CPU, armv8.7-a](https://github.com/llvm/llvm-project/commit/eba1ef5a1b7a84ed1954797dcd6d6f073b1f1a56); [apple-a20 as an alias of apple-m6](https://github.com/llvm/llvm-project/pull/238808) (open on November 4, 2026).
- GPU names: [an M4 logs `applegpu_g16g`](https://github.com/infinigence/ApxInf/pull/143); [an iPhone Duo reports `applegpu_g19p`](https://github.com/seedds/nxnative/pull/653); [a bundled `g18p` archive crashing at boot](https://github.com/LNPANDY/NX2Apple/issues/640).
- Swift 6 and the C `stderr` global: [build logs of the error](https://swiftpackageindex.com/builds/43340118-32B0-47D7-B47B-5E6D95BA3FB9); `SWIFT_VERSION` values: [What Setting Should I Use?](https://massicotte.org/blog/what-settings/).
