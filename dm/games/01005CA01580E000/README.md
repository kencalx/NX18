# Persona 5 Royal (`01005CA01580E000`)

Update 1.0.2 (`v65536`) over the base game, SDK 13.3.2. Atlus GFD / Needle on NVN, with CRI middleware. Modules `main`, `subsdk0` (NintendoSDK_movie) and `sdk`.

**Current:** opening casino gameplay tested on Mac with the complete shader library. The unsigned 1.0.2 IPA is built (15,969,549,546 bytes, about 14.9 GiB). iOS and later battles have not been tested.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | [`game.tsv`](game.tsv) | the NPDM declares no system resource; the game sets a heap in the existing 4 GB layout |
| `mem_used 0x4c00000` | `game.tsv` | the rewritten modules require 76 MB, exceeding the default 64 MB deducted from the pool |
| `pad_layout full` | `game.tsv` | movement and camera use both sticks |
| `present_interval_choice on` | `game.tsv` | the launcher's **Frame rate** 30 / 60. The game asks for present interval 2 (`the game sets present interval 1 → 2`) and steps its logic by its own clock; at 60 (`DM_PRESENT_INTERVAL=display`) it showed 60 fps on an iPhone 18 Pro Max (2026-11-05), at normal speed as reported. The community 60 fps patch for 1.0.2 (StevensND, `sdk` build `357efc19…` at IPS offset `0x486DA0`, which counts the module's 0x100-byte header, so module offset `sdk+0x486ca0`: `mov w8, #1`) changes the same interval in the `sdk`'s NVN, which the host replaces, so as a mod it changes nothing here |

## Rendering

- **Resolved:** the first boot trapped in `SetupSurfaceInfoMemoryInside`, at `main+0x1028fbc`, asserting `ctx.memorySize <= localmemsetupinfo.memorySize`. A 16x16 RGBA8 texture with flags `0x44` (`IMAGE | LINEAR_RENDER_TARGET`) and stride 128 received only 1 KB from the host; the game independently calculated 2 KB. The general fix is linked below. No executable cut is needed.

- **Resolved:** the casino clears only alpha on a 1920x1080 RGBA8 texture (`mask 0x8`). The general partial-channel texture clear implementation preserves RGB and supports explicit regions; no game-specific override is needed.

## Files and builds

- `CPK/ALL_USEU.CPK` contains 94,631 files, 74,521 CRILAYLA-compressed; `CPK/PATCH1.CPK` contains one USM movie. The host reads the archives through the game's own CRI file system.
- The available release supports English, French, German, Spanish and Italian language codes. The build defaults to American English.
- Only the merged update is extracted and registered. Fixed addresses in this note refer to `main` build `d4b150b29a931cd381e2a30318fc299f`.

## Shaders

- **Resolved:** the initial split found no shaders. NEEDLE `HNSHV002` containers hold 228 shader records in `main` and 30,418 in nine GSC files inside `ALL_USEU.CPK`. The descriptor-based reader extracts 30,646 unique keys: 29,526 pixel, 1,114 vertex and 6 compute, with 3,342 single-stage cover pairs.
- All 13 shader control/code pairs captured during startup match the extracted package bytes and keys (8 from `main`, 5 from GSC files).
- **Resolved:** all 30,646 keys translated successfully for both Mac and iOS, producing 27,501 variants. The full libraries use chain `dec5ee141a9f` and profile-input stamp `f53e8a12f4ad`; there are no unfillable driver reads or undecoded bindings. Final Mac gameplay validation loaded this full stamped library on base `7a3b958`. The port was subsequently integrated onto `c3a0880`, whose upstream image-atomic changes advance the chain to `467efdfd0b62`; the affected Metal regression tests were rebuilt and passed there, but a full game shader rebuild and gameplay replay on that chain have not been performed. The existing IPA remains the validated earlier-chain build.

### Pipelines on a first start

[`pso_manifest.tsv`](pso_manifest.tsv), the prewarm list the app ships, is an iPhone 18 Pro Max's own `Documents/pso_user.tsv` from the owner's play on release 1 (`5b302cd0`, Frame rate 60): the first start, boot and about 4 minutes of play (12,500 frames), with no list present, so everything it drew was built on the spot. Its 30,923 rows are 30,357 shaders (`S`), 564 render pipelines (`R`) and 2 compute pipelines (`C`), in the order of first use, every one checked against [`shader_map.tsv`](shader_map.tsv) by `dm/tools/pso_seed.py` (keys, stages, no pointer or other device bytes, no path, no repeats). The `S` rows are kept, as in every recorded list: they are nearly the whole shader map, every library the game's program creation loads, and the prepare step loads them on every core before the first frame.

