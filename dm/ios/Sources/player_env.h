// Opt-in player builds ignore saved diagnostic overrides while retaining the
// FPS/HUD, controller, language and normal launcher settings. The game profile
// and bundle still supply the renderer's required paths and compatibility keys.
#pragma once
#include <string.h>
#ifndef DM_DEV_BUILD
#define DM_DEV_BUILD 0   // 1: a developer build of the owner's (NX18_DEV, dm/tools/nx18_dev.py; build_ipa.sh compiles it so), never a player's
#endif
// Kept from env.txt in a player build too, so the owner can A/B the X1.0 changes on the phone (docs/development.md, the player build's list): measurement-only diagnostics
// that change no behaviour (DM_NVN_WAITS: the wait ledger; DM_SLOWFRAME: the long-frame rows; DM_POWER_DETAIL: the power detail line), the yield storm arm (DM_YIELD_STORM) and parked yields (DM_YIELD_PARK, on by default: =0 the old spinning yield path), the switches that turn a profile's X1.0 change off or the field log back to X1.0's
// lines, DM_NVN_GHOST, which takes a profile's ghost_table back to 512 (or sets another size), DM_NVN_MDX_PRESCAN, whose =0 or =ab is X2's on-battery A/B of the pass-split fix (Mario Kart World),
// DM_SW2_MODE, the experimental Switch 2 answer (off by default; hle_sdk16.c), and the GPU memory switches of the ntzuca port's phone A/Bs: DM_NVN_BCRT_CACHE (the render-target shadow
// cache by format and size), DM_NVN_FAMILY_PFV (32-bit integer family members with the format-view usage), DM_NVN_FAMILY_NOCOMPRESS (=1: resolution families
// uncompressed, without the valid-size tracking, as before upstream NXNative 4015ce2c0's port; rendering.md), DM_NVN_FB_SNAP_KEEP and DM_NVN_FB_SNAP_IDLE (feedback snapshots kept after
// coming back, and the idle release), and the GPU switches of the upstream ports that each wait for an iPhone battery A/B: DM_NVN_FB_TILE_EARLY (=1 turns on, =0 off, the tile read of a
// draw that samples an attachment it writes and opens its pass, off on iOS by default; Breath of the Wild), DM_NVN_PASS_SPLIT and DM_NVN_PASS_SPLIT_MAX (the long render pass split
// and its limit per pass, off on iOS by default; Breath of the Wild and Ocarina of Time) and DM_NVN_MFX_DIRECT (=0 or =ab: MetalFX's input copied into RGBA16F again, with
// DM_UPSCALER=metalfx; a picture and battery A/B on Ocarina of Time), DM_NVN_PREDICT_NEXT (=0 or =ab: the look-ahead's old bound of two pipelines a
// submission, for the battery A/B of upstream PR #1344; shaders.md), and DM_NVN_SUB_MERGE (=0 or =ab: every submission committed on its own again, as before the held
// submissions of upstream b2ae958f2; Ocarina of Time's iPhone frame-rate A/B) with its two fallbacks, DM_NVN_SUB_IDLE_FB (=1 or =ab: held submissions released on the commit feedback's
// count, not the queue event, which has not run on a phone) and DM_NVN_SUB_DRAIN (=1 or =ab: the replay waits for the encode thread at each submission's end again), and DM_NVN_DISPATCH_RANGE (=0: a barrier before every
// compute dispatch again, as before the range rule ported from S2Arm 116fe90e; =1 that range rule, as before the game's barriers of S2Arm a51b43f7; =ab alternates 1 and the default; rendering.md), and DM_NVN_BG_PURGE (=0: the host's textures stay non-volatile in the background, for the
// footprint and resume A/B of the background purge, S2Arm 23b99c4a), and DM_NVN_RT_DEAD with DM_NVN_RT_DEAD_MS and DM_NVN_RT_DEAD_PRESSURE
// (=0 or =ab, on by default: render targets another one drew over released after the wait, and sooner at memory pressure; any game's memory A/B, Ocarina of Time's first; memory.md), and DM_NVN_DEPTH_LAZY (=1: depth textures of 64 MB or more take
// memory only where the GPU writes them, for the memory and GPU-time A/B on Ocarina of Time's save load; memory.md), and DM_NVN_MIP_DROP with DM_NVN_MIP_DROP_MIN
// (=1 or =2: large block-compressed textures made without their top levels, off by default; the phone's memory and battery A/B, memory.md), with DM_NVN_MIP_DROP_COMPRESSIBLE
// and DM_NVN_MIP_DROP_PARTIAL (=0 / =1: the two kinds of texture it may also take), and DM_NVN_SHARED_IDLE with DM_NVN_SHARED_IDLE_SUBS (=1, =2, off by default: shared textures kept by the
// sharing table alone and long unused, memory.md),
// and DM_NVN_TBUF_GPU_COPY (=0: texel buffers below Metal's alignment copied on the CPU again, as before S2Arm 8aa6f66c), and DM_NVN_BG_LOOK (=0 or =ab: the look-ahead's base
// lookups on the submit thread again, as before upstream 9d3a58364; Ocarina of Time's first-visit A/B, frame-rate.md), and DM_NVN_GPUPROF (measurement only: every:<n> times each GPU pass of one frame in n, for finding what to cut in a game that misses 60 at the phone's lower GPU clock; NX18-X2.0 gpu-clock-collapse.md), and DM_NVN_WIN_AREA (=0: passes on the window textures cover the whole texture again, the off side of its phone A/B; rendering.md), and DM_NVN_PASS_ALT (=0: a profile's pass_alternate pass drawn every frame, the Quality preset and its A/B), and DM_NVN_BARRIER (=full: every draw pass behind the full barrier again, the off side of a profile's draw_barriers game; rendering.md), and DM_NVN_PCM (=0: one-draw passes keep their render pass, the off side of a profile's pass_compute; =ab alternates; rendering.md), and DM_NVN_GEOMETRY_JOIN (=0: a colour-less geometry draw ends an open pass with colours again; rendering.md), and DM_NVN_FACE_SPLIT with DM_NVN_FACE_MERGE (=0: upstream 30d892158's face-split draws, or their merge, off; on by default, for a phone check of cube-map reflections), and DM_NVN_TRIM_FRAMES (=0: the idle trims count submissions as frames again, the old side of the Ocarina memory A/B; NX18-X2.0 oot-alldata-analysis.md), and DM_NVN_ARGS_STATS (measurement only: =1 adds the [args-stats] lines, what makes argument blocks encode again and where their encode time goes, for Ocarina of Time's long phone run; NX18-X2.0 bindless-study.md step 0), and DM_NVN_ARGS_PARTIAL (=0: argument blocks whose texture, sampler, storage or base instance changed are encoded in full again, the off side of the partial patches' phone A/B; frame-rate.md). Named one by one: every other DM_NVN_* and test switch stays filtered
// Also kept (2026-11-20 performance batch; each =0 restores the old behaviour, for its phone A/B): DM_NVN_CUBE_ALT and DM_NVN_UP_BILINEAR (Bananza's preset picture trades,
// off in Quality), DM_FPS_CTL_PROBE (the controller's tries at 60), DM_NVN_DIRTY_INDEX (the write-fault hook's address index), DM_NVN_REUPLOAD_COALESCE (banded, coalesced
// re-uploads), DM_NVN_RES_ASYNC (residency commits off the replay), DM_NVN_MFX_CONTENT (one MetalFX scaler per output), DM_NVN_POOL_MEMO, DM_NVN_POOL_ENTRY, DM_NVN_ARGS_DRV and DM_NVN_ARGS_REGCHK,
// DM_NVN_TEX_SEQ and DM_NVN_TEX_ALT2 (texture lookups past the cached view), DM_NVN_RES_PREWIRE (=0: residency commits page guest files in holding the lock; DM_NVN_PREWIRE_JOBS=1: its mlock calls one after another, as before; DM_NVN_TEX_READAHEAD=0: no read-ahead of texture storage at setup; DM_NVN_PF_PARTS=1: the replay's page-ins by part in long-frame lines; DM_NVN_POOL_READAHEAD=1: the pool walk's read-ahead (off by default); DM_NVN_EDGE_COLD=0: a packaged texture's edge bytes taken even with their pages out of memory; DM_NVN_PREREAD=1: read-ahead of pools, buffers and textures at setup (off by default); DM_NVN_RES_TRICKLE_MB=<MB>: addressed pools made resident a submission at a time ahead of the raw memory table (off by default);
// again) and DM_NVN_IDLE_TEX_FOOT_MB (=0: no footprint cap for idle live textures; =<MB> another cap; frame-rate.md), with DM_NVN_IDLE_TEX_PKG (=0: packaged textures
// kept, as before) and DM_NVN_IDLE_TEX_FOOT_TRIM (=0: no cache trim for the cap; the same frame-rate.md entry)
// (argument-block levers), DM_NVN_BINDLESS (=1: stage 1's slot tables built and checked, measurement only), DM_NVN_QUERY_POOL (pooled occlusion queries), DM_NVN_SUB_YIELD (the replay lends g_sub_mu mid-node), DM_NVN_SAME_CLEAR, DM_NVN_FB_DSNAP and
// DM_NVN_UNWRITTEN_LOAD (render-pass savings), DM_NVN_SAME_CLEAR_TRI (=0: a masked stencil clear drawn at once again, fcdc1fd0's same-clear skip), DM_NVN_STAGE_POOL_MB (=0: no upload staging pool,
// temporary staging blocks freed after each batch again; =<MB> its cap; S2Arm 01afd92a, 6e708d3e),
// DM_NVN_SPARSE_LOG (=0: a whole sparse texture's page table walked at every check again, as before S2Arm de791716's change log),
// DM_NVN_IDLE_TEX_MB (=0: live textures idle at low headroom kept, as before S2Arm 8adc5673's port; memory.md),
// DM_NVN_I2F_NATIVE (=0: 8 / 16-bit integer-read-as-float vertex formats converted on the CPU again, as before ComicBit 39cc2e79c's native fetch; rendering.md),
// DM_NVN_SHADER_SHARE (=0: each shader loading path prepares its own copy of a library again, as before ComicBit bee12ec's port; shaders.md),
// DM_NVN_UP_SLOTS (=3: three upload slots again, the off side of Breath of the Wild's upload_slots 8, adapted from MacNativeGames 6ecb27c1; frame-rate.md),
// DM_NVN_GMEM_KEEP (=0: the raw pool table built again at every change of the pool set, as before MacNativeGames b964bd4e's port; frame-rate.md),
// DM_GPU_LOST_S (the GPU hang watchdog's limit, =0 off; nvn-objects.md), DM_NVN_CUT_HOLD and DM_NVN_CUT_EVENT (=0 or =ab: a segment boundary with earlier work running stays
// open again, and the cut reads the commit feedback again; Ocarina of Time's warm-phone frame-rate A/B, frame-rate.md),
// DM_GPU_LOST_S (the GPU hang watchdog's limit, =0 off; nvn-objects.md); reference: docs/env_switches.tsv
// again) and DM_NVN_IDLE_TEX_FOOT_MB (=0: no footprint cap for idle live textures; =<MB> another cap; frame-rate.md), DM_NVN_UNWIRE_UP (=m counts, =1 takes upload-only pools out of
// the residency set, =0 off; frame-rate.md), DM_NVN_CACHE_VOLATILE (=0: idle reuse-cache entries stay non-volatile, as before; frame-rate.md)
// the residency set, =0 off; frame-rate.md), DM_NVN_PASS_REPEAT (=1, measurement only: the [pass repeat] line, the share of render passes recorded as one of the previous frame; frame-rate.md)
// DM_NVN_LS_STATS (=1, measurement only: the [ls-stats] lines, attachment loads and stores by pass kind and the stores no later pass loads), DM_NVN_CLEARED_LOAD, DM_NVN_DS_DEAD_STORE,
// DM_NVN_MSAA_RESOLVE_ONLY and DM_NVN_HOST_BARRIER (=0 each: that attachment-traffic or barrier reduction off, for the phone A/B; frame-rate.md), DM_NVN_ACQ_NEXT (=0: an acquired
// image's sync is the commits at the acquire again, not the GPU end of the present after it, for a frame-rate A/B of upstream 1999cbd1f; frame-rate.md)
static const char *const dm_player_kept_keys[]={"DM_NVN_WAITS","DM_SLOWFRAME","DM_REPLAY_RT","DM_REPLAY_SPARES","DM_FPS_HOLD_BACKOFF","DM_FPS_RESUME","DM_MOVIE_RESTART","DM_FIELD_LOG","DM_POWER_DETAIL","DM_YIELD_STORM","DM_YIELD_PARK","DM_NVN_GHOST",
    "DM_NVN_MDX_PRESCAN","DM_SW2_MODE","DM_NVN_BCRT_CACHE","DM_NVN_FAMILY_PFV","DM_NVN_FAMILY_NOCOMPRESS","DM_NVN_FB_SNAP_KEEP","DM_NVN_FB_SNAP_IDLE",
    "DM_NVN_FB_TILE_EARLY","DM_NVN_PASS_SPLIT","DM_NVN_PASS_SPLIT_MAX","DM_NVN_MFX_DIRECT","DM_NVN_SUB_MERGE","DM_NVN_SUB_IDLE_FB","DM_NVN_SUB_DRAIN","DM_NVN_CUT_HOLD","DM_NVN_CUT_EVENT","DM_NVN_PREDICT_NEXT","DM_NVN_DISPATCH_RANGE","DM_NVN_BG_PURGE","DM_NVN_CACHE_VOLATILE",
    "DM_NVN_RT_DEAD","DM_NVN_RT_DEAD_MS","DM_NVN_RT_DEAD_PRESSURE","DM_NVN_DEPTH_LAZY","DM_NVN_MIP_DROP","DM_NVN_MIP_DROP_MIN",
    "DM_NVN_MIP_DROP_COMPRESSIBLE","DM_NVN_MIP_DROP_PARTIAL","DM_NVN_SHARED_IDLE","DM_NVN_SHARED_IDLE_SUBS",
    "DM_NVN_TBUF_GPU_COPY","DM_NVN_BG_LOOK","DM_NVN_GPUPROF","DM_NVN_WIN_AREA","DM_NVN_PASS_ALT","DM_NVN_BARRIER","DM_NVN_PCM","DM_NVN_GEOMETRY_JOIN","DM_NVN_FACE_SPLIT","DM_NVN_FACE_MERGE","DM_NVN_TRIM_FRAMES","DM_NVN_ARGS_STATS","DM_NVN_ARGS_PARTIAL","DM_NVN_CUBE_ALT","DM_NVN_UP_BILINEAR","DM_FPS_CTL_PROBE","DM_NVN_DIRTY_INDEX","DM_NVN_REUPLOAD_COALESCE","DM_NVN_RES_ASYNC","DM_NVN_RES_PREWIRE","DM_NVN_PREWIRE_JOBS","DM_NVN_TEX_READAHEAD","DM_NVN_PF_PARTS","DM_NVN_POOL_READAHEAD","DM_NVN_PREREAD","DM_NVN_RES_TRICKLE_MB","DM_NVN_EDGE_COLD","DM_NVN_IDLE_TEX_FOOT_MB","DM_NVN_IDLE_TEX_PKG","DM_NVN_IDLE_TEX_FOOT_TRIM","DM_NVN_MFX_CONTENT","DM_NVN_POOL_MEMO","DM_NVN_ARGS_DRV","DM_NVN_ARGS_REGCHK","DM_NVN_TEX_SEQ","DM_NVN_TEX_ALT2","DM_NVN_QUERY_POOL","DM_NVN_SUB_YIELD","DM_NVN_SAME_CLEAR","DM_NVN_FB_DSNAP","DM_NVN_UNWRITTEN_LOAD","DM_NVN_SAME_CLEAR_TRI","DM_NVN_SPARSE_LOG","DM_NVN_STAGE_POOL_MB","DM_NVN_IDLE_TEX_MB","DM_NVN_I2F_NATIVE","DM_NVN_SHADER_SHARE","DM_NVN_UP_SLOTS","DM_NVN_GMEM_KEEP","DM_GPU_LOST_S","DM_NVN_POOL_ENTRY","DM_NVN_BINDLESS","DM_NVN_UNWIRE_UP","DM_NVN_PASS_REPEAT","DM_NVN_LS_STATS","DM_NVN_CLEARED_LOAD","DM_NVN_DS_DEAD_STORE","DM_NVN_MSAA_RESOLVE_ONLY","DM_NVN_HOST_BARRIER","DM_NVN_ACQ_NEXT"};
