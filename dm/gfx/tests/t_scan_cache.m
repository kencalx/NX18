// DM_NVN_FB_SCAN_CACHE (upstream NXNative 63611f3e4, slice 3 of PR #3344, NX 18's subset): same-pass feedback keeps the last negative finding of fb_prepare's walk and each
// shader's of fb_depth_rule. A kept finding answers only while the shader, its slots (g_args_gen[1]), the IDs' textures (g_fbc_gen), the sparse mappings and the targets are
// those it was found for: a slot bound through state_op, a registration of the bound ID (as the target, then gone), another target, state_reset, a queue switch and a sparse
// mapping each make the next draw walk again, and it then finds the target. Negative control: the stamps put back by hand after a registration make the kept finding answer, and
// the walk misses the target the slot names now
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static void target(tex_t *t, uint64_t serial, int format) {
    *t = (tex_t){.magic = MAGIC('T','E','X',0), .serial = serial};
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = 4, .height = 4, .depth = 1, .levels = 1, .samples = 1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> x = [g_dev newTextureWithDescriptor:d]; CHECK(x != nil, "texture made"); res_add(x); mtl_tex_init(t); serial_put(serial, x);
}
static void bind_slot0(uint32_t tid) {   // through state_op, as a recorded BindTexture
    p_bind_handles h = {0}; h.stage = 1; h.first = 0; h.n = 1; h.h[0] = tid; state_op(OP_BIND_TEX, &h);
}
int main(void) { @autoreleasepool {
    alarm(60); setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_MANIFEST", "off", 1);
    mtl_init();
    tex_t col, dep, other, col2; target(&col, 88001, NVN_FORMAT_RGBA8); target(&dep, 88002, NVN_FORMAT_DEPTH32F); target(&other, 88003, NVN_FORMAT_RGBA8); target(&col2, 88004, NVN_FORMAT_RGBA8);
    mtl_reg_tex(11, &other, NULL);   // the bound ID: another texture, no target
    NvProg *pr = [NvProg new]; NvShader *fs = [NvShader new]; strcpy(fs->key, "5ca9cac4e0000001"); fs->stage = 1;
    fs->rf.nb = 1; fs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .reg = 0, .aid = 0, .dtt = MTLTextureType2D}; pr->sh[1] = fs;
    state_reset(); memset(&R, 0, sizeof R); bind_slot0(11);
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &col; R.rt.depth = &dep;
    // 1. The first draw walks and keeps a finding of nothing; the second is answered by it (fb_prepare's walk and the depth rule)
    uint64_t h0 = g_fbsc_hits[0], h1 = g_fbsc_hits[1];
    fb_prepare(pr); CHECK(g_fb_n == 0 && g_fbsc.fs == (__bridge const void *)fs && fs->fbd_dser == dep.serial, "the first draw keeps a finding of nothing");
    fb_prepare(pr); CHECK(g_fbsc_hits[1] == h1 + 1 && g_fbsc_hits[0] == h0 + 1, "the second draw is answered by the kept findings");
    // 2. Each change makes the next draw walk again
    #define MOVES_(what, change, depth_too) do { fb_prepare(pr); uint64_t a0 = g_fbsc_hits[0], a1 = g_fbsc_hits[1]; change; fb_prepare(pr); CHECK(g_fbsc_hits[1] == a1 && (!(depth_too) || g_fbsc_hits[0] == a0), what); } while (0)
    #define MOVES(what, change) MOVES_(what, change, 1)
    MOVES("a slot bound through state_op", bind_slot0(12));
    bind_slot0(11);
    { fb_prepare(pr); uint64_t a1 = g_fbsc_hits[1]; bind_slot0(11); fb_prepare(pr); CHECK(g_fbsc_hits[1] == a1 + 1, "the same handle bound again moves nothing: still answered"); }
    MOVES("a registration of another ID", mtl_reg_tex(12, &other, NULL));
    MOVES_("another colour target (the depth rule's finding is about the depth target alone)", R.rt.color[0] = &col2, 0);
    MOVES("another depth target", R.rt.depth = &col2);
    R.rt.depth = &dep;
    R.rt.color[0] = &col;
    MOVES("a sparse mapping generation other than the kept one", (g_fbsc.vg ^= 1, fs->fbd_vg ^= 1));   // (the mapping requests themselves are hle_nvn.c's: the key is checked)
    MOVES("state_reset", (state_reset(), bind_slot0(11)));
    MOVES("a queue switch", (mtl_queue_activate(4242), bind_slot0(11), R.has_rt = 1, R.rt.n = 1, R.rt.color[0] = &col, R.rt.depth = &dep));
    // 3. The bound ID registered as the colour target: the walk finds it (feedback), and as the depth target, the depth rule does
    fb_prepare(pr); fb_prepare(pr);
    mtl_reg_tex(11, &col, NULL); g_fb_rmask = 0;
    fb_prepare(pr); int colour_found = g_fb_n > 0 || g_fb_rmask != 0;
    CHECK(colour_found && g_fbsc.fs == NULL, "the ID registered as the colour target: the walk finds it and keeps nothing");
    rp_end(); g_fb_rmask = 0; g_fb_dread = 0;
    mtl_reg_tex(11, &other, NULL); fb_prepare(pr); fb_prepare(pr);
    mtl_reg_tex(11, &dep, NULL); g_fb_dread = 0; fb_prepare(pr);
    CHECK(fs->fbd_dser == 0 && g_fb_dread != 0, "the ID registered as the depth target: the depth rule finds it");
    rp_end(); g_fb_dread = 0; g_fb_rmask = 0;
    // 4. Negative control: back to a finding of nothing, then the ID registered as the colour target with the stamps put back as a missing generation would leave them
    mtl_reg_tex(11, &other, NULL); fb_prepare(pr); fb_prepare(pr);
    uint64_t keep_fgen = g_fbsc.fgen; mtl_reg_tex(11, &col, NULL); g_fbsc.fgen = fbc_gen_load(); (void)keep_fgen;
    uint64_t c1 = g_fbsc_hits[1]; g_fb_rmask = 0; fb_prepare(pr);
    CHECK(g_fbsc_hits[1] == c1 + 1 && g_fb_n == 0 && g_fb_rmask == 0, "negative control: a kept finding with its stamp put back misses the target the slot names now");
    rp_end(); g_fb_rmask = 0;
    // 4b. Another object over the colour target's storage (fb_att_is's storage test): whether it is the attachment depends on the host textures' roots, which change without a
    // registration (serial_put: a host texture made again for the serial, no g_fbc_gen move). A walk that reached that test keeps nothing, so the draw after the host change finds
    // the attachment. Negative control: a finding kept by hand answers that draw and misses it
    {   static pool_t apool; tex_t asrc, aoth; target(&asrc, 88010, NVN_FORMAT_RGBA8); asrc.pool = &apool; asrc.off = 0x10000;
        aoth = asrc; aoth.serial = 88011; mtl_tex_init(&aoth);
        uint64_t ak = asrc.serial; id att = hm_get_id(&g_by_serial, &ak);
        MTLTextureDescriptor *d = tex_desc(&aoth, 0); d.storageMode = MTLStorageModePrivate; id<MTLTexture> sep = [g_dev newTextureWithDescriptor:d]; res_add(sep);
        serial_put(aoth.serial, sep); mtl_reg_tex(13, &aoth, NULL);
        state_reset(); memset(&R, 0, sizeof R); bind_slot0(13); R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &asrc; g_fb_rmask = 0; g_fbsc.fs = NULL;
        fb_prepare(pr); CHECK(g_fb_n == 0 && g_fb_rmask == 0, "storage alias: a separate host texture over the target's storage is not the attachment");
        serial_put(aoth.serial, att);   // the serial's host texture is the attachment's now
        uint64_t a1 = g_fbsc_hits[1]; fb_prepare(pr);
        CHECK(g_fbsc_hits[1] == a1 && (g_fb_n > 0 || g_fb_rmask != 0), "storage alias: the walk that reached the storage test kept nothing, and the draw after the host change finds the attachment");
        rp_end(); g_fb_rmask = 0;
        if (g_fb_rebind) { args_dirty_all_w(AW_FB); g_fb_rebind = 0; }   // as the next fb_prepare starts, so the hand-kept finding is stamped after it
        fbsc_put(fs, fbc_gen_load(), nvn_sparse_gen()); a1 = g_fbsc_hits[1]; fb_prepare(pr);
        CHECK(g_fbsc_hits[1] == a1 + 1 && g_fb_n == 0 && g_fb_rmask == 0, "storage alias negative control: a kept finding answers the draw and misses the attachment");
        rp_end(); g_fb_rmask = 0; g_fbsc.fs = NULL;
        state_reset(); memset(&R, 0, sizeof R); bind_slot0(11); R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &col; R.rt.depth = &dep;
    }
    // 5. Off: nothing kept
    g_fb_scan_cache = 0; mtl_reg_tex(11, &other, NULL); g_fbsc.fs = NULL; uint64_t o0 = g_fbsc_hits[0], o1 = g_fbsc_hits[1];
    fb_prepare(pr); fb_prepare(pr); CHECK(g_fbsc_hits[0] == o0 && g_fbsc_hits[1] == o1 && g_fbsc.fs == NULL, "off: every draw walks");
    g_fb_scan_cache = 1;
    if (getenv("T_SCAN_BENCH")) {
        double best[2] = {1e9, 1e9}; enum { N = 200000 };
        for (int r = 0; r < 5; r++) for (int k = 0; k < 2; k++) { g_fb_scan_cache = !k; g_fbsc.fs = NULL; fs->fbd_dser = 0; uint64_t t0 = bp_now();
            for (int i = 0; i < N; i++) fb_prepare(pr);
            double ns = (double)(bp_now() - t0) / N; if (ns < best[k]) best[k] = ns; }
        g_fb_scan_cache = 1;
        printf("t_scan_cache bench (one texture slot, a colour and a depth target, no pass open): fb_prepare %.1f ns with DM_NVN_FB_SCAN_CACHE=0, %.1f ns on\n", best[1], best[0]);
    }
    printf("t_scan_cache: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
