// Same-pass depth / stencil feedback by plane, and identical depth-only target bindings continuing their pass (upstream a739027a6). Real replay with pass counts and GPU
// readback of both planes: reads and writes of the same and of different planes in each order, clears waiting or applied before a read of their plane. Taken from upstream's
// t_rt_unbind (its depth_only and replay_planes), without its deferred-unbind and vertex-handle cases, which NX 18 does not have.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
typedef struct { uint8_t p[8192]; size_t n; } chain;
static void emit(chain *c, unsigned op, const void *a, size_t n) {
    size_t size = (8 + n + 7) & ~7ull; if (c->n + size > sizeof c->p) abort();
    op_hdr h = {op, (uint32_t)size}; memcpy(c->p + c->n, &h, 8);
    if (n) memcpy(c->p + c->n + 8, a, n); c->n += size;
}
static tex_t texture(uint64_t serial) {
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=serial, .off=(int64_t)serial<<20};
    t.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8, .width=8, .height=8, .depth=1, .levels=1, .samples=1};
    nvn_tex_layout(&t.d, &t.L); return t;
}
static void triangle(chain *c) { p_draw d = {.prim=NVN_DRAW_PRIMITIVE_TRIANGLES, .count=3, .instances=1}; emit(c, OP_DRAW, &d, sizeof d); }
static void run(chain *c) {
    emit(c, OP_END, NULL, 0); state_reset(); memset(&R, 0, sizeof R);
    mtl_sub_begin(); mtl_exec(c->p); mtl_sub_commit(); mtl_drain();
    CHECK(!mtl_last_commit_error(), "submission has no GPU error");
}
static id<MTLBuffer> read_pixels(tex_t *t, MTLBlitOption option) {
    id<MTLTexture> mt = tex_mtl(t);
    id<MTLBuffer> b = [g_dev newBufferWithLength:2048 options:MTLResourceStorageModeShared];
    CHECK(mt && b, "readback resources allocate"); if (!mt || !b) return nil;
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> en = t4_copy(cb); t4_use(cb, mt); t4_use(cb, b);
    [en copyFromTexture:mt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1) toBuffer:b destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:2048 options:option];
    t4_end(cb, en); long st = t4_wait(cb);
    CHECK(st == MTLCommandBufferStatusCompleted, "GPU readback completes");
    return st == MTLCommandBufferStatusCompleted ? b : nil;
}
static void pixels(tex_t *t, int red, int green, const char *label) {
    id<MTLBuffer> b = read_pixels(t, MTLBlitOptionNone); if (!b) return;
    int ok = 1;
    for (int y=0; y<8; y++) for (int x=0; x<8; x++) { const uint8_t *p=(const uint8_t *)b.contents+y*256+x*4; ok &= p[0]==red && p[1]==green && p[2]==0 && p[3]==255; }
    CHECK(ok, label);
}
static void plane_pixels(tex_t *t, MTLBlitOption option, float left, float right, const char *label) {
    id<MTLBuffer> b = read_pixels(t, option); if (!b) return;
    int ok = 1;
    for (int y = 0; y < 8; y++) {
        const uint8_t *row = (const uint8_t *)b.contents + y * 256;
        for (int x = 0; x < 8; x++) {
            float value = option == MTLBlitOptionStencilFromDepthStencil ? row[x] : ((const float *)row)[x];
            ok &= value == (x < 4 ? left : right);
        }
    }
    CHECK(ok, label);
}
static void program(chain *c, const prog_t *pg, unsigned stages) {
    p_bind_program bind = {.prog=pg, .stages=stages};
    emit(c, OP_BIND_PROGRAM, &bind, sizeof bind);
}
static void depth_stencil(chain *c, int depth, int stencil) {
    ds_st ds = {.dt=depth, .dw=depth, .df=NVN_DEPTH_FUNC_ALWAYS,
        .st=stencil, .sf_f=NVN_STENCIL_FUNC_ALWAYS, .sf_b=NVN_STENCIL_FUNC_ALWAYS,
        .fail_f=NVN_STENCIL_OP_KEEP, .zfail_f=NVN_STENCIL_OP_KEEP, .zpass_f=NVN_STENCIL_OP_REPLACE,
        .fail_b=NVN_STENCIL_OP_KEEP, .zfail_b=NVN_STENCIL_OP_KEEP, .zpass_b=NVN_STENCIL_OP_REPLACE};
    p_bind_state bind = {.kind=5};
    memcpy(bind.bytes, &ds, sizeof ds); emit(c, OP_BIND_STATE, &bind, sizeof bind);
    if (stencil) for (int k = 0; k < 3; k++) {
        p_stencil state = {.face=NVN_FACE_FRONT_AND_BACK, .which=k, .value_mask=255, .mask=255, .ref=23};
        emit(c, OP_STENCIL, &state, sizeof state);
    }
}
static void clear_depth_stencil(chain *c) {
    p_clear_ds clear = {.depth=.75f, .depth_mask=1, .stencil=7, .stencil_mask=255};
    emit(c, OP_CLEAR_DS, &clear, sizeof clear);
}
static void depth_only(const prog_t *pg, tex_t *depth, tex_t *other) {
    for (int changed = 0; changed < 2; changed++) {
        chain seed = {0}; p_set_rt rt = {.depth=depth};
        emit(&seed, OP_SET_RT, &rt, sizeof rt); clear_depth_stencil(&seed);
        rt.depth = other; emit(&seed, OP_SET_RT, &rt, sizeof rt); clear_depth_stencil(&seed);
        chain c = {0}; rt.depth = depth; emit(&c, OP_SET_RT, &rt, sizeof rt);
        program(&c, pg, 1); depth_stencil(&c, 1, 0);
        p_scissor left = {.w=4, .h=8}, right = {.x=4, .w=4, .h=8};
        emit(&c, OP_SCISSOR, &left, sizeof left); triangle(&c);
        if (changed) rt.depth = other;
        emit(&c, OP_SET_RT, &rt, sizeof rt);
        emit(&c, OP_SCISSOR, &right, sizeof right); triangle(&c);
        chain warm = c; run(&warm); run(&seed);
        uint64_t before = g_stat_pass; run(&c);
        CHECK(g_stat_pass - before == (changed || !rtc_on() ? 2 : 1),
              changed ? "changing the depth-only attachment splits the pass" : "identical depth-only bindings continue one pass");
        plane_pixels(depth, MTLBlitOptionDepthFromDepthStencil, 0, changed ? .75f : 0, "depth-only draws write the intended halves of the first target");
        plane_pixels(other, MTLBlitOptionDepthFromDepthStencil, .75f, changed ? 0 : .75f, "depth-only draws leave the other target alone until it is bound");
    }
}
static NvShader *read_shader(id<MTLLibrary> lib, NSString *entry, int stage, int kind, int dpf) {
    NvShader *sh = [NvShader new];
    sh->stage = stage; sh->fn = t4_fn(lib, entry);
    snprintf(sh->key, sizeof sh->key, "rt-%s", entry.UTF8String);
    sh->arg_len = [sh->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    sh->rf.bindless = kind == NVN_RB_TEXU; sh->rf.nb = 1;
    sh->rf.color_known = 1; sh->rf.color_mask = 1;
    sh->rf.b[0] = (nvn_rbind){.kind=kind, .reg=2, .dtt=MTLTextureType2D, .dpf=dpf};
    return sh;
}
static void feedback_draw(chain *c, const prog_t *pg, int depth, int stencil, int reads, const p_bind_buf *ub) {
    program(c, pg, 3); depth_stencil(c, depth, stencil);
    chmask_st mask = {.mask=reads ? 15 : 0}; p_bind_state bind = {.kind=2};
    memcpy(bind.bytes, &mask, sizeof mask); emit(c, OP_BIND_STATE, &bind, sizeof bind);
    if (ub) emit(c, OP_BIND_UBO, ub, sizeof *ub);
    triangle(c);
}
static uint64_t seeded_replay(const chain *seed, chain *draws) {
    chain init = *seed, warm = *draws;
    run(&init); run(&warm); init = *seed; run(&init);
    uint64_t before = g_stat_pass; run(draws);
    return g_stat_pass - before;
}
static void replay_planes(const prog_t *writer, id<MTLLibrary> lib, NvShader *vs, tex_t *color, tex_t *depth) {
    prog_t readers[] = {{.serial=882012}, {.serial=882013}};
    mtl_reg_tex(605, depth, NULL);
    view_t stencil = {.set_dsmode=1, .dsmode=NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL};
    mtl_reg_tex(606, depth, &stencil);
    void *mem = NULL;
    if (posix_memalign(&mem, getpagesize(), getpagesize())) abort();
    memset(mem, 0, getpagesize()); mtl_pool_add(mem, getpagesize());
    for (int read_stencil = 0; read_stencil < 2; read_stencil++) {
        NvProg *pr = [NvProg new]; pr->sh[0] = vs;
        pr->sh[1] = read_shader(lib, read_stencil ? @"read_stencil" : @"read_depth", 1,
                               read_stencil ? NVN_RB_TEX : NVN_RB_TEXU, read_stencil ? NVN_DPF_UINT : NVN_DPF_DEPTH);
        serial_put(readers[read_stencil].serial, pr);
        *(uint32_t *)mem = 605;
        p_bind_buf ub = {.stage=1, .index=2, .addr=(uint64_t)(uintptr_t)mem, .size=16};
        p_bind_tex1 tex = {.stage=1, .slot=2, .h=606};
        p_set_rt rt = {.n=1, .depth=depth}; rt.color[0] = color;
        chain seed = {0}; emit(&seed, OP_SET_RT, &rt, sizeof rt); clear_depth_stencil(&seed);
        p_clear_color black = {.mask=15, .rgba={0,0,0,1}};
        emit(&seed, OP_CLEAR_COLOR, &black, sizeof black);
        const p_bind_buf *handle = read_stencil ? NULL : &ub;
        enum { READ_AFTER, READ_BEFORE, READ_WHILE_WRITING };
        for (int write_stencil = 0; write_stencil < 2; write_stencil++) for (int order = READ_AFTER; order <= READ_WHILE_WRITING; order++) {
            int overlap = read_stencil == write_stencil;
            if (overlap && order == READ_WHILE_WRITING) continue;   // existing depth feedback tests cover overlapping snapshots
            chain c = {0}; emit(&c, OP_SET_RT, &rt, sizeof rt);
            if (read_stencil) emit(&c, OP_BIND_TEX1, &tex, sizeof tex);
            if (order != READ_BEFORE) feedback_draw(&c, writer, !write_stencil, write_stencil, 0, NULL);
            feedback_draw(&c, &readers[read_stencil], order == READ_WHILE_WRITING && !write_stencil,
                          order == READ_WHILE_WRITING && write_stencil, 1, handle);
            if (order == READ_BEFORE) feedback_draw(&c, writer, !write_stencil, write_stencil, 0, NULL);
            CHECK(seeded_replay(&seed, &c) == (overlap ? 2 : 1),
                  overlap ? "sampling and writing the same plane splits in either order" : "sampling and writing different planes stays in one pass");
            int reads_after_writer = order != READ_BEFORE && overlap;
            int expected = read_stencil ? (reads_after_writer ? 23 : 7) : (reads_after_writer ? 0 : 191);
            pixels(color, expected, 255, "fragment reads the expected depth or stencil value");
            plane_pixels(depth, MTLBlitOptionDepthFromDepthStencil, write_stencil ? .75f : 0, write_stencil ? .75f : 0,
                         "depth plane contains only the intended writes");
            plane_pixels(depth, MTLBlitOptionStencilFromDepthStencil, write_stencil ? 23 : 7, write_stencil ? 23 : 7,
                         "stencil plane contains only the intended writes");
        }
        // Cover a waiting load-action clear, one already applied when a draw opened
        // the pass, and a masked stencil clear emitted as a triangle.
        for (int open = 0; open <= !read_stencil; open++) {
            chain c = {0}; emit(&c, OP_SET_RT, &rt, sizeof rt);
            p_clear_ds clear = {.depth=.5f, .depth_mask=!read_stencil, .stencil=11, .stencil_mask=read_stencil ? 15 : 0};
            emit(&c, OP_CLEAR_DS, &clear, sizeof clear);
            if (open) feedback_draw(&c, writer, 0, 1, 0, NULL);
            if (read_stencil) emit(&c, OP_BIND_TEX1, &tex, sizeof tex);
            feedback_draw(&c, &readers[read_stencil], 0, 0, 1, handle);
            CHECK(seeded_replay(&seed, &c) == 2, "sampling a cleared plane waits for its store");
            pixels(color, read_stencil ? 11 : 128, 255, "readback sees the new clear on the sampled plane");
        }
    }
    mtl_pool_del(mem); free(mem);
}
int main(void) { @autoreleasepool {
    alarm(60); setvbuf(stdout,NULL,_IONBF,0); mtl_init();
    NSError *error=nil;
    id<MTLLibrary> lib=t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "float4 position(uint i) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "vertex float4 v(uint i [[vertex_id]]) { return position(i); }\n"
        "fragment float4 red() { return float4(1,0,0,1); }\n"
        "struct D { depth2d<float,access::read> source [[id(0)]]; };\n"
        "struct T { texture2d<uint,access::read> source [[id(0)]]; };\n"
        "fragment float4 read_depth(float4 p [[position]], constant D &a [[buffer(0)]]) { return float4(a.source.read(uint2(p.xy)),1,0,1); }\n"
        "fragment float4 read_stencil(float4 p [[position]], constant T &a [[buffer(0)]]) { return float4(float(a.source.read(uint2(p.xy)).r)/255,1,0,1); }\n", nil, &error);
    if (!lib) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String); return 2; }
    prog_t pg={.serial=882000}; NvProg *pr=[NvProg new]; pr->sh[0]=[NvShader new]; pr->sh[1]=[NvShader new];
    pr->sh[0]->fn=t4_fn(lib, @"v"); pr->sh[0]->stage=0;
    pr->sh[1]->fn=t4_fn(lib, @"red"); pr->sh[1]->stage=1; pr->sh[1]->rf.color_known=1; pr->sh[1]->rf.color_mask=1; serial_put(pg.serial,pr);
    tex_t t=texture(882001);
    tex_t depth=texture(882010), other=texture(882011);
    depth.d.format=other.d.format=NVN_FORMAT_DEPTH32F_STENCIL8;
    nvn_tex_layout(&depth.d, &depth.L); nvn_tex_layout(&other.d, &other.L);
    depth_only(&pg, &depth, &other);
    replay_planes(&pg, lib, pr->sh[0], &t, &depth);
    mtl_tex_release(&t); mtl_tex_release(&depth); mtl_tex_release(&other);
    printf("depth/stencil planes: %d checks, %d failed\n",checks,failed); return failed!=0;
} }