static inline int dm_player_diagnostic_key(const char *key) {
    // Encoding placement changes scheduling, not diagnostics or launcher state.
    if(!strcmp(key,"DM_NVN_ENC_THREAD"))return 0;
    for(unsigned i=0;i<sizeof dm_player_kept_keys/sizeof *dm_player_kept_keys;i++)if(!strcmp(key,dm_player_kept_keys[i]))return 0;
#if DM_DEV_BUILD
    // A developer build (NX18_DEV) keeps every DM_NVN_* switch and DM_SLOWFRAME too, the diagnostics of a new game's bring-up; the test, Metal validation and scripted input switches stay filtered
    if(!strncmp(key,"DM_NVN_",7)||!strcmp(key,"DM_SLOWFRAME"))return 0;
#endif
    static const char *const prefixes[]={"DM_NVN_","DM_TEST_","MTL_DEBUG_","MTL_SHADER_VALIDATION"};
    for(unsigned i=0;i<sizeof prefixes/sizeof *prefixes;i++)
        if(!strncmp(key,prefixes[i],strlen(prefixes[i])))return 1;
    static const char *const names[]={"DM_CTL","DM_KEYS","DM_KBD","DM_DETCLOCK","DM_SLOWFRAME","DM_PROBE","DM_MSL_DIR"};
    for(unsigned i=0;i<sizeof names/sizeof *names;i++)if(!strcmp(key,names[i]))return 1;
    return 0;
}
// A whole env.txt line: the key dropped as above, or DM_SLOWFRAME with an empty value or zeros. slow_on (hle_nvn.c) takes any value as on, and before the player build kept the key a
// leftover DM_SLOWFRAME=0 did nothing there; dropped, it still does nothing, and =0 is the off side of an A/B as with every other kept switch
static inline int dm_player_env_dropped(const char *key,const char *value) {
    if(dm_player_diagnostic_key(key))return 1;
    return !strcmp(key,"DM_SLOWFRAME")&&value&&strspn(value,"0")==strlen(value);
}
