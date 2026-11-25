# Fire Emblem Fortune's Weave (`04007EF01F8AE000`)

A Switch 2 game: v131072, SDK 22.2.0 built for the Switch 2 (`Ounce`), NVN2 API 231.40. Intelligent Systems' engine on NintendoWare (G3d, Ui2d, Vfx, Atk), PhysX 5.6, a deferred renderer. Modules `main`, `subsdk2` (movies) and `sdk`; `subsdk0` (DLSS) and `subsdk1` (CUDA) are not loaded. **Plays on the Mac**: the opening movie, the dialogue and the first battle map, whose first turn matches published footage, and its battle scenes in the user's playtest. **Plays on the iPhone 18 Pro Max** (X1.0, handheld): about 18.7 minutes of the owner's play at 60 fps on a fresh install; the app's prewarm list now holds the rows that run recorded too ([On the iPhone](#on-the-iphone)).

## What it needs

| Setting | Where | Why |
|---|---|---|
| `mem_alias 0x400000000`, `mem_reserve 0x550000000`, `mem_stack 0x10000000`, `app_pool 0x240000000` | [`game.tsv`](game.tsv) | Splatoon Raiders' split as a starting point; the Switch 2's 9 GB |
| `sys_resource 0x4000000` | `game.tsv` | the NPDM declares 64 MB, so virtual address memory is on |
| `pad_layout full` | `game.tsv` | the game asks for most of the controller at once |
| `zip_store .zst:.mp4:.webm:.metallib` | `game.tsv` | the RomFS's files are compressed already |
| `fps_target 60` | `game.tsv` | the host writes 60 into the game's target frame rate, which the rewriter finds by its readers in any build; see [Frame rate](#frame-rate) |
| `fps_max 120` | `game.tsv` | **Frame rate** offers 120 on the Mac: speed measured below; see [Frame rate](#frame-rate) |
| `depth_mode zero` | `game.tsv` | the game selects near-zero NVN depth; offline pipeline bases must use the matching vertex entry. Without it the app's bundled archive (661.6 MB on an M1 Pro) was refused at every start and the Mac built 872 MB of bases of its own in the background |

No `render_cond`: not tried, and nothing has called for it so far.

## Files

- A dump folder of the player's own copy holding only `exefs/` and `romfs/`, with no `base/` layout: a RomFS of 28 GB. The NSOs are ZBIC-compressed, so tools that read them need the `zbic` package in the work folder's venv.
- Shaders: 16,888 in [`shader_map.tsv`](shader_map.tsv), from `Shaders/*.bfsha.zst` and the effect and layout packages.
- Movies: 82, AV1 in WebM at 2560x1440 ([AV1 movies through SDK 22's decoder](../../../docs/reference/movies.md#av1-movies-through-sdk-22s-decoder)). A Mac without a hardware AV1 decoder (before M3) decodes them with dav1d.

## Shaders

All 16,888 translate (current). One shader has 10 texture handles the translator cannot resolve (`Failed to find handle source for bindless access of type "texture2D"`) and one logs `Invalid reduction type: F32FtzRn`; neither has been traced to anything visible (open).

## Rendering

- The battle map renders at 1024x576 and DLSS, on MetalFX here, takes it to 2048x1152 ([NVN2's DLSS on MetalFX](../../../docs/reference/rendering.md#nvn2s-dlss-on-metalfx)), which is scaled to the 3840x2160 window. The network's size follows the display ([The display's largest buffer](../../../docs/reference/services.md#the-displays-largest-buffer)).
- Auto exposure does not meter the scene. `5372c7e7cb7bbda2` writes one luminance into a 16x16 RGBA16F target (134.4 on the first map, log2 7.07), `6d0f6db3f0d396a3` makes a 256-bin histogram of it (the single bin 218), and `a0c632d8b5fa925b` averages its 10th to 90th percentile with a 64-bit division, takes the average through two 256x4 curves and moves a 3x1 R16F image towards the result. The tonemap reads `2^-(image[0] + 3) × 1.44`. On the first map `image` holds 8.96, 18.89, 9.46 with neither of the translator fixes below, and 5.555, 15.195, 6.055 with them, when the picture matches the footage. At a scene change the game clears the image to 1 and dispatches these shaders ([Pending clears land before a compute dispatch](../../../docs/reference/rendering.md#pending-clears-land-before-a-compute-dispatch)).
- Ambient occlusion is interleaved: depth into a 4-layer 512x288 array, four triangles picking the layer by primitive ID, then back together at 1024x576 ([`[[primitive_id]]` in a specialized Metal 4 pipeline](../../../docs/reference/rendering.md#primitive_id-in-a-specialized-metal-4-pipeline)).
- The enemy's checkered look and the pale squares over the ground are in the published footage too: both are the game's.
- Frame time: 33 ms with the window on screen at the game's own 30 fps (16.7 ms at `fps_target 60`, [Frame rate](#frame-rate)), and GPU about 12 ms. A covered window reads 80-180 ms, the host's display-link fallback (`front end: window covered`), which measures nothing.
- Resolved: at Alcineus Bridge on an M1 Pro (macOS 27.2, 1080p output) the scene ran at 4.24 fps, the lighting pass 196.7 ms of a 236 ms frame, while its reads of a uniform buffer's handle table were marked through a null address ([Reads of a handle table marked through a null address](../../../docs/reference/shaders.md#reads-of-a-handle-table-marked-through-a-null-address)). PR #1738's host bitmap measured 56.1 fps and 2.35 ms there (on `bd979ce`, chain `3ee52af3ca18`); the chain change that replaced it was not run on an M1 Pro.

## Frame rate

- **Current:** 60 fps (30 in gameplay as shipped). The game's graphics object, a global at `[main+0x21e60d8]`, holds the display rate at +0x1d8 (60), the target frame rate at +0x1dc and the longest present interval at +0x1e0 (5). The present (`main+0x648da0`, through `gxc::NvnDevice`'s present, its vtable's slot 3 at `main+0x5d170`) asks for interval min(+0x1e0, +0x1d8 / min(+0x1d8, +0x1dc)).
- The game sets the target to 60 at `main+0x652960` and `main+0x66af3c` (the title and menus run at 60) and to 30 at `main+0x7bf1c0`, where gameplay starts, which makes it interval 2. 59 readers step the game by 60.0 / target (`main+0x770d5c`, `main+0x11e6310`, `main+0x13a6c94`): 2.0 a frame at 30, 1.0 at 60.
- The rewriter finds the field by those readers and the store of 30, with no build ID ([A target frame rate the game steps by](../../../docs/reference/frame-rate.md#a-target-frame-rate-the-game-steps-by); `dm/tools/fps_target.py`: 55 of the 59 readers have the pattern it matches, `FPS_TARGET_PTR 0x21e60d8`, `FPS_TARGET_FIELD 0x1dc` in main's fixups), and the host writes the profile's `fps_target` there on every present where it differs (`hle_fpslock.c`, "target frame rate"). The game then asks for interval 1 itself. On an M4 Pro the battle map holds frame time p50 16.7 ms, p95 17.1 ms, about 2 frames of 300 dropped, in a window. Headless with the found field (2026-11-03, M4 Pro, A every 0.8 s from the title into gameplay): the game sets interval 1 → 2, the host writes 30 → 60, the game sets interval 2 → 1 (`main+0x5d1c8`), p50 16.6-16.7 ms through frame 7200.
- `DM_FPS_TARGET=30` (the settings window's Frame rate) writes 30, menus included, where the game itself chose 60.
- Not measured: game speed at 60 against 30 over the same route (the player saw battles at 60 with nothing reported fast).
- **Current: 120 fps on the Mac when chosen** ([120 fps follows the frame step](../../../docs/reference/frame-rate.md#120-fps-follows-the-frame-step)). The present (`main+0x649920`) still asks for interval 1, as 60 / min(60, 120) = 1, and all 60 reads of the target found through the global are floats, so the step takes 0.5. Nothing ties this to a build: the rewriter finds the field in any main, and `fps_max` is not gated. v131072 is the only version tested. The target follows what fits, so frames at 60 step by 1.0 and the game keeps its speed; before that, the same field at a fixed 120 would have run a 70 fps scene at 58%.
  - Speed: from one save on a battle map, the same timed cursor holds (0.3, 0.5 and 1 s, then back) at 120 and 60 stop at the same place on all eight shots: the best match between each pair is a shift of zero pixels (2026-11-04, M6, headless). The user played at 120 and saw the speed as right. The holds are in whole tiles and the rest was judged by eye, so a difference of a few percent would not show.
  - Frame rate: on the map, headless, 107-119 fps with 96-100% of frames at 120 per 1,800 frames (frame time p50 8.3 ms, GPU 5.5 ms, about 840 draws). In the window on the prototype, without the fallback, most of the user's session held 106-117 fps at 600-990 draws, and 65-72 fps where the GPU took 12-13 ms; that stretch would now run at 60. Added lag of 12 ms a frame holds a steady 60 with the target at 60. In a window the host picks the 120 Hz display link by itself (open: the frame rate of this build in a window; the one short run had two other games running on the Mac and measured nothing).
  - Known: `game::telop::ListResultMenuItemBase` (`main+0x17885f8`) adds max(int(step), 1) to a timer each update, 8 times that while an input flag is set, so its In / Out timer runs at double speed at 120. It is a results list's menu item, a matter of looks, and is left as it is (a cut would tie this to the build). Systems that ignore the step altogether would also run fast; none has been seen so far.

## On the iPhone

The owner's start on an iPhone 18 Pro Max (A20 Pro GPU), the X1.0 build (`6448f757`, chain `222e58e346d6`), v131072, handheld (graphics scale tier 0), Picture Stretch, no upscaling, no edge smoothing, Frame rate 60, a controller: the first start after a fresh install, with the app's 1,811-row prewarm list (the Mac recording) and an empty device archive. From its `log.txt` (`scripts/devlog.py`):

| | First start (fresh install) |
|---|---|
| Played | about 18.7 minutes (55,814 frames) |
| Before the first frame | the app's 1,811-line list prepared in 1.14 s on 6 workers: 2 bases compiled, 379 from the archive (333 layout bases from the archive bundled with the app), 60 reused; its 26 compute pipelines from the app's archive |
| Bases compiled in play | 185 (21.6 s of compile time on all threads); the submit thread waited 1.22 s for pipelines |
| Frames | 60 fps (the power windows' median); frame time p50 16.67 ms, p95 17.46 ms; 389 of 55,732 frames dropped (0.7%) |
| Frames over 100 ms | 12, 5 of them with new pipelines (336, 253, 178, 131 ms, and the first frame's 879 ms, mostly its present); the longest, 3,064 ms, spanned a system applet (a focus change) |
| GPU time p50 | 10.49 ms |
| CPU | 0.49 W (median), 8.3 mJ a frame; thermal state 0 throughout |
| Memory | footprint at most 1.93 GB; at least 6.26 GB of headroom to the app's limit |
| Enqueue to display p50 | 28.16 ms |

No audio underrun. The archive bundled with the app (933.1 MB) was taken (`holds the bases of every shader pair (16 of 16 probed bases found)`). The address space held: the host reserved the guest's 16 GB alias region, the game's allocator took the 15.69 GB it has room for (`StandardAllocator::Initialize(nullptr, 36.00 GB) … 15.69 GB of address space`), and the region was mapped up to +15.75 GB. `[RED]` lines: the known `stage 1 cb4 has no uniform buffer bound` once, and 17 `command buffer execution error` lines from about frame 17,100, the first with `Discarded (victim of GPU error/recovery)` ([Open](#open)).

### Pipelines on a first start

[`pso_manifest.tsv`](pso_manifest.tsv), the prewarm list the app ships, is the Mac recording (1,811 rows: boot, the opening movie, the dialogue, the first battle map to its enemy phase) and, below it and its own note, that iPhone's own `Documents/pso_user.tsv` after the run. `pso_user.tsv` records only what the list did not hold, so its 474 rows, 220 shaders (`S`), 241 render pipelines (`R`) and 13 compute pipelines (`C`), are all new: the list now has 2,285 rows (1,563 `S`, 683 `R`, 39 `C`), in the order of first use. `dm/tools/pso_seed.py` checked every row against [`shader_map.tsv`](shader_map.tsv), the profile's at `6448f757`, the commit the phone's build was made from (16,888 entries, as the log's `shader map 16888 entries`): none refused, none repeated, none a repeat of a Mac row. Grown on 2026-11-16 by the 3,711 rows (2,058 S, 1,608 R, 45 C) the owner's iPhone recorded over two X2.0 sessions (`431d5d18`, about 35 min, which compiled 687 bases in play; `29dcbb4d`, about 9 min, 77), its geometry-path rows left out: 5,996 rows in all (3,621 S, 2,291 R, 84 C). On that phone the second session's start took 9.3 s, most of it a one-time compaction of its own pipeline archive (49 files, 447 bases captured again, about 6 s), not the list.

- **What it changes:** a fresh install also prepares the 474 rows before its first frame, so the run's in-play compiles (185 bases, 5 frames over 100 ms with new pipelines, up to 336 ms) move into the prepare step and, at the next build, into the app's bundled archive, whose layout bases `pso_offline.py` then also makes for the 241 new `R` rows ([Pipelines with a vertex layout compiled at a fresh install's prepare step](../../../docs/reference/shaders.md#pipelines-with-a-vertex-layout-compiled-at-a-fresh-installs-prepare-step)); its plan for this list has not been run.
- **Its cost on a fresh install** (an estimate, not measured): the run's 1.14 s for the 1,811 rows, with nearly every base from the app, plus the 220 libraries and the new bases: about 1.3-1.5 s with those bases in the app's archive, or about 3-6 s if it does not serve them (at most 241 more bases at 7.6 ms, Xenoblade Chronicles: Definitive Edition's measured prepare step, to 20 ms a base on 6 workers).
- **In play after it:** places past those 18.7 minutes still build their pipelines at their first draw, and `pso_user.tsv` records them.
- **The settings:** handheld and Picture Stretch change no row: the stretch is the host's present, and a row's pipeline key (`pso_skey`) holds no picture size. Docked play on the iPhone was not recorded.
- **The build:** the next build of this game runs the shader step again (its key covers the profile's files, `pso_manifest.tsv` among them), and `pso_offline.py` compiles its compute groups again (the 13 new `C` rows move those shaders up) and the new layout groups. No game build was run for this change. No other game's build changes.

## Driving it on the Mac

Keyboard in a window: J K U I are A B X Y, WASD the left stick, Shift + arrows the right stick, Z and C are ZL (threat range) and ZR (settings). The work folder has `win.sh` (a window with Metal's HUD, `run/ctl.txt` as `DM_CTL`), `mash.sh <secs> [dir]` (A every 0.8 s, with shots), `rebuild.sh` (a host copy, `build/fewhost`), `shaders.sh`, and `scripts/shdump.py <key> [ops]` for a shader's raw instructions. Pressing A from boot goes through the movie and the dialogue to the first battle map in about 80 s. Serials shift between runs, so read them from a pass dump; `DM_NVN_PASSDUMP_ALL=1` lists every dispatch's bindings.

## Open

- On the Mac, nothing past the first map has been played on this build. The iPhone run's 18.7 minutes were not mapped to a route.
- `stage 1 cb4 has no uniform buffer bound`, once a run, with no effect seen.
- MetalFX's jitter sign is unchecked, and what this game's DLSS bias mask holds has not been looked at (it reaches MetalFX as its reactive mask: [NVN2's DLSS on MetalFX](../../../docs/reference/rendering.md#nvn2s-dlss-on-metalfx)). No ghosting has been seen so far.
- A fresh install with the 2,285-row prewarm list on the iPhone, estimated at about 1.3-1.5 s of prepare step ([Pipelines on a first start](#pipelines-on-a-first-start)): its `pipeline prepare` line, and whether play to the same places has none of the 5 frames over 100 ms with new pipelines.
- 17 `[RED] command buffer execution error` lines on the iPhone from about frame 17,100, the first with `Discarded (victim of GPU error/recovery)`: another command buffer's GPU fault, which the log does not name. Nothing in the run's frame lines points at it; not reproduced.
- `dm/games/profile_guess.py` does not recognise the SDK's `Generic` version name.

## Found on this game

- [The split shader tables differ from a game profile's](../../../docs/reference/packing.md#the-split-shader-tables-differ-from-a-game-profiles): the `main` duplicate-selection mismatch is resolved, 2026-11-17, with the registered shader identities preserved.
- [Scaled shared memory addresses](../../../docs/reference/shaders.md#scaled-shared-memory-addresses) and [IMAD.HI adds a register pair, and IMAD.X its carry](../../../docs/reference/shaders.md#imadhi-adds-a-register-pair-and-imadx-its-carry): the dark map.
- [Pending clears land before a compute dispatch](../../../docs/reference/rendering.md#pending-clears-land-before-a-compute-dispatch): battles and scene changes blown white.
- [NVN2 compute reads its workgroup counts at c0 + 4](../../../docs/reference/shaders.md#nvn2-compute-reads-its-workgroup-counts-at-c0--4).
- [Texture handles of SDK 22's Ampere code](../../../docs/reference/shaders.md#texture-handles-of-sdk-22s-ampere-code): white units.
- [A table of handles past the array's length](../../../docs/reference/shaders.md#a-table-of-handles-past-the-arrays-length): black characters.
- [Reads of a handle table marked through a null address](../../../docs/reference/shaders.md#reads-of-a-handle-table-marked-through-a-null-address): 4 fps at Alcineus Bridge on an M1 Pro.
- [`[[primitive_id]]` in a specialized Metal 4 pipeline](../../../docs/reference/rendering.md#primitive_id-in-a-specialized-metal-4-pipeline): the dot lattice over the ground.
- [NVN2's DLSS on MetalFX](../../../docs/reference/rendering.md#nvn2s-dlss-on-metalfx).
- [Bindless shaders taken as depth readers](../../../docs/reference/rendering.md#bindless-shaders-taken-as-depth-readers): the battle maps' decals split the G-buffer pass about 31 times a frame.
- [System applets opened by `Show…` calls](../../../docs/reference/services.md#system-applets-opened-by-show-calls): a null read in `nn::applet::CreateLibraryApplet` at the title about 100 s in, the strap guide overload with a `StrapGuideArg`.
- [A target frame rate the game steps by](../../../docs/reference/frame-rate.md#a-target-frame-rate-the-game-steps-by): gameplay at 60 fps.
- [120 fps follows the frame step](../../../docs/reference/frame-rate.md#120-fps-follows-the-frame-step).
- [AV1 movies through SDK 22's decoder](../../../docs/reference/movies.md#av1-movies-through-sdk-22s-decoder).
- [The Joy-Con mouse pointer](../../../docs/reference/services.md#the-joy-con-mouse-pointer) and [The display's largest buffer](../../../docs/reference/services.md#the-displays-largest-buffer).
- [The output device notification under its SDK 21 and 22 name](../../../docs/reference/audio.md#the-output-device-notification-under-its-sdk-21-and-22-name): an abort at start without it.
- [An SDK 21 Switch 2 game with a 4.5 GB alias region](../../../docs/reference/memory.md#an-sdk-21-switch-2-game-with-a-45-gb-alias-region): SDK 22's node area.
- The title screen's hand-over to the opening demo finalizes a program its queue still has bound: [Finalized programs leave every queue's bindings](../../../docs/reference/nvn-objects.md#finalized-programs-leave-every-queues-bindings) (resolved).
- [Top mip levels left out on the phone](../../../docs/reference/memory.md#top-mip-levels-left-out-on-the-phone): the mip drop line's tally of why an upload kept every level (`md_tally`), after the 2026-11-15 round left out the levels of only 0-1 of its textures with about 1.3 GB of packaged textures.
- [Innocent-victim GPU errors said nothing of what ran beside them](../../../docs/reference/rendering.md#innocent-victim-gpu-errors-said-nothing-of-what-ran-beside-them): 7 command buffers discarded as innocent victims as an AV1 movie stopped (the 2026-11-15 round); the run's first one now says what was in flight, open.
- [A compacting start captured every old base again before its first frame](../../../docs/reference/rendering.md#a-compacting-start-captured-every-old-base-again-before-its-first-frame): a start of 9.32 s on the owner's iPhone, 447 bases captured again in its prepare step (8.41 s); now after the first frame.
