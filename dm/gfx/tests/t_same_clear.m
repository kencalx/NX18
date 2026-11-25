// A clear-only pass leaves out the attachments that already hold its clear (nvn_mtl.m sc_note / sc_skip_held, DM_NVN_SAME_CLEAR). Donkey Kong Bananza clears a 2880x1620 RGBA8
// target and its D32S8 depth every frame and nothing else touches them. Here a colour target and a D32S8 depth of a GPU-only pool are cleared each "frame" by a clear-only pass
// (the lazy clear lands at the command list's end, lc_land): the second identical clear opens no pass, and every way the textures are read afterwards (a pass that loads the
// colour and draws over half, a texture copy, a copy drawn by sampling, the readback) sees the clear's values. Every kind of write between two identical clears (a draw, a depth
// write, a texture copy into it, a texture clear, a scissored zero clear, a buffer-to-texture copy, a clear to another value, a clear of the stencil alone, the background purge)
// makes the next clear land again. A target of a CPU-visible pool, a view through another format and a level of a mipmapped texture never skip. Each step is run with the switch
// on and off (=0: every clear-only pass opens) and the read-backs must match byte for byte, besides the literal values.
// Clear triangles (DM_NVN_SAME_CLEAR_TRI): Bananza's real pass clears colour and depth whole and the stencil through a write mask of 0x1, a masked clear drawn as a triangle. That shape
// repeated opens no pass once the records hold its results (the stencil record knows only the bits triangles wrote when nothing cleared it whole); a draw, a texture copy and an image
// binding of the target between two of them make the next land, a sampling read does not; another stencil value or mask lands, a partial scissor and a blended draw in the pass are
// never left out. The same steps run a third time with DM_NVN_SAME_CLEAR_TRI=0 (the masked clear drawn at once, as fcdc1fd0): all three read back the same bytes.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

