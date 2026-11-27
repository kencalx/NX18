# 13 Sentinels: Aegis Rim, Asian release (`01008D7016438000`)

Base game 1.00 (v0), SDK 11.4.3: the Japanese / Korean / Chinese cartridge and eShop release, under its own title ID. Vanillaware's own engine on NVN, as in the western release ([01003FC01670C000](../01003FC01670C000/README.md)), whose note covers the engine. Modules `main`, `subsdk0` (NintendoSDK_movie 11.4.3) and `sdk`. `subsdk0` and `sdk` are the western builds; `main` (`31194702…`) is not the western 1.10's (`4b632573…`), so the NSP script's lookup by main build ([`same_build`](../../../scripts/build_ipa_from_nsp.py)) does not find the western profile for it. Plays on the Mac from the base NSP alone (packed with `--platform mac`): 60 fps with sound, saving and loading (PR #161). Not tested on the iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `alloc_big_align on` | [`game.tsv`](game.tsv) | the engine's ring heaps are cut from a memory pool at 64 KB alignment; without it they do not fit the pool ([the western note, Memory](../01003FC01670C000/README.md#memory)) |
| 4 GB layout: `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000` | `game.tsv` | as the western profile: no system resource in the NPDM, the game sets a heap |
| `sys_resource 0x0` | `game.tsv` | the NPDM declares no system resource (the NSP script writes it from the NPDM) |
| `depth_mode zero` | `game.tsv` | the game sets the near = 0 depth mode, so the pipeline bases made before it runs (the NSP script's Mac prebuild, and the [pipeline archive made offline](../../../docs/development.md#the-pipeline-archive-made-offline) for the iPhone) take its vertex shaders' `main0_z` entries (the host itself follows the mode the game sets) |

No `patches.py`, no `sdk_patches.py` cut for its `sdk` build (`2d369d99…`), no `pad_layout` (the iPhone pad starts in the 2D layout). The rest of the profile is the NSP script's provisional one.

## Files and shaders

- The data is in CRI CPK archives as in the western release; `ROBO_CN.CPK` is the `romfs_marker`.
- Shaders: GLSLC outputs in `main`, with the same keys as the western release's (all 751 `shader_map.tsv` rows; `shader_pairs.tsv`, `shader_facts.tsv` and `bf_want.tsv` are identical), at other offsets in `main`.

## Found on this game

Nothing: no host change was needed.

## Open

- Not tested on the iPhone.
- `pso_manifest.tsv` is not recorded on NX 18's devices; it holds upstream's rows (below).
- **Upstream's seed rows (2026-11-27, second check):** [`pso_manifest.tsv`](pso_manifest.tsv) takes the 947 rows (751 `S`, 196 `R`, 0 `C`) of upstream NXNative's list at `1a54371cf` (its seed commits `732f50193` since the last check, and older rows; inbox captures and recordings from upstream's players); NX 18 had no rows for this game, so they are the whole list, 947 rows. Every row checks clean against this shader map. Not recorded on NX 18's devices; a first start with them on the iPhone (prepare time, footprint) is not measured.
- Only the base game was packed; no update is known.
- Whether the western base game's own `main` (v0) is this build was not checked; the western profile registers only its 1.10.
