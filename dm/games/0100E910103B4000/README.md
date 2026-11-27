# Thronebreaker: The Witcher Tales (`0100E910103B4000`)

Switch update 1.0.2 (v131072) over the base NSP. Unity 2018.4.2f1 IL2CPP with Wwise, SDK 8.2.1 and NVN. A provisional profile from upstream NXNative (`ffe0d357b`, `84731b379`, `d0122edf4`; MIT): upstream's Mac bring-up reached the difficulty menu and a new campaign's opening movie on an Apple M6 Mac mini. Not run on NX 18 yet.

## On NX 18

- Build it from your legally owned and acquired copy of this exact build (update 1.0.2, `v131072`, `main` `1bd04611…`); no other version is registered.
- The profile asks for 60 fps (`fps_target 60`; see [Frame rate](#frame-rate)). The Gate's Frame rate setting can pick 30.
- iPhone and iPad: untested anywhere. The heap layout is FINAL FANTASY CRYSTAL CHRONICLES' (`app_pool 0xCD500000`); check the log's `[mem] guest memory` line and the footprint first.

## What it needs

| Setting | Reason |
|---|---|
| `modules main subsdk0 sdk` | `subsdk0` is NintendoSDK_movie. The SDK and movie modules match those used by [FINAL FANTASY CRYSTAL CHRONICLES Remastered Edition](../0100CE4010AAC000/README.md). |
| 5 GiB guest block, 4.375 GiB alias region, 8 MiB system resource | The NPDM declares the system resource. Upstream's 15-second address-region check reserved up to 3.21 GiB into the alias region, including 3.14 GiB for the standard allocator. The game set no heap during the check. |
| `depth_mode zero` | The game calls `nvnDeviceSetDepthMode` with near = 0. The offline pipeline prebuild uses the matching vertex entry point. |

## Files and shaders

Upstream reports a merged RomFS of 13,568 files, about 4.2 GiB: UnityFS bundles, Wwise banks and MP4 movies under `Data/`. Its splitter found 5,952 shaders (3,439 vertex, 2,475 pixel and 38 compute), four of them GLSLC outputs in `main`; all 5,952 Mac and iOS libraries built there with no unresolved binding and no unsupported driver-bank read. The tables here (`shader_map.tsv`, `shader_pairs.tsv`, `pso_pairs.tsv`, `shader_facts.tsv`, `bf_want.tsv`) are upstream's; NX 18's split has not run on this game yet.

- Prewarm list: [`pso_manifest.tsv`](pso_manifest.tsv), 791 rows (649 `S`, 136 `R`, 6 `C`): upstream's Mac recording from a fresh boot through the opening movie, then upstream's inbox captures of 1.0.1 (`d0122edf4`). Every row checks clean against this shader map. Not recorded on NX 18's devices.

## Mac route

Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac` and use the printed run command. From a fresh save, wait for the autosave notice, then press A to continue. Start a new game, select a difficulty and press A. The opening movie has subtitles and offers a hold-B skip. On a later run, choose Continue for Lyria to reload the campaign.

## Frame rate

The profile targets 60 fps. On 1.0.2, Unity leaves `Application.targetFrameRate` at `-1` and starts with `QualitySettings.vSyncCount` at 2. The rewriter finds both through Unity's internal-call table (`dm/tools/unity_fps.py`). The host sets the count to 1 and presents at the profile's target. Upstream's offline discovery found both fields in the base NSP too, at different addresses. Set `DM_FPS_TARGET=30` for 30 fps. [Unity's frame-rate discovery](../../../docs/reference/frame-rate.md#unitys-vsynccount-and-targetframerate-found-through-the-internal-call-table)

Upstream's numbers (Apple M6 Mac mini, the same opening dialogue in Lyria): median frame time 33.15 ms at the stock setting, 16.52 ms at 60 fps, a median on-screen interval of 16.67 ms; Unity's scaled clock tracked wall time at both targets (8.09 in 8.09 s at 30 fps, 8.12 in 8.14 s at 60). Both runs reached the dialogue from the same autosave without a crash, stall or `[RED]` line.

## Found on this game

- Three of the Unity stream buffer functions matched the existing engine rule. The fourth, at `main+0x2ba7290`, stores the writer-sleep flag with `stlr` at `+0x160` and loads the reader position with `ldr` at `+0x168`; its fingerprint joins the rule's writer-sleep function (`dm/tools/engine_patches.py`), so all eight sites get their load-acquire. Upstream's two-word test on an Apple M6 saw both loads read stale values in 22 of 400,000 trials with `stlr` then `ldr`, none of 400,000 with `stlr` then `ldar`. [Unity's stream buffer handshake loses a wake-up on Apple cores](../../../docs/reference/threads.md#unitys-stream-buffer-handshake-loses-a-wake-up-on-apple-cores)

## Open

- Any run on NX 18 (Mac or phone).
- Upstream's open items: field controls, card battles and later campaign areas on the Mac; iPhone and iPad runtime.
