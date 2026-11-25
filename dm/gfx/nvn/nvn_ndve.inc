// nn::ndve's movie network run by the host's kernels (dm/gfx/msl/ndve_engine.metal) instead of its translated dispatches (the Mac's default; DM_NDVE_ENGINE=1), or
// skipped with the picture scaled by MetalFX (the iPhone's default; DM_NDVE_ENGINE=mfx, see ndve_mfx_scale); DM_NDVE_ENGINE=0 runs the game's dispatches. Included by
// nvn_mtl.m; shaders.md, "The NDVE movie network by the host" and "The NDVE movie network skipped for MetalFX on the iPhone". Bound to the library's model, not to a game: nn::ndve (a
// Nintendo library linked into main, nn::ndve::RouleauArchiveIO) reads Movie/Ndve/Ndve-Nvn2-vid_seq5.dat, a Rouleau archive whose first network is the U-Net below: its 9
// compute shaders (the keys here are their contents' hashes) and its 0x3c320 bytes of weights, the size the archive's network table states. Any game that ships that model
// runs these keys with these weights; the archive holds no layer graph (the library's code does), so the graph is written here, and the weights' offsets follow from it.
// A movie frame is 14 compute dispatches: the colour conversion 49dff010 (NV12 -> RGBA8, from the archive's NDSR pack), eleven of a U-Net over the picture packed 2x2 at
// 960x540 (16 / 32 / 64 channels, HMMA.16816.F16 convolutions; the model's shaders are compiled for that size), 5a7d69b0 (the last convolution, added to the picture, into
// an RGB10A2 image) and the resampler 4f41ccf2 (the model's 4/3, to 2560x1440). The host skips the eleven, computes the whole network at 5a7d69b0 from the picture the first
// of them read, with the weights and biases the game bound, into the image 5a7d69b0 writes, and runs its own resampler at 4f41ccf2. 49dff010 stays the game's. The kernels
// do the translated shaders' arithmetic in their order (each HMMA as dmsh_rewrite.py's HMMA_BODY does it), so the output bits are theirs (dm/gfx/tests/test_ndve_engine.py).
// Recognition: the keys in order, the weights and biases each dispatch binds at the offsets the graph gives from the first layer's, the picture and image sizes and formats,
// the resampler's constants. Anything else (another model, the archive's second network, other bindings or sizes, a dispatch out of order, no library) leaves the game's
// dispatches running, logged once; a deviation after some dispatches were skipped turns the host's network off for the rest of the run, and that frame's movie picture is
// not updated. The intermediate tensors the skipped dispatches would have written stay unwritten: the network reads them only within the frame's sequence

enum { NDVE_N = 14, NDVE_WBYTES = 0x3c320 };
static const char k_ndve_keys[NDVE_N][17] = {"49dff010b9832251", "ba079f68ae288dba", "a8b4fb48fee0ccf8", "e2eebd7ba18fe35f", "e6be82d835fbe4d3", "9442573ee4ace011",
    "0a56002cdc7e1fce", "0a56002cdc7e1fce", "d15370a382630d4e", "e6be82d835fbe4d3", "7f7ff0f36b54d90f", "a8b4fb48fee0ccf8", "5a7d69b067a7f011", "4f41ccf24f163e0d"};

// The host's network: its kernels (ndve_engine.metal), its tensors (f16 NHWC with a zero border), one layer table
typedef struct { uint32_t W, H, tiles_x, tiles_y; } ndve_args;
enum { NT_X0, NT_A, NT_S16, NT_B32, NT_S32, NT_E32, NT_C64, NT_D64, NT_N };
static const int k_ndve_t[NT_N][3] = {{960, 540, 16}, {960, 540, 16}, {960, 540, 16}, {480, 270, 32}, {480, 270, 32}, {480, 270, 32}, {240, 135, 64}, {240, 135, 64}};
enum { NK_PACK, NK_C16, NK_C32, NK_C64, NK_D16, NK_D32, NK_U64, NK_U32, NK_OUT, NK_LUMA, NK_RS, NK_CMP, NK_FLIP, NK_N };
static const char *k_ndve_kern[NK_N] = {"pack_input", "conv3s_16_16", "conv3s_32_32", "conv3s_64_64", "down_16_32", "down_32_64", "up_64_32", "up_32_16", "out_16", "rs_luma", "resample", "cmp_img",
    "flip_rows"};
static const int k_ndve_ry[NK_N] = {0, 4, 2, 1, 2, 1, 1, 2, 4, 0, 0, 0, 0};
// each kernel's weights: taps, input channels, output channels (w[tap][k][n] halves), then N biases
static const int k_ndve_shape[NK_N][3] = {{0, 0, 0}, {9, 16, 16}, {9, 32, 32}, {9, 64, 64}, {4, 16, 32}, {4, 32, 64}, {4, 64, 32}, {4, 32, 16}, {9, 16, 16}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0}, {0, 0, 0}};
typedef struct { int k, in, out, skip, layer; } ndve_layer;   // layer: the game's dispatch it stands for (its position in k_ndve_keys)
static const ndve_layer k_ndve_l[] = {
    {NK_PACK, -1, NT_X0, -1, 0}, {NK_C16, NT_X0, NT_A, -1, 1}, {NK_C16, NT_A, NT_S16, -1, 2}, {NK_D16, NT_S16, NT_B32, -1, 3}, {NK_C32, NT_B32, NT_S32, -1, 4},
    {NK_D32, NT_S32, NT_C64, -1, 5}, {NK_C64, NT_C64, NT_D64, -1, 6}, {NK_C64, NT_D64, NT_C64, -1, 7}, {NK_U64, NT_C64, NT_B32, NT_S32, 8}, {NK_C32, NT_B32, NT_E32, -1, 9},
    {NK_U32, NT_E32, NT_A, NT_S16, 10}, {NK_C16, NT_A, NT_X0, -1, 11}, {NK_OUT, NT_X0, -1, -1, 12}};
