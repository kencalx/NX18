# Nintanium

Nintanium is a fork of [NXNative](https://github.com/seedds/nxnative) (MIT License, kept in [LICENSE](LICENSE)), which turns your own Switch games into iPhone, iPad and Mac apps. It adds a Stretch picture option, cheats on iPhone and iPad, a mods folder for code patches, replacement files and cheats, High frame rate and Ultrawide toggles for such mods, iPhone-only or iPad-only builds, a Mac app that builds and installs games, and tuning for the iPhone 18 Pro Max and iPad Pro (M4) on iOS 27.

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

### The gear appears on a double tap

The gear is hidden while you play: **double-tap** anywhere except on a button, the D-pad or the left stick to show it. It fades out again after 5 seconds if you don't touch it, and stays while its menu is open. It also shows when the game starts, until 5 seconds after its first picture (and after the **Preparing shaders** or **Preparing pipelines** screen of a first start); it stays while VoiceOver or Switch Control is on (turning either on shows it), and while the game shows an offline web page. A double tap on a control counts as two presses, not a request for the menu, so pressing a button twice quickly never brings it up.

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
- **`cheats` folders**: cheat files are packed into the app, which copies each into its `cheats` folder at each start when that folder does not have it (a file already there is kept). A cheat file not named after a build ID counts as the packed version's. A packed file you delete comes back at the next start: to stop its cheats, turn off the Cheats submenu's master switch (**Cheats on**), or set `DM_CHEATS=` in `Documents/env.txt`.

A folder named with a title ID counts for that title and its update (+0x800); other games' folders are skipped. In a game of several programs (Super Mario 3D All-Stars), each program takes only the folders named with its own title ID (the application's + the program's index), and mods outside title folders go to every program. A DLC's folder (the application's title ID + 0x1000 + its index) is not packed: a DLC's game data is not modded, and the report lists the folder as ignored. To turn a mod off without deleting it, rename its folder to start with `-`. `--mods <folder>` uses another folder, and `--no-mods` builds without mods. The console lists what was applied, and `<title ID>_build/mods/<version>.txt` keeps that report. Your extracted game files are never modified: the modded copy is in `<title ID>_build/mods/<version>/` (`--no-keep-extracted` deletes it with them).

Limits:

- If a patch changes an instruction that NXNative's own fixes for that game also change, the rewrite stops with an error naming it. Turn that patch off.
- A `romfs` mod that replaces the game's shader files can fail NXNative's shader checks.

### High frame rate and Ultrawide toggles

A mod whose folder name says it changes the frame rate (`60FPS`, `Frame rate`) or the picture's shape (`Ultrawide`, `21.9`, `21:9`) is no longer written into the game for good. The build packs it so the launcher's **High frame rate** and **Ultrawide** toggles turn it on and off at the next start, without rebuilding. Mods like those of [Switch-Emulator-Ultrawide-FPS-Mods](https://github.com/Fl4sh9174/Switch-Emulator-Ultrawide-FPS-Mods) work as they come, in yuzu's or Ryujinx's layout. That repository has no license, so its mods are not included here: copy the ones for your game into its mods folder yourself.

- **One mod per kind.** Of several mods (a pack's 30, 60 and 120 FPS, its 21:9 and 32:9), the build takes 60 fps and the ultrawide shape nearest the iPhone 18 Pro Max's screen, and prefers a mod not made for Ryujinx alone. The report lists the others it left out.
- **Ultrawide on the iPhone.** The mod's aspect value is set to the iPhone 18 Pro Max's screen (2868 x 1320) when the mod keeps it as a number, and the picture is stretched to fill the screen, which is the shape the wider view was drawn for. While Ultrawide stretches the picture, the in-game menu has no **Picture** row: the picture stays at Stretch until Ultrawide is turned off at the next start. On an iPad, whose screen is taller than 16:9, Ultrawide stays off.
- **Games with their own Frame rate setting** (Breath of the Wild, Luigi's Mansion 3 and others) take no frame-rate mod: the launcher's Frame rate already does it, and the two would fight.
- **How it works.** The build rewrites the game's code once more with the mod and keeps only the bytes that change. With both toggles, the two rewrites run at the same time (`DM_VARIANT_J=1` runs them one after another on a Mac short of memory), and a repeat build reuses the bytes it found (`DM_VARIANT_RUNS_CACHE=0` finds them again). On iPhone and iPad, each code page the mod touches is packed as signed code, once with and once without the mod, and the app swaps the page in at start. A mod that changes code NXNative's own fixes also change, or data the game's loader adjusts, can't be switched: the build leaves it out and says why.
- **FPSLocker** patches (FPSLocker-Warehouse) are a different format, for a system module that changes memory while the game runs. They aren't read. Most of the games they cover already have the launcher's Frame rate.

### Nintanium Builder (Mac app)

[builder/](builder/README.md) is a Mac app that does all of this without the terminal:

- it builds a game's app with the NSP script, for the **iPhone** or the **iPad** (`--device`, below);
- it keeps each game's patches and cheats and adds them at build time;
- it installs the app and its game files on the device, signed with your Apple account through Xcode, or as an unsigned IPA for a sideloading tool;
- it pulls this repository's new commits as they are added.

Build it with `builder/make_app.sh`.

### Both memory entitlements in every build

Every build, whether the Xcode project or the unsigned IPA, asks for **Increased Memory Limit** and **Extended Virtual Addressing**:
- **Increased Memory Limit** lets the app use more of the device's RAM before iOS closes it.
- **Extended Virtual Addressing** lifts the cap of about 5 to 6 GB that iOS otherwise puts on the app's address space ([memory reference](docs/reference/memory.md)).

An Apple Developer Program team provisions both; a free Personal Team only the first (build with `DM_ENTITLEMENTS=<plist>` holding Increased Memory Limit alone, which Nintanium Builder does when its paid-account setting is off). The log's `boot: memory:` line shows that both are in effect on the device: how much RAM iOS allows the app, and whether an 8 GB address reservation succeeds. The games' memory layouts are their profiles' own, tested within 5 GB, so a game uses more address space only where its profile asks for it.

### Drag Here: build by dropping a folder

`scripts/make_drag_here.sh` makes **Drag Here.app** on your Desktop. Drop a game's folder on it and Terminal opens and runs the build. The folder holds the game's NSPs, and can also hold its `mods` folder and `prod.keys`.

The build it runs:
```
python3 scripts/build_ipa_from_nsp.py "<folder>" -k "<keys>" --device iphone
```
- **The keys** are the first one found: `prod.keys` in the folder, beside it, in `~/.switch/`, or one other `.keys` file in the folder. A dump folder (`base/exefs/main.npdm`, with a RomFS in `base/` or `updates/<version>/`) or a NUP needs no keys.
- **The mods folder** is packed in as usual.
- **Several folders** dropped together are built one after another in one Terminal window; only the last waits for Return at the end. A build that stops leaves its lines there, and the next one starts.
- **The window stays open** at the end so you can read the result.
- **Other devices:** `scripts/make_drag_here.sh ipad` makes an iPad droplet, and `both` makes one for iPhone + iPad builds.

The first drop asks to let it control Terminal: allow it. The droplet runs the build from the checkout you ran `make_drag_here.sh` in, so pulling that checkout updates what it runs. `scripts/drop_build.sh "<folder>"` does the same from Terminal.

### iPhone or iPad builds

`--device iphone` or `--device ipad` (`DEVICE` in Spyder) builds an app for that device family only. When the build makes a pipeline archive (the GPU's own compiled shaders), it makes it for that device's GPU alone: the A20 Pro (`g19p`) or the M4 (`g16g`), rather than every GPU the default rule names. The Metal shader libraries are the same for every iOS device, so there is no other per-device shader output. An iPad build leaves out the Ultrawide toggle and does not pack the Ultrawide mod (the build says `mods: Ultrawide left out`). Without `--device`, one app serves both, as before.

### Tuned for iPhone 18 Pro Max and iPad Pro (M4) on iOS 27

NXNative already requires an A17 Pro or M1 or later with Metal 4, already drives ProMotion's 120 Hz display link, and already asks for the Increased Memory Limit. On top of that:

- **iOS 27.0 is the minimum, everywhere:** the app, its C and Objective-C, the host's own Metal shaders, every game's shaders (NVN, Vulkan, OpenGL) and the pipeline archives. Support for iOS 26 is dropped.
- **The M4's and A20's CPU:** the app's code is compiled with `-mcpu=apple-m4`. One app runs on both devices, so it can only use instructions both chips have: the M4's, which the newer A20 has in full. In LLVM, the compiler Xcode is built on, `apple-a18` (NXNative's setting) is another name for `apple-m4`, so this produces the same code as before; it names your device. `apple-a20` is another name for the newer `apple-m6` core, which adds instructions the M4 lacks (FP8, PAuth_LR, CPA), and LLVM support for it was only proposed on November 4, 2026, so Xcode 27.2 is unlikely to have it. Older iPhones and iPads (A17 Pro, M1–M3) are no longer a target.
- **The newest Metal Shading Language:** every game's shaders are compiled for iOS 27 in Metal 4.1 (`-std=metal4.1`), which Apple's Metal Shading Language Specification (version 4.1) gives as the language for iOS 27. Upstream named no version, with an iOS 18 minimum, where the language follows the deployment target (Metal 3.2). A shader Metal 4.1 rejects is compiled in Metal 3.2 instead, and the build log names it. This changes NXNative's shader chain version (`dm/gfx/nvn/dmsh_chain.h`), so every game's shaders are compiled again on its next build. The Metal API was already the newest: Metal 4 command queues, compiler, pipeline archives and MetalFX. The translator still writes the same Metal source (MSL 2.3, or 3.1 for image atomics), the version NXNative tests its output in.
- **Swift 6:** the app's Swift (the start screen, the in-game menu) builds in the Swift 6 language mode, with its complete concurrency checks, using the Swift compiler of your Xcode. If a newer compiler finds fault with it, `DM_SWIFT_VERSION=5 python3 scripts/build_ipa_from_nsp.py …` builds in Swift 5 mode.
- **Faster host code:** the app's own C and Objective-C (the NVN-to-Metal translator, the encode thread, audio) are built with `-O2` instead of Xcode's size-first `-Os`.
- **Metal 4 pipelines on for every game.** This turns on the pipeline archive, hybrid "stand-in" pipelines and the one-time prebuild. Upstream had it on only for Breath of the Wild on iOS (it was already on for every game on the Mac). The result is fewer first-time stutters. The first start of each game (and after each update) waits a few minutes on **Preparing pipelines**, once, unless the app carries an archive for the device's GPU (below). If a game runs out of memory, turn **Metal 4 pipelines** off for it in the start screen's Performance section.
- **Unreal Engine games** (DRAGON QUEST VII Reimagined) get the larger texture streaming pool on iOS too, when the memory has room for it (below), for sharper textures. `DM_UE_TEXTURE_POOL=0` in `Documents/env.txt` restores the game's own.

To get the most out of the two devices:

- **Pipelines made ahead of time for your two GPUs (opt-in).** `--gpu g19p,g16g` builds a game's pipelines into GPU code for the A20 Pro (`g19p`) and the M4 (`g16g`) on your Mac (Apple's `metal-tt`), so its first start skips **Preparing pipelines**. Setting `DEVICE_GPUS = 'g19p,g16g'` at the top of `scripts/build_ipa_from_nsp.py` does it for every game. It is off by default: a bundled archive for the A19 Pro (`g18p`) crashed Metal at boot on an iPhone Air with iOS 27.0, and the cause is still open ([NX2Apple#640](https://github.com/LNPANDY/NX2Apple/issues/640)), while the same games started without one. Games whose profile sets `pso_mtl4 on` (Breath of the Wild, 13 Sentinels: Aegis Rim) are the exception: they always get an archive for the GPU of the device the build is for, and `--gpu none` leaves it out. Try it on one game first; if that game crashes right after starting, build it again without `--gpu` (`--gpu none` for those two games). Each GPU adds minutes to a game's first build and several hundred MB to the app. Each device prints its GPU's name in `log.txt` at first start, if you want to confirm the names (an M4 reports `applegpu_g16g`).
- **Upscaling: Automatic** (new) uses MetalFX only when the game's picture is smaller than 1920x1080, such as handheld mode's 1280x720, and smooth scaling at 1080p or more (MetalFX starts after 60 frames below 1080p, and a 1080p picture is scaled smoothly at once: a switch to docked prepares nothing, and a switch back to handheld reuses MetalFX's setup once it has been made). It is a good fit for both devices: the sharpness where the picture is smallest, without MetalFX's GPU cost on a picture that is already 1080p. On the iPad Pro, plain **MetalFX** is also worth trying: the M4 has the GPU time for it on the 13" screen. Both step back to smooth scaling while the device is hot or in Low Power Mode.
- **Frame buffering** (Performance section) holds a steadier frame rate in heavy games, at the cost of about one frame of input latency. It stays a per-game choice.

### Memory, CPU/GPU scheduling and heat

A check of these areas found NXNative already well tuned: Metal 4 residency sets, upload staging capped per batch, unmapped guest memory released at once, textures kept lossless-compressed unless a view needs otherwise, ProMotion asked for 60 Hz (30 for a 30 fps target) rather than 120, pipeline building on background (utility) queues, the game's and audio's threads at user-interactive priority, and a 30 fps hold for games whose speed the host controls while iOS reports serious heat. Added, none of which changes what a game sees or how fast it runs:

- **MetalFX steps aside when hot.** With **Upscaling: MetalFX** or **Automatic** on, the app scales smoothly instead while the device is thermally serious or in Low Power Mode, and MetalFX comes back after 30 s of calm. This is for every game, including those whose frame rate the host does not control. `DM_THERMAL_CAP=0` keeps MetalFX.
- **Memory warnings are logged and acted on.** iOS's memory warning, the last notice before it ends an app for memory, now writes the footprint and the room left to `log.txt`, and the app hands its allocators' free pages back to the system.
- **The game's drawables are render targets only.** The iOS game layer's drawables are now only drawn into (`framebufferOnly`, as on the Mac), which lets Core Animation and Metal keep them in the form best for display (lossless compression). The game never sees them, so how it runs is unchanged; `DM_DRAWABLE_SHADER_ACCESS=1` in `Documents/env.txt` restores the old setting. The saving is not measured.
- **The larger Unreal texture pool only with room to spare:** on iOS it applies when at least the pool plus 2 GB is left before the memory limit at the game's first present (checked once); otherwise the game keeps its own pool.
- **Texture-upload staging given back after loading.** The staging a loading screen grows (up to 192 MB, counted in the app's memory on iOS) goes back to 4 MB per upload slot once a slot has gone 600 submissions and 20 s without needing more, after its last upload has finished on the GPU; the next burst allocates again. This leaves more room under the memory limit for the large games. `DM_UPLOAD_TRIM=0` keeps it for the whole run. The saving is not measured.

Changed, the frame rate in Low Power Mode (the game's speed stays the same):

- **Low Power Mode holds 30 fps for frame-step games** (Breath of the Wild, Tears of the Kingdom, Age of Calamity, Paper Mario: The Thousand-Year Door, Astral Chain), and 60 for a game the host lets run at 120, as the heat cap already did: you chose battery over speed, and the clocks are lower in it anyway. The frame rate comes back 30 s after Low Power Mode is turned off. Other games are not affected. `DM_LOW_POWER_CAP=0` in `Documents/env.txt` keeps the chosen frame rate; `DM_THERMAL_CAP=0` turns off the heat cap too.

Left alone, because each could change how a game runs and needs a measurement on your devices first:

- **`DM_QOS_MAP=1`** lets low-priority game threads run on the efficiency cores, which could save power. NXNative keeps it off until a phone test shows it drops no frames. Try it per game in `Documents/env.txt` and compare the `[nvn] on-screen` lines in `log.txt`.
- **Freeing compiled shaders and pipelines under memory pressure:** in-flight pipelines point at them directly, and rebuilding them would bring back stutters.
- **A 30 Hz display for every 30 fps game:** games that time themselves on vsync would run at half speed.
- **Frame buffering** for every game: steadier frame rates for one frame of input latency. It stays a per-game choice in the start screen.
- **NVN's depth bounds test on the GPU (`DM_DEPTH_BOUNDS=1`, new, off by default).** Breath of the Wild, Tears of the Kingdom and Pokémon Scarlet call it, most likely to limit their lights, and the host has always dropped it. Metal runs it on Apple10-or-later GPUs only: the iPhone 18 Pro Max's A20 Pro should be one (A19 and M5 are), the iPad Pro's M4 is not, and there the switch changes nothing. It may save GPU time in those games' lighting passes, and it changes what is drawn, so it needs a look and a measurement first (`DM_DEPTH_BOUNDS=ab` with `DM_AB=300` alternates it for the `[ab]` lines; [rendering](docs/reference/rendering.md#nvns-depth-bounds-test-on-an-apple10-gpu-opt-in)).
- **Preparing in the background (`DM_BG_PREPARE=1`, new, off by default).** **Preparing shaders** and **Preparing pipelines** go on while you're in another app, shown in a Live Activity where you can cancel it (iOS 26 and later; no GPU work in the background). Off until it is measured on the devices: the app then keeps running in the background for as long as the step lasts.

### Faster repeat builds

A build of a game that was built before redoes less, with the same app as a result:

- **The iOS shaders stay reused** after an edit of a game profile's notes or test tables (README.md, bench.tsv, smoke.tsv and the like) or a game.tsv key the shaders do not read; only what the shader chain reads from the profile counts (Breath of the Wild: about 100 s saved, and the shader folder is not compressed again). `DM_SHADER_KEY_ALL_PROFILE=1` keys every profile file, as before.
- **Xcode builds only what changed.** `dm/ios/Gen` is no longer deleted and written again: only the files whose bytes changed are replaced, the Xcode project is generated only when its inputs changed, and the executable is signed in a copy of the app. A repeat build of the same game then assembles, links and signs nothing, and the IPA packer reuses the executable's compressed bytes. `DM_GEN_REUSE=0` and `DM_SIGN_REUSE=0` restore the old way. On a drive that is not APFS, the signed copy takes as much space again as the app.
- **The High frame rate and Ultrawide rewrites** run at the same time and keep the bytes they found (above).

### Privacy: nothing leaves the device

The app sends no telemetry: no analytics, no crash reporting, and no network code but the web viewer of a game's offline pages (manuals, help). Games' own reports to Nintendo (`nn::prepo` play reports) are answered by the host, which sends nothing (`hle_offline.c`). The one path left open is closed here: a game's offline page could load an image, a script or a fetch from the internet (a tracking pixel, an analytics script); a WebKit content rule list now blocks every `http(s)` and `ws(s)` load of such a page, as navigations away from it already were.

Kept, because they stay on the device and help when something goes wrong:
- **`log.txt`:** every 5 seconds a few lines on frame times, memory, power and pipelines. It is written in the app's Documents folder, replaced at each start (the previous one is `log.prev.txt`) and never sent anywhere. The sampling is a few system queries every 5 seconds, and part of it feeds the frame-rate statistics.
- **The notification prompt:** only for games of several programs (Super Mario 3D All-Stars), for the local "Tap to start" note when one program starts another.
- **MetricKit's reports** (new), which iOS collects itself (crashes, hangs, a run ended for going over the memory limit, daily performance metrics), are only written into the app's `Documents/metrics` folder, for you to read or attach to a bug report: such an end leaves no line in `log.txt`, and the next start's `log.txt` names its report. The app sends them nowhere, and `DM_METRICS=0` turns this off. Whether iOS shares them with developers is the system's own **Share With App Developers** setting, which the app does not touch.

## Testing status

These changes were written on Linux. The user built them on a Mac at commit 31703df5 (2026-11-05), with Xcode, and ran that build on an iPhone 18 Pro Max:

- **Tested:** the Python side (mods folder, patch formats, game-data overlay, cheat packing, the switchable mods' selection, byte diff and packed pages, the build script's new stages, settings and docs checks) passes NXNative's test suite and the new tests in `dm/tools/tests/test_game_mods.py` and `test_gen_embed_variants.py`.
- **Run on a device (reported, 2026-11-05), from the 31703df5 build:** Luigi's Mansion 3 with an ultrawide mod's Ultrawide toggle, and Persona 5 Royal at 60 fps with `DM_PRESENT_INTERVAL=display` in `Documents/env.txt`, on an iPhone 18 Pro Max; the Stretch and Automatic upscaling options; both memory entitlements (`boot: memory:`).
- **Not run on a device yet:** Persona 5 Royal's launcher **Frame rate** row (`present_interval_choice`, added after that build). It sets the same `DM_PRESENT_INTERVAL`, and its Python side is tested.
- **Not compiled anywhere yet:** the gear shown on a double tap (`DmGamepad.m`, 73be18c2); Nintanium Builder's SwiftUI views (`builder/`); and the Objective-C, C and Swift changes of the 2026-11-05 checkup: the gear's showing at the start, with VoiceOver or Switch Control and over an offline web page (`DmGamepad.m`, `front_ios.m`), the in-game menu without a **Picture** row while Ultrawide stretches the picture, the render-target-only drawables (`front_ios.m`, and the drawable's one-time log line in `nvn_mtl.m`), the loader's switchable mods for a module the jit layout places and its "switchable mods put in place" line (`loader.c`), the cost of a dropped `DM_CHEATS_DEBUG` line (`hle_cheats.c`), the Duo harness's double-tap tests, and the Builder's fixes (its reading of the script's output, Copy Cheats, Stop, a library file it cannot read, builds during a pull, Cmd-N). Check them with a build on your Mac before relying on them.
- **Checked on Linux only, by their tests:** the checkup's script and tool changes: the rewriter's counter reads into x18 (`patch_nso.py`, `test_counter_gates.py`); the mods stage's reuse, the title folders of a game of several programs, and the iPad-only build without Ultrawide (`test_game_mods.py`, `test_nsp_incremental.py`, `test_nro_pack.py`); the IPA build lock and the droplet's one-after-another builds (`test_drop_build.py`, with `osacompile` stubbed); the pipeline archive kept in the work folder (`test_pso_offline.py`); and the IPA packer's parallel deflate (`test_pack_ipa_parallel.py`). None of them has run on a Mac or with a game's files yet.
- **Not compiled or run on a device yet (2026-11-05 optimizations, written on Linux):** the Low Power Mode frame-rate cap (`hle_nvn.c`), the idle upload staging trim and the depth bounds test (`nvn_mtl.m`, `nvn_rec.h`, `nvn_obj.h`, `hle_nvn.c`; their Mac tests `t_thermal.c`, `t_upload_slots.m` and `t_depth_bounds.m` have not run either), the prepare step's background task (`front_ios.m`, `main.m`, `project.yml`) and the MetricKit reports (`DmMetrics.m`, `Metrics.swift`). They were checked for syntax against stand-ins only; Apple's documentation was checked for the names and availability of the APIs they use. Check them with a build on your Mac before relying on them.
- **Checked on Linux only, by their tests (2026-11-05 optimizations):** the iOS shaders' profile key (`test_nsp_shader_key.py`), the variant rewrites at once and their kept bytes (`test_game_mods.py`), and `build_ipa.sh`'s reuse of `Gen/` and the signed copy (`dm/ios/tests/test_gen_reuse.py`, `test_ipa_unsigned.py`, with Xcode's tools stubbed). None of them has run on a Mac or with a game's files yet.
- **Not measured:** the speed-ups and savings. They follow from what the code does, but no frame times, power or memory were taken on an iPhone 18 Pro Max or an M4 iPad, and no build times on a Mac.

## Sources checked

- Apple, [Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf), version 4.1 (2026-06-04), section 1.6.10 "Compiler Options Controlling the Language Version": `metal3.2` for iOS 18, `metal4.0` for iOS 26, `metal4.1` for iOS 27.
- Apple Developer Forums: [the Metal language version follows the deployment target](https://developer.apple.com/forums/thread/704212); [a command-line Metal compile takes the SDK's version unless given a minimum](https://developer.apple.com/forums/thread/105719); [`MTL_LANGUAGE_REVISION` Metal41 in Xcode 27](https://developer.apple.com/forums/thread/842123).
- Apple documentation: [`MainActor.assumeIsolated`](https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:)) (its result must be `Sendable`), [`Binding.init(get:set:)`](https://developer.apple.com/documentation/swiftui/binding/init(get:set:)) (`@isolated(any) @Sendable` closures), [`UIActionHandler`](https://developer.apple.com/documentation/uikit/uiactionhandler), [`dismiss(animated:completion:)`](https://developer.apple.com/documentation/uikit/uiviewcontroller/dismiss(animated:completion:)), [`MTLDevice.architecture`](https://developer.apple.com/documentation/metal/mtldevice/architecture).
- LLVM: [apple-m4 and apple-a18 as one CPU, armv8.7-a](https://github.com/llvm/llvm-project/commit/eba1ef5a1b7a84ed1954797dcd6d6f073b1f1a56); [apple-a20 as an alias of apple-m6](https://github.com/llvm/llvm-project/pull/238808) (open on November 4, 2026).
- GPU names: [an M4 logs `applegpu_g16g`](https://github.com/infinigence/ApxInf/pull/143); [an iPhone Duo reports `applegpu_g19p`](https://github.com/seedds/nxnative/pull/653); [a bundled `g18p` archive crashing at boot](https://github.com/LNPANDY/NX2Apple/issues/640).
- Swift 6 and the C `stderr` global: [build logs of the error](https://swiftpackageindex.com/builds/43340118-32B0-47D7-B47B-5E6D95BA3FB9); `SWIFT_VERSION` values: [What Setting Should I Use?](https://massicotte.org/blog/what-settings/).
