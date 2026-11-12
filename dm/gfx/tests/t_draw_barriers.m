// draw_barriers game (DM_NVN_BARRIER=game): which draw passes skip the full entry barrier, also while aliases exist, and that a fragment-only game barrier still orders one
// pass's fragment storage writes before the next pass's fragment reads. Upstream e7750541: with an image family heap every pass took the full barrier (Ocarina of Time's
// dynamic resolution has one from its first frame), and any nonzero game barrier forced it; only ORDER_PRIMITIVES and ORDER_INDIRECT_DATA (GAME_BARRIER_FULL) do now.
// Run with DM_NVN_BARRIER=full as well: the fallback puts every pass behind the full barrier, whatever the barrier bits or the profile say.
// After NVN2's DLSS on MetalFX's temporal scaler (dlss_eval), whose encoders take no barrier, the next draw pass takes the full barrier, as after the spatial upscaler
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, label) do { checks++; if (!(c)) { fails++; fprintf(stderr,"FAIL: %s\n",label); } } while (0)
static uint8_t *cmd; static size_t used;
static void emit(unsigned op, const void *p, size_t n) {
    size_t z = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)z};
    memcpy(cmd + used, &h, 8); if (n) memcpy(cmd + used + 8, p, n); used += z;
}
static void execute(void) {
    emit(OP_END,NULL,0); mtl_sub_begin(); uint64_t handle=(uint64_t)cmd; mtl_sub_index(&handle,1); mtl_exec(cmd);
    uint64_t fence=mtl_sub_commit(); CHECK(mtl_wait(fence,5000000000ull),"GPU submission completes");
    CHECK(!mtl_last_commit_error(),"GPU reports no error"); used=0;
}
static tex_t texture(uint64_t serial, unsigned w, unsigned h, int format) {   // as t_dlss_mfx
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .off = serial << 24};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1, .flags = NVN_TEXTURE_FLAGS_IMAGE};
    nvn_tex_layout(&t.d, &t.L); mtl_tex_init(&t); return t;
}
static int red(const tex_t *t) {   // every pixel of the 8x8 target red (the reader saw the writer's value), not green
    mtl_sub_begin(); id<MTLBuffer> b=[g_dev newBufferWithLength:2048 options:MTLResourceStorageModeShared]; res_add(b);
    enc_b_copy_texture_buffer(blit(),tex_mtl(t),0,0,MTLOriginMake(0,0,0),MTLSizeMake(8,8,1),b,0,256,2048);
    uint64_t fence=mtl_sub_commit(); CHECK(mtl_wait(fence,5000000000ull),"readback completes");
    int good=1; for(int y=0;y<8;y++) for(int x=0;x<8;x++) { const uint8_t *p=(const uint8_t *)b.contents+y*256+x*4; good &= p[0]==255 && p[1]==0 && p[2]==0 && p[3]==255; }
    return good;
}
int main(void) { @autoreleasepool {
    const char *mode = getenv("DM_NVN_BARRIER"); if (!mode) { setenv("DM_NVN_BARRIER","game",1); mode = "game"; }
    const int game = !strcmp(mode,"game");
    setenv("DM_NVN_TBDR","0",1); setenv("DM_PSO_ARCHIVE","off",1); setenv("DM_PSO_MANIFEST","off",1); setenv("DM_PSO_USER","/dev/null",1);
    setenv("DM_PSO_PREBUILD","0",1); setenv("DM_PSO_HYBRID","0",1); setenv("DM_NVN_PREDICT","0",1);
    mtl_init();
    CHECK(barrier_game()==game,"DM_NVN_BARRIER picks the draw-pass order");
    void *memory=NULL; if(posix_memalign(&memory,getpagesize(),65536))abort(); memset(memory,0,65536); mtl_pool_add(memory,65536);
    cmd=memory; uint32_t *data=(uint32_t *)((uint8_t *)memory+32768);
    NSError *error=nil; id<MTLLibrary> lib=t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct A{device uint* p[[id(0)]];};\n"
        "vertex float4 v(uint n[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n%3],0,1);}\n"
        "fragment float4 f(){return float4(1,0,0,1);}\n"
        "fragment float4 fw(constant A&a[[buffer(0)]]){uint x=a.p[1];for(uint i=0;i<(1u<<22);i++)x=x*1664525u+1013904223u;a.p[2]=x;a.p[0]=0x5a5a;return float4(0,0,1,1);}\n"
        "fragment float4 fr(constant A&a[[buffer(0)]]){return a.p[0]==0x5a5a?float4(1,0,0,1):float4(0,1,0,1);}\n", nil, &error);
    if(!lib){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1;}
    // NOLINTBEGIN(clang-analyzer-osx.cocoa.RetainCount): serial_put retains each program in g_by_serial through hm_put_id's CFBridgingRetain
    NvShader *vs=[NvShader new]; vs->fn=t4_fn(lib,@"v");
    static prog_t plain={.serial=983001},writer={.serial=983002},reader={.serial=983003};
    NSString *frag[3]={@"f",@"fw",@"fr"}; prog_t *progs[3]={&plain,&writer,&reader};
    for(int i=0;i<3;i++){ NvProg *p=[NvProg new]; NvShader *fs=[NvShader new]; fs->fn=t4_fn(lib,frag[i]); fs->stage=1;
        if(i){ fs->arg_len=[fs->fn newArgumentEncoderWithBufferIndex:0].encodedLength; fs->rf.nb=1; fs->rf.b[0]=(nvn_rbind){.kind=NVN_RB_SBUFP,.rw=i==1,.reg=0,.aid=0}; }
        p->sh[0]=vs; p->sh[1]=fs; serial_put(progs[i]->serial,p); }
    // NOLINTEND(clang-analyzer-osx.cocoa.RetainCount)
    tex_t a={.magic=MAGIC('T','E','X',0),.serial=983010},b={.magic=MAGIC('T','E','X',0),.serial=983011};
    a.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=8,.depth=1,.levels=1,.samples=1}; b.d=a.d;
    state_reset(); memset(&R,0,sizeof R);
    p_bind_buf fbuf={.stage=1,.index=0,.addr=(uint64_t)data,.size=256}; emit(OP_BIND_SSBO,&fbuf,sizeof fbuf);
    ds_st ds={.df=NVN_DEPTH_FUNC_ALWAYS}; p_bind_state bs={.kind=5}; memcpy(bs.bytes,&ds,sizeof ds); emit(OP_BIND_STATE,&bs,sizeof bs);
    p_scissor sc={.w=8,.h=8}; emit(OP_SCISSOR,&sc,sizeof sc);
    p_draw tri={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1};
    p_bind_program bp={.stages=3};
    // Two draw passes (on a, then on b) with the game's barrier bits between them; the second pass's entry barrier is what is counted. The first pass of each submission
    // starts after a full end (nothing relaxed before it), so it takes the full barrier
    const struct { int32_t bits; int alias; int skip; const char *what; } cases[]={
        {0,0,1,"no game barrier: the next pass skips the full barrier"},
        {NVN_BARRIER_ORDER_FRAGMENTS_BIT|NVN_BARRIER_INVALIDATE_TEXTURE_BIT,0,1,"ORDER_FRAGMENTS | INVALIDATE_TEXTURE (0x12, Ocarina of Time's most common) keeps the relaxed order"},
        {NVN_BARRIER_INVALIDATE_SHADER_BIT|NVN_BARRIER_ORDER_FRAGMENTS_TILED_BIT,0,1,"a tiled fragment barrier with a shader invalidate keeps the relaxed order"},
        {NVN_BARRIER_ORDER_PRIMITIVES_BIT|NVN_BARRIER_INVALIDATE_TEXTURE_BIT,0,0,"ORDER_PRIMITIVES takes the full barrier"},
        {NVN_BARRIER_ORDER_INDIRECT_DATA_BIT,0,0,"ORDER_INDIRECT_DATA takes the full barrier"},
        {0,1,1,"while an image family heap exists, the next pass still skips the full barrier"},
        {NVN_BARRIER_ORDER_FRAGMENTS_BIT|NVN_BARRIER_INVALIDATE_TEXTURE_BIT,1,1,"0x12 with an image family heap keeps the relaxed order"},
        {NVN_BARRIER_ORDER_PRIMITIVES_BIT,1,0,"ORDER_PRIMITIVES with an image family heap takes the full barrier"}};
    for(unsigned c=0;c<sizeof cases/sizeof *cases;c++){
        if(cases[c].alias) atomic_fetch_add(&g_image_heap_n,1);
        CHECK(!!(resource_vis()&MTL4VisibilityOptionResourceAlias)==cases[c].alias,"resource_vis carries the alias flush exactly while an image family heap exists");
        atomic_store_explicit(&g_last_end_relaxed,0,memory_order_relaxed);
        p_set_rt rt={.n=1}; rt.color[0]=&a; emit(OP_SET_RT,&rt,sizeof rt);
        bp.prog=&plain; emit(OP_BIND_PROGRAM,&bp,sizeof bp); emit(OP_DRAW,&tri,sizeof tri);
        if(cases[c].bits) emit(OP_BARRIER,&cases[c].bits,4);
        rt.color[0]=&b; emit(OP_SET_RT,&rt,sizeof rt); emit(OP_DRAW,&tri,sizeof tri);
        uint64_t skip0,full0,skip1,full1,pass0=g_stat_pass; mtl_barrier_stats(&skip0,&full0); execute(); mtl_barrier_stats(&skip1,&full1);
        if(cases[c].alias) atomic_fetch_sub(&g_image_heap_n,1);
        CHECK(g_stat_pass-pass0==2,"two draw passes");
        char what[256]; snprintf(what,sizeof what,"%s%s",game?"":"DM_NVN_BARRIER=full (fallback): every pass takes the full barrier, not as: ",cases[c].what);
        CHECK(skip1-skip0==(uint64_t)(game&&cases[c].skip) && full1-full0==2-(uint64_t)(game&&cases[c].skip),what);
    }
    // A fragment storage write in one pass, the fragment-only game barrier, and a fragment read in the next pass (on another target): the read sees the write, with and without
    // an image family heap (whose alias flush is the second pass's start barrier before its fragment stage)
    // The writer spins (4M steps a fragment) before its write: with a write at once, the reader saw it even with no end barrier at all on the relaxed pass (the check could not fail);
    // with the spin, dropping the relaxed end barrier fails the check without an image family heap
    for(int alias=0;alias<2;alias++){
        if(alias) atomic_fetch_add(&g_image_heap_n,1);
        data[0]=0; atomic_store_explicit(&g_last_end_relaxed,0,memory_order_relaxed);
        p_set_rt rt={.n=1}; rt.color[0]=&a; emit(OP_SET_RT,&rt,sizeof rt);
        bp.prog=&writer; emit(OP_BIND_PROGRAM,&bp,sizeof bp); emit(OP_DRAW,&tri,sizeof tri);
        int32_t bits=NVN_BARRIER_ORDER_FRAGMENTS_BIT|NVN_BARRIER_INVALIDATE_TEXTURE_BIT; emit(OP_BARRIER,&bits,4);
        rt.color[0]=&b; emit(OP_SET_RT,&rt,sizeof rt); bp.prog=&reader; emit(OP_BIND_PROGRAM,&bp,sizeof bp); emit(OP_DRAW,&tri,sizeof tri);
        uint64_t skip0,full0,skip1,full1; mtl_barrier_stats(&skip0,&full0); execute(); mtl_barrier_stats(&skip1,&full1);
        if(alias) atomic_fetch_sub(&g_image_heap_n,1);
        CHECK(data[0]==0x5a5a,"the writer pass's fragment storage write landed");
        CHECK(skip1-skip0==(uint64_t)game,alias?"the reader pass skips the full barrier with an image family heap (game) or takes it (full)":"the reader pass skips the full barrier (game) or takes it (full)");
        CHECK(red(&b),alias?"after a fragment-only barrier the next pass's fragments read the previous pass's fragment write, with an image family heap":"after a fragment-only barrier the next pass's fragments read the previous pass's fragment write");
    }
    // A draw pass ended relaxed, then DLSS through MetalFX's temporal scaler: the next draw pass takes the full barrier, so it waits for the scaler's own encoders
    { tex_t col = texture(983020, 960, 540, NVN_FORMAT_RGBA16F), dep = texture(983021, 960, 540, NVN_FORMAT_DEPTH32F), mot = texture(983022, 960, 540, NVN_FORMAT_RG16F), out = texture(983023, 1920, 1080, NVN_FORMAT_RGBA16F);
      p_dlss c = {.tex = {&col, &dep, &mot, &out}, .net = 1, .iw = 960, .ih = 540, .ow = 1920, .oh = 1080, .mv = {1, 1}, .pre_exposure = 1, .flags = DLSS_F_MV_LOW_RES | DLSS_F_DEPTH_INVERTED, .reset = 1};
      mtl_sub_begin(); dlss_eval(&c); c.reset = 0;   // the first evaluation makes the scaler and gives the textures MetalFX's usages, through copies whose encoders end in full
      atomic_store_explicit(&g_last_end_relaxed, game, memory_order_relaxed);   // as a draw pass's relaxed end leaves it (enc_r_end_pass)
      dlss_eval(&c);   // a later frame's: nothing else is encoded
      CHECK(g_dlss[0].sc != nil, "MetalFX made a temporal scaler");
      CHECK(!atomic_load_explicit(&g_last_end_relaxed, memory_order_relaxed), "after the temporal scaler no relaxed end is left for the next pass");
      MTL4RenderPassDescriptor *d = [MTL4RenderPassDescriptor new]; d.colorAttachments[0].texture = tex_mtl(&a); d.colorAttachments[0].loadAction = MTLLoadActionClear; d.colorAttachments[0].storeAction = MTLStoreActionStore;
      uint64_t skip0, full0, skip1, full1; mtl_barrier_stats(&skip0, &full0);
      id<MTL4RenderCommandEncoder> e = enc_r_begin_pass(d); enc_r_end_pass(e);
      mtl_barrier_stats(&skip1, &full1);
      CHECK(skip1 == skip0 && full1 - full0 == 1, "the draw pass after the temporal scaler takes the full barrier");
      CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the submission with the scaler completes"); }
    printf("draw barriers (DM_NVN_BARRIER=%s): %d checks, %d failed\n",game?"game":"full",checks,fails); return fails!=0;
} }