enum { W = 16 };
static pool_t gpool, cpool;   // GPU-only, CPU-visible
static tex_t C, Z, O, D2, S2, V, M;   // colour, depth, the other target, a copy destination, a copy source, a colour of the CPU-visible pool, a mipmapped colour
static tex_t CT;   // the clear-triangle steps' colour: a new texture each run (its image binding makes it shader-writable, which no record takes)
static prog_t green_prog = {.serial = 99611}, depth_prog = {.serial = 99612};
static tex_t target(pool_t *pool, uint64_t serial, int64_t off, NVNformat format, int levels) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .pool = pool, .mem = pool->mem + off, .off = off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = W, .height = W, .depth = 1, .levels = levels, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); mtl_tex_init(&t); return t;
}
static uint8_t ops[8192]; static size_t nops;
static void *op(uint32_t code, size_t size) { op_hdr h = {code, (uint32_t)(sizeof h + size)}; memcpy(ops + nops, &h, sizeof h); void *a = ops + nops + sizeof h; memset(a, 0, size); nops += h.size; return a; }
static p_set_rt rt_of(const tex_t *c, const tex_t *z) { p_set_rt r = {0}; if (c) { r.n = 1; r.color[0] = c; } r.depth = z; return r; }
static void set_rt(p_set_rt r) { *(p_set_rt *)op(OP_SET_RT, sizeof r) = r; }
// A clear-only pass of colour c and depth z (either may be NULL): set the targets, clear, then other targets with no draw (the clears wait, lc_push) and the list's end lands them (lc_land)
static void clear_ops(const tex_t *c, const tex_t *z, float r, float g, float b, float a, float depth, int stencil, int dmask) {
    set_rt(rt_of(c, z));
    if (c) *(p_clear_color *)op(OP_CLEAR_COLOR, sizeof(p_clear_color)) = (p_clear_color){0, 0xf, {r, g, b, a}};
    if (z) *(p_clear_ds *)op(OP_CLEAR_DS, sizeof(p_clear_ds)) = (p_clear_ds){.depth = depth, .depth_mask = dmask, .stencil = stencil, .stencil_mask = 0xff};
    set_rt(rt_of(&O, NULL));
}
// The Donkey Kong Bananza shape: colour and depth cleared whole, the stencil through a write mask (smask), then other targets with no draw: a pass of clears alone. sc: a scissor for the depth-stencil clear
static void tri_ops(const tex_t *c, const tex_t *z, float r, float g, float b, float a, float depth, int stencil, int smask, const p_scissor *sc) {
    set_rt(rt_of(c, z));
    if (c) *(p_clear_color *)op(OP_CLEAR_COLOR, sizeof(p_clear_color)) = (p_clear_color){0, 0xf, {r, g, b, a}};
    if (sc) *(p_scissor *)op(OP_SCISSOR, sizeof *sc) = *sc;
    *(p_clear_ds *)op(OP_CLEAR_DS, sizeof(p_clear_ds)) = (p_clear_ds){.depth = depth, .depth_mask = 1, .stencil = stencil, .stencil_mask = smask};
    if (sc) *(p_scissor *)op(OP_SCISSOR, sizeof *sc) = (p_scissor){0, 0, W, W};
    set_rt(rt_of(&O, NULL));
}
static void draw_ops(const tex_t *c, const tex_t *z, const prog_t *pr, const p_scissor *sc) {
    set_rt(rt_of(c, z));
    if (sc) *(p_scissor *)op(OP_SCISSOR, sizeof *sc) = *sc;
    *(p_bind_program *)op(OP_BIND_PROGRAM, sizeof(p_bind_program)) = (p_bind_program){pr, 3};
    *(p_draw *)op(OP_DRAW, sizeof(p_draw)) = (p_draw){NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3};
    set_rt(rt_of(&O, NULL));
    if (sc) *(p_scissor *)op(OP_SCISSOR, sizeof *sc) = (p_scissor){0, 0, W, W};
}
typedef struct { uint8_t c[W * W * 4], d2[W * W * 4], v[W * W * 4], ct[W * W * 4]; float z[W * W]; uint8_t s[W * W]; uint64_t att, pass, tpass, tbytes; } rb_shot;
// Replays the list built so far (plus extra, run inside the submission after the list), then reads back C, Z (depth and stencil), D2 and V in the same submission
static rb_shot frame(void (^extra)(void)) {
    static uint64_t f; mtl_set_frame(++f);
    op(OP_END, 0);
    mtl_sub_begin();
    mtl_exec(ops); nops = 0;
    if (extra) extra();
    rp_end();
    id<MTLBuffer> b[6]; for (int i = 0; i < 6; i++) { b[i] = [g_dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared]; res_add(b[i]); }
    [blit() copyFromTexture:tex_mtl(&C) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[0] destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [blit() copyFromTexture:tex_mtl(&Z) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[1] destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4 options:MTLBlitOptionDepthFromDepthStencil];
    [blit() copyFromTexture:tex_mtl(&Z) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[2] destinationOffset:0 destinationBytesPerRow:W destinationBytesPerImage:W * W options:MTLBlitOptionStencilFromDepthStencil];
    [blit() copyFromTexture:tex_mtl(&D2) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[3] destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [blit() copyFromTexture:tex_mtl(&V) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[4] destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [blit() copyFromTexture:tex_mtl(&CT) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[5] destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completes");
    mtl_drain();
    CHECK(!mtl_last_commit_error(), "no GPU error");
    rb_shot s; memcpy(s.c, b[0].contents, sizeof s.c); memcpy(s.z, b[1].contents, sizeof s.z); memcpy(s.s, b[2].contents, sizeof s.s); memcpy(s.d2, b[3].contents, sizeof s.d2); memcpy(s.v, b[4].contents, sizeof s.v); memcpy(s.ct, b[5].contents, sizeof s.ct);
    uint64_t bytes; mtl_sc_stats(&s.att, &s.pass, &bytes); mtl_sct_stats(&s.tpass, &s.tbytes);
    return s;
}
static int all_rgba(const uint8_t *p, int x0, int x1, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {   // every pixel with x0 <= x < x1
    for (int y = 0; y < W; y++) for (int x = x0; x < x1; x++) { const uint8_t *q = p + (y * W + x) * 4; if (q[0] != r || q[1] != g || q[2] != b || q[3] != a) return 0; }
    return 1;
}
static int all_depth(const rb_shot *s, float z, uint8_t st) { for (int i = 0; i < W * W; i++) if (s->z[i] != z || s->s[i] != st) return 0; return 1; }
static NvProg *g_img_prog;   // a program whose fragment stage writes image slot 0 (image_prepare)
enum { TID_CT = 7 };   // CT's texture ID

// The whole sequence; each step's read-back goes to out[step]. Returns the number of steps
enum { STEPS = 96 };
static void fill(const tex_t *t, MTLClearColor cc) {   // a fixed content outside the replay, so both runs start alike
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new]; p.colorAttachments[0].texture = tex_mtl(t); p.colorAttachments[0].loadAction = MTLLoadActionClear;
    p.colorAttachments[0].storeAction = MTLStoreActionStore; p.colorAttachments[0].clearColor = cc;
    mtl_sub_begin(); enc_r_end(enc_r_begin(p)); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the fill completes"); mtl_drain();
}
static int run(int on, int tri, rb_shot *out) {
    g_sc_on = on; g_sct_on = tri; sc_forget_all();
    static int runs; CT = target(&gpool, 99620 + (uint64_t)runs, (6 << 20) + (int64_t)runs * 65536, NVN_FORMAT_RGBA8, 1); runs++;
    fill(&CT, MTLClearColorMake(0, 0, 0, 0));
    fill(&D2, MTLClearColorMake(0, 0, 0, 0)); fill(&V, MTLClearColorMake(0, 0, 0, 0));
    int n = 0;
    #define STEP(...) (out[n] = frame(__VA_ARGS__), &out[n++])
    rb_shot *s, *p;
    // 0, 1: the first clear opens its pass and leaves a record; the second identical one opens none
    clear_ops(&C, &Z, 1, 0, 0, 1, .25f, 0x5a, 1); s = STEP(nil);
    CHECK(all_rgba(s->c, 0, W, 255, 0, 0, 255) && all_depth(s, .25f, 0x5a), "the first clear lands");
    clear_ops(&C, &Z, 1, 0, 0, 1, .25f, 0x5a, 1); p = s; s = STEP(nil);
    CHECK(all_rgba(s->c, 0, W, 255, 0, 0, 255) && all_depth(s, .25f, 0x5a), "the repeated clear: the textures still hold it");
    if (on) CHECK(s->pass == p->pass + 1 && s->att == p->att + 3, "the repeated clear opens no pass (colour, depth and stencil left out)");
    else CHECK(s->pass == p->pass && s->att == p->att, "with DM_NVN_SAME_CLEAR=0 it opens its pass");
    // 2: read by a pass that loads the colour and draws green over its left half
    clear_ops(&C, &Z, 1, 0, 0, 1, .25f, 0x5a, 1); p = s; s = STEP(nil);
    if (on) CHECK(s->pass == p->pass + 1, "skipped again");
    p_scissor half = {0, 0, W / 2, W};
    draw_ops(&C, NULL, &green_prog, &half); p = s; s = STEP(nil);
    CHECK(all_rgba(s->c, 0, W / 2, 0, 255, 0, 255) && all_rgba(s->c, W / 2, W, 255, 0, 0, 255), "a pass that loads the target sees the clear beside its own draw");
    // the draw wrote it: the same clear lands again
    clear_ops(&C, &Z, 1, 0, 0, 1, .25f, 0x5a, 1); p = s; s = STEP(nil);
    CHECK(all_rgba(s->c, 0, W, 255, 0, 0, 255), "after a draw into the target the clear is back whole");
    if (on) CHECK(s->pass == p->pass && s->att == p->att + 2, "the colour clear lands (a pass), depth and stencil, untouched, are left out");
    // read by a texture copy (into D2) and by a copy drawn by sampling (into V's place: D2 again, scaled)
    clear_ops(&C, &Z, 1, 0, 0, 1, .25f, 0x5a, 1);
    p_copy_t2t cp = {.src = &C, .dst = &D2, .sr = {0, 0, 0, W, W, 1}, .dr = {0, 0, 0, W, W, 1}};
    *(p_copy_t2t *)op(OP_COPY_T2T, sizeof cp) = cp; p = s; s = STEP(nil);
    if (on) CHECK(s->pass == p->pass + 1, "skipped before the copy");
    CHECK(all_rgba(s->d2, 0, W, 255, 0, 0, 255), "a texture copy of the target reads the clear");
    clear_ops(&C, &Z, 1, 0, 0, 1, .25f, 0x5a, 1); p = s;
    s = STEP(^{ NVNcopyRegion sr = {0, 0, 0, W / 2, W / 2, 1}, dr = {0, 0, 0, W, W, 1}; rp_end();
        CHECK(copy_t2t_draw(tex_mtl(&C), tex_mtl(&D2), 0, 0, 0, 0, &sr, &dr, 0, 0), "the sampling copy draws"); });
    if (on) CHECK(s->pass == p->pass + 1, "skipped before the sampling copy");
    CHECK(all_rgba(s->d2, 0, W, 255, 0, 0, 255), "a draw sampling the target reads the clear");
    // writes between two identical clears: each makes the next one land
    struct { const char *what; int kind; } w[] = {{"a texture copy into it", 0}, {"a texture clear", 1}, {"a scissored zero clear", 2}, {"a buffer-to-texture copy", 3},
                                                   {"a draw writing depth", 4}, {"a clear to another colour", 5}, {"the background purge", 6}};
    for (unsigned k = 0; k < sizeof w / sizeof *w; k++) {
        clear_ops(&C, &Z, 1, 0, 0, 1, .25f, 0x5a, 1); p = s; s = STEP(nil);
        if (on) CHECK(s->pass == p->pass + 1, "skipped before the write");
        void (^extra)(void) = nil;
        if (w[k].kind == 0) { p_copy_t2t c2 = {.src = &S2, .dst = &C, .sr = {0, 0, 0, W, W, 1}, .dr = {0, 0, 0, W, W, 1}}; *(p_copy_t2t *)op(OP_COPY_T2T, sizeof c2) = c2; }
        if (w[k].kind == 1) { p_clear_tex ct = {.tex = &C, .r = {0, 0, 0, W, W, 1}, .mask = 0xf}; ct.c.f[1] = 1; ct.c.f[3] = 1; *(p_clear_tex *)op(OP_CLEAR_TEX, sizeof ct) = ct; }
        if (w[k].kind == 2) { set_rt(rt_of(&C, NULL)); *(p_scissor *)op(OP_SCISSOR, sizeof(p_scissor)) = (p_scissor){0, 0, 4, 4}; *(p_clear_color *)op(OP_CLEAR_COLOR, sizeof(p_clear_color)) = (p_clear_color){0, 0xf, {0, 0, 0, 0}};
                              *(p_scissor *)op(OP_SCISSOR, sizeof(p_scissor)) = (p_scissor){0, 0, W, W}; set_rt(rt_of(&O, NULL)); }
        if (w[k].kind == 3) extra = ^{ rp_end(); id<MTLBuffer> zb = [g_dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared]; memset(zb.contents, 0x40, W * W * 4); res_add(zb);
                                       enc_b_copy_buffer_texture(blit(), zb, 0, W * 4, W * W * 4, MTLSizeMake(W, W, 1), tex_mtl(&C), 0, 0, MTLOriginMake(0, 0, 0)); };
        if (w[k].kind == 4) draw_ops(NULL, &Z, &depth_prog, NULL);
        if (w[k].kind == 5) clear_ops(&C, NULL, 0, 0, 1, 1, 0, 0, 0);
        if (w[k].kind == 6) extra = ^{ rp_end(); mtl_bg_purge(1); mtl_bg_purge(0); };
        p = s; s = STEP(extra);
        if (w[k].kind == 0) CHECK(all_rgba(s->c, 0, W, 0, 0, 255, 255), "the copy's source is in the target");
        if (w[k].kind == 1) CHECK(all_rgba(s->c, 0, W, 0, 255, 0, 255), "the texture clear is in the target");
        if (w[k].kind == 2) { int ok = 1; for (int y = 0; y < W; y++) for (int x = 0; x < W; x++) { const uint8_t *q = s->c + (y * W + x) * 4; int in = x < 4 && y < 4;
            ok &= in ? !q[0] && !q[1] && !q[2] && !q[3] : q[0] == 255 && !q[1] && !q[2] && q[3] == 255; }
            CHECK(ok, "the zero clear is in its rectangle of the target"); }
        if (w[k].kind == 3) CHECK(all_rgba(s->c, 0, W, 0x40, 0x40, 0x40, 0x40), "the buffer's bytes are in the target");
        if (w[k].kind == 4) CHECK(all_depth(s, .5f, 0x5a), "the draw's depth is in the depth target");
        if (w[k].kind == 5) CHECK(all_rgba(s->c, 0, W, 0, 0, 255, 255), "the other clear is in the target");
        clear_ops(&C, &Z, 1, 0, 0, 1, .25f, 0x5a, 1); p = s; s = STEP(nil);
        CHECK(all_rgba(s->c, 0, W, 255, 0, 0, 255) && all_depth(s, .25f, 0x5a), w[k].what);
        if (on) { int want = w[k].kind == 4 ? 1 : w[k].kind == 6 ? 0 : 2;   // a colour write: depth and stencil still left out; a depth write: the colour; the purge: none
            CHECK(s->pass == p->pass && s->att == p->att + (uint64_t)want, "after the write the clear lands again"); }
    }
    // the stencil alone, cleared to another value, then the old one: depth stays left out, the stencil lands
    clear_ops(&C, &Z, 1, 0, 0, 1, .25f, 0x5a, 1); p = s; s = STEP(nil);
    clear_ops(NULL, &Z, 0, 0, 0, 0, 0, 0x33, 0); p = s; s = STEP(nil);
    CHECK(all_depth(s, .25f, 0x33), "the stencil clear lands, depth kept");
    clear_ops(&C, &Z, 1, 0, 0, 1, .25f, 0x5a, 1); p = s; s = STEP(nil);
    CHECK(all_rgba(s->c, 0, W, 255, 0, 0, 255) && all_depth(s, .25f, 0x5a), "the stencil is back to its clear");
    if (on) CHECK(s->pass == p->pass && s->att == p->att + 1, "the colour is left out (depth was loaded and stored by the stencil's pass: not known, so cleared)");
    // never left out: a target of a CPU-visible pool, and a mipmapped one
    for (int k = 0; k < 2; k++) { clear_ops(&V, NULL, 0, 1, 1, 1, 0, 0, 0); p = s; s = STEP(nil); }
    CHECK(all_rgba(s->v, 0, W, 0, 255, 255, 255), "the CPU-visible target holds its clear");
    CHECK(s->pass == p->pass && s->att == p->att, "a target of a CPU-visible pool is cleared every time");
    for (int k = 0; k < 2; k++) { clear_ops(&M, NULL, 0, 1, 1, 1, 0, 0, 0); p = s; s = STEP(nil); }
    CHECK(s->pass == p->pass && s->att == p->att, "a mipmapped target is cleared every time");
    // Clear triangles (DM_NVN_SAME_CLEAR_TRI). ts: the triangle passes are left out; tb: the triangle waits for its pass (clear-only), so held colour and depth are left out too
    int ts = on && tri; const p_scissor half_sc = {0, 0, W / 2, W};
    #define SBIT(prev, m, v) (uint8_t)(((prev) & ~(m)) | ((v) & (m)))
    #define ALL_S(sh, val) ({ int ok_ = 1; for (int i_ = 0; i_ < W * W; i_++) ok_ &= (sh)->s[i_] == (val); ok_; })
    draw_ops(NULL, &Z, &depth_prog, NULL); p = s; s = STEP(nil);   // the depth's record is gone: its stencil is not known at all
    uint8_t st0 = s->s[0];
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s; s = STEP(nil);
    CHECK(all_rgba(s->ct, 0, W, 255, 0, 0, 255) && all_depth(s, .25f, SBIT(st0, 1, 1)), "the Bananza shape lands: colour, depth, stencil bit 0 set, the other bits kept");
    CHECK(s->pass == p->pass && s->tpass == p->tpass, "its first pass opens");
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s; s = STEP(nil);
    CHECK(all_rgba(s->ct, 0, W, 255, 0, 0, 255) && all_depth(s, .25f, SBIT(st0, 1, 1)), "the repeated Bananza shape: the textures still hold its results");
    if (ts) CHECK(s->pass == p->pass + 1 && s->tpass == p->tpass + 1 && s->att == p->att + 3 && s->tbytes > p->tbytes, "the repeated Bananza shape opens no pass (colour, depth and the stencil triangle left out)");
    else CHECK(s->pass == p->pass && s->tpass == p->tpass, "without the clear triangles (or the switch) it opens its pass");
    // a sampling read of the colour between two of them: still left out
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s;
    s = STEP(^{ NVNcopyRegion sr = {0, 0, 0, W, W, 1}, dr = {0, 0, 0, W, W, 1}; rp_end(); CHECK(copy_t2t_draw(tex_mtl(&CT), tex_mtl(&D2), 0, 0, 0, 0, &sr, &dr, 0, 0), "the sampling copy draws"); });
    CHECK(all_rgba(s->d2, 0, W, 255, 0, 0, 255), "a draw sampling the target reads the clear");
    if (ts) CHECK(s->tpass == p->tpass + 1, "left out before the sampling read");
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s; s = STEP(nil);
    if (ts) CHECK(s->pass == p->pass + 1 && s->tpass == p->tpass + 1, "a sampling read writes nothing: left out again");
    // a draw into the colour, then a texture copy into it: the colour lands, depth and the stencil triangle are left out
    for (int k = 0; k < 2; k++) {
        if (k == 0) draw_ops(&CT, NULL, &green_prog, &half_sc);
        else { p_copy_t2t c2 = {.src = &S2, .dst = &CT, .sr = {0, 0, 0, W, W, 1}, .dr = {0, 0, 0, W, W, 1}}; *(p_copy_t2t *)op(OP_COPY_T2T, sizeof c2) = c2; }
        p = s; s = STEP(nil);
        CHECK(k ? all_rgba(s->ct, 0, W, 0, 0, 255, 255) : all_rgba(s->ct, 0, W / 2, 0, 255, 0, 255), k ? "the copy is in the colour" : "the draw is in the colour");
        tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s; s = STEP(nil);
        CHECK(all_rgba(s->ct, 0, W, 255, 0, 0, 255) && all_depth(s, .25f, SBIT(st0, 1, 1)), k ? "after a copy into the colour the shape is whole again" : "after a draw into the colour the shape is whole again");
        if (ts) CHECK(s->pass == p->pass && s->tpass == p->tpass && s->att == p->att + 2, "the colour lands in a pass; depth and the stencil triangle are left out");
        tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s; s = STEP(nil);
        if (ts) CHECK(s->pass == p->pass + 1 && s->tpass == p->tpass + 1, "then the whole pass is left out again");
    }
    // a draw writing depth: depth and the stencil land (the triangle's bit only is known again), the colour is left out
    draw_ops(NULL, &Z, &depth_prog, NULL); p = s; s = STEP(nil);
    CHECK(all_depth(s, .5f, SBIT(st0, 1, 1)), "the draw's depth is in the depth target");
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s; s = STEP(nil);
    CHECK(all_depth(s, .25f, SBIT(st0, 1, 1)), "after a depth write the depth clear and the stencil triangle land");
    if (ts) CHECK(s->pass == p->pass && s->att == p->att + 1, "the colour is left out, depth and the stencil land");
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s; s = STEP(nil);
    if (ts) CHECK(s->pass == p->pass + 1 && s->tpass == p->tpass + 1, "left out again");
    // another stencil value: lands; back to 1: lands; repeated: left out
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 0, 1, NULL); p = s; s = STEP(nil);
    CHECK(ALL_S(s, SBIT(st0, 1, 0)), "another stencil value through the same mask lands");
    if (ts) CHECK(s->pass == p->pass && s->att == p->att + 1, "its triangle is drawn with the depth clear (a depth texture's planes land together); the colour is left out");
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s; s = STEP(nil);
    CHECK(ALL_S(s, SBIT(st0, 1, 1)), "the first value again lands");
    if (ts) CHECK(s->pass == p->pass, "its pass opens");
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s; s = STEP(nil);
    if (ts) CHECK(s->pass == p->pass + 1, "repeated: left out");
    // another mask: bit 1 is not known (no whole stencil clear since the depth draw), so it lands; repeated, left out; the first mask's bit is still held
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 3, NULL); p = s; s = STEP(nil);
    CHECK(ALL_S(s, SBIT(st0, 3, 1)), "a wider mask clears its bits");
    if (ts) CHECK(s->pass == p->pass && s->att == p->att + 1, "a mask with bits the record does not know lands, with the depth clear");
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 3, NULL); p = s; s = STEP(nil);
    if (ts) CHECK(s->pass == p->pass + 1 && s->tpass == p->tpass + 1, "the wider mask repeated: left out");
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 1, NULL); p = s; s = STEP(nil);
    CHECK(ALL_S(s, SBIT(st0, 3, 1)), "the narrower mask leaves bit 1 as it was");
    if (ts) CHECK(s->pass == p->pass + 1, "the narrower mask's bit is held: left out");
    // a partial scissor: drawn at once in a draw pass, never left out, and the records of its targets are gone
    for (int k = 0; k < 2; k++) { tri_ops(&CT, &Z, 1, 0, 0, 1, .75f, 2, 2, &half_sc); p = s; s = STEP(nil);
        if (on) CHECK(s->pass == p->pass && s->tpass == p->tpass, "a scissored masked clear opens its pass every time"); }
    { int ok = 1; for (int y = 0; y < W; y++) for (int x = 0; x < W; x++) { int i = y * W + x; ok &= s->z[i] == (x < W / 2 ? .75f : .25f) && s->s[i] == (x < W / 2 ? SBIT(st0, 3, 3) : SBIT(st0, 3, 1)); }
      CHECK(ok, "the scissored clear is in its half"); }
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 3, NULL); p = s; s = STEP(nil);
    CHECK(all_rgba(s->ct, 0, W, 255, 0, 0, 255) && all_depth(s, .25f, SBIT(st0, 3, 1)), "the whole shape again after the scissored one");
    if (ts) CHECK(s->pass == p->pass, "it lands (the scissored pass wrote both targets)");
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 3, NULL); p = s; s = STEP(nil);
    if (ts) CHECK(s->pass == p->pass + 1, "and is left out when repeated");
    // a blended draw in the pass of the clears: never a clear-only pass
    for (int k = 0; k < 2; k++) {
        set_rt(rt_of(&CT, &Z)); *(p_clear_color *)op(OP_CLEAR_COLOR, sizeof(p_clear_color)) = (p_clear_color){0, 0xf, {1, 0, 0, 1}};
        *(p_clear_ds *)op(OP_CLEAR_DS, sizeof(p_clear_ds)) = (p_clear_ds){.depth = .25f, .depth_mask = 1, .stencil = 1, .stencil_mask = 3};
        *(p_bind_program *)op(OP_BIND_PROGRAM, sizeof(p_bind_program)) = (p_bind_program){&green_prog, 3};
        *(p_draw *)op(OP_DRAW, sizeof(p_draw)) = (p_draw){NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3};
        set_rt(rt_of(&O, NULL));
        S.color.blend_en = 1; S.blend[0].dst_rgb = NVN_BLEND_FUNC_ONE; S.blend[0].dst_a = NVN_BLEND_FUNC_ONE; S.ds.dw = 0; g_pso_dirty = g_dss_dirty = 1;
        p = s; s = STEP(nil);
        S.color.blend_en = 0; S.blend[0].dst_rgb = NVN_BLEND_FUNC_ZERO; S.blend[0].dst_a = NVN_BLEND_FUNC_ZERO; S.ds.dw = 1; g_pso_dirty = g_dss_dirty = 1;
        CHECK(all_rgba(s->ct, 0, W, 255, 255, 0, 255) && all_depth(s, .25f, SBIT(st0, 3, 1)), "the blended draw adds to the clear");
        if (on) CHECK(s->pass == p->pass && s->tpass == p->tpass, "a pass with a blended draw opens every time");
    }
    // an image binding of the colour: it lands (the texture becomes shader-writable, which no record takes)
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 3, NULL); p = s; s = STEP(nil);
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 3, NULL); p = s; s = STEP(nil);
    if (ts) CHECK(s->pass == p->pass + 1, "left out before the image binding");
    mtl_reg_tex(TID_CT, &CT, NULL); S.img[1][0] = TID_CT; p = s; s = STEP(^{ rp_end(); image_prepare(g_img_prog, 2); });
    S.img[1][0] = 0;
    tri_ops(&CT, &Z, 1, 0, 0, 1, .25f, 1, 3, NULL); p = s; s = STEP(nil);
    CHECK(all_rgba(s->ct, 0, W, 255, 0, 0, 255) && all_depth(s, .25f, SBIT(st0, 3, 1)), "after the image binding the shape is whole");
    if (ts) CHECK(s->pass == p->pass && s->att == p->att + 2, "the colour lands; depth and the stencil triangle are left out");
    #undef SBIT
    #undef ALL_S
    #undef STEP
    return n;
}

