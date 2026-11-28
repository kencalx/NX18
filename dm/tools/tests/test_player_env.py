"""Saved diagnostics are filtered only for the opt-in player IPA."""
import pathlib
import re
import subprocess
import tempfile
import unittest


class PlayerEnvironment(unittest.TestCase):
    def test_overlays_and_player_options_survive(self):
        header = pathlib.Path(__file__).resolve().parents[2] / 'ios/Sources/player_env.h'
        source = r'''
#include <assert.h>
#include "player_env.h"
int main(void) {
 const char *drop[]={"DM_NVN_CPUPROF","DM_NVN_TSV","DM_NVN_PASSDUMP_ALL",
   "DM_NVN_GEOMETRY_PACK","DM_NVN_SHMAP","DM_NVN_ZBLOCK","DM_NVN_ENC_THREAD_PROBE","DM_CTL",
   "DM_TEST_UP_LOST","MTL_DEBUG_LAYER","MTL_SHADER_VALIDATION","DM_MSL_DIR",
   "DM_NVN_PROF","DM_NVN_TSV_CALLS","DM_NVN_WAITS_X","DM_NVN_WAIT","DM_PROBE","DM_DETCLOCK"};
 const char *keep[]={"DM_SHOW_FPS","DM_METAL_HUD","MTL_HUD_ENABLED",
   "DM_FPS_TARGET","DM_DYNAMIC_RESOLUTION","DM_OPMODE","DM_RENDER_SCALE","DM_LANG","DM_RT",
   "DM_TOUCH_HAPTICS","DM_RUMBLE","DM_SAVE","DM_ROMFS","DM_NVN_ENC_THREAD","DM_DEPTH_BOUNDS",
   "DM_NVN_WAITS","DM_SLOWFRAME","DM_REPLAY_RT","DM_REPLAY_SPARES","DM_FPS_HOLD_BACKOFF","DM_FPS_RESUME","DM_MOVIE_RESTART","DM_FIELD_LOG","DM_POWER_DETAIL","DM_YIELD_STORM","DM_YIELD_PARK","DM_NVN_GHOST","DM_NVN_MDX_PRESCAN","DM_FRAME_WG","DM_STALL_LOG","DM_SW2_MODE",
   "DM_NVN_BCRT_CACHE","DM_NVN_FAMILY_PFV","DM_NVN_FAMILY_NOCOMPRESS","DM_NVN_FB_SNAP_KEEP","DM_NVN_FB_SNAP_IDLE"};
 for(unsigned i=0;i<sizeof drop/sizeof *drop;i++)assert(dm_player_diagnostic_key(drop[i]));
 for(unsigned i=0;i<sizeof keep/sizeof *keep;i++)assert(!dm_player_diagnostic_key(keep[i]));
 // the whole line: DM_SLOWFRAME kept only with a value that is not empty or zeros (slow_on takes any value as on)
 assert(dm_player_env_dropped("DM_SLOWFRAME","0")&&dm_player_env_dropped("DM_SLOWFRAME","")&&dm_player_env_dropped("DM_SLOWFRAME","00"));
 assert(!dm_player_env_dropped("DM_SLOWFRAME","1")&&!dm_player_env_dropped("DM_SLOWFRAME","10"));
 assert(!dm_player_env_dropped("DM_NVN_WAITS","0")&&!dm_player_env_dropped("DM_REPLAY_RT","0")&&!dm_player_env_dropped("DM_REPLAY_SPARES","0")&&!dm_player_env_dropped("DM_POWER_DETAIL","0")&&!dm_player_env_dropped("DM_YIELD_STORM","sleep")&&!dm_player_env_dropped("DM_YIELD_PARK","1")&&!dm_player_env_dropped("DM_YIELD_PARK","0")&&!dm_player_env_dropped("DM_NVN_GHOST","512")&&!dm_player_env_dropped("DM_NVN_MDX_PRESCAN","0")&&!dm_player_env_dropped("DM_NVN_MDX_PRESCAN","ab"));   // both sides of an A/B are kept
 assert(!dm_player_env_dropped("DM_FRAME_WG","1")&&!dm_player_env_dropped("DM_FRAME_WG","0"));   // a test arm no filter names: it reaches a player build
 assert(!dm_player_env_dropped("DM_STALL_LOG","0")&&!dm_player_env_dropped("DM_STALL_LOG","10"));   // the freeze detector (stall.c): its off switch and its threshold reach a player build
 assert(!dm_player_env_dropped("DM_GPU_LOST_S","0")&&!dm_player_env_dropped("DM_GPU_LOST_S","20"));   // the GPU hang watchdog (nvn_mtl.m gpu_watch): its off switch and its limit reach a player build
 assert(!dm_player_env_dropped("DM_SW2_MODE","1")&&!dm_player_env_dropped("DM_SW2_MODE","0"));   // the experimental Switch 2 answer (hle_sdk16.c): both sides reach a player build
 assert(!dm_player_env_dropped("DM_NDVE_ENGINE","1")&&!dm_player_env_dropped("DM_NDVE_ENGINE","0")&&!dm_player_env_dropped("DM_NDVE_ENGINE","mfx")&&!dm_player_env_dropped("DM_NDVE_ENGINE","ab"));   // Ocarina of Time's movie network against the iPhone's MetalFX scale (nvn_ndve.inc): every value reaches a player build
 assert(!dm_player_env_dropped("DM_HEAT_STEPS","0")&&!dm_player_env_dropped("DM_HEAT_STEPS","1")&&!dm_player_env_dropped("DM_HEAT_FORCE","1:60,2:240,0:420")&&!dm_player_env_dropped("DM_HEAT_TUNE","r1=20,share=15"));   // the heat ladder's A/B arms and its forced state (nvn_heat.h) reach a player build
 assert(!dm_player_env_dropped("DM_FRAMEGEN","1")&&!dm_player_env_dropped("DM_FRAMEGEN","0")&&!dm_player_env_dropped("DM_FRAMEGEN_MOTION","zero"));   // frame generation (nvn_framegen.inc, off by default, no launcher row): a player can try it from env.txt
 assert(!dm_player_diagnostic_key("DM_PRESENT_REPEAT")&&!dm_player_env_dropped("DM_PRESENT_REPEAT","1")&&!dm_player_env_dropped("DM_PRESENT_REPEAT","0"));   // the present repeat (nvn_present_repeat.inc, off by default, no launcher row): no filter names it, so a phone's env.txt turns it on
 assert(!dm_player_diagnostic_key("DM_FRAME_WG_PERIOD")&&!dm_player_env_dropped("DM_FRAME_WG_PERIOD","16")&&!dm_player_diagnostic_key("DM_CLOCK_RESCUE_S")&&!dm_player_env_dropped("DM_CLOCK_RESCUE_S","10"));   // the GPU clock experiments (frame-rate.md, off by default): no filter names them, so a phone's env.txt turns them on
 assert(!dm_player_diagnostic_key("DM_DRS_GPU_TARGET")&&!dm_player_env_dropped("DM_DRS_GPU_TARGET","0")&&!dm_player_env_dropped("DM_DRS_GPU_TARGET","80"));   // GPU headroom under the game's dynamic resolution (nvn_drs_gpu.h, on by default at 75, no launcher row): no filter names it, so =0, the off side of its phone run, reaches a player build
 assert(!dm_player_diagnostic_key("DM_AUDREN_RT")&&!dm_player_env_dropped("DM_AUDREN_RT","0")&&!dm_player_env_dropped("DM_AUDREN_RT","1"));   // the audio renderer's real-time policy (hle_audren.c render_rt, on by default): no filter names it, so =0, the off side of its phone A/B, reaches a player build
 assert(!dm_player_diagnostic_key("DM_PSO_LATER_START")&&!dm_player_env_dropped("DM_PSO_LATER_START","0"));   // a later start's prepare step in the background (nvn_mtl.m warm_later_ready, on by default, no launcher row): no filter names it, so =0, the off side of its phone check, reaches a player build
 assert(!dm_player_diagnostic_key("DM_BRIGHT_PROBE")&&!dm_player_env_dropped("DM_BRIGHT_PROBE","0.27"));   // the brightness probe (front_ios.m, logging only, off by default): no filter names it, so it reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_BCRT_CACHE","0")&&!dm_player_env_dropped("DM_NVN_FAMILY_PFV","0")&&!dm_player_env_dropped("DM_NVN_FAMILY_NOCOMPRESS","1")&&!dm_player_env_dropped("DM_NVN_FB_SNAP_KEEP","0")&&!dm_player_env_dropped("DM_NVN_FB_SNAP_KEEP","64")&&!dm_player_env_dropped("DM_NVN_FB_SNAP_IDLE","0"));   // the GPU memory A/Bs (M1 pack): the off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_BG_PURGE","0")&&!dm_player_env_dropped("DM_NVN_BG_PURGE","1")&&dm_player_diagnostic_key("DM_NVN_BG_PURGEX"));   // the background purge's off side (S2Arm 23b99c4a) reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_CACHE_VOLATILE","0")&&!dm_player_env_dropped("DM_NVN_CACHE_VOLATILE","1")&&dm_player_diagnostic_key("DM_NVN_CACHE_VOLATILEX"));   // idle reuse-cache entries volatile: its off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_DEPTH_LAZY","1")&&!dm_player_env_dropped("DM_NVN_DEPTH_LAZY","0")&&dm_player_diagnostic_key("DM_NVN_DEPTH_LAZYX"));   // lazily backed large depth textures (memory.md): both sides reach a player build
 assert(!dm_player_env_dropped("DM_NVN_BG_LOOK","0")&&!dm_player_env_dropped("DM_NVN_BG_LOOK","ab")&&dm_player_diagnostic_key("DM_NVN_BG_LOOKX"));   // the look-ahead's background base lookups' phone A/B (upstream 9d3a58364) reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_FACE_SPLIT","0")&&!dm_player_env_dropped("DM_NVN_FACE_MERGE","0")&&dm_player_diagnostic_key("DM_NVN_FACE_SPLITX"));   // the face-split draws' off sides reach a player build
    assert(!dm_player_env_dropped("DM_NVN_TRIM_FRAMES","0"));   // the idle trims' old timing, for Ocarina's memory A/B
 assert(!dm_player_env_dropped("DM_FPS_CTL_PROBE","0")&&!dm_player_env_dropped("DM_FPS_CTL_PROBE","22")&&!dm_player_diagnostic_key("DM_FPS_CTL_PROBE"));   // the frame-rate controller's probe rules: their off side and a gate reach a player build
 assert(!dm_player_env_dropped("DM_NVN_DIRTY_INDEX","0")&&!dm_player_env_dropped("DM_NVN_DIRTY_INDEX","1")&&dm_player_diagnostic_key("DM_NVN_DIRTY_INDEXX")&&dm_player_diagnostic_key("DM_NVN_DIRTYCHECK"));   // the fault hook's address index, both sides, reaches a player build; its neighbours do not
 assert(!dm_player_env_dropped("DM_NVN_REUPLOAD_COALESCE","0")&&dm_player_diagnostic_key("DM_NVN_REUPLOAD_COALESCEX")&&dm_player_diagnostic_key("DM_NVN_REUPLOAD_PART"));   // the coalesced re-uploads' off side reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_RES_ASYNC","0")&&!dm_player_env_dropped("DM_NVN_RES_ASYNC","ab")&&!dm_player_env_dropped("DM_NVN_MFX_CONTENT","0")&&dm_player_diagnostic_key("DM_NVN_RES_ASYNCX")&&dm_player_diagnostic_key("DM_NVN_MFX_CONTENTX"));   // the residency hand-off's and the one-scaler-per-output's off sides reach a player build; neighbours do not
 assert(!dm_player_env_dropped("DM_NVN_ARGS_STATS","1")&&dm_player_diagnostic_key("DM_NVN_ARGS_STATSX")&&dm_player_diagnostic_key("DM_NVN_ARGS"));   // the argument block counts (measurement only) reach a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_ARGS_PARTIAL","0")&&dm_player_diagnostic_key("DM_NVN_ARGS_PARTIALX"));   // the partial argument patches' off side reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_ARGS_DRV","0")&&dm_player_diagnostic_key("DM_NVN_ARGS_DRVX"));   // the shared driver banks' off side reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_ARGS_REGCHK","0")&&dm_player_diagnostic_key("DM_NVN_ARGS_REGCHKX"));   // the registration check's off side reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_POOL_MEMO","0")&&dm_player_diagnostic_key("DM_NVN_POOL_MEMOX"));   // the pool table memo's off side reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_POOL_ENTRY","0")&&dm_player_diagnostic_key("DM_NVN_POOL_ENTRYX"));   // the pool entry order's off side reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_TEX_SEQ","0")&&!dm_player_env_dropped("DM_NVN_TEX_ALT2","0")&&dm_player_diagnostic_key("DM_NVN_TEX_SEQX")&&dm_player_diagnostic_key("DM_NVN_TEX"));   // the texture lookups' off sides reach a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_BINDLESS","1")&&dm_player_diagnostic_key("DM_NVN_BINDLESSX"));   // stage 1's slot tables (measurement only) reach a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_SUB_YIELD","0")&&dm_player_diagnostic_key("DM_NVN_SUB_YIELDX"));   // the replay's lock lending's off side reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_QUERY_POOL","0")&&dm_player_diagnostic_key("DM_NVN_QUERY_POOLX"));   // the pooled query records' off side reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_GEOMETRY_JOIN","0")&&dm_player_diagnostic_key("DM_NVN_GEOMETRY_JOINX"));   // the geometry pass join's off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_SAME_CLEAR","0")&&dm_player_diagnostic_key("DM_NVN_SAME_CLEARX"));   // the clears a texture already holds: the off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_SAME_CLEAR_TRI","0")&&dm_player_diagnostic_key("DM_NVN_SAME_CLEAR_TRIX"));   // masked stencil clears that wait for their pass: the off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_SPARSE_LOG","0")&&!dm_player_env_dropped("DM_NVN_SPARSE_LOG","1")&&dm_player_diagnostic_key("DM_NVN_SPARSE_LOGX"));   // a whole sparse texture's check through the change log: both sides reach a player build
 assert(!dm_player_env_dropped("DM_NVN_I2F_NATIVE","0")&&dm_player_diagnostic_key("DM_NVN_I2F_NATIVEX"));   // native integer-to-float vertex fetch (ComicBit 39cc2e79c): its off side reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_STAGE_POOL_MB","0")&&!dm_player_env_dropped("DM_NVN_STAGE_POOL_MB","256")&&dm_player_diagnostic_key("DM_NVN_STAGE_POOL_MBX"));   // the upload staging pool (S2Arm 01afd92a, 6e708d3e): its off side and its cap reach a player build
 assert(!dm_player_env_dropped("DM_NVN_SHADER_SHARE","0")&&dm_player_diagnostic_key("DM_NVN_SHADER_SHAREX"));   // the shared shader preparations' off side (ComicBit bee12ec) reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_UP_SLOTS","3")&&dm_player_diagnostic_key("DM_NVN_UP_SLOTSX"));   // Breath of the Wild's upload slots' off side (MacNativeGames 6ecb27c1) reaches a player build; a neighbour does not
 assert(!dm_player_env_dropped("DM_NVN_GMEM_KEEP","0")&&dm_player_diagnostic_key("DM_NVN_GMEM_KEEPX"));   // the raw pool table kept within a submission (MacNativeGames b964bd4e): the off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_FB_DSNAP","0")&&dm_player_diagnostic_key("DM_NVN_FB_DSNAPX"));   // one depth snapshot a barrier interval: the off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_UNWRITTEN_LOAD","0")&&dm_player_diagnostic_key("DM_NVN_UNWRITTEN_LOADX"));   // colour loads no draw needs: the off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_BARRIER","full")&&dm_player_diagnostic_key("DM_NVN_BARRIERS"));   // draw_barriers game's off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_PASS_ALT","0")&&dm_player_diagnostic_key("DM_NVN_PASS_ALTX"));   // the pass drawn every other frame's off side (the Quality preset) reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_CUBE_ALT","0")&&dm_player_diagnostic_key("DM_NVN_CUBE_ALTX"));   // the cube passes drawn every other frame: the off side (the Quality preset) reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_UP_BILINEAR","0")&&!dm_player_env_dropped("DM_NVN_UP_BILINEAR","1")&&dm_player_diagnostic_key("DM_NVN_UP_BILINEARX"));   // the bilinear upscaler stretch's off side (the Quality preset) and its on side for other games reach a player build
 assert(!dm_player_env_dropped("DM_NVN_WIN_AREA","0")&&dm_player_diagnostic_key("DM_NVN_WIN_AREAX"));   // the window textures' render area's off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_GPUPROF","every:600")&&dm_player_diagnostic_key("DM_NVN_GPUPROFX"));   // the per-pass GPU profile (measurement only) reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_LS_STATS","1")&&!dm_player_env_dropped("DM_NVN_DS_DEAD_STORE","0")&&!dm_player_env_dropped("DM_NVN_CLEARED_LOAD","0")&&!dm_player_env_dropped("DM_NVN_MSAA_RESOLVE_ONLY","0")&&!dm_player_env_dropped("DM_NVN_HOST_BARRIER","ab")&&dm_player_diagnostic_key("DM_NVN_LS_STATSX"));   // the attachment-traffic measurement and the reductions' off sides reach a player build
 assert(!dm_player_env_dropped("DM_NVN_ACQ_NEXT","0")&&dm_player_diagnostic_key("DM_NVN_ACQ_NEXTX"));   // the acquire sync on the next present (upstream 1999cbd1f): its off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_ACQ_DEFER","0")&&dm_player_diagnostic_key("DM_NVN_ACQ_DEFERX"));   // the deferred acquire (upstream c17a54984): its off side reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_PREDICT_NEXT","0")&&!dm_player_env_dropped("DM_NVN_PREDICT_NEXT","ab")&&dm_player_diagnostic_key("DM_NVN_PREDICT_NEXTX"));   // the look-ahead bound's battery A/B (upstream PR #1344) reaches a player build
 assert(!dm_player_env_dropped("DM_NVN_DISPATCH_RANGE","0")&&!dm_player_env_dropped("DM_NVN_DISPATCH_RANGE","1")&&!dm_player_env_dropped("DM_NVN_DISPATCH_RANGE","ab")&&dm_player_diagnostic_key("DM_NVN_DISPATCH_RANGES")&&dm_player_diagnostic_key("DM_NVN_DISPATCH_OWN"));   // the dispatch barrier rule's A/B (S2Arm 116fe90e) reaches a player build; its neighbours do not
 assert(!dm_player_env_dropped("DM_NVN_RT_DEAD","1")&&!dm_player_env_dropped("DM_NVN_RT_DEAD","ab")&&!dm_player_env_dropped("DM_NVN_RT_DEAD_MS","1000")&&!dm_player_env_dropped("DM_NVN_RT_DEAD_PRESSURE","0")&&dm_player_diagnostic_key("DM_NVN_RT_DEADX")&&dm_player_diagnostic_key("DM_NVN_RT_RECYCLE"));   // the drawn-over render targets' memory A/B reaches a player build; its neighbours do not
 assert(!dm_player_env_dropped("DM_NVN_MIP_DROP","2")&&!dm_player_env_dropped("DM_NVN_MIP_DROP","0")&&!dm_player_env_dropped("DM_NVN_MIP_DROP_MIN","2048")&&dm_player_diagnostic_key("DM_NVN_MIP_DROPS"));   // the mip drop's phone A/B (memory.md) reaches a player build; a neighbour does not
 // named one by one: neighbours stay filtered in a player build that is not a developer build (compiled here without DM_DEV_BUILD; a developer build keeps every DM_NVN_* key)
 assert(dm_player_diagnostic_key("DM_NVN_BCRT")&&dm_player_diagnostic_key("DM_NVN_FB_SNAP")&&dm_player_diagnostic_key("DM_NVN_FAMILY_NOCOMPRESSX")&&dm_player_diagnostic_key("DM_NVN_FAMILY"));
 assert(dm_player_env_dropped("DM_NVN_PROF","1")&&!dm_player_env_dropped("DM_SHOW_FPS","0"));
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            c = pathlib.Path(tmp) / 'test.c'
            exe = pathlib.Path(tmp) / 'test'
            c.write_text(source)
            subprocess.run(['cc', '-Wall', '-Werror', '-I', str(header.parent), str(c), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

    def test_kept_switches_are_documented_and_not_launcher_rows(self):   # an env.txt line the player build keeps: in docs/env_switches.tsv and the development guide's list, and no launcher row (main.m drops those too)
        repo = pathlib.Path(__file__).resolve().parents[3]
        header = (repo / 'dm/ios/Sources/player_env.h').read_text()
        kept = re.findall(r'"(DM_[A-Z0-9_]+)"', header[header.index('dm_player_kept_keys'):header.index('dm_player_diagnostic_key')])
        self.assertEqual(sorted(kept), sorted(['DM_NVN_ACQ_NEXT', 'DM_NVN_ACQ_DEFER', 'DM_FIELD_LOG', 'DM_FPS_CTL_PROBE', 'DM_FPS_HOLD_BACKOFF', 'DM_FPS_RESUME', 'DM_GPU_LOST_S', 'DM_MOVIE_RESTART', 'DM_NVN_ARGS_DRV', 'DM_NVN_ARGS_PARTIAL', 'DM_NVN_ARGS_REGCHK', 'DM_NVN_ARGS_STATS', 'DM_NVN_BARRIER', 'DM_NVN_BCRT_CACHE', 'DM_NVN_FAMILY_NOCOMPRESS', 'DM_NVN_PCM', 'DM_NVN_BG_LOOK', 'DM_NVN_BG_PURGE', 'DM_NVN_BINDLESS', 'DM_NVN_CACHE_VOLATILE', 'DM_NVN_CLEARED_LOAD', 'DM_NVN_CUBE_ALT', 'DM_NVN_CUT_EVENT', 'DM_NVN_CUT_HOLD', 'DM_NVN_DEPTH_LAZY', 'DM_NVN_DIRTY_INDEX', 'DM_NVN_DISPATCH_RANGE', 'DM_NVN_DS_DEAD_STORE', 'DM_NVN_EDGE_COLD', 'DM_NVN_FACE_MERGE', 'DM_NVN_FACE_SPLIT', 'DM_NVN_FAMILY_PFV', 'DM_NVN_FB_DSNAP', 'DM_NVN_FB_SNAP_IDLE', 'DM_NVN_FB_SNAP_KEEP', 'DM_NVN_FB_TILE_EARLY', 'DM_NVN_GEOMETRY_JOIN', 'DM_NVN_GHOST', 'DM_NVN_GMEM_KEEP', 'DM_NVN_GPUPROF', 'DM_NVN_HOST_BARRIER', 'DM_NVN_I2F_NATIVE', 'DM_NVN_IDLE_TEX_FOOT_MB', 'DM_NVN_IDLE_TEX_FOOT_TRIM', 'DM_NVN_IDLE_TEX_MB', 'DM_NVN_IDLE_TEX_PKG', 'DM_NVN_LS_STATS', 'DM_NVN_MDX_PRESCAN', 'DM_NVN_MFX_CONTENT', 'DM_NVN_MFX_DIRECT', 'DM_NVN_MIP_DROP', 'DM_NVN_MIP_DROP_COMPRESSIBLE', 'DM_NVN_MIP_DROP_MIN', 'DM_NVN_MIP_DROP_PARTIAL', 'DM_NVN_MSAA_RESOLVE_ONLY', 'DM_NVN_PASS_ALT', 'DM_NVN_PASS_REPEAT', 'DM_NVN_PASS_SPLIT', 'DM_NVN_PASS_SPLIT_MAX', 'DM_NVN_PF_PARTS', 'DM_NVN_POOL_ENTRY', 'DM_NVN_POOL_MEMO', 'DM_NVN_POOL_READAHEAD', 'DM_NVN_PREDICT_NEXT', 'DM_NVN_PREREAD', 'DM_NVN_PREWIRE_JOBS', 'DM_NVN_QUERY_POOL', 'DM_NVN_RES_ASYNC', 'DM_NVN_RES_PREWIRE', 'DM_NVN_RES_TRICKLE_MB', 'DM_NVN_REUPLOAD_COALESCE', 'DM_NVN_RT_DEAD', 'DM_NVN_RT_DEAD_MS', 'DM_NVN_RT_DEAD_PRESSURE', 'DM_NVN_SAME_CLEAR', 'DM_NVN_SAME_CLEAR_TRI', 'DM_NVN_SHADER_SHARE', 'DM_NVN_SHARED_IDLE', 'DM_NVN_SHARED_IDLE_SUBS', 'DM_NVN_SPARSE_LOG', 'DM_NVN_STAGE_POOL_MB', 'DM_NVN_SUB_DRAIN', 'DM_NVN_SUB_IDLE_FB', 'DM_NVN_SUB_MERGE', 'DM_NVN_SUB_YIELD', 'DM_NVN_TBUF_GPU_COPY', 'DM_NVN_TEX_ALT2', 'DM_NVN_TEX_READAHEAD', 'DM_NVN_TEX_SEQ', 'DM_NVN_TRIM_FRAMES', 'DM_NVN_UNWIRE_UP', 'DM_NVN_UNWRITTEN_LOAD', 'DM_NVN_UP_BILINEAR', 'DM_NVN_UP_SLOTS', 'DM_NVN_WAITS', 'DM_NVN_WIN_AREA', 'DM_POWER_DETAIL', 'DM_REPLAY_RT', 'DM_REPLAY_SPARES', 'DM_SLOWFRAME', 'DM_SW2_MODE', 'DM_YIELD_PARK', 'DM_YIELD_STORM']))
        switches = {l.split('\t')[0] for l in (repo / 'docs/env_switches.tsv').read_text(encoding='utf-8').splitlines() if l and not l.startswith('#')}
        rows = {l.split('\t')[0] for l in (repo / 'dm/games/settings.tsv').read_text(encoding='utf-8').splitlines() if l and not l.startswith('#')}
        guide = (repo / 'docs/development.md').read_text(encoding='utf-8')
        for k in kept:
            self.assertIn(k, switches, k); self.assertNotIn(k, rows, k); self.assertIn(f'`{k}`', guide, k)
