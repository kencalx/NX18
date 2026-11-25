// ---------- Frame generation (DM_FRAMEGEN, X2.0 item C6; off by default) ----------
// Included by nvn_mtl.m before the display link's delegate. A game at a 30 fps cap on the 60 Hz display link shows 60 pictures a second: on the tick that takes frame n, MetalFX's
// frame interpolator (MTL4FXFrameInterpolator) makes G, the midpoint between frame n-1 and frame n, which goes through the same present pass as every frame (edge smoothing, MetalFX
// or bilinear scaling, Sharpening, picture fit, the touch controls drawn into the frame) onto that tick's drawable; F(n) itself is shown on the next tick, the one the 30 fps hold
// kept before (nvn_framegen.h has the decision and the tick order, t_framegen.c their tests). The interpolator needs depth and motion at the game's render size besides the
// colour. They are copied where NX 18 runs the game's upscaler, into a ring of host textures (fg_cap), so the game can reuse its own:
//   (a) NVN2's DLSS (dlss_eval): its depth and motion textures, motion scale, depth direction and reset, on the MetalFX temporal scaler's path only (the bilinear stand-in means
//       inputs are missing). Motion at the output's size (DLSS without MVLowRes) is left out: the interpolator takes depth and motion of one size;
//   (b) the NDSR networks (DM_GAME_UPSCALER_KEYS, up_mfx_named: agl_ndsr and its _vr / _vr_light variants, the other packs; drawn by the game's shader or by MetalFX with
//       DM_UPSCALER=metalfx): spatial networks, one texture in and one image out, so their push constants give only the input and output rectangles. Of a network's dispatches
//       only its last, the upscale, has them (the others hold floats there): a dispatch whose rectangles are not an upscale is not taken. Ocarina of Time plays with
//       agl_ndsr_vr_light (1536x864 into 2048x1152). The depth is the frame's scene depth found structurally (fg_depth_seen: the last depth attachment drawn this frame that
//       covers the input rectangle with the same shape, reversed when it was cleared to 0); there is no motion, so path (b) generates only with DM_FRAMEGEN_MOTION=zero (zero
//       motion: MetalFX estimates none, so G is close to a blend of the two pictures and ghosts when the camera moves). Host-built motion for it is the open next step.
// The colour is the presented picture F itself, from the present snapshot ring, which DM_FRAMEGEN turns on (mtl_snap_on): the HUD is interpolated with the scene (H0 in
// docs/reference/rendering.md, Frame generation); the interpolator keeps the previous colour itself (requiresPrevColorTexture NO, t_framegen_probe), and its history is
// reset by fg_decide after any frame shown without generation. t_framegen_probe found what this relies on: every colour, depth and motion format NVN games present or
// render with makes an interpolator; motion in input pixels pointing to the previous frame at scale 1 (DLSS's convention, as the MetalFX temporal scaler takes it); the
// content rectangle and offsets inside larger depth and motion textures; and the reset encode and the two after it give the current picture, not a midpoint.
// It steps aside (real frames only, no captures, and the 30 Hz link where the 30 fps cap has it) whenever power comes first: thermal state serious or worse, Low Power Mode
// (both until they have been gone 30 s, as the thermal cap's hold; on the Mac, whose host reports neither, the system's own), any rung of the heat ladder (nvn_heat_rung,
// hle_nvn.c: the rungs on, the 30 fps heat hold's included, through their restore waits; Low Power Mode's own 30 fps cause is not one), and the Battery Saver preset
// (DM_PRESET=battery: the launcher sets it before the game starts, and the in-game menu after a preset change).
// It is off altogether with DM_PRESENT_REPEAT=1 (the present repeat, a change of its own, fills the same empty ticks).
// Off (the default) it costs nothing: every hook in nvn_mtl.m asks fg_on(), one cached load, before doing anything; nothing is allocated (the ring, the interpolator, its
// output and command buffers are made on the first capture or generated frame) and no per-frame work runs. On, what it made goes again after FG_IDLE_FRAMES frames without a
// generated frame or a capture, at a memory trim while it is not generating, and going to the background (fg_trim), and is made again when it generates again (the interpolator
// only for a frame that would be generated once it is there). A game that never gives it a capture (DLSS without low-resolution motion, NDSR without DM_FRAMEGEN_MOTION=zero),
// a device without MetalFX's interpolator and an interpolator MetalFX would not make keep the 30 fps cap's 30 Hz link (fg_keeps_60hz). Vitals' fps field says "60 fps,
// 30 rendered" while it produces frames (mtl_framegen_frames, hle_nvn.c vitals_tick). No telemetry: the status line is the log's.
// Switches: DM_FRAMEGEN=1 (0 default); DM_FRAMEGEN_MOTION=zero lets path (b) run on zero motion; DM_FRAMEGEN_JITTER=1 passes DLSS's jitter (the colour the interpolator
// sees is the upscaled, de-jittered picture, so 0 by default); DM_FRAMEGEN_SHOT writes generated frames as PNGs. A status line every 600 frames the link took counts generated
// and real frames by reason, and gives the generated frames' command buffer GPU time (the interpolation and the present pass) as p50 / p95
#include "nvn_framegen.h"
static int fg_on(void) {
    static int v = -1; if (v >= 0) return v;
    const char *e = getenv("DM_FRAMEGEN"); v = e && !strcmp(e, "1");
    if (e && *e && strcmp(e, "1") && strcmp(e, "0")) MLOG("[RED] DM_FRAMEGEN=%s: 1 or 0; off", e);
    if (v && rep_on()) { v = 0; MLOG("frame generation: off, the present repeat is on (DM_PRESENT_REPEAT=1 or the profile's present_repeat)"); }
    if (v) MLOG("frame generation (DM_FRAMEGEN=1): at the 30 fps cap on the 60 Hz display link a MetalFX midpoint frame is shown before each game frame; it steps aside for heat, Low Power Mode%s and Battery Saver",
                TARGET_OS_IPHONE ? "" : " (the Mac's own, from NSProcessInfo)");
    return v;
}
static int fg_motion_zero(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_FRAMEGEN_MOTION"); v = e && !strcmp(e, "zero"); } return v; }
static int fg_jitter(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_FRAMEGEN_JITTER"); v = e && atoi(e); } return v; }
static int fg_supported(void) { static int v = -1; if (v < 0) v = g_dev && [MTLFXFrameInterpolatorDescriptor supportsMetal4FX:g_dev]; return v; }
static _Atomic int g_fg_hold;   // a hold of the caller's (the tests' stand-in for the in-game menu); the front end's menu is dm_front_menu_now
void mtl_framegen_hold(int on) { atomic_store(&g_fg_hold, on != 0); }
int dm_movie_playing(void);   // hle_movie.c: the SDK's movie library or an nn::codec video decoder handed out a picture in the last half second
int dm_low_power_now(void);     // hle_nvn.c's weak 0 (the Mac), front_ios.m: Low Power Mode on
int nvn_heat_rung(void);   // hle_nvn.c: the heat ladder's rungs on (0: none), from the ladder (nvn_heat.h); no weak stand-in, as 31 graphics tests compile both files as one
static int g_link_mode;   // defined with the display link below
// Power first: FG_THERMAL (heat, Low Power Mode, a rung of the heat ladder), FG_BATTERY (the Battery Saver preset), 0 when generation may run. Asked on the display link's thread
// at each frame it takes and on the present thread at each link_sync, only while frame generation is on. A reader of its own, with no side effects: the thermal state and Low
// Power Mode (front_ios.m; the Mac's host reports neither, hle_nvn.c's weak -1 and 0, so there the system's own from NSProcessInfo) and the launcher's preset (DM_PRESET, copied
// under the in-game menu's lock, front_env_copy: the menu writes it after a preset change in game) are read once a second. Heat (serious or worse) or Low Power Mode keeps it
// aside until both have been gone g_fg_calm_ns, the thermal cap's own 30 s, so a thermal state at the edge does not turn it on and off. The thermal cap's hold itself is not
// sampled (hle_nvn.c thermal_capped logs and reports a hold, also for a game the host does not pace); the heat ladder's rungs are read at each call (nvn_heat_rung, one
// relaxed load of what the ladder's last 1 s sample published), so it stays aside through a rung's restore wait, the heat hold's backed-off calm included
static _Atomic uint64_t g_fg_preset_at;   // when they were last read (t_framegen_dlss clears it to read them again at once)
static uint64_t g_fg_calm_ns = 30000000000ull;   // t_framegen_dlss shortens it
static _Atomic uint64_t g_fg_hot_ns;   // the last read that found heat or Low Power Mode (0: none)
static _Atomic int g_fg_battery, g_fg_heat_said, g_fg_power;   // the preset's answer; the heat line said; fg_power_why's last answer (no captures while it steps aside: fg_cap_wanted)
static int fg_power_why(void) {
    uint64_t t = now_ns(), at = atomic_load_explicit(&g_fg_preset_at, memory_order_relaxed);
    if (!at || t - at >= 1000000000ull) {
        atomic_store_explicit(&g_fg_preset_at, t, memory_order_relaxed);
        int th = dm_thermal_now(), lp = dm_low_power_now();
        if (th < 0) { NSProcessInfo *pi = NSProcessInfo.processInfo; th = (int)pi.thermalState; lp = lp || pi.lowPowerModeEnabled; }   // the Mac
        if (th >= 2 || lp) atomic_store_explicit(&g_fg_hot_ns, t, memory_order_relaxed);
        char e[16]; int b = front_env_copy("DM_PRESET", e, sizeof e) && !strcmp(e, "battery");
        if (atomic_exchange_explicit(&g_fg_battery, b, memory_order_relaxed) != b) MLOG("frame generation: %s (DM_PRESET)", b ? "steps aside for the Battery Saver preset" : "back, the preset is no longer Battery Saver");
    }
    uint64_t hot = atomic_load_explicit(&g_fg_hot_ns, memory_order_relaxed);
    int rung = nvn_heat_rung(), heat = rung > 0 || (hot && (t <= hot || t - hot < g_fg_calm_ns));
    if (atomic_exchange_explicit(&g_fg_heat_said, heat, memory_order_relaxed) != heat) {
        if (heat) MLOG("frame generation: steps aside for %s", rung > 0 ? "a rung of the heat ladder" : "heat or Low Power Mode");
        else MLOG("frame generation: back, no rung of the heat ladder and no heat or Low Power Mode for %g s", g_fg_calm_ns / 1e9);
    }
    int why = heat ? FG_THERMAL : atomic_load_explicit(&g_fg_battery, memory_order_relaxed) ? FG_BATTERY : 0;
    atomic_store_explicit(&g_fg_power, why, memory_order_relaxed);
    return why;
}

// ---- the capture ring (written on the submit thread at the upscale, read on the display link's thread) ----
enum { FG_RING = 4, FG_PATH_DLSS = 1, FG_PATH_NDSR = 2 };
typedef struct {
    id<MTLTexture> dep, mot;      // the copies the interpolator reads (mot: the zero-motion texture on path (b))
    id<MTLTexture> ring_mot;      // the slot's own motion texture (kept while the slot holds zero motion)
    NSUInteger cw, ch, dox, doy, mox, moy, iw, ih;   // content size and its corners in the depth and motion textures; the interpolator's input size
    float mvx, mvy, jx, jy;
    int rev, reset, path, busy;   // busy: the display link is encoding a generated frame from this slot (a capture skips it)
    uint64_t v;                   // the capture's version (g_fg_cap_v), 0 = empty
    NSUInteger key[6];            // depth and motion formats, input size, path: the interpolator's inputs
} fg_cap;
static fg_cap g_fg_cap[FG_RING];
static os_unfair_lock g_fg_lk = OS_UNFAIR_LOCK_INIT;
static _Atomic uint64_t g_fg_cap_v;   // the newest capture (present_enqueue attaches it to the frame's present)
static uint64_t g_fg_cap_skipped;
enum { FG_IDLE_FRAMES = 300 };   // frames without a generated frame (the display link's) or without a capture (the submit thread's) before what they use goes: 10 s at 30 fps
static uint64_t g_fg_idle_frames = FG_IDLE_FRAMES;   // t_framegen_dlss lowers it
static _Atomic int g_fg_fps30 = 1;   // link_sync: the 30 fps cap is in force, and not in variable-refresh fullscreen's 30 Hz fallback (1 until it says: the tests call no link_sync)
static _Atomic int g_fg_captured;    // a capture was made this run: the game's upscaler gives generation its depth and motion (fg_keeps_60hz)
// Whether an upscale is captured: not while generation steps aside for power, away from the 30 fps cap or in its variable-refresh fallback to the 30 Hz link (link_sync), or
// without MetalFX's interpolator, where nothing would be generated from it (each capture is two copies at the game's render size). The first frame back captures again; its
// generated frame resets the interpolator's history (fg_decide)
static int fg_cap_wanted(void) { return fg_supported() && atomic_load_explicit(&g_fg_fps30, memory_order_relaxed) && !atomic_load_explicit(&g_fg_power, memory_order_relaxed); }
static void fg_cap_idle(void);   // an upscale not captured (below)
static uint64_t g_fg_cap_idle_n, g_fg_cap_idle_frame;   // submit thread: frames in a row whose upscale was not captured, and the last of them
static id<MTLTexture> g_fg_zero;   // the zero-motion texture (path (b)); submit thread
// A ring texture shaped like src (2D, its format and level-0 size); the old one goes once the GPU is past the submissions that may still use it
static id<MTLTexture> fg_ring_tex(id<MTLTexture> old, MTLPixelFormat pf, NSUInteger w, NSUInteger h, const char *what) {
    if (old && old.pixelFormat == pf && old.width == w && old.height == h) return old;
    if (old) defer_obj_release(old);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d];
    if (!t) { RED_ONCE(176, "frame generation: no %lux%lu %s texture of format %lu", (unsigned long)w, (unsigned long)h, what, (unsigned long)pf); return nil; }
    t.label = [NSString stringWithFormat:@"framegen %s", what]; res_add(t); res_commit();
    return t;
}
// A zero motion texture (RG16F) of at least w x h, made once in shared memory (Apple GPUs) and filled by the CPU
static id<MTLTexture> fg_zero_motion(NSUInteger w, NSUInteger h) {
    id<MTLTexture> z = g_fg_zero;
    if (z && z.width >= w && z.height >= h) return z;
    if (z) defer_obj_release(z);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    g_fg_zero = z = [g_dev newTextureWithDescriptor:d]; if (!z) return nil;
    void *zeros = calloc(w * h, 4); [z replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:zeros bytesPerRow:w * 4]; free(zeros);
    z.label = @"framegen zero motion"; res_add(z); res_commit();
    return z;
}
// Copy the frame's depth (and motion, nil for zero motion) into the next ring slot, recorded on the submission in stream order (the replay's blit encoder)
static void fg_capture(int path, id<MTLTexture> dep, id<MTLTexture> mot, NSUInteger cw, NSUInteger ch, const NSUInteger dofs[2], const NSUInteger mofs[2], float mvx, float mvy, float jx, float jy, int rev, int reset) {
    if (!dep || dep.sampleCount != 1 || (dep.textureType != MTLTextureType2D && dep.textureType != MTLTextureType2DArray)) return;
    if (mot && (mot.sampleCount != 1 || (mot.textureType != MTLTextureType2D && mot.textureType != MTLTextureType2DArray))) return;
    uint64_t v = atomic_load(&g_fg_cap_v) + 1; fg_cap *s = &g_fg_cap[v % FG_RING];
    os_unfair_lock_lock(&g_fg_lk); int busy = s->busy; if (!busy) s->v = 0; os_unfair_lock_unlock(&g_fg_lk);   // emptied while it is refilled: a frame still pointing at it is stale
    if (busy) { g_fg_cap_skipped++; return; }
    id<MTLTexture> d = fg_ring_tex(s->dep, dep.pixelFormat, dep.width, dep.height, "depth"), m = mot ? fg_ring_tex(s->ring_mot, mot.pixelFormat, mot.width, mot.height, "motion") : fg_zero_motion(dep.width, dep.height);
    s->dep = d; if (mot) s->ring_mot = m;
    if (!d || !m) return;
    rp_end();
    enc_b_copy_texture(blit(), dep, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(dep.width, dep.height, 1), d, 0, 0, MTLOriginMake(0, 0, 0));
    if (mot) enc_b_copy_texture(blit(), mot, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(mot.width, mot.height, 1), m, 0, 0, MTLOriginMake(0, 0, 0));
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    NSUInteger iw = MIN(d.width, m.width), ih = MIN(d.height, m.height);
    os_unfair_lock_lock(&g_fg_lk);
    s->dep = d; s->mot = m; s->cw = MIN(cw, iw); s->ch = MIN(ch, ih); s->dox = dofs[0]; s->doy = dofs[1]; s->mox = mot ? mofs[0] : 0; s->moy = mot ? mofs[1] : 0;
    s->iw = iw; s->ih = ih; s->mvx = mvx; s->mvy = mvy; s->jx = jx; s->jy = jy; s->rev = rev; s->reset = reset; s->path = path; s->v = v;
    NSUInteger key[6] = {d.pixelFormat, m.pixelFormat, iw, ih, (NSUInteger)path, 0}; memcpy(s->key, key, sizeof key);
    os_unfair_lock_unlock(&g_fg_lk);
    atomic_store(&g_fg_cap_v, v); atomic_store_explicit(&g_fg_captured, 1, memory_order_relaxed); g_fg_cap_idle_n = 0;
    static int said[3]; if (!said[path]++) MLOG("frame generation: first capture on the %s path, depth %lux%lu format %lu, motion %lux%lu format %lu%s, content %lux%lu, motion scale %g, %g, depth %s",
        path == FG_PATH_DLSS ? "DLSS" : "NDSR", (unsigned long)dep.width, (unsigned long)dep.height, (unsigned long)dep.pixelFormat, (unsigned long)m.width, (unsigned long)m.height,
        (unsigned long)m.pixelFormat, mot ? "" : " (zero motion)", (unsigned long)cw, (unsigned long)ch, mvx, mvy, rev ? "reversed" : "forward");
}
// Path (a): DLSS evaluated through MetalFX's temporal scaler (dlss_eval). Motion at the output's size (no MVLowRes) is not taken (see the top)
static void fg_capture_dlss(const p_dlss *a, id<MTLTexture> dep, id<MTLTexture> mot, NSUInteger iw, NSUInteger ih, int reset) {
    enum { MV_LOW_RES = 1 << 1, DEPTH_INVERTED = 1 << 3 };
    if (!(a->flags & MV_LOW_RES)) { static int once; if (!once++) MLOG("frame generation: DLSS motion at the output's size (flags %#x) is not taken; no generated frames on this network", a->flags); return; }
    if (!fg_cap_wanted()) { fg_cap_idle(); return; }
    NSUInteger dofs[2] = {(NSUInteger)a->base[DLSS_DEPTH][0], (NSUInteger)a->base[DLSS_DEPTH][1]}, mofs[2] = {(NSUInteger)a->base[DLSS_MOTION][0], (NSUInteger)a->base[DLSS_MOTION][1]};
    fg_capture(FG_PATH_DLSS, dep, mot, iw, ih, dofs, mofs, a->mv[0], a->mv[1], fg_jitter() ? a->jitter[0] : 0, fg_jitter() ? a->jitter[1] : 0, (a->flags & DEPTH_INVERTED) != 0, reset);
}
// Path (b): the scene depth, the last depth attachment this frame drew into (rp_begin_ex), kept with its clear value
enum { FG_DC = 4 };
static __strong id<MTLTexture> g_fg_dc_t[FG_DC]; static float g_fg_dc_clear[FG_DC]; static uint64_t g_fg_dc_frame[FG_DC];   // the newest last; submit thread only
static int g_fg_dc_n;
static void fg_dc_drop(int i) { for (; i + 1 < g_fg_dc_n; i++) { g_fg_dc_t[i] = g_fg_dc_t[i + 1]; g_fg_dc_clear[i] = g_fg_dc_clear[i + 1]; g_fg_dc_frame[i] = g_fg_dc_frame[i + 1]; } g_fg_dc_t[--g_fg_dc_n] = nil; }
static void fg_depth_seen(id<MTLTexture> t, int cleared, double clear) {
    if (!t || t.sampleCount != 1 || t.textureType != MTLTextureType2D) return;
    float cv = -1;
    for (int i = 0; i < g_fg_dc_n; i++) if (g_fg_dc_t[i] == t) { cv = g_fg_dc_clear[i]; fg_dc_drop(i); break; }
    if (cleared) cv = (float)clear;
    if (g_fg_dc_n == FG_DC) fg_dc_drop(0);
    g_fg_dc_t[g_fg_dc_n] = t; g_fg_dc_clear[g_fg_dc_n] = cv; g_fg_dc_frame[g_fg_dc_n++] = atomic_load(&g_cur_frame);
}
static void fg_capture_ndsr(NvShader *cs) {
    if (!up_mfx_named(cs)) return;
    uint32_t v[8]; memcpy(v, S.push[1], sizeof v);   // the input rectangle (origin, last texel relative to it), then the output's
    uint64_t f = atomic_load(&g_cur_frame);
    if (v[0] > 16384 || v[1] > 16384 || v[2] >= 16384 || v[3] >= 16384 || v[4] > 16384 || v[5] > 16384 || v[6] >= 16384 || v[7] >= 16384 || v[6] < v[2] || v[7] < v[3] || (v[6] == v[2] && v[7] == v[3])) return;   // not the upscale
    if (!fg_cap_wanted()) { fg_cap_idle(); return; }
    NSUInteger x = v[0], y = v[1], w = (NSUInteger)v[2] + 1, h = (NSUInteger)v[3] + 1;
    for (int i = g_fg_dc_n - 1; i >= 0; i--) {   // the newest depth of this frame that covers the input rectangle in its shape (not a shadow map, not a half-size buffer)
        id<MTLTexture> t = g_fg_dc_t[i]; if (g_fg_dc_frame[i] != f) continue;
        double ra = (double)t.width / t.height, rr = (double)(x + w) / (y + h);
        if (t.width < x + w || t.height < y + h || fabs(ra / rr - 1) > 0.1) continue;
        if (!fg_motion_zero()) { static int once; if (!once++) MLOG("frame generation: NDSR %s found the scene depth %lux%lu, but no motion (DM_FRAMEGEN_MOTION=zero runs on zero motion); real frames only", cs->key, (unsigned long)t.width, (unsigned long)t.height); return; }
        NSUInteger o[2] = {x, y}, zo[2] = {0, 0};
        fg_capture(FG_PATH_NDSR, t, nil, w, h, o, zo, 1, 1, 0, 0, g_fg_dc_clear[i] == 0, 0);
        return;
    }
    static int once; if (!once++) MLOG("frame generation: NDSR %s: no depth attachment of this frame covers its %lux%lu input; real frames only", cs->key, (unsigned long)w, (unsigned long)h);
}
// The capture ring's textures, the zero-motion texture and the depth attachments path (b) remembers, let go: on the submit thread, where captures are made (FG_IDLE_FRAMES frames
// without one, or a memory trim at a submission's start), or with it stopped (the trim going to the background). A slot the display link is encoding a generated frame from is
// kept; the rest wait for fence, which no generated frame committed before outlasts on the queue. The next capture makes them again. Returns the bytes, *n the textures
static uint64_t fg_ring_release(uint64_t fence, int *n) {
    id<MTLTexture> drop[2 * FG_RING + 1]; int k = 0, zero_busy = 0; uint64_t b = 0;
    os_unfair_lock_lock(&g_fg_lk);
    for (int i = 0; i < FG_RING; i++) {
        fg_cap *s = &g_fg_cap[i];
        if (s->busy) { zero_busy |= s->mot && s->mot == g_fg_zero; continue; }
        if (s->dep) drop[k++] = s->dep;
        if (s->ring_mot) drop[k++] = s->ring_mot;
        s->dep = s->mot = s->ring_mot = nil; s->v = 0;
    }
    os_unfair_lock_unlock(&g_fg_lk);
    if (g_fg_zero && !zero_busy) { drop[k++] = g_fg_zero; g_fg_zero = nil; }
    for (int i = 0; i < k; i++) { b += drop[i].allocatedSize; defer_obj_at(drop[i], 0, fence); }
    for (int i = 0; i < g_fg_dc_n; i++) g_fg_dc_t[i] = nil;   // the game's own depth textures, which a reference here kept alive
    g_fg_dc_n = 0;
    *n = k; return b;
}
// An upscale not captured (fg_cap_wanted said no; submit thread): after FG_IDLE_FRAMES frames of them in a row the ring goes (a long step-aside: Battery Saver, heat)
static void fg_cap_idle(void) {
    uint64_t f = atomic_load(&g_cur_frame);
    if (f == g_fg_cap_idle_frame) return;   // one count a frame (a network may run more than once)
    g_fg_cap_idle_frame = f;
    if (++g_fg_cap_idle_n != g_fg_idle_frames) return;
    int n = 0; uint64_t b = fg_ring_release(g_fence + 1, &n);
    if (n) MLOG("frame generation: no capture for %llu frames (%s): the capture ring's %d textures released (%.1f MB)", (unsigned long long)g_fg_idle_frames,
                atomic_load(&g_fg_power) == FG_THERMAL ? "heat or Low Power Mode" : atomic_load(&g_fg_power) == FG_BATTERY ? "Battery Saver" : !fg_supported() ? "no MetalFX frame interpolator" : "no 30 fps cap on the 60 Hz link", n, b / 1048576.0);
}

// ---- the display link's side ----
static fg_gate g_fg_gate;
static fg_seq g_fg_seq;   // under g_pq_mu
// The ticket of the last frame fg_present_gen decided on (0: none, or its real frame was dropped). The interpolator keeps the colour of the frames it encoded, so a frame whose
// ticket does not follow it (frames the link dropped as old, frames the present thread showed in a rescue, a suspend) has no history: a midpoint across that gap would blend
// pictures more than one frame apart
static _Atomic uint64_t g_fg_prev_ticket;
static NSUInteger g_fg_last_key[8];
typedef struct { id<MTL4FXFrameInterpolator> fi; NSUInteger key[8]; int state; } fg_interp;   // state 1 being made, 2 made, 3 MetalFX made none
static fg_interp g_fg_fi;   // under g_fg_lk
static id<MTLTexture> g_fg_out, g_fg_in, g_fg_win;   // the generated frame; the crop of the presented frame when the crop is part of its texture; G put back at that crop in a texture of the window texture's size
static id<MTL4CommandAllocator> g_fg_alloc[3]; static id<MTL4CommandBuffer> g_fg_cb[3]; static id<MTLBuffer> g_fg_uv[3];
static uint64_t g_fg_fence[3], g_fg_done[3], g_fg_n;   // g_fg_done: under g_pq_mu
static double g_fg_gpu[600]; static int g_fg_gpu_n;   // under g_pq_mu
// The last generated frame whose present pass ran the live present's MetalFX scaler or edge smoothing (g_fx_present, g_aa_present; under g_pq_mu): present_fx_idle releases
// neither while that frame is still on the GPU, as it waits for the last real present that ran them
static int g_fg_fx_ai, g_fg_aa_ai; static uint64_t g_fg_fx_seq, g_fg_aa_seq;
static int fg_effect_busy(int aa) {   // aa: edge smoothing, else MetalFX
    if (!fg_on()) return 0;
    pthread_mutex_lock(&g_pq_mu);
    int b = aa ? g_fg_aa_seq && g_fg_done[g_fg_aa_ai] < g_fg_aa_seq : g_fg_fx_seq && g_fg_done[g_fg_fx_ai] < g_fg_fx_seq;
    pthread_mutex_unlock(&g_pq_mu);
    return b;
}
// link_sync, at the 30 fps cap: whether frame generation keeps the 60 Hz link, where its generated frames take the ticks between. Only where it can generate: not while it steps
// aside for power, not before the game's upscaler gave it a capture (a game whose upscaler gives it nothing, DLSS without low-resolution motion or NDSR without
// DM_FRAMEGEN_MOTION=zero, never does), not without MetalFX's frame interpolator, and not while MetalFX made none for the capture's sizes and formats. There the 30 fps cap keeps its
// 30 Hz power-saving link. A movie, the menu or frames without an upscale keep the 60 Hz link once captures came: generation comes back on the next frame, without a change of rate
static int fg_keeps_60hz(void) {
    if (!fg_supported() || !atomic_load_explicit(&g_fg_captured, memory_order_relaxed) || fg_power_why()) return 0;
    os_unfair_lock_lock(&g_fg_lk); int failed = g_fg_fi.state == 3; os_unfair_lock_unlock(&g_fg_lk);
    return !failed;
}
// What the display link's side made, let go after FG_IDLE_FRAMES frames it took without a generated frame, at a memory trim while it is not generating, or going to the background
// (fg_trim): G's output, the crop copy and the window-sized texture, its command allocators, command buffers and uv buffers, and the interpolator (one MetalFX did not make, or
// one being made, stays). g_fg_res_mu, which fg_present_gen holds, guards them: a trim going to the background takes it, as the link calls back nothing there
static pthread_mutex_t g_fg_res_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_fg_idle;   // frames the display link took in a row without a generated frame
// A memory trim's request that the display link's side let go at its next frame without a generated frame: the generated frames counted when it was made (g_fg_gen_n), + 1; 0:
// none. A generated frame takes it back (fg_present_gen), and one made from a g_fg_idle read before a generated frame lapses (fg_idle_tick): generation runs again, all of it in use
static _Atomic uint64_t g_fg_trim_req, g_fg_gen_n;
static int fg_link_held(void) {
    if (g_fg_out || g_fg_in || g_fg_win || g_fg_alloc[0] || g_fg_alloc[1] || g_fg_alloc[2]) return 1;
    os_unfair_lock_lock(&g_fg_lk); int made = g_fg_fi.state == 2; os_unfair_lock_unlock(&g_fg_lk);
    return made;
}
// Under g_fg_res_mu, which fg_present_gen holds from its decision through its commit (no generated frame is being encoded meanwhile): whether a generated frame committed so far
// is still on the GPU, after waiting up to wait_ns for its feedback handler
static int fg_gen_in_flight(uint64_t wait_ns) {
    uint64_t until = now_ns() + wait_ns; int busy;
    pthread_mutex_lock(&g_pq_mu);
    for (;;) {
        busy = 0; for (int i = 0; i < 3; i++) busy |= g_fg_done[i] < g_fg_fence[i];
        uint64_t t = now_ns(); if (!busy || t >= until) break;
        struct timespec ts = {(time_t)((until - t) / 1000000000ull), (long)((until - t) % 1000000000ull)};
        pthread_cond_timedwait_relative_np(&g_pq_cv, &g_pq_mu, &ts);
    }
    pthread_mutex_unlock(&g_pq_mu);
    return busy;
}
static int64_t fg_link_release(void) {   // under g_fg_res_mu: the bytes of the textures let go; -1 while a generated frame is still on the GPU (nothing let go)
    if (fg_gen_in_flight(0)) return -1;
    int64_t b = 0;
    id<MTLTexture> t[3] = {g_fg_out, g_fg_in, g_fg_win};
    for (int i = 0; i < 3; i++) if (t[i]) { b += (int64_t)t[i].allocatedSize; res_remove(t[i]); }
    g_fg_out = g_fg_in = g_fg_win = nil;
    for (int i = 0; i < 3; i++) { if (g_fg_uv[i]) res_remove(g_fg_uv[i]); g_fg_alloc[i] = nil; g_fg_cb[i] = nil; g_fg_uv[i] = nil; }
    os_unfair_lock_lock(&g_fg_lk); if (g_fg_fi.state == 2) { g_fg_fi.fi = nil; memset(g_fg_fi.key, 0, sizeof g_fg_fi.key); g_fg_fi.state = 0; } os_unfair_lock_unlock(&g_fg_lk);
    memset(g_fg_last_key, 0, sizeof g_fg_last_key); atomic_store(&g_fg_prev_ticket, 0);   // the next one starts with no history (fg_decide resets the new interpolator's)
    res_commit();
    return b;
}
// The display link's thread, under g_fg_res_mu: a frame it took without a generated frame
static void fg_idle_tick(void) {
    uint64_t n = atomic_fetch_add(&g_fg_idle, 1) + 1, r = atomic_load(&g_fg_trim_req);
    int req = r && r == atomic_load(&g_fg_gen_n) + 1;
    if (r && !req) atomic_compare_exchange_strong(&g_fg_trim_req, &r, 0);   // made before a generated frame: lapsed (a newer one the trim stores meanwhile stays)
    if (n < g_fg_idle_frames && !req) return;
    if (!fg_link_held()) { if (req) atomic_compare_exchange_strong(&g_fg_trim_req, &r, 0); return; }
    int64_t b = fg_link_release(); if (b < 0) return;   // a generated frame still on the GPU: at the next frame
    atomic_store(&g_fg_trim_req, 0);
    if (req) MLOG("frame generation: a memory trim, while it is not generating: its output and window textures (%.1f MB), command allocators and interpolator released (made again when it generates)", b / 1048576.0);
    else MLOG("frame generation: no generated frame for %llu frames: its output and window textures (%.1f MB), command allocators and interpolator released (made again when it generates)", (unsigned long long)n, b / 1048576.0);
}
// A memory trim (mtl_trim_at: a pressure warning or critical at a submission's start, on the submit thread; going to the background, with every submission and present drained):
// frame generation's memory while it is not generating (the display link's last frame was real), and all of it going to the background, where the link calls back nothing and the
// return starts with a new interpolator. The capture ring here; the display link's side here going to the background, else at its next frame without a generated frame.
// A pressure trim's ring waits for the next submission's fence, which the queue orders after every generated frame committed before it. Going to the background the fence has
// passed, but a display-link callback that took its frame before the drain looked may have committed a generated frame after it: g_fg_res_mu keeps one from being encoded
// meanwhile, one still on the GPU is waited for a moment (g_fg_bg_wait_ns), and one still there then keeps what it reads: the ring behind the next submission's fence, the
// display link's side at its next frame without a generated one
static uint64_t g_fg_bg_wait_ns = 50000000ull;
static void fg_trim(int level, uint64_t fence) {
    if (!fg_on()) return;
    uint64_t gn = atomic_load(&g_fg_gen_n);   // before g_fg_idle, which a generated frame zeroes before it counts itself: a request made from a stale g_fg_idle lapses
    if (level != 3 && !atomic_load(&g_fg_idle)) return;   // generating: all of it is in use
    int n = 0, held = 0, busy = 0; uint64_t b; int64_t lb = -1;
    if (level == 3) {
        pthread_mutex_lock(&g_fg_res_mu);
        busy = fg_gen_in_flight(g_fg_bg_wait_ns);
        b = fg_ring_release(busy ? g_fence + 1 : fence, &n);
        held = fg_link_held(); lb = !held ? 0 : busy ? -1 : fg_link_release();
        pthread_mutex_unlock(&g_fg_res_mu);
    } else b = fg_ring_release(fence, &n);
    if (lb < 0) atomic_store(&g_fg_trim_req, gn + 1);   // fg_idle_tick says what it lets go
    const char *why = level == 3 ? "going to the background" : "while it is not generating";
    if (held && lb >= 0) MLOG("frame generation: memory trim (%s): the capture ring's %d textures (%.1f MB), its output and window textures (%.1f MB), command allocators and interpolator released", why, n, b / 1048576.0, lb / 1048576.0);
    else if (n) MLOG("frame generation: memory trim (%s): the capture ring's %d textures released (%.1f MB)%s%s", why, n, b / 1048576.0, busy ? " once a generated frame still on the GPU is done" : "",
                     lb < 0 ? "; the display link's side at its next frame without a generated one" : "");
}
// The interpolator for key, made on a queue of its own the first time (its pipelines take 0.1-0.5 s): until then the frames are real (FG_MAKING)
static id<MTL4FXFrameInterpolator> fg_interp_for(const NSUInteger key[8], int *failed) {
    static dispatch_queue_t q; static dispatch_once_t once; dispatch_once(&once, ^{ q = dispatch_queue_create("nx18.framegen.make", DISPATCH_QUEUE_SERIAL); });
    os_unfair_lock_lock(&g_fg_lk);
    if (!memcmp(g_fg_fi.key, key, sizeof g_fg_fi.key) && g_fg_fi.state) {
        id<MTL4FXFrameInterpolator> fi = g_fg_fi.state == 2 ? g_fg_fi.fi : nil; *failed = g_fg_fi.state == 3;
        os_unfair_lock_unlock(&g_fg_lk); return fi;
    }
    if (g_fg_fi.state == 1) { os_unfair_lock_unlock(&g_fg_lk); *failed = 0; return nil; }   // another key being made: this one after it
    memcpy(g_fg_fi.key, key, sizeof g_fg_fi.key); g_fg_fi.state = 1; g_fg_fi.fi = nil;
    os_unfair_lock_unlock(&g_fg_lk);
    struct { NSUInteger v[8]; } kb; memcpy(kb.v, key, sizeof kb.v);
    dispatch_async(q, ^{ @autoreleasepool {
        const NSUInteger *k = kb.v;
        uint64_t t0 = now_ns();
        MTLFXFrameInterpolatorDescriptor *d = [MTLFXFrameInterpolatorDescriptor new];
        d.colorTextureFormat = (MTLPixelFormat)k[0]; d.outputTextureFormat = (MTLPixelFormat)k[0]; d.depthTextureFormat = (MTLPixelFormat)k[3]; d.motionTextureFormat = (MTLPixelFormat)k[4];
        d.outputWidth = k[1]; d.outputHeight = k[2]; d.inputWidth = k[5]; d.inputHeight = k[6]; d.requiresPrevColorTexture = NO;
        id<MTL4Compiler> comp = mtl_comp4();
        id<MTL4FXFrameInterpolator> fi = comp ? [d newFrameInterpolatorWithDevice:g_dev compiler:comp] : nil;
        MLOG("%sframe generation: MetalFX frame interpolator %lux%lu → %lux%lu, colour format %lu, depth %lu, motion %lu%s, %.0f ms", fi ? "" : "[RED] ", (unsigned long)k[5], (unsigned long)k[6],
             (unsigned long)k[1], (unsigned long)k[2], (unsigned long)k[0], (unsigned long)k[3], (unsigned long)k[4], fi ? "" : ": MetalFX made none; real frames only", (now_ns() - t0) / 1e6);
        os_unfair_lock_lock(&g_fg_lk);
        if (!memcmp(g_fg_fi.key, k, sizeof kb.v)) { g_fg_fi.fi = fi; g_fg_fi.state = fi ? 2 : 3; }
        os_unfair_lock_unlock(&g_fg_lk);
    } });
    *failed = 0; return nil;
}
// The on-screen time of every picture while frame generation is on, generated and real (their drawables' presented handlers): the status line's interval percentiles are those
// of the screen itself, which the per-frame rows (@presented_ms, real frames only) cannot show. A picture the system did not show (presentedTime 0) is counted, not timed
enum { FG_SHOWN = 1024 };
static struct { double t; int gen; } g_fg_shown[FG_SHOWN];
static uint64_t g_fg_shown_n, g_fg_shown_lost[2];
static os_unfair_lock g_fg_shown_lk = OS_UNFAIR_LOCK_INIT;
static _Atomic uint64_t g_fg_gen_shown;   // generated pictures handed to the screen (their presents committed), for Vitals' "N fps, M rendered"
uint64_t mtl_framegen_frames(void) { return atomic_load_explicit(&g_fg_gen_shown, memory_order_relaxed); }   // hle_nvn.c vitals_tick: generated pictures so far (0 while off)
static void fg_shown(double t, int gen) {
    if (gen && t > 0) atomic_fetch_add_explicit(&g_fg_gen_shown, 1, memory_order_relaxed);   // as Vitals counts real frames: those the system says it showed
    os_unfair_lock_lock(&g_fg_shown_lk);
    if (t > 0) { g_fg_shown[g_fg_shown_n % FG_SHOWN].t = t; g_fg_shown[g_fg_shown_n % FG_SHOWN].gen = gen; g_fg_shown_n++; } else g_fg_shown_lost[gen != 0]++;
    os_unfair_lock_unlock(&g_fg_shown_lk);
}
static int fg_dbl_cmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }
// The intervals between consecutive pictures of the last 600 shown (ms, nearest-rank p50 / p95 / p99), how many lasted two ticks or more (> 25 ms) and less than half a tick (< 8 ms)
static void fg_shown_line(char *out, size_t cap) {
    static double t[FG_SHOWN], d[FG_SHOWN]; int m = 0, g = 0, nd = 0, longer = 0, shorter = 0; uint64_t lost[2];
    os_unfair_lock_lock(&g_fg_shown_lk);
    uint64_t n = g_fg_shown_n, from = n > 600 ? n - 600 : 0;
    for (uint64_t i = from; i < n; i++) { t[m++] = g_fg_shown[i % FG_SHOWN].t; g += g_fg_shown[i % FG_SHOWN].gen; }
    memcpy(lost, g_fg_shown_lost, sizeof lost);
    os_unfair_lock_unlock(&g_fg_shown_lk);
    qsort(t, m, sizeof *t, fg_dbl_cmp);
    for (int i = 1; i < m; i++) { double x = (t[i] - t[i - 1]) * 1e3; if (x <= 0 || x > 1000) continue; d[nd++] = x; longer += x > 25; shorter += x < 8; }
    qsort(d, nd, sizeof *d, fg_dbl_cmp);
    #define FG_P(p) (nd ? d[MIN(nd - 1, MAX(0, (int)ceil((p) / 100.0 * nd) - 1))] : 0)
    snprintf(out, cap, "on screen: the last %d pictures (%d generated), interval p50 %.2f / p95 %.2f / p99 %.2f / max %.2f ms, %d over 25 ms, %d under 8 ms; not shown by the system: generated %llu, real %llu",
             m, g, FG_P(50), FG_P(95), FG_P(99), nd ? d[nd - 1] : 0, longer, shorter, (unsigned long long)lost[1], (unsigned long long)lost[0]);
    #undef FG_P
}
// Each picture's display-link target time and its present command buffer's GPU end (the commit feedback): the target intervals show whether every tick got a picture, and a GPU
// end after its target is a picture that would miss its refresh. Measurable with no screen to show on (a locked Mac, DM_LINK_SIM)
static struct { double target, end; int gen; } g_fg_paced[FG_SHOWN];
static uint64_t g_fg_paced_n;
static void fg_paced(double target, double end, int gen) {
    if (target <= 0 || end <= 0) return;
    os_unfair_lock_lock(&g_fg_shown_lk);
    g_fg_paced[g_fg_paced_n % FG_SHOWN].target = target; g_fg_paced[g_fg_paced_n % FG_SHOWN].end = end; g_fg_paced[g_fg_paced_n % FG_SHOWN].gen = gen; g_fg_paced_n++;
    os_unfair_lock_unlock(&g_fg_shown_lk);
}
static void fg_paced_line(char *out, size_t cap) {
    static double t[FG_SHOWN], d[FG_SHOWN], mg[FG_SHOWN]; int m = 0, nd = 0, longer = 0, late = 0;
    os_unfair_lock_lock(&g_fg_shown_lk);
    uint64_t n = g_fg_paced_n, from = n > 600 ? n - 600 : 0;
    for (uint64_t i = from; i < n; i++) { t[m] = g_fg_paced[i % FG_SHOWN].target; mg[m] = (g_fg_paced[i % FG_SHOWN].target - g_fg_paced[i % FG_SHOWN].end) * 1e3; late += mg[m] < 0; m++; }
    os_unfair_lock_unlock(&g_fg_shown_lk);
    qsort(t, m, sizeof *t, fg_dbl_cmp); qsort(mg, m, sizeof *mg, fg_dbl_cmp);
    for (int i = 1; i < m; i++) { double x = (t[i] - t[i - 1]) * 1e3; if (x <= 0 || x > 1000) continue; d[nd++] = x; longer += x > 25; }
    qsort(d, nd, sizeof *d, fg_dbl_cmp);
    #define FG_Q(a, k, p) ((k) ? (a)[MIN((k) - 1, MAX(0, (int)ceil((p) / 100.0 * (k)) - 1))] : 0)
    snprintf(out, cap, "targets: the last %d pictures, target interval p50 %.2f / p95 %.2f / p99 %.2f / max %.2f ms, %d over 25 ms; GPU done before its target p50 %.2f / p5 %.2f / min %.2f ms, %d after it",
             m, FG_Q(d, nd, 50), FG_Q(d, nd, 95), FG_Q(d, nd, 99), nd ? d[nd - 1] : 0, longer, FG_Q(mg, m, 50), FG_Q(mg, m, 5), m ? mg[0] : 0, late);
    #undef FG_Q
}
static void fg_status(void) {   // every 600 frames the link took while frame generation is on (display-link thread)
    static uint64_t n; if (++n % 600) return;
    char shown[400], paced[400]; fg_shown_line(shown, sizeof shown); fg_paced_line(paced, sizeof paced);
    char why[600] = {0}; size_t at = 0;
    for (int i = 1; i < FG_WHY_N; i++) if (g_fg_gate.why[i]) at += snprintf(why + at, sizeof why - at, "%s%s %llu", at ? ", " : "", fg_why_name[i], (unsigned long long)g_fg_gate.why[i]);
    pthread_mutex_lock(&g_pq_mu); int m = g_fg_gpu_n < 600 ? g_fg_gpu_n : 600; double a[600]; memcpy(a, g_fg_gpu, m * sizeof *a); pthread_mutex_unlock(&g_pq_mu);
    for (int i = 1; i < m; i++) { double x = a[i]; int j = i - 1; while (j >= 0 && a[j] > x) { a[j + 1] = a[j]; j--; } a[j + 1] = x; }
    MLOG("frame generation up to frame %llu: generated %llu, real %llu (%s); generated frame command buffer GPU time (interpolation and present pass) p50 %.3f ms, p95 %.3f ms over %d; captures skipped %llu; %s; %s",
         (unsigned long long)n, (unsigned long long)g_fg_gate.gen, (unsigned long long)g_fg_gate.real, at ? why : "no fallbacks", m ? a[m / 2] : 0, m ? a[m * 95 / 100] : 0, m, (unsigned long long)g_fg_cap_skipped, shown, paced);
}
// DM_FRAMEGEN_SHOT=<path prefix>:<count> (diagnostic; also set while running with DM_CTL's `env`): the next <count> generated frames are written as <prefix>_<k>_G.png, each
// with the real frame it leads into as <prefix>_<k>_F.png (the interpolator's colour input, the crop). G(k) lies between F(k-1) and F(k). Both are copied inside the generated
// frame's command buffer (fg_shot_copy) and written on a queue of their own once it completes, so neither the link nor the game waits: the frames shot are the frames shown
static void shot(id<MTLTexture> src, const char *path, int screen, const int crop[4]);
static struct { char prefix[480]; char last[512]; int left, k; } g_fg_shot;   // display-link thread
static id<MTLTexture> fg_shot_tex(id<MTLTexture> like) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:like.pixelFormat width:like.width height:like.height mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; if (t) { t.label = @"framegen shot"; res_add(t); res_commit(); }
    return t;
}
// Before the generated frame's command buffer ends: when a shot is due, copies of G and of its colour input (out: the two textures, nil when none is due)
static void fg_shot_copy(id<MTL4CommandBuffer> cb, id<MTLTexture> col, __strong id<MTLTexture> out[2]) {
    out[0] = out[1] = nil;
    const char *e = getenv("DM_FRAMEGEN_SHOT");
    if (e && strcmp(e, g_fg_shot.last)) {
        snprintf(g_fg_shot.last, sizeof g_fg_shot.last, "%s", e); const char *c = strrchr(e, ':');
        if (c && atoi(c + 1) > 0) { snprintf(g_fg_shot.prefix, sizeof g_fg_shot.prefix, "%.*s", (int)(c - e), e); g_fg_shot.left = atoi(c + 1); g_fg_shot.k = 0; MLOG("frame generation: writing the next %d generated frames and their real ones as %s_<k>_G.png / _F.png", g_fg_shot.left, g_fg_shot.prefix); }
    }
    if (g_fg_shot.left <= 0) return;
    id<MTLTexture> g = fg_shot_tex(g_fg_out), f = fg_shot_tex(col); if (!g || !f) return;
    id<MTL4ComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageBlit visibilityOptions:resource_vis()];
    [ce copyFromTexture:g_fg_out toTexture:g]; [ce copyFromTexture:col toTexture:f];
    [ce endEncoding];
    out[0] = g; out[1] = f;
}
// After the commit: the PNGs, written once the command buffer has completed
static void fg_shot_write(int ai, uint64_t seq, __strong id<MTLTexture> t[2]) {
    if (!t[0]) return;
    static dispatch_queue_t q; static dispatch_once_t once; dispatch_once(&once, ^{ q = dispatch_queue_create("nx18.framegen.shot", DISPATCH_QUEUE_SERIAL); });
    char pg[600], pf[600]; snprintf(pg, sizeof pg, "%s_%d_G.png", g_fg_shot.prefix, g_fg_shot.k); snprintf(pf, sizeof pf, "%s_%d_F.png", g_fg_shot.prefix, g_fg_shot.k);
    g_fg_shot.k++; g_fg_shot.left--;
    id<MTLTexture> g = t[0], f = t[1]; NSString *sg = @(pg), *sf = @(pf);
    dispatch_async(q, ^{
        pthread_mutex_lock(&g_pq_mu); while (g_fg_done[ai] < seq && !gpu_gone()) pthread_cond_wait(&g_pq_cv, &g_pq_mu); pthread_mutex_unlock(&g_pq_mu);
        shot(g, sg.UTF8String, 0, NULL); shot(f, sf.UTF8String, 0, NULL);
        res_remove(g); res_remove(f);
    });
}
// The frame the display link takes on this tick (ticket, its item): when fg_decide says so, encode G and present it on dr. 1: G presented, the real frame is pending for the
// next tick; 0: present the real frame now, as without frame generation
static int fg_present_gen_(const pq_item *it, uint64_t ticket, id<CAMetalDrawable> dr, double target_ts);
static int fg_present_gen(const pq_item *it, uint64_t ticket, id<CAMetalDrawable> dr, double target_ts) {
    pthread_mutex_lock(&g_fg_res_mu);
    int gen = fg_present_gen_(it, ticket, dr, target_ts);
    if (gen) { atomic_store(&g_fg_idle, 0); atomic_fetch_add(&g_fg_gen_n, 1); atomic_store(&g_fg_trim_req, 0); }   // generating again: a trim's request is taken back (in this order: fg_trim)
    else fg_idle_tick();
    pthread_mutex_unlock(&g_fg_res_mu);
    return gen;
}
static int fg_present_gen_(const pq_item *it, uint64_t ticket, id<CAMetalDrawable> dr, double target_ts) {
    id<MTLTexture> src = tex_mtl(&it->t);
    int power = fg_power_why();
    fg_in in = {.enabled = 1, .supported = fg_supported(), .movie = dm_movie_playing(), .menu = atomic_load(&g_fg_hold) || dm_front_menu_now(), .period = (int)lround(it->period * 60.0),
                .link_mode = g_dm_present_link == 1 ? g_link_mode : 0, .rescue = atomic_load(&g_rescue_mode) != 0, .thermal = power == FG_THERMAL, .battery = power == FG_BATTERY,
                .fps30 = mtl_fps_target() == 30,
                .snap = it->snap_v != 0, .upscale = it->fg_v != 0};
    uint64_t prev = atomic_exchange(&g_fg_prev_ticket, ticket); in.history = prev && ticket == prev + 1;
    pthread_mutex_lock(&g_shotq_mu); in.shot = g_nshotq > 0 || g_grab_cb != nil; pthread_mutex_unlock(&g_shotq_mu);
    fg_cap c = {0}; fg_cap *s = it->fg_v ? &g_fg_cap[it->fg_v % FG_RING] : NULL;
    if (s) { os_unfair_lock_lock(&g_fg_lk); if (s->v == it->fg_v) { c = *s; s->busy = 1; } else in.stale = 1; os_unfair_lock_unlock(&g_fg_lk); }
    NSUInteger r[4] = {0}, key[8] = {0};
    if (src && c.v) {
        in.depth = c.dep != nil; in.motion = c.mot != nil; in.reset = c.reset;
        in.crop_full = present_crop_rect(src, it->crop, r);   // a valid crop (a partial one is copied out first, below)
        NSUInteger k[8] = {src.pixelFormat, r[2], r[3], c.key[0], c.key[1], c.key[2], c.key[3], c.key[4]}; memcpy(key, k, sizeof key);
        in.key_changed = g_fg_last_key[0] && memcmp(key, g_fg_last_key, sizeof key); memcpy(g_fg_last_key, key, sizeof key);
    }
    // The interpolator is asked for (and made, the first time) only for a frame that would be generated once it is there: everything but its being made, its history and
    // MetalFX's answer says FG_GEN. Under the menu, a movie, a screenshot, power, another link or period, a stale capture or a change of sizes none is made, so what a long
    // stretch without generated frames let go (fg_idle_tick) stays let go until generation can run again, and is not made and let go over and over while captures keep coming
    // An interpolator MetalFX would not make for another key (sizes or formats since changed: the menu's docked/handheld, another render size) is tried for this one: that
    // refusal is what gave the 30 fps cap its 30 Hz link (fg_keeps_60hz), so the link and period are not held against it; a key it refused is not tried again
    int retry = 0;
    if (src && c.v) { os_unfair_lock_lock(&g_fg_lk); retry = g_fg_fi.state == 3 && memcmp(g_fg_fi.key, key, sizeof key) != 0; os_unfair_lock_unlock(&g_fg_lk); }
    fg_in can = in; can.ready = 1; can.history = 1; can.failed = 0;
    if (retry) { can.link_mode = 1; can.rescue = 0; can.period = 2; }
    id<MTL4FXFrameInterpolator> fi = src && c.v && fg_why(&can) == FG_GEN ? fg_interp_for(key, &in.failed) : nil;
    in.ready = fi != nil;
    fg_out o = fg_decide(&g_fg_gate, &in);
    fg_status();
    if (!o.gen) { if (s) { os_unfair_lock_lock(&g_fg_lk); s->busy = 0; os_unfair_lock_unlock(&g_fg_lk); } return 0; }
    // G's own command allocators (three, used in turn), so the real frames keep theirs by ticket (present_now)
    int ai = (int)(g_fg_n++ % 3);
    if (!g_fg_alloc[ai]) {
        g_fg_alloc[ai] = [g_dev newCommandAllocator]; g_fg_cb[ai] = [g_dev newCommandBuffer];
        g_fg_uv[ai] = [g_dev newBufferWithLength:sizeof(float) * PRESENT_UV_FLOATS options:MTLResourceStorageModeShared]; res_add(g_fg_uv[ai]);
    }
    // The interpolator works on the crop: a crop that is part of the window texture (Ocarina of Time's 2048x1152 of 2560x1440) is copied out first, and G is the crop's size
    // (the interpolator maps its content rectangle onto the whole of its colour and output). G is then copied back to the crop's place in a texture of the window texture's
    // size and presented with the frame's own crop, so the present pass sees G as it sees the real frames: the MetalFX present scaler, whose input is the window texture's
    // size (fx_input_size), and the crop's statistics are not made over at every generated frame
    int partial = r[0] || r[1] || r[2] != src.width || r[3] != src.height;
    if (!g_fg_out || g_fg_out.width != r[2] || g_fg_out.height != r[3] || g_fg_out.pixelFormat != src.pixelFormat) {
        if (g_fg_out) defer_obj_release(g_fg_out);
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:r[2] height:r[3] mipmapped:NO];
        d.storageMode = MTLStorageModePrivate; d.usage = fi.outputTextureUsage | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        g_fg_out = [g_dev newTextureWithDescriptor:d]; g_fg_out.label = @"framegen output"; res_add(g_fg_out);
    }
    if (partial && (!g_fg_in || g_fg_in.width != r[2] || g_fg_in.height != r[3] || g_fg_in.pixelFormat != src.pixelFormat)) {
        if (g_fg_in) defer_obj_release(g_fg_in);
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:r[2] height:r[3] mipmapped:NO];
        d.storageMode = MTLStorageModePrivate; d.usage = fi.colorTextureUsage | MTLTextureUsageShaderRead;
        g_fg_in = [g_dev newTextureWithDescriptor:d]; g_fg_in.label = @"framegen crop"; res_add(g_fg_in);
    }
    if (partial && (!g_fg_win || g_fg_win.width != src.width || g_fg_win.height != src.height || g_fg_win.pixelFormat != src.pixelFormat)) {
        if (g_fg_win) defer_obj_release(g_fg_win);
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:src.width height:src.height mipmapped:NO];
        d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        g_fg_win = [g_dev newTextureWithDescriptor:d]; g_fg_win.label = @"framegen window"; res_add(g_fg_win);
    }
    id<MTLTexture> col = partial ? g_fg_in : src;
    CAMetalLayer *layer = (__bridge CAMetalLayer *)front_metal_layer();
    if (!g_fg_out || !col || (partial && !g_fg_win) || !g_fg_alloc[ai] || !g_fg_cb[ai] || !g_fg_uv[ai] || !layer) { fg_undo(&g_fg_gate); os_unfair_lock_lock(&g_fg_lk); s->busy = 0; os_unfair_lock_unlock(&g_fg_lk); return 0; }
    if (g_present_layer_resident != layer) { [g_q4 addResidencySet:layer.residencySet]; g_present_layer_resident = layer; }
    res_commit();
    pthread_mutex_lock(&g_pq_mu); while (g_fg_done[ai] < g_fg_fence[ai] && !gpu_gone()) pthread_cond_wait(&g_pq_cv, &g_pq_mu); pthread_mutex_unlock(&g_pq_mu);
    [g_fg_alloc[ai] reset];
    [g_q4 waitForDrawable:dr];
    id<MTL4CommandBuffer> cb = g_fg_cb[ai];
    [cb beginCommandBufferWithAllocator:g_fg_alloc[ai]];
    id<MTL4ComputeCommandEncoder> ce = [cb computeCommandEncoder];   // MetalFX opens encoders of its own, which take no barrier: this one orders it after the frame's work and the presents before
    [ce barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageBlit visibilityOptions:resource_vis()];
    if (partial) [ce copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(r[0], r[1], 0) sourceSize:MTLSizeMake(r[2], r[3], 1) toTexture:col destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [ce barrierAfterStages:MTLStageBlit beforeQueueStages:MTLStageAll visibilityOptions:resource_vis()];
    [ce endEncoding];
    fi.colorTexture = col; fi.prevColorTexture = nil; fi.depthTexture = c.dep; fi.motionTexture = c.mot; fi.outputTexture = g_fg_out; fi.uiTexture = nil;
    fi.contentWidth = c.cw; fi.contentHeight = c.ch; fi.depthContentOffsetX = c.dox; fi.depthContentOffsetY = c.doy; fi.motionContentOffsetX = c.mox; fi.motionContentOffsetY = c.moy;
    fi.outputOffsetX = 0; fi.outputOffsetY = 0;
    fi.motionVectorScaleX = c.mvx; fi.motionVectorScaleY = c.mvy; fi.jitterOffsetX = c.jx; fi.jitterOffsetY = c.jy;
    fi.deltaTime = (float)it->period; fi.depthReversed = c.rev; fi.shouldResetHistory = o.reset_history;
    fi.nearPlane = 0.1f; fi.farPlane = 1000.0f; fi.fieldOfView = 60.0f; fi.aspectRatio = c.ch ? (float)c.cw / (float)c.ch : 16.0f / 9.0f;   // not known generically (no matrices: "not supplied")
    [fi encodeToCommandBuffer:cb];
    if (partial) {   // G to the crop's place (after MetalFX's encoders, which take no barrier)
        ce = [cb computeCommandEncoder];
        [ce barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageBlit visibilityOptions:resource_vis()];
        [ce copyFromTexture:g_fg_out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(r[2], r[3], 1) toTexture:g_fg_win destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(r[0], r[1], 0)];
        [ce barrierAfterStages:MTLStageBlit beforeQueueStages:MTLStageAll visibilityOptions:resource_vis()];
        [ce endEncoding];
    }
    int kind = present_encode_m4(cb, partial ? g_fg_win : g_fg_out, dr.texture, it->crop, g_fg_uv[ai], &g_fx_present, &g_aa_present);
    id<MTLTexture> shots[2]; fg_shot_copy(cb, col, shots);
    [cb endCommandBuffer];
    if (!kind) { os_unfair_lock_lock(&g_fg_lk); s->busy = 0; os_unfair_lock_unlock(&g_fg_lk); [g_q4 signalDrawable:dr]; fg_undo(&g_fg_gate); return 0; }   // nothing was committed: the real frame is presented now on this drawable (present_now waits for it again)
    uint64_t seq = g_fg_n;
    MTL4CommitOptions *op = [MTL4CommitOptions new];
    // A Metal 4 command buffer retains nothing: what it reads and writes lives until it has completed. The interpolator too, which a new key replaces (fg_interp_for drops it)
    id<MTLTexture> keep_dep = c.dep, keep_mot = c.mot, keep_src = src, keep_col = col, keep_out = g_fg_out, keep_win = partial ? g_fg_win : nil; id<MTL4FXFrameInterpolator> keep_fi = fi;
    [op addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        fb_in("generated frame");
        (void)keep_dep; (void)keep_mot; (void)keep_src; (void)keep_col; (void)keep_out; (void)keep_win; (void)keep_fi;
        gpu_busy_note(f.GPUStartTime, f.GPUEndTime);   // Vitals' GPU busy counts the generated frames' work too
        if (f.error) { MLOG("[RED] frame generation: generated frame command buffer error: %s", f.error.description.UTF8String); gpu_lost_check(f.error, "generated frame"); }
        pthread_mutex_lock(&g_pq_mu); if (seq > g_fg_done[ai]) g_fg_done[ai] = seq; g_pq_inflight--;
        double ms = (f.GPUEndTime - f.GPUStartTime) * 1e3; if (ms > 0 && ms < 1000) g_fg_gpu[g_fg_gpu_n++ % 600] = ms; fg_paced(target_ts, f.GPUEndTime, 1);
        pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
        fb_out();
    }];
    pthread_mutex_lock(&g_pq_mu); g_pq_inflight++;
    if (kind & PRESENT_AA) { g_fg_aa_ai = ai; g_fg_aa_seq = seq; }   // present_fx_idle keeps them until this command buffer has completed (fg_effect_busy)
    if ((kind & ~PRESENT_AA) == PRESENT_METALFX) { g_fg_fx_ai = ai; g_fg_fx_seq = seq; }
    pthread_mutex_unlock(&g_pq_mu);
    id<MTL4CommandBuffer> buffers[] = {cb};
    if (gpu_gone()) gpu_gone_skip(); else [g_q4 commit:buffers count:1 options:op];   // nothing more is sent to a GPU taken as lost
    os_unfair_lock_lock(&g_fg_lk); s->busy = 0; os_unfair_lock_unlock(&g_fg_lk);   // committed: a capture into this slot from now on is committed after this command buffer
    g_fg_fence[ai] = seq;
    [g_q4 signalDrawable:dr];
    [dr addPresentedHandler:^(id<MTLDrawable> d) { fg_shown(d.presentedTime, 1); }];
    [dr present];   // on the tick's own target time (the display link's drawable); no presented-time record: g_pres follows the real frames
    fg_shot_write(ai, seq, shots);
    static int said; if (!said++) MLOG("frame generation: first generated frame shown (frame %llu, ticket %llu)", (unsigned long long)it->frame, (unsigned long long)ticket);
    return 1;
}
// The frame present_enqueue queues: the newest capture since the last present (this frame's upscale), 0 when none came (present_enqueue's thread)
static uint64_t fg_frame_capture(void) { static uint64_t last; uint64_t v = atomic_load(&g_fg_cap_v); if (v == last) return 0; last = v; return v; }
static pq_item g_fg_pend_it;
// A real frame shown after its generated frame reaches the screen one tick after the tick that took it. The per-ticket records follow it: the link's (g_link_ring: its target is
// the tick that shows F, so @pres_at_ms - @link_target_ms stays how late the system showed it), and this shift (under g_pq_mu, read 8 presents later as g_pres is), which
// hle_nvn.c takes out of the real frames' on-screen intervals (pres_shifted_ms: the frame step's screen verdict, the dropped frames, Vitals' gap, @presented_ms). Without it each
// switch between generated and real frames read as a late frame (three ticks) and a short one (one tick), though a picture was on screen at every tick
typedef struct { uint64_t n; double s; } fg_shift_ent;
static fg_shift_ent g_fg_shift[PRING];
static void fg_shift_note(uint64_t ticket) { g_fg_shift[ticket % PRING] = (fg_shift_ent){ticket, 1.0 / 60}; }   // one tick of the 60 Hz link, the only one it generates on
double mtl_presented_shift(uint64_t n) { if (!fg_on()) return 0; fg_shift_ent e = g_fg_shift[n % PRING]; return e.n == n ? e.s : 0; }   // seconds; 0 for a frame shown on its own tick
// The display link's tick, under g_pq_mu with a real frame pending behind the generated frame the tick before showed: shows it on this tick (dr, at target_ts; cb the callback's
// time), before the hold and before a newer frame, and unlocks g_pq_mu. Returns 0 (still locked) when the link is not the one that showed the generated frame (stopped or rescued:
// the present thread takes the pending frame first, present_main)
static int fg_take_pending(id<CAMetalDrawable> dr, double target_ts, double cb) {
    if (!g_dm_present_link || g_rescue_mode || fg_tick(&g_fg_seq, 0, 0, 0) != FG_A_PENDING) return 0;
    pq_item it = g_fg_pend_it; uint64_t ticket = g_fg_seq.ticket; g_link_it_tin = it.t_in;
    link_ent *le = &g_link_ring[ticket % PRING]; if (le->n == ticket) { le->target = target_ts; le->lead_ms = (target_ts - cb) * 1e3; }   // ticks and gap stay the take tick's
    fg_shift_note(ticket);
    pthread_mutex_unlock(&g_pq_mu);
    int submitted; @autoreleasepool { submitted = present_now(&it.t, it.period, it.frame, ticket, it.crop, dr, target_ts); mtl_tex_unpin(it.t.serial); }
    if (!submitted) { pthread_mutex_lock(&g_pq_mu); if (ticket > g_pq_done) g_pq_done = ticket; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu); }
    return 1;
}
// Under g_pq_mu: a pending real frame that will not be shown (a suspend, a discard, a stall): counted as dropped, its texture unpinned. Returns its ticket (0: none)
static uint64_t fg_drop_pending_locked(void) {
    uint64_t t = fg_flush(&g_fg_seq);
    if (t) { g_pres[t % PRING] = (pres_ent){t, -1}; mtl_tex_unpin(g_fg_pend_it.t.serial); g_link_dropped++; if (g_pq_done < t) g_pq_done = t; atomic_store(&g_fg_prev_ticket, 0); pthread_cond_broadcast(&g_pq_cv); }
    return t;
}