- **Without it** (that first start): the prewarm lists held nothing, and 847 pipeline bases were compiled in play (37 ms each, 31.7 s of compile time on all threads), and the submit thread waited 6.2 s for pipelines: 11 frames over 100 ms, the worst 1,142 ms (96 pipelines), 836 ms and 840 ms; in the 300 frames up to frame 4200 alone, 199 draws waited 2.36 s for a pulling base not made yet.
- **The list's own measure** (the second start, the device's list then 30,923 lines): prepared before the first frame in 2.19 s on 6 workers behind the progress screen (305 bases compiled, 140 from the device's archive, 119 reused; 564 specializations), and no frame over 100 ms in play (the longest 39 ms).
- **Its cost on a first start** (an estimate, not measured): a fresh install has no device archive, so about 445 bases are compiled (the 305 and 140 above). At the second start's 23.5 ms a base, or the first start's 37 ms, that is 10-17 s of compile time on 6 workers, so the prepare step takes about 3-5 s behind the progress screen, in place of the stalls above. The archive bundled with the app holds the shader pairs' and compute bases, not these. A Mac measurement was not possible: the Mac build folder's library image for this chain (`b-ac67cb709fa0`) holds no Mac libraries, since the release build was for iPhone.
- **What it does not cover:** places past those 4 minutes (battles, later story scenes), which still build their pipelines at their first draw, and `pso_user.tsv` records them for the next start.
- **The build:** the next build of this game runs the shader step again (its key covers the profile's files, `pso_manifest.tsv` among them; the libraries come back from the shader cache), and `pso_offline.py` compiles its compute group again, since the 2 `C` rows put those compute shaders first, then merges the archive; the 3,342 bases' groups are reused. No other game's build changes.

## Testing and running

On 2026-10-25, update 1.0.2 was tested on an M4 Pro Mac with Metal API validation enabled. Boot, startup movies, title and language menus, opening dialogue, and casino gameplay rendered. Movement, camera control and the first two platform jumps were exercised. The full-library run exceeded 35 minutes without a crash, missing shader or Metal validation error. Recent casino frame-time windows measured p50 33.33 ms and p95 33.36 ms (about 30 fps); occasional longer frames occurred during the run. Resident memory was about 1.9 GB and GPU allocations about 1.75 GB. This is an opening-sequence check, not a full playthrough.

Build with `scripts/build_ipa_from_nsp.py` pointed at the NSP folder and the local keys file. The output is `Persona5Royal.ipa`; it contains no code signature or provisioning profile. For Mac testing use the generated `<title ID>_build/tools/dmhost` and `patched_v65536`, with `DM_ROOT` set to the build directory, `DM_ROMFS` to `extract/v65536/RomFS`, `DM_MSL_DIR` to `shader/cache`, and `DM_FONT_DIR` to `font`. Set `DM_NVN_SHMAP` to this profile's `shader_map.tsv`, `DM_LANG=en-US`, and writable `DM_SAVE` / `DM_TEMP` directories under the NSP folder. See the [control-file recipe](../../../docs/agents/05-debugging.md) for `DM_CTL`.

Choose offline mode at the network prompt, then New Game and English voices. Advance the opening dialogue; Plus shows and confirms movie skipping. In the casino, the left stick moves, the right stick controls the camera, and A jumps at marked platform edges.

## Found on this game

- [Linear render-target storage without the LINEAR flag](../../../docs/reference/nvn-objects.md#linear-render-target-storage-without-the-linear-flag): sizing, row pitch and deswizzle eligibility must all recognize `LINEAR_RENDER_TARGET` independently.
- [Needle shader containers in main and GFD archives](../../../docs/reference/shaders.md#needle-shader-containers-in-main-and-gfd-archives): descriptor-based extraction of NVN control/code sections.
- [Stale prebuild files kept in the pipeline archive](../../../docs/reference/shaders.md#stale-prebuild-files-kept-in-the-pipeline-archive): an iPhone 18 Pro Max run of a fork of this tree with `DM_PSO_MTL4=1` kept 20 files of bases without a vertex layout (259.6 MB in all with the plain files) beside a bundled archive that holds every pair's base.

- [Texture clears with partial channel masks or regions](../../../docs/reference/rendering.md#texture-clears-with-partial-channel-masks-or-regions): a load/store draw applies the requested write mask and rectangle.
- [A frame that stands in the display link's queue](../../../docs/reference/frame-rate.md#a-frame-that-stands-in-the-display-links-queue) and [the iPhone's drawable at the picture's render size](../../../docs/reference/rendering.md#the-iphones-drawable-at-the-pictures-render-size): seen in its iPhone 18 Pro Max logs (enqueue to display p50 65.5 ms against a 33.2 ms lead; Stretch drawables of the screen's pixels).

## Open

- A fresh install's prepare step with the shipped prewarm list, estimated at 3-5 s ([Pipelines on a first start](#pipelines-on-a-first-start)): its `pipeline prepare` line on the iPhone, and whether play to the same place has no frame over 100 ms.
- 60 fps (Frame rate): measured speed against 30 fps over a timed scene (an in-game clock, a cutscene's length), beyond the player's report; battles and movies at 60.
- Rebuild the complete game libraries and host on the current upstream chain, then repeat gameplay validation.
- Test battles, later story scenes and save/load over a longer playthrough.
- `SetRenderEnableConditional` still reports that the host draws unconditionally. No visual failure was identified in the tested opening; conditional rendering remains unvalidated.
- Device validation remains for the user after sideloading.
- Power: the iPhone's `power up to frame` lines stay at about 4,000 wakeups a second (Super Mario Odyssey: 250–480). The encode thread is not the cause (the wakeups do not follow the draw count, and Super Mario Odyssey has the same thread); the `threads up to frame` line's wake sources ([Power](../../../docs/development.md#power), "Wake sources") are to say which source it is, from a new device log. Not yet measured.