enum { NDVE_NL = sizeof k_ndve_l / sizeof k_ndve_l[0] };
// Each network dispatch's weights and biases (storage buffer registers 2 / 3), bytes from the first layer's weights: the model's layers in order, each one's weights then its
// biases, each padded to 256 bytes but the last biases, to the end of the model's 0x3c320 bytes (ndve_offsets checks it)
static uint32_t g_ndve_w[NDVE_N], g_ndve_b[NDVE_N];
static int ndve_offsets(void) {
    uint32_t o = 0;
    for (int i = 1; i < NDVE_NL; i++) {
        const int *sh = k_ndve_shape[k_ndve_l[i].k]; const int p = k_ndve_l[i].layer;
        g_ndve_w[p] = o; o += ((uint32_t)(sh[0] * sh[1] * sh[2] * 2) + 255) & ~255u;
        g_ndve_b[p] = o; o += i == NDVE_NL - 1 ? (uint32_t)sh[2] * 2 : ((uint32_t)sh[2] * 2 + 255) & ~255u;
    }
    return o == NDVE_WBYTES;
}
static struct {
    _Atomic int state;   // 0 not started, 1 building (background), 2 ready, -1 failed
    id<MTLComputePipelineState> ps[NK_N];
    id<MTLBuffer> t[NT_N], args, luma;
    id<MTL4ArgumentTable> at;
    int pos;             // the next dispatch of the sequence expected (0 = none taken), 13 = 4f41ccf2 next
    int off;             // permanently off after a deviation in the middle of a sequence
    uint64_t w0;         // guest address of the first layer's weights in this sequence
    int pic;             // texture ID of the picture the first layer read (the engine's input)
    uint64_t frames, skipped, rs_frames;
    uint64_t wrs;        // GPU address of the resampler's weights this frame (storage buffer register 2 of 4f41ccf2)
    // DM_NDVE_ENGINE=check: the engine's network and resampler into images of their own beside the game's, compared texel by texel (ndve_compare)
    id<MTLTexture> shadow, shadow_rs, game_out, game_rs;   // the engine's network output and resampled picture; the game's, to compare once its dispatch has run
    id<MTLBuffer> cnt;   // uint32: network texels that differ, the largest difference; the same for the resampler
    uint64_t chk_net, chk_rs;   // frames compared
    // DM_NDVE_ENGINE=mfx (ndve_mfx_scale): MetalFX's spatial scalers, one a canvas size (k_ndve_cv), made with the pipelines (mfx_state 2; -1 none, or turned off after it
    // failed); its own input and outputs, made on first use by a side that cannot be the game's texture; this sequence's choice (seq_mfx, taken at its first network dispatch)
    // and what 5a7d69b0 bound, kept for the resampler: the picture, the network's image (and its texture serial, m_net_ser) and the weights (to run the network after all
    // when MetalFX cannot draw the frame, or something other than the resampler comes first: ndve_mfx_settle)
    _Atomic int mfx_state;
    id<MTL4FXSpatialScaler> mfx[2];
    id<MTLTexture> mfx_in, mfx_out[2], m_pic, m_net;
    uint64_t m_wgpu, m_net_ser, mfx_frames;
    int seq_mfx, mfx_sides;   // mfx_sides: the last frame's sides that were the game's own textures (1 the picture, 2 the canvas)
    int t_zero;           // the tensors were made on first need (ndve_net_mem) and the next ndve_encode zeroes them first
} g_nd;
// The canvases MetalFX writes: the model's 2560x1440, and 2048x1152, the game's output docked on the iPhone and iPad, where the host answers graphics scale tier 1 (0.8 of it;
// services.md, "The graphics scale does not follow the operation mode"). Whether the movie's canvas follows the tier is not seen; a scaler for each costs little
static const int k_ndve_cv[2][2] = {{2560, 1440}, {2048, 1152}};
static int ndve_cv_slot(NSUInteger w, NSUInteger h) { for (int s = 0; s < 2; s++) if (w == (NSUInteger)k_ndve_cv[s][0] && h == (NSUInteger)k_ndve_cv[s][1]) return s; return -1; }
// DM_NDVE_ENGINE: unset or empty, the platform's default (MetalFX on iOS and iPadOS, the host's network on the Mac); 1 the host's network; 0 the game's dispatches; mfx the
// network skipped and the picture scaled by MetalFX (metalfx the same); check (ndve_check); ab MetalFX in the DM_AB phases it is on in, the host's network in the others (both
// in one process, for the GPU and power A/B of the two); another word keeps the default with a red line
enum { NDVE_GAME, NDVE_NET, NDVE_MFX, NDVE_AB, NDVE_CHECK };
#define NDVE_MFX_DEFAULT (TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST)
static int ndve_parse(const char *e, int mfx_default) {
    if (!e || !*e) return mfx_default ? NDVE_MFX : NDVE_NET;
    if (!strcmp(e, "mfx") || !strcmp(e, "metalfx")) return NDVE_MFX;
    if (!strcmp(e, "check")) return NDVE_CHECK;
    if (!strncmp(e, "ab", 2)) return NDVE_AB;
    char *end = NULL; long v = strtol(e, &end, 10);
    if (end == e || *end) return -1;
    return v ? NDVE_NET : NDVE_GAME;
}
static int g_ndve_ab;   // sw_mode's value for DM_NDVE_ENGINE=ab
static int ndve_sel(void) {
    static int m = -1;
    if (m >= 0) return m;
    const char *e = getenv("DM_NDVE_ENGINE"); int v = ndve_parse(e, NDVE_MFX_DEFAULT);
    if (v < 0) { v = ndve_parse(NULL, NDVE_MFX_DEFAULT); MLOG("[RED] DM_NDVE_ENGINE=%s: 0, 1, mfx, ab or check; keeping the default (%s)", e, v == NDVE_MFX ? "mfx" : "1"); }
    if (v == NDVE_AB) { g_ndve_ab = sw_mode_of("DM_NDVE_ENGINE", e, 0); MLOG("DM_NDVE_ENGINE=ab: the movie by MetalFX in the phases it is on in, by the host's network in the others"); }
    return m = v;
}
// What the next movie frame's sequence runs: NDVE_GAME, NDVE_NET or NDVE_MFX (asked between sequences only, so an A/B phase changes nothing in the middle of one)
static int ndve_kind(void) { int s = ndve_sel(); return s == NDVE_AB ? (sw_on(g_ndve_ab) ? NDVE_MFX : NDVE_NET) : s == NDVE_CHECK ? NDVE_NET : s; }
// DM_NDVE_ENGINE=check: the game's dispatches run, and the engine computes the same frame beside them into images of its own, compared with the game's (logged every 300 frames)
static int ndve_check(void) { static int c = -1; if (c < 0) { c = ndve_sel() == NDVE_CHECK; if (c) MLOG("DM_NDVE_ENGINE=check: the game's movie network runs, and the host's beside it, compared"); } return c; }
static int ndve_index(NvShader *cs, int from) { for (int i = from; i < NDVE_N; i++) if (!strncmp(cs->key, k_ndve_keys[i], 16)) return i; return -1; }
// DM_NDVE_ENGINE=mfx: MetalFX's spatial scaler for the movie, the model's fixed sizes and RGBA8 on both sides (see ndve_mfx_scale), made with the pipelines in the
// background. Without one (a GPU with no Metal 4 MetalFX, or MetalFX refuses), the host's network runs the movie, with one line
static void ndve_mfx_make(void) {
    if (![MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]) {
        MLOG("NDVE engine: this GPU has no Metal 4 MetalFX spatial scaler; the movie's network runs as the host's kernels instead of the MetalFX scale"); g_nd.mfx_state = -1; return;
    }
    uint64_t t0 = now_ns(); id<MTL4Compiler> comp = mtl_comp4();
    for (int s = 0; s < 2; s++) {
        MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
        d.colorTextureFormat = MTLPixelFormatRGBA8Unorm; d.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
        d.inputWidth = 1920; d.inputHeight = 1080; d.outputWidth = (NSUInteger)k_ndve_cv[s][0]; d.outputHeight = (NSUInteger)k_ndve_cv[s][1];
        d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;   // the picture is video colour, gamma-encoded in 0-1 (RGBA8Unorm, no sRGB decode): perceptual in and out
        id<MTL4FXSpatialScaler> sc = nil;
        @try { sc = comp ? [d newSpatialScalerWithDevice:g_dev compiler:comp] : nil; } @catch (NSException *x) { sc = nil; }
        if (!sc && !s) { MLOG("[RED] NDVE engine: MetalFX made no spatial scaler for the movie (1920x1080 RGBA8 -> 2560x1440 RGBA8, perceptual); the movie's network runs as the host's kernels"); g_nd.mfx_state = -1; return; }
        if (!sc) MLOG("NDVE engine: MetalFX made no scaler for a 2048x1152 canvas; a movie drawn at that size runs the host's network");
        g_nd.mfx[s] = sc;
    }
    g_nd.mfx_state = 2;
    MLOG("NDVE engine: MetalFX spatial scalers for the movie made (1920x1080 -> 2560x1440%s, perceptual), %.1f ms", g_nd.mfx[1] ? " and 2048x1152" : "", (now_ns() - t0) / 1e6);
}
// The network's tensors (f16 with a zero border) and the resampler's luma, private: about 92 MB. ndve_build makes and zeroes them wherever the network may run; under
// DM_NDVE_ENGINE=mfx alone (the iPhone's default) they are made only when the network runs after all (a MetalFX fallback), here on the submitting thread, and the first
// ndve_encode zeroes them before its kernels (t_zero). 0 when they cannot be made
static size_t ndve_tsize(int i) { return (size_t)(k_ndve_t[i][0] + 2) * (k_ndve_t[i][1] + 2 + 16) * k_ndve_t[i][2] * 2; }
static int ndve_net_mem(void) {
    if (g_nd.t[0] && g_nd.luma) return 1;
    uint64_t t0 = now_ns(); size_t n = 1920 * 1080 * 2;
    id<MTLBuffer> t[NT_N]; id<MTLBuffer> luma = [g_dev newBufferWithLength:1920 * 1080 * 2 options:MTLResourceStorageModePrivate];
    for (int i = 0; i < NT_N; i++) { t[i] = [g_dev newBufferWithLength:ndve_tsize(i) options:MTLResourceStorageModePrivate]; n += ndve_tsize(i); if (!t[i]) luma = nil; }
    if (!luma) { MLOG("[RED] NDVE engine: the host's network's tensors (%.0f MB) could not be made", n / 1e6); return 0; }
    for (int i = 0; i < NT_N; i++) { g_nd.t[i] = t[i]; res_add(t[i]); }
    g_nd.luma = luma; res_add(luma); res_commit();
    g_nd.t_zero = 1;
    MLOG("NDVE engine: the host's network's tensors made now that it runs (%.0f MB, %.1f ms)", n / 1e6, (now_ns() - t0) / 1e6);
    return 1;
}
// Pipelines and tensors, made once in the background; the game's dispatches run until they are ready
static void ndve_build(void) {
    int z = 0; if (!atomic_compare_exchange_strong(&g_nd.state, &z, 1)) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        if (!ndve_offsets()) { MLOG("[RED] NDVE engine: the layer table does not add up to the model's weights; the game's network runs"); g_nd.state = -1; return; }
        NSError *e = nil; id<MTLLibrary> lib = host_lib("ndve_engine", &e);
        if (!lib) { MLOG("[RED] NDVE engine: no library (%s); the game's network runs", e.localizedDescription.UTF8String); g_nd.state = -1; return; }
        for (int k = 0; k < NK_N; k++) {
            g_nd.ps[k] = host_cps(lib, @(k_ndve_kern[k]), nil, &e);
            if (!g_nd.ps[k]) { MLOG("[RED] NDVE engine: no pipeline for %s (%s); the game's network runs", k_ndve_kern[k], e ? e.localizedDescription.UTF8String : "no error given"); g_nd.state = -1; return; }
        }
        if (ndve_sel() == NDVE_MFX || ndve_sel() == NDVE_AB) ndve_mfx_make(); else g_nd.mfx_state = -1;
        if (ndve_sel() != NDVE_MFX || g_nd.mfx_state != 2) {   // the network may run: its tensors now (under mfx alone, on first need: ndve_net_mem)
            // a one-off command buffer of the Metal 4 queue (nvn_mtl.m once_new); order 0: new buffers, it reads nothing and waits for nothing before it
            NvOnce *cb = once_new(0); id<MTL4ComputeCommandEncoder> be = once_copy(cb);
            for (int i = 0; i < NT_N; i++) {   // private, zeroed once: the borders stay zero (the kernels write interiors only)
                g_nd.t[i] = [g_dev newBufferWithLength:ndve_tsize(i) options:MTLResourceStorageModePrivate];
                once_use(cb, g_nd.t[i]);
                [be fillBuffer:g_nd.t[i] range:NSMakeRange(0, ndve_tsize(i)) value:0];
            }
            once_end(cb, be);
            if (!once_wait(cb)) { MLOG("[RED] NDVE engine: zeroing its tensors failed on the GPU; the game's network runs"); g_nd.state = -1; return; }
            for (int i = 0; i < NT_N; i++) res_add(g_nd.t[i]);
            g_nd.luma = [g_dev newBufferWithLength:1920 * 1080 * 2 options:MTLResourceStorageModePrivate]; res_add(g_nd.luma);
        }
        g_nd.args = [g_dev newBufferWithLength:256 * NDVE_NL options:MTLResourceStorageModeShared]; res_add(g_nd.args);
        for (int i = 0; i < NDVE_NL; i++) {
            const ndve_layer *L = &k_ndve_l[i]; const int *T = k_ndve_t[L->in >= 0 ? L->in : NT_X0]; ndve_args a = {960, 540, 0, 0};
            if (L->k != NK_PACK) {
                const int down = L->k == NK_D16 || L->k == NK_D32;   // a.W, a.H: the output's size, the input's for the transposed convolutions
                a.W = (uint32_t)(down ? T[0] / 2 : T[0]); a.H = (uint32_t)(down ? T[1] / 2 : T[1]);
                a.tiles_x = a.W / 8; a.tiles_y = (a.H + k_ndve_ry[L->k] - 1) / k_ndve_ry[L->k];
            }
            memcpy((uint8_t *)g_nd.args.contents + 256 * i, &a, sizeof a);
        }
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 6; ad.maxTextureBindCount = 3;
        g_nd.at = rec_table([g_dev newArgumentTableWithDescriptor:ad error:&e]);
        if (!g_nd.at) { MLOG("[RED] NDVE engine: no argument table; the game's network runs"); g_nd.state = -1; return; }
        g_nd.state = 2;
        if (g_nd.mfx_state == 2) MLOG("NDVE engine ready: nn::ndve's movie network (12 dispatches after the colour conversion) is skipped and MetalFX scales the picture%s (DM_NDVE_ENGINE=1 runs the network as the host's kernels, 0 the game's)",
                                      ndve_sel() == NDVE_AB ? " in the DM_AB phases it is on in, the host's kernels in the others" : "; the network's tensors (92 MB) are made only if it runs after all");
        else MLOG("NDVE engine ready: nn::ndve's movie network (12 dispatches after the colour conversion) runs as the host's kernels (DM_NDVE_ENGINE=0 runs the game's)");
    } });
}
static int ndve_fail(NvShader *cs, const char *why) {
    if (g_nd.pos > 1) { g_nd.off = 1; MLOG("[RED] NDVE engine: %s at %s after %d of the network's dispatches were skipped; the engine is off from now on (this frame's movie picture is not updated)", why, cs->key, g_nd.pos - 1); }
    else { static int once; if (!once++) MLOG("NDVE engine: %s at %s; the game's network runs (logged once)", why, cs->key); }
    g_nd.pos = 0; g_nd.seq_mfx = 0; g_nd.m_pic = g_nd.m_net = nil; return 0;
}
// The image (img) or texture (tex) binding of a stage-5 reflection entry, or nil; *id_out (when given) its texture ID
static id<MTLTexture> ndve_tex_id(NvShader *cs, int kind, int reg, int *id_out) {
    for (int i = 0; i < cs->rf.nb; i++) {
        const nvn_rbind *b = &cs->rf.b[i]; if (b->kind != kind || b->reg != reg) continue;
        int tid = kind == NVN_RB_TEX ? (int)(tex_slot_h(S.tex[5], S.img[5], b->reg) & 0xfffff) : b->reg < 32 ? (int)(S.img[5][b->reg] & 0xfffff) : 0;
        id<MTLTexture> t = nil; uint64_t rid = 0; int real = 0;
        rmu_lock();
        if (tid > 0 && tid < g_ntreg && g_treg[tid].ok) { if (kind == NVN_RB_IMG) { t = img_binding(tid, b, &rid, &real); if (!real) t = nil; } else t = tex_by_id(tid); }
        os_unfair_lock_unlock(&g_rmu);
        if (id_out) *id_out = tid;
        return t;
    }
    return nil;
}
static id<MTLTexture> ndve_tex(NvShader *cs, int kind, int reg) { return ndve_tex_id(cs, kind, reg, NULL); }
// The network: 13 kernels in one compute encoder, ordered by barriers; input = the picture 5a7d69b0 reads, output = the image it writes
// (1 when encoded; 0 with nothing encoded, when its tensors cannot be made)
static int ndve_encode(id<MTLTexture> rgba, id<MTLTexture> out, uint64_t wgpu) {
    if (!ndve_net_mem()) return 0;
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    id<MTL4ComputeCommandEncoder> ce = enc_c_begin();   // waits for the work before it (queue barrier)
    [ce setArgumentTable:g_nd.at];
    if (g_nd.t_zero) {   // tensors made on first need: zeroed once, their borders stay zero
        for (int i = 0; i < NT_N; i++) [ce fillBuffer:g_nd.t[i] range:NSMakeRange(0, ndve_tsize(i)) value:0];
        [ce barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageDispatch visibilityOptions:resource_vis()];
        g_nd.t_zero = 0;
    }
    id<MTL4ArgumentTable> at = g_nd.at;
    for (int i = 0; i < NDVE_NL; i++) {
        const ndve_layer *L = &k_ndve_l[i];
        if (i) [ce barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch visibilityOptions:resource_vis()];
        [ce setComputePipelineState:g_nd.ps[L->k]];
        [at setAddress:g_nd.args.gpuAddress + 256 * i atIndex:4];
        const ndve_args *a = (const ndve_args *)((uint8_t *)g_nd.args.contents + 256 * i);
        if (L->k == NK_PACK) {
            [at setTexture:rgba.gpuResourceID atIndex:0]; [at setAddress:g_nd.t[L->out].gpuAddress atIndex:1];
            [ce dispatchThreadgroups:MTLSizeMake((960 + 31) / 32, (540 + 3) / 4, 1) threadsPerThreadgroup:MTLSizeMake(32, 4, 1)];
            continue;
        }
        [at setAddress:g_nd.t[L->in].gpuAddress atIndex:0];
        if (L->out >= 0) [at setAddress:g_nd.t[L->out].gpuAddress atIndex:1];
        [at setAddress:wgpu + g_ndve_w[L->layer] atIndex:2]; [at setAddress:wgpu + g_ndve_b[L->layer] atIndex:3];
        if (L->skip >= 0) [at setAddress:g_nd.t[L->skip].gpuAddress atIndex:5];
        if (L->k == NK_OUT) { sc_forget(out); [at setTexture:rgba.gpuResourceID atIndex:0]; [at setTexture:out.gpuResourceID atIndex:1]; }
        const int staged = L->k == NK_C16 || L->k == NK_C32 || L->k == NK_C64;   // conv3s_*: a threadgroup = 32 x RY outputs
        uint32_t groups = staged ? (a->W + 31) / 32 * a->tiles_y : (a->tiles_x * a->tiles_y + 3) / 4;
        [ce dispatchThreadgroups:MTLSizeMake(groups, 1, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
    }
    [ce barrierAfterStages:MTLStageDispatch | MTLStageBlit beforeQueueStages:MTLStageAll visibilityOptions:resource_vis()];   // what follows (4f41ccf2) waits for the image
    enc_c_end(ce);
    args_dirty_all();
    return 1;
}
// The resampler 4f41ccf2's bindings and constants, when they are the model's: the network's 1920x1080 RGB10A2 picture, a 512x512 dither, 2560x1440 RGBA8 out (any_cv: or
// another of MetalFX's canvases, k_ndve_cv, with constants of that size), dither on
static int ndve_rs_bound(NvShader *cs, int any_cv, id<MTLTexture> *pic_, id<MTLTexture> *dith_, id<MTLTexture> *out_) {
    id<MTLTexture> pic = ndve_tex(cs, NVN_RB_TEX, 0), dith = ndve_tex(cs, NVN_RB_TEX, 3), out = ndve_tex(cs, NVN_RB_IMG, 1);
    const int32_t *c = (const int32_t *)S.push[1];
    const int cv = out ? ndve_cv_slot(out.width, out.height) : -1;
    if (!pic || !dith || !out || pic.width != 1920 || pic.height != 1080 || pic.pixelFormat != MTLPixelFormatRGB10A2Unorm || dith.width != 512 || dith.height != 512 ||
        cv < 0 || (cv && !any_cv) || out.pixelFormat != MTLPixelFormatRGBA8Unorm || out.textureType != MTLTextureType2D ||
        c[0] || c[1] || c[2] != 1919 || c[3] != 1079 || c[4] || c[5] || c[6] != (int32_t)out.width - 1 || c[7] != (int32_t)out.height - 1 || c[20] != 1) {
        static int once; if (!once++) MLOG("NDVE engine: the resampler's bindings or constants are not the model's (%s RGBA8 from 1920x1080, dither on; here %lux%lu); the %s (logged once)",
                                           any_cv ? "2560x1440 or 2048x1152" : "2560x1440", (unsigned long)out.width, (unsigned long)out.height, any_cv ? "MetalFX scale falls back" : "game's resampler runs");
        return 0;
    }
    *pic_ = pic; *dith_ = dith; *out_ = out; return 1;
}
// The resampler 4f41ccf2: luma pre-pass, then one SIMD-group an 8x8 output block
static int ndve_resample(NvShader *cs, id<MTLTexture> into) {
    id<MTLTexture> pic = nil, dith = nil, out = nil;
    if (!g_nd.luma || !ndve_rs_bound(cs, 0, &pic, &dith, &out)) return 0;
    __strong id<MTLBuffer> cb = nil; size_t co = arena_alloc(256, &cb); memcpy((uint8_t *)cb.contents + co, S.push[1], 96);
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    id<MTL4ComputeCommandEncoder> ce = enc_c_begin();
    id<MTL4ArgumentTable> at = g_nd.at; [ce setArgumentTable:at];
    [ce setComputePipelineState:g_nd.ps[NK_LUMA]]; [at setTexture:pic.gpuResourceID atIndex:0]; [at setAddress:g_nd.luma.gpuAddress atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake(60, 135, 1) threadsPerThreadgroup:MTLSizeMake(32, 8, 1)];
    [ce barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch visibilityOptions:resource_vis()];
    [ce setComputePipelineState:g_nd.ps[NK_RS]];
    [at setAddress:g_nd.luma.gpuAddress atIndex:0]; [at setAddress:g_nd.wrs atIndex:2]; [at setAddress:cb.gpuAddress + co atIndex:3];
    if (into) g_nd.game_rs = out;
    [at setTexture:pic.gpuResourceID atIndex:0]; [at setTexture:dith.gpuResourceID atIndex:1]; [at setTexture:(into ? into : out).gpuResourceID atIndex:2];
    [ce dispatchThreadgroups:MTLSizeMake(80, 180, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
    [ce barrierAfterStages:MTLStageDispatch beforeQueueStages:MTLStageAll visibilityOptions:resource_vis()];
    enc_c_end(ce);
    args_dirty_all();
    return 1;
}
// DM_NDVE_ENGINE=check: an image of the engine's own like the game's, made once
static id<MTLTexture> ndve_shadow(id<MTLTexture> like) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:like.pixelFormat width:like.width height:like.height mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; res_add(t); return t;
}
// DM_NDVE_ENGINE=check: the game's image a against the engine's b, into counters slot (0 network, 1 resampler); every 300 frames the totals so far
static void ndve_compare(id<MTLTexture> a, id<MTLTexture> b, int slot) {
    if (!g_nd.cnt) { g_nd.cnt = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(g_nd.cnt.contents, 0, 16); res_add(g_nd.cnt); }
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    id<MTL4ComputeCommandEncoder> ce = enc_c_begin();
    id<MTL4ArgumentTable> at = g_nd.at; [ce setArgumentTable:at];
    [ce setComputePipelineState:g_nd.ps[NK_CMP]]; [at setTexture:a.gpuResourceID atIndex:0]; [at setTexture:b.gpuResourceID atIndex:1]; [at setAddress:g_nd.cnt.gpuAddress + 8 * slot atIndex:1];
    [ce dispatchThreadgroups:MTLSizeMake((a.width + 15) / 16, (a.height + 15) / 16, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [ce barrierAfterStages:MTLStageDispatch beforeQueueStages:MTLStageAll visibilityOptions:resource_vis()];
    enc_c_end(ce);
    args_dirty_all();
    uint64_t *n = slot ? &g_nd.chk_rs : &g_nd.chk_net;
    if (++*n % 300 == 0) {
        const uint32_t *c = (const uint32_t *)g_nd.cnt.contents;
        MLOG("%sNDVE engine check, %s, %llu frames compared: %u texels of the engine's %lux%lu differ from the game's (largest difference %u/1023)", c[2 * slot] ? "[RED] " : "",
             slot ? "resampler" : "network", (unsigned long long)*n, c[2 * slot], (unsigned long)a.width, (unsigned long)a.height, c[2 * slot + 1]);
    }
}
// DM_NDVE_ENGINE=mfx (the iPhone's default): the movie frame without its network. The U-Net's 11 dispatches and its last convolution 5a7d69b0 are skipped as with the host's
// network (the same recognition), nothing is computed there, and at the resampler 4f41ccf2 MetalFX's spatial scaler writes the game's 2560x1440 RGBA8 output (or a 2048x1152
// one, k_ndve_cv) from the colour conversion's 1920x1080 RGBA8 picture (the one the network's first layer reads and its last adds to): about 15.7 billion multiply-adds a frame less (the U-Net's 10.6,
// the resampler's 5.1). The approach is MacNativeGames' (games/oot, github.com/ly05010419/MacNativeGames, MIT: dm/third_party/macnativegames/LICENSE), which measured 29 ->
// 1.3-1.7 ms of GPU a movie frame on an M4; written here on NX 18's recognition, none of their code. What is lost: the network's learned clean-up of the AV1 picture and the
// resampler's learned detail; on a phone the 2560x1440 canvas is scaled down to the screen's ~1320 lines anyway.
// Perceptual mode: the picture is video colour, gamma-encoded in 0-1 (RGBA8Unorm with no sRGB decode), and the output stays in that encoding, as the resampler writes it.
// The resampler's dither is dropped: it rounds the network's 10-bit picture (RGB10A2) plus its delta to 8 bits, so its noise hides the steps of that rounding. Here the input
// is the 8-bit picture itself and MetalFX writes 8 bits from 8 bits, so there are no such steps to hide; the dither would cost a pass of its own (a read and a write of the
// 2560x1440 canvas) for added noise only.
// Each side is the game's texture when MetalFX can take it (its usage, a private output; an output view of the game's own is taken, as up_mfx_encode does), else MetalFX's own
// texture in the same format and a copy: the picture copied in before, the output copied out after (whole textures, same format: a plain copy). A resampler that flips its rows
// (c4.w on, c4.z = 1439) gets the picture flipped into MetalFX's input (flip_rows), as a scale of the flipped picture is the flipped scale. Order: everything before (the colour
// conversion) lands, the input copy if any, then mfx_order (a real copy behind a queue barrier: MetalFX's own encoders take no barrier), the scaler, the output copy behind a
// queue barrier of its own, and the relaxed end cleared, so the game's next pass or dispatch (which open with queue barriers) reads the finished canvas.
// 1 when the output is written; 0 with nothing encoded (every refusal comes before the first encoder)
static id<MTLTexture> ndve_mfx_tex(MTLTextureUsage usage, NSUInteger w, NSUInteger h, NSString *label) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = usage;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
    if (!t) return nil;
    t.label = label; res_add(t); res_commit(); return t;
}
static const char *g_ndve_mfx_why;   // why the last ndve_mfx_scale drew nothing
static int g_ndve_mfx_own;   // t_ndve_mfx: both sides through MetalFX's own textures and the copies, as for a game texture MetalFX cannot take
static int ndve_mfx_scale(id<MTLTexture> pic, id<MTLTexture> out, int flip, int *sides) {
    const int cv = out ? ndve_cv_slot(out.width, out.height) : -1;
    g_ndve_mfx_why = "the picture or the canvas is not the model's 1920x1080 RGBA8 / 2560x1440 (or 2048x1152) RGBA8";
    if (cv < 0 || !pic || pic.width != 1920 || pic.height != 1080 || pic.pixelFormat != MTLPixelFormatRGBA8Unorm ||
        out.pixelFormat != MTLPixelFormatRGBA8Unorm || pic.textureType != MTLTextureType2D || out.textureType != MTLTextureType2D || pic.sampleCount != 1 || out.sampleCount != 1) return 0;
    id<MTL4FXSpatialScaler> sc = g_nd.mfx[cv];
    const NSUInteger ow = (NSUInteger)k_ndve_cv[cv][0], oh = (NSUInteger)k_ndve_cv[cv][1];
    g_ndve_mfx_why = cv ? "no scaler for a 2048x1152 canvas" : "no scaler";
    if (!sc || g_nd.mfx_state != 2) return 0;
    const int sin = !g_ndve_mfx_own && !flip && (pic.usage & sc.colorTextureUsage) == sc.colorTextureUsage;
    const int sout = !g_ndve_mfx_own && (out.usage & sc.outputTextureUsage) == sc.outputTextureUsage && out.storageMode == MTLStorageModePrivate;
    g_ndve_mfx_why = "MetalFX's own input or output texture could not be made";
    if (!sin && !g_nd.mfx_in && !(g_nd.mfx_in = ndve_mfx_tex(sc.colorTextureUsage | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, 1920, 1080, @"NDVE MetalFX input"))) return 0;
    if (!sout && !g_nd.mfx_out[cv] && !(g_nd.mfx_out[cv] = ndve_mfx_tex(sc.outputTextureUsage | MTLTextureUsageShaderRead, ow, oh, @"NDVE MetalFX output"))) return 0;
    id<MTLTexture> color = sin ? pic : g_nd.mfx_in, result = sout ? out : g_nd.mfx_out[cv];
    sc_forget(out);   // the scaler or the copy writes the game's canvas (nvn_mtl.m sc_note)
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    ubd_land_compute();
    if (!sin) {   // the picture into MetalFX's input, after the colour conversion (enc_c_begin's queue barrier)
        id<MTL4ComputeCommandEncoder> ce = enc_c_begin();
        if (flip) {
            id<MTL4ArgumentTable> at = g_nd.at; [ce setArgumentTable:at];
            [ce setComputePipelineState:g_nd.ps[NK_FLIP]]; [at setTexture:pic.gpuResourceID atIndex:0]; [at setTexture:color.gpuResourceID atIndex:1];
            [ce dispatchThreadgroups:MTLSizeMake(1920 / 32, (1080 + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(32, 8, 1)];
        } else enc_b_copy_texture(ce, pic, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(1920, 1080, 1), color, 0, 0, MTLOriginMake(0, 0, 0));
        [ce barrierAfterStages:MTLStageDispatch | MTLStageBlit beforeQueueStages:MTLStageAll visibilityOptions:resource_vis()];
        enc_c_end(ce);
    }
    mfx_order();   // the scaler after the frame's work so far (MetalFX opens encoders of its own, which take no barrier)
    rec_cb_block(g_cb, ^(id<MTL4CommandBuffer> cb) {   // the real command buffer, on the encoding thread when it runs
        sc.colorTexture = color; sc.outputTexture = result; sc.inputContentWidth = 1920; sc.inputContentHeight = 1080;
        [sc encodeToCommandBuffer:cb];
    });
    atomic_store_explicit(&g_last_end_relaxed, 0, memory_order_relaxed);   // the next draw pass waits for the scaler whole (enc_r_begin_pass)
    if (!sout) {   // MetalFX's output into the game's canvas: enc_c_begin's queue barrier waits for the scaler's encoders
        id<MTL4ComputeCommandEncoder> ce = enc_c_begin();
        enc_b_copy_texture(ce, result, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(ow, oh, 1), out, 0, 0, MTLOriginMake(0, 0, 0));
        [ce barrierAfterStages:MTLStageBlit beforeQueueStages:MTLStageAll visibilityOptions:resource_vis()];
        enc_c_end(ce);
    }
    args_dirty_all();
    if (sides) *sides = sin | sout << 1;
    return 1;
}
// MetalFX off for the rest of the run (the host's network from then on), with one red line; under DM_NDVE_ENGINE=ab the [ab] lines still name the switch in its on phases
static void ndve_mfx_off(const char *why) {
    g_nd.mfx_state = -1;
    MLOG("[RED] NDVE engine: MetalFX cannot scale the movie (%s); the host's network runs it from now on%s", why,
         ndve_sel() == NDVE_AB ? ". DM_NDVE_ENGINE=ab: the [ab] phases that name NDVE_ENGINE run the host's network too from here, so the A/B is void from this phase on" : "");
}
// The texture serial of descriptor tid (0 for none)
static uint64_t ndve_ser(int tid) { uint64_t s = 0; rmu_lock(); if (tid > 0 && tid < g_ntreg && g_treg[tid].ok) s = g_treg[tid].t.serial; os_unfair_lock_unlock(&g_rmu); return s; }
// Whether a dispatch binds the texture of serial ser, as a texture or an image
static int ndve_binds(NvShader *cs, uint64_t ser) {
    for (int i = 0; ser && i < cs->rf.nb; i++) {
        const nvn_rbind *b = &cs->rf.b[i]; if (b->kind != NVN_RB_TEX && b->kind != NVN_RB_IMG) continue;
        int tid = b->kind == NVN_RB_TEX ? (int)(tex_slot_h(S.tex[5], S.img[5], b->reg) & 0xfffff) : b->reg < 32 ? (int)(S.img[5][b->reg] & 0xfffff) : 0;
        if (ndve_ser(tid) == ser) return 1;
    }
    return 0;
}
// A MetalFX frame waits at the resampler with the network's image unwritten (pos 13, seq_mfx): when another compute dispatch comes first (the next frame's colour
// conversion, a network dispatch, or any dispatch that binds that image), the network the frame skipped is encoded into it before that dispatch, so whatever reads the
// image reads the frame, and MetalFX is off from then on. (A draw or a copy that reads the image before the resampler is not seen here.)
static void ndve_mfx_settle(NvShader *cs, int i) {
    if (!g_nd.seq_mfx || g_nd.pos != 13 || i == NDVE_N - 1 || (i < 0 && !ndve_binds(cs, g_nd.m_net_ser))) return;
    char why[200]; snprintf(why, sizeof why, "%s (%s) came before the resampler 4f41ccf2", i == 0 ? "the next frame's colour conversion" : i > 0 ? "a network dispatch" : "a dispatch that reads the network's image", cs->key);
    ndve_mfx_off(why);
    if (!ndve_encode(g_nd.m_pic, g_nd.m_net, g_nd.m_wgpu)) MLOG("[RED] NDVE engine: and the network could not run for that frame (its movie picture is not updated)");
    g_nd.seq_mfx = 0; g_nd.m_pic = g_nd.m_net = nil; g_nd.m_net_ser = 0;   // pos stays 13: a resampler after this reads the image written now
}
// The network layer a dispatch is while the engine is on, else -1: dispatch asks for such a dispatch's pipeline only after ndve_engine_dispatch lets the game's run (NXNative 9df3c09fc)
static int ndve_dispatch_index(NvShader *cs) { return ndve_sel() == NDVE_GAME || g_nd.off ? -1 : ndve_index(cs, 0); }
// 1 when the dispatch was taken (skipped or replaced by the engine), 0 to run it
static int ndve_engine_dispatch(NvShader *cs, const p_dispatch *dp) {
    const int chk = ndve_check();
    if (ndve_sel() == NDVE_GAME || g_nd.off) return 0;
    int i = ndve_index(cs, 0);
    if (g_nd.seq_mfx) ndve_mfx_settle(cs, i);
    if (i < 0) return 0;
    if (g_nd.state == 0) ndve_build();
    if (i == 0) {   // the colour conversion runs; a new frame's sequence may start. Under check, the game's resampled picture of the last frame is there now
        if (chk && g_nd.game_rs && g_nd.state == 2) ndve_compare(g_nd.game_rs, g_nd.shadow_rs, 1);
        g_nd.game_rs = nil; g_nd.pos = 0; g_nd.seq_mfx = 0; g_nd.m_pic = g_nd.m_net = nil; g_nd.m_net_ser = 0; return 0;
    }
    if (i == NDVE_N - 1) {   // the resampler: by MetalFX or the engine right after the skipped network, else the game's
        int take = g_nd.pos == 13, mfx = g_nd.seq_mfx;
        g_nd.pos = 0; g_nd.seq_mfx = 0;
        if (!take) return 0;
        if (mfx) {   // DM_NDVE_ENGINE=mfx: MetalFX from the picture into the resampler's canvas (ndve_mfx_scale)
            id<MTLTexture> pic = g_nd.m_pic, net = g_nd.m_net, rpic = nil, dith = nil, out = nil; g_nd.m_pic = g_nd.m_net = nil; g_nd.m_net_ser = 0;
            const int32_t *c = (const int32_t *)S.push[1];
            const int bound = ndve_rs_bound(cs, 1, &rpic, &dith, &out), flip = c[19] != 0, rows = !flip || (bound && c[18] == (int32_t)out.height - 1);
            int sides = 0;
            if (bound && rows && ndve_mfx_scale(pic, out, flip, &sides)) {
                g_nd.mfx_sides = sides;
                if (!g_nd.mfx_frames++)
                    MLOG("NDVE engine: first movie frame scaled by MetalFX (spatial, perceptual): the colour conversion's %lux%lu RGBA8 picture -> the game's %lux%lu RGBA8 canvas, the network's 12 dispatches "
                         "and the resampler skipped (input %s, output %s%s; no dither). DM_NDVE_ENGINE=1 in env.txt brings the host's network back, =0 the game's",
                         (unsigned long)pic.width, (unsigned long)pic.height, (unsigned long)out.width, (unsigned long)out.height, sides & 1 ? "straight" : flip ? "flipped into MetalFX's own" : "copied into MetalFX's own",
                         sides & 2 ? "straight" : "copied from MetalFX's own", flip ? ", rows flipped as the resampler's constants ask" : "");
                return 1;
            }
            // MetalFX cannot draw it: the network this frame skipped, into the image the resampler reads, then the host's resampler (else the game's) as below; the host's network from now on
            ndve_mfx_off(!bound ? "the resampler's bindings or constants are not the model's" : !rows ? "the resampler flips its rows about another line" : g_ndve_mfx_why);
            if (!ndve_encode(pic, net, g_nd.m_wgpu)) { MLOG("[RED] NDVE engine: and the network could not run for that frame (its movie picture is not updated)"); return 1; }
        }
        if (chk && g_nd.game_out) { ndve_compare(g_nd.game_out, g_nd.shadow, 0); g_nd.game_out = nil; }   // the game's network has run: its image against the engine's
        const p_bind_buf *w = &S.ssbo[5][2]; void *wb = NULL; uint64_t wo = 0;
        if (!w->addr || w->size < 0x3000 || !mtl_gpu_addr(w->addr, 0x3000, &wb, &wo, &g_nd.wrs)) { static int once; if (!once++) MLOG("NDVE engine: the resampler's weights are not bound; the game's resampler runs"); return 0; }
        if (chk && !g_nd.shadow_rs) { id<MTLTexture> o = ndve_tex(cs, NVN_RB_IMG, 1); if (o) g_nd.shadow_rs = ndve_shadow(o); }
        if (!ndve_resample(cs, chk ? g_nd.shadow_rs : nil)) return 0;
        if (!g_nd.rs_frames++) MLOG("NDVE engine: first movie frame resampled by the engine");
        return !chk;
    }
    // dispatch i of the sequence: the keys repeat (a8b4, e6be, 0a56 twice), so position decides
    if (g_nd.pos == 0) {   // a sequence starts: MetalFX or the host's network for all of it (an A/B phase changes only between sequences)
        if (i != 1 || g_nd.state != 2) return 0;
        g_nd.seq_mfx = !chk && ndve_kind() == NDVE_MFX && g_nd.mfx_state == 2;
    }
    else if (ndve_index(cs, g_nd.pos) != g_nd.pos) return ndve_fail(cs, "a dispatch out of the network's order");
    const int p = g_nd.pos ? g_nd.pos : 1;
    const p_bind_buf *w = &S.ssbo[5][2], *b = &S.ssbo[5][3];
    if (p == 1) {   // the first layer: its weights place the others, its picture is the engine's input
        if (!ndve_tex_id(cs, NVN_RB_TEX, 1, &g_nd.pic)) return ndve_fail(cs, "the first layer reads no picture");
        g_nd.w0 = w->addr;
    }
    if (w->addr != g_nd.w0 + g_ndve_w[p] || b->addr != g_nd.w0 + g_ndve_b[p] || !w->size || !b->size) return ndve_fail(cs, "weights or biases not where the model's layers put them");
    if (p < 12) { g_nd.pos = p + 1; g_nd.skipped += !chk && !g_nd.seq_mfx; return !chk; }   // skipped: the host's network's only (its first-frame line)
    // 5a7d69b0: the whole network now
    int rgba_id = 0, out_id = 0;
    id<MTLTexture> rgba = ndve_tex_id(cs, NVN_RB_TEX, 4, &rgba_id), out = ndve_tex_id(cs, NVN_RB_IMG, 0, &out_id);
    void *wb = NULL; uint64_t wo = 0, wgpu = 0;
    if (!rgba || !out || rgba.width != 1920 || rgba.height != 1080 || out.width != 1920 || out.height != 1080 || rgba.pixelFormat != MTLPixelFormatRGBA8Unorm ||
        out.pixelFormat != MTLPixelFormatRGB10A2Unorm || rgba.textureType != MTLTextureType2D || out.textureType != MTLTextureType2D)
        return ndve_fail(cs, "the picture or the image is not the model's 1920x1080 RGBA8 / RGB10A2 pair");
    if (rgba_id != g_nd.pic) return ndve_fail(cs, "the picture added to the network's output is not the one its first layer read");
    if (!mtl_gpu_addr(g_nd.w0, NDVE_WBYTES, &wb, &wo, &wgpu)) return ndve_fail(cs, "the weight table is in no memory pool");
    if (g_nd.seq_mfx) { g_nd.m_pic = rgba; g_nd.m_net = out; g_nd.m_net_ser = ndve_ser(out_id); g_nd.m_wgpu = wgpu; g_nd.pos = 13; return 1; }   // nothing here: MetalFX at the resampler (or ndve_mfx_settle)
    if (chk && !g_nd.shadow) g_nd.shadow = ndve_shadow(out);
    if (!ndve_encode(rgba, chk ? g_nd.shadow : out, wgpu)) return ndve_fail(cs, "the host's network's tensors could not be made");
    if (chk) g_nd.game_out = out;   // compared once the game's 5a7d69b0 has written it, at 4f41ccf2
    g_nd.pos = 13;   // the resampler next
    if (!g_nd.frames++) MLOG("NDVE engine: first movie frame by the engine (%llu dispatches skipped)", (unsigned long long)g_nd.skipped);
    (void)dp; return !chk;
}