int main(void) { @autoreleasepool {
    mtl_init();
    void *gm = NULL, *cm = NULL; posix_memalign(&gm, 16384, 8 << 20); memset(gm, 0, 8 << 20); posix_memalign(&cm, 16384, 1 << 20); memset(cm, 0, 1 << 20);
    gpool = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE, .mem = gm, .size = 8 << 20};
    cpool = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = cm, .size = 1 << 20};
    C = target(&gpool, 99601, 0, NVN_FORMAT_RGBA8, 1); Z = target(&gpool, 99602, 1 << 20, NVN_FORMAT_DEPTH32F_STENCIL8, 1); O = target(&gpool, 99603, 2 << 20, NVN_FORMAT_RGBA8, 1);
    D2 = target(&gpool, 99604, 3 << 20, NVN_FORMAT_RGBA8, 1); S2 = target(&gpool, 99605, 4 << 20, NVN_FORMAT_RGBA8, 1); M = target(&gpool, 99607, 5 << 20, NVN_FORMAT_RGBA8, 2);
    V = target(&cpool, 99606, 0, NVN_FORMAT_RGBA8, 1);
    id<MTLTexture> tc = tex_mtl(&C), tz = tex_mtl(&Z);
    CHECK(tc && tz && sc_eligible(&C, sc_root(tc)) && sc_eligible(&Z, sc_root(tz)), "the GPU-only targets can take a record");
    CHECK(!sc_eligible(&V, sc_root(tex_mtl(&V))) && !sc_eligible(&M, sc_root(tex_mtl(&M))), "the CPU-visible and the mipmapped target cannot");
    fill(&S2, MTLClearColorMake(0, 0, 1, 1));   // the copy source: blue
    NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal; vertex float4 v(uint n [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[n], .5, 1); }\n"
                                "fragment float4 g() { return float4(0, 1, 0, 1); } fragment void none() {}", nil, &error);
    CHECK(lib != nil, "the test shaders compile"); if (!lib) return 1;
    NvProg *gp = [NvProg new]; gp->sh[0] = [NvShader new]; gp->sh[1] = [NvShader new]; gp->sh[0]->fn = t4_fn(lib, @"v"); gp->sh[1]->fn = t4_fn(lib, @"g");
    gp->sh[1]->stage = 1; gp->sh[1]->rf.color_known = 1; gp->sh[1]->rf.color_mask = 1; serial_put(green_prog.serial, gp);
    NvProg *dp = [NvProg new]; dp->sh[0] = gp->sh[0]; dp->sh[1] = [NvShader new]; dp->sh[1]->fn = t4_fn(lib, @"none"); dp->sh[1]->stage = 1; dp->sh[1]->rf.color_known = 1; serial_put(depth_prog.serial, dp);
    state_reset(); memset(&R, 0, sizeof R);
    S.ds = (ds_st){.dt = 1, .dw = 1, .df = NVN_DEPTH_FUNC_ALWAYS};
    static nvn_rbind ib = {.kind = NVN_RB_IMG, .rw = 1, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 0};
    g_img_prog = [NvProg new]; g_img_prog->sh[1] = [NvShader new]; g_img_prog->sh[1]->stage = 1; g_img_prog->sh[1]->rf.nb = 1; g_img_prog->sh[1]->rf.b = &ib;
    static rb_shot on[STEPS], off[STEPS], notri[STEPS];
    int n_on = run(1, 1, on), n_off = run(0, 1, off), n_notri = run(1, 0, notri);
    CHECK(n_on == n_off && n_on == n_notri && n_on <= STEPS, "the runs take the same steps");
    for (int i = 0; i < n_on && i < n_off && i < n_notri; i++) for (int r = 0; r < 2; r++) { const rb_shot *a = &on[i], *b = r ? &notri[i] : &off[i];
        int same = !memcmp(a->c, b->c, sizeof a->c) && !memcmp(a->z, b->z, sizeof a->z) && !memcmp(a->s, b->s, sizeof a->s) && !memcmp(a->d2, b->d2, sizeof a->d2) && !memcmp(a->v, b->v, sizeof a->v) && !memcmp(a->ct, b->ct, sizeof a->ct);
        if (!same) fprintf(stderr, "step %d differs from the %s run\n", i, r ? "DM_NVN_SAME_CLEAR_TRI=0" : "DM_NVN_SAME_CLEAR=0");
        CHECK(same, "on, off and the clear triangles off read back the same bytes at every step");
    }
    uint64_t att, pass, bytes, tpass, tbytes; mtl_sc_stats(&att, &pass, &bytes); mtl_sct_stats(&tpass, &tbytes);
    printf("same clear: %d steps, %llu attachments left out (%llu bytes of stores), %llu passes not opened (%llu with a stencil triangle, %llu bytes); %d checks, %d failed\n", n_on, (unsigned long long)att, (unsigned long long)bytes, (unsigned long long)pass,
           (unsigned long long)tpass, (unsigned long long)tbytes, checks, failed);
    return failed != 0;
} }
