// Production argument encoding around inline updates: old GPU tables must remain
// immutable while later draws/dispatches see the new texture and sampler handles.
#include "../nvn/nvn_mtl.m"
#include <unistd.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (%d)\n", label, __LINE__); } } while (0)
static uint8_t *mem;
static uint64_t next_serial = 96000;

static id<MTLTexture> texture(tex_t *t, int width, int height) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=next_serial++};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8,
        .width=width, .height=height, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:d];
    CHECK(out != nil, "synthetic texture allocated");
    if (!out) return nil;
    res_add(out); mtl_tex_init(t); serial_put(t->serial, out); return out;
}
static NvShader *shader(id<MTLLibrary> lib, NSString *name, int stage) {
    NvShader *s = [NvShader new]; s->stage = stage; strcpy(s->key, "0123456789abcdef");
    s->fn = [lib newFunctionWithName:name]; s->arg_len = [s->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    s->rf.nb = 2; s->rf.htab = s->rf.bindless = 1;
    s->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEXH, .aid=0, .dtt=MTLTextureType2D};
    s->rf.b[1] = (nvn_rbind){.kind=NVN_RB_SAMPH, .aid=1};
    return s;
}
static void draw_handles(NvShader *fs, id<MTLRenderPipelineState> pso, int x) {
    CHECK(rp_begin() != nil, "production render pass open");
    enc_r_pso(g_enc, pso); enc_r_viewport(g_enc, (MTLViewport){x, 0, 4, 4, 0, 1});
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc, fs, 1, 0), "production fragment arguments encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
}
static uint64_t bound(NvShader *s, int i) { return ((uint64_t *)((uint8_t *)s->ab_buf.contents + s->ab_off))[i]; }
// The texture table's handles were read again (1) or kept from the last look (0): htab_gpu as encode_args calls it
static int reread(NvShader *s) {
    uint64_t reads = g_stat_htab_reads; __unsafe_unretained id<MTLBuffer> pb = nil;
    os_unfair_lock_lock(&g_rmu); htab_gpu(s->stage, &s->rf.b[0], &pb); os_unfair_lock_unlock(&g_rmu);
    return g_stat_htab_reads != reads;
}
static void render_case(NvShader *fs, id<MTLRenderPipelineState> pso, uint64_t first, uint64_t second, int partial, int unrelated) {
    memset(mem, 0, 64); memcpy(mem, &first, 8);
    tex_t output; id<MTLTexture> target = texture(&output, 8, 4);
    id<MTLBuffer> result = [g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared]; CHECK(result != nil && target != nil, "render readback storage allocated");
    if (!result || !target) return;
    res_add(result);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    S.ubo[1][0] = (p_bind_buf){.addr=(uint64_t)mem, .size=16};
    R.has_rt=1; R.rt.n=1; R.rt.color[0]=&output; R.clear_c[0]=1; R.cc[0]=MTLClearColorMake(0, 0, 0, 1);
    draw_handles(fs, pso, 0); uint64_t before[2] = {bound(fs, 0), bound(fs, 1)}, pass = g_pass.serial;
    if (unrelated) mtl_sub_update(&second, (uint64_t)mem + 32, 8);
    else if (partial) { mtl_sub_update(&second, (uint64_t)mem, 4); mtl_sub_update((uint8_t *)&second + 4, (uint64_t)mem + 4, 4); }
    else mtl_sub_update(&second, (uint64_t)mem, 8);
    CHECK(g_enc && g_pass.serial == pass && g_nubd, "the inline update stays deferred in the same pass");
    if (unrelated) CHECK(!reread(fs), "a write beside the table keeps it without reading the handles again");
    draw_handles(fs, pso, 4);
    CHECK(!reread(fs), "no write since the last look keeps the table without reading the handles again");
    if (unrelated) CHECK(bound(fs, 0)==before[0] && bound(fs, 1)==before[1], "unrelated update keeps identical resource tables");
    else CHECK(bound(fs, 0)!=before[0] || bound(fs, 1)!=before[1], "changed handle gets a new immutable resource table");
    rp_end(); enc_b_copy_texture_buffer(blit(), target, 0, 0, MTLOriginMake(0,0,0), MTLSizeMake(8,4,1), result, 0, 256, 1024);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "real GPU submission completed");
    int left=1,right=1; int first_green=(first & 0xfffff)==3;
    for (int y=0;y<4;y++) for (int x=0;x<8;x++) {
        const uint8_t *p=(const uint8_t *)result.contents+y*256+x*4;
        int green=x<4?first_green:unrelated?first_green:!first_green;
        int ok=p[0]==(green?0:255) && p[1]==(green?255:0) && p[2]==0 && p[3]==255;
        if(x<4)left&=ok;else right&=ok;
    }
    CHECK(left,"earlier draw keeps its original literal colour"); CHECK(right,"later draw has the updated literal colour");
    mtl_tex_release(&output);
}
static void compute_case(NvShader *cs, id<MTLComputePipelineState> pso, int reverse) {
    uint64_t first=(reverse?2:1)|(1ull<<20),second=(reverse?1:2)|(1ull<<20); memset(mem,0,64);memcpy(mem,&first,8);
    id<MTLBuffer> result=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    CHECK(result != nil, "compute readback storage allocated"); if (!result) return; res_add(result);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();S.ubo[5][0]=(p_bind_buf){.addr=(uint64_t)mem,.size=16};
    for(int i=0;i<2;i++) {
        if(i)mtl_sub_update(&second,(uint64_t)mem,8);
        id<MTL4ComputeCommandEncoder> ce=dispatch_enc();enc_c_pso(ce,pso);
        CHECK(encode_args((id<MTLCommandEncoder>)ce,cs,5,0),"production compute handle tables encoded");
        enc_c_args(ce,result.gpuAddress+16*i,1);enc_c_dispatch(ce,MTLSizeMake(1,1,1),MTLSizeMake(1,1,1));
    }
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull)&&!mtl_last_commit_error(),"compute GPU submission completed");
    const float *p=result.contents;
    CHECK(p[0]==(reverse?0:1)&&p[1]==(reverse?1:0)&&p[2]==0&&p[3]==1,"first dispatch reads the current CPU backing in a new submission");
    CHECK(p[4]==(reverse?1:0)&&p[5]==(reverse?0:1)&&p[6]==0&&p[7]==1,"second dispatch reads the new handle after inline update");
}
// Across submissions (upstream NXNative 8955c6bde's cross-submission case, adapted): an unchanged table is written again into each new submission's frame arena (DM_NVN_HTAB_ARENA)
// without a build or a g_psnap_gen move, never naming an earlier submission's arena slice, also after that block is reclaimed and written over, and after an unrelated registration.
// Off (=0), the table keeps a buffer of its own across submissions, as before
static void htab_dispatch(NvShader *cs, id<MTLComputePipelineState> pso, uint8_t *ubo, id<MTLBuffer> result, const char *what) {
    S.ubo[5][0] = (p_bind_buf){.addr = (uint64_t)ubo, .size = 16};
    id<MTL4ComputeCommandEncoder> ce = dispatch_enc(); enc_c_pso(ce, pso);
    CHECK(encode_args((id<MTLCommandEncoder>)ce, cs, 5, 0), what);
    enc_c_args(ce, result.gpuAddress, 1); enc_c_dispatch(ce, MTLSizeMake(1, 1, 1), MTLSizeMake(1, 1, 1));
}
static int red(id<MTLBuffer> result) { const float *p = result.contents; return p[0] == 1 && p[1] == 0 && p[2] == 0 && p[3] == 1; }
static int arena_holds(uint64_t gpu) { for (NvArena *a in g_sub_arenas) if (gpu >= a->gpu && gpu < a->gpu + a->len) return 1; return 0; }
static void cross_sub_case(NvShader *cs, id<MTLComputePipelineState> pso, const tex_t *unrelated) {
    const int ar = g_htab_arena > 0;
    uint8_t *ubo = mem + 0x100; uint64_t handle = 1 | (1ull << 20); memset(ubo, 0, 64); memcpy(ubo, &handle, 8);
    id<MTLBuffer> result = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; CHECK(result != nil, "cross-submission readback allocated"); if (!result) return; res_add(result);
    uint64_t b0 = g_stat_htab_builds, e0 = g_stat_htab_emits;
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); htab_dispatch(cs, pso, ubo, result, "submission 1 encodes the tables");
    uint64_t gpu1 = g_htab_last->gpu, b1 = g_stat_htab_builds, pg1 = g_psnap_gen;
    CHECK(b1 == b0 + 2, "the first submission builds the texture and sampler tables once each");
    CHECK(ar ? arena_holds(gpu1) && g_htab_last->epoch == g_arena_epoch && !g_htab_last->buf : g_htab_last->buf && gpu1 == g_htab_last->buf.gpuAddress, ar ? "the table is a slice of this submission's arena" : "off: the table is a buffer of its own");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "submission 1 completed"); CHECK(red(result), "submission 1 reads the red texture");
    memset(result.contents, 0, 16);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); htab_dispatch(cs, pso, ubo, result, "submission 2 encodes the tables");
    CHECK(g_stat_htab_builds == b1 && g_psnap_gen == pg1, "an unchanged table in a new submission is not built again and keeps g_psnap_gen");
    CHECK(ar ? g_htab_last->gpu != gpu1 && arena_holds(g_htab_last->gpu) && g_stat_htab_emits == e0 + 2 : g_htab_last->gpu == gpu1 && g_stat_htab_emits == e0, ar ? "it is written again into the new submission's arena" : "off: it keeps its buffer");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "submission 2 completed"); CHECK(red(result), "submission 2 reads the red texture");
    // Submission 3: the block the last one ended in is not taken back (g_arena_next), so the arena gives a reclaimed block from its start, written over here before the table is asked for
    g_arena_next = nil; memset(result.contents, 0, 16);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    __unsafe_unretained id<MTLBuffer> scratch = nil; arena_at clobber = arena_take_u(4096, &scratch); memset(clobber.cpu, 0xff, 4096);
    htab_dispatch(cs, pso, ubo, result, "submission 3 encodes the tables after an arena block is reclaimed");
    CHECK(!ar || (g_htab_last->epoch == g_arena_epoch && g_htab_last->gpu >= clobber.gpu + 4096), "the table is written past what this submission wrote over");
    CHECK(g_stat_htab_builds == b1 && g_psnap_gen == pg1, "after the reclaim the table is still not built again");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "submission 3 completed"); CHECK(red(result), "submission 3 reads the red texture over a reclaimed, overwritten block");
    // Submission 4: a registration of another ID moves g_reg_gen; the entries come out the same, so no build and no g_psnap_gen move
    mtl_reg_tex(9, unrelated, NULL); memset(result.contents, 0, 16);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); htab_dispatch(cs, pso, ubo, result, "submission 4 encodes the tables after an unrelated registration");
    CHECK(g_stat_htab_builds == b1 && g_psnap_gen == pg1 && g_ht_how == HT_SAMEIDS, "an unrelated registration with the same entries is not a build");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "submission 4 completed"); CHECK(red(result), "submission 4 reads the red texture");
    mtl_reg_tex(9, NULL, NULL);
    // Negative control (on only): the snapshot's slice of an earlier submission taken as current (a missing epoch check), its bytes since rewritten as a reclaimed block's would be
    // (here with texture 2's entry, green): the dispatch then reads green, which the checks above would have failed
    if (ar) {
        htab_snap *ts = NULL; for (int i = 0; i < HTAB_SNAPS; i++) if (g_htab[i].valid && !g_htab[i].samp && g_htab[i].addr == (uint64_t)ubo) ts = &g_htab[i];
        CHECK(ts != NULL, "the texture table's snapshot is found");
        if (ts) {
            memset(result.contents, 0, 16);
            state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
            NvArena *old = nil; for (NvArena *a in g_arenas) if (ts->gpu >= a->gpu && ts->gpu < a->gpu + a->len) old = a;
            for (NvArena *a in g_sub_arenas) if (ts->gpu >= a->gpu && ts->gpu < a->gpu + a->len) old = a;
            void *tv = NULL; os_unfair_lock_lock(&g_rmu); uint64_t green = tex_fast_rid(2, &tv); os_unfair_lock_unlock(&g_rmu);
            CHECK(old && green, "the old slice's block and texture 2's resource ID are found");
            if (old && green) {
                memcpy(old->cpu + (ts->gpu - old->gpu) + DMSH_POOL_HEAD, &green, 8);
                ts->epoch = g_arena_epoch; ts->abuf = old->buf;   // the broken form
                htab_dispatch(cs, pso, ubo, result, "the negative control encodes");
                CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the negative control's submission completed");
                const float *q = result.contents;
                CHECK(q[0] == 0 && q[1] == 1 && q[2] == 0 && q[3] == 1, "negative control: an earlier submission's slice taken as current reads what its block holds now");
            } else mtl_wait(mtl_sub_commit(), 5000000000ull);
            ts->valid = 0;   // let go, so later cases build afresh
        }
    }
}
// A table naming a retired registration's view (its texture finalized, read late in that submission: the view goes at the submission's end, treg_finish_submission) is resolved again
// in the next submission, which makes the view again (on). The generations are put back as a steady frame leaves them (here the commit's own serial notes move g_ser_gen), so only
// the submission note (sub_trans) can send it there. control: the note cleared, the broken form: the next submission keeps the old entries and no view is made (a dropped view's ID)
static void trans_case(NvShader *cs, id<MTLComputePipelineState> pso, tex_t *tx, int id_, int control) {
    if (g_htab_arena <= 0) return;
    uint8_t *ubo = mem + 0x200 + 0x40 * control; uint64_t handle = (uint64_t)id_ | (1ull << 20); memset(ubo, 0, 64); memcpy(ubo, &handle, 8);
    id<MTLBuffer> result = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; res_add(result);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    mtl_tex_release(tx);   // the ID retires; a late read in this submission makes a transient view
    htab_dispatch(cs, pso, ubo, result, "the retired registration's submission encodes");
    htab_snap *ts = g_htab_last; for (int i = 0; i < HTAB_SNAPS; i++) if (g_htab[i].valid && !g_htab[i].samp && g_htab[i].addr == (uint64_t)ubo) ts = &g_htab[i];   // the texture table (the sampler table is asked for last)
    int took = 0; for (uint32_t k = 0; k < ts->n; k++) took |= ts->ser[k] == tx->serial;
    CHECK(took && g_treg[id_].retired && g_treg[id_].transient_sub == g_sub_serial && g_treg[id_].view, "the table names the retired registration's view of this submission");
    CHECK(ts->sub_trans == g_sub_serial, "the snapshot notes the submission whose view it names");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the retired registration's submission completed");
    CHECK(!g_treg[id_].view, "the transient view went at that submission's end");
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    ts->sgen = atomic_load(&g_ser_gen); ts->reg = atomic_load(&g_reg_gen); if (control) ts->sub_trans = 0;
    htab_dispatch(cs, pso, ubo, result, "the next submission encodes");
    if (!control) {
        CHECK(ts->sub_trans == g_sub_serial && g_treg[id_].view, "the next submission resolves the table again, making the view again");
        CHECK(ts->elems[0] == g_treg[id_].view_rid, "its entry is the view made in this submission (the same resource ID may come back: then the same entries)");
    } else CHECK(!g_treg[id_].view && ts->sub == g_sub_serial, "negative control: without the note, the next submission keeps the entries of a view that went");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the next submission completed");
}
// T_HTAB_BENCH=1: the cost of a table build (each of 256 uniform blocks of 8 handles in turn, more than the 64 snapshots hold, so each lookup builds) and of an unchanged table's first
// look in a new submission (8 blocks), per call, best of 5, with the switch as set
static void bench(void) {
    static mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    nvn_rbind b = {.kind = NVN_RB_TEXH, .reg = 0, .dtt = MTLTextureType2D};
    uint8_t *blk = mem + 0x8000; for (int i = 0; i < 256; i++) for (int k = 0; k < 8; k++) { uint64_t h = (uint64_t)(1 + (i + k) % 3) | (1ull << 20); memcpy(blk + 64 * i + 8 * k, &h, 8); }
    double best_b = 1e9, best_r = 1e9;
    for (int round = 0; round < 5; round++) {
        state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); __unsafe_unretained id<MTLBuffer> pb = nil;
        uint64_t t0 = mach_absolute_time();
        os_unfair_lock_lock(&g_rmu);
        for (int i = 0; i < 2048; i++) { S.ubo[5][0] = (p_bind_buf){.addr = (uint64_t)(blk + 64 * (i % 256)), .size = 64}; htab_gpu(5, &b, &pb); }
        os_unfair_lock_unlock(&g_rmu);
        double ns = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 2048; if (ns < best_b) best_b = ns;
        mtl_wait(mtl_sub_commit(), 5000000000ull);
        double rn = 0;
        for (int s2 = 0; s2 < 64; s2++) {
            state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
            os_unfair_lock_lock(&g_rmu);
            uint64_t t1 = mach_absolute_time();
            for (int i = 0; i < 8; i++) { S.ubo[5][0] = (p_bind_buf){.addr = (uint64_t)(blk + 64 * i), .size = 64}; htab_gpu(5, &b, &pb); }
            rn += (double)(mach_absolute_time() - t1) * tb.numer / tb.denom / 8;
            os_unfair_lock_unlock(&g_rmu);
            mtl_wait(mtl_sub_commit(), 5000000000ull);
        }
        if (rn / 64 < best_r) best_r = rn / 64;
    }
    printf("t_htab_update bench (DM_NVN_HTAB_ARENA=%d): a build %.0f ns, an unchanged table's first look in a new submission %.0f ns\n", g_htab_arena, best_b, best_r);
}
int main(void) { @autoreleasepool {
    alarm(45);setenv("DM_PSO_ARCHIVE","off",1);setenv("DM_PSO_PREBUILD","0",1);setenv("DM_PSO_MANIFEST","off",1);setenv("DM_PSO_USER","/dev/null",1);setenv("DM_PSO_RECORD","/dev/null",1);
    mtl_init();NSError *error=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct TP {uint n;ulong seen;array<texture2d<float>,1> e;};struct SP {uint n;ulong seen;array<sampler,1> e;};\n"
        "struct A {constant TP*t[[id(0)]];constant SP*s[[id(1)]];};\n"
        "float4 value(constant A&a){return a.t->e[0].sample(a.s->e[0],float2(1.25,0.5),level(0));}\n"
        "vertex float4 v(uint i[[vertex_id]]){return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1);}\n"
        "fragment float4 f(constant A&a[[buffer(0)]]){return value(a);}\n"
        "kernel void k(constant A&a[[buffer(0)]],device float4*out[[buffer(1)]]){out[0]=value(a);}\n" options:nil error:&error];
    CHECK(lib!=nil,"synthetic library compiles");if(!lib){fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 2;}
    NvShader *fs=shader(lib,@"f",1),*cs=shader(lib,@"k",5);
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];d.vertexFunction=[lib newFunctionWithName:@"v"];d.fragmentFunction=fs->fn;d.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pso=[g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    id<MTLComputePipelineState> cps=[g_dev newComputePipelineStateWithFunction:cs->fn error:&error];CHECK(pso&&cps,"render and compute pipelines compile");if(!pso||!cps)return 2;
    mem=mmap(NULL,0x10000,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);CHECK(mem!=MAP_FAILED,"uniform backing allocated");if(mem==MAP_FAILED)return 2;mtl_pool_add(mem,0x10000);
    tex_t t[3];const uint8_t values[3][8]={{255,0,0,255,255,0,0,255},{0,255,0,255,0,255,0,255},{255,0,0,255,0,255,0,255}};
    for(int i=0;i<3;i++){id<MTLTexture> tex=texture(&t[i],2,1);if(!tex)return 2;[tex replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:values[i] bytesPerRow:8];t[i].mem=mem+0x1000*(i+1);t[i].L.size=8;memcpy((void *)t[i].mem,values[i],8);mtl_reg_tex(i+1,&t[i],NULL);}
    samp_par sp={.minf=NVN_MIN_FILTER_NEAREST,.magf=NVN_MAG_FILTER_NEAREST,.ws=NVN_WRAP_MODE_CLAMP_TO_EDGE,.wt=NVN_WRAP_MODE_CLAMP_TO_EDGE,.wr=NVN_WRAP_MODE_CLAMP_TO_EDGE,.lod_max=1000};mtl_reg_samp(1,&sp);sp.ws=NVN_WRAP_MODE_REPEAT;mtl_reg_samp(2,&sp);
    render_case(fs,pso,1|(1ull<<20),2|(1ull<<20),0,0);
    render_case(fs,pso,3|(1ull<<20),3|(2ull<<20),0,0);
    render_case(fs,pso,1|(1ull<<20),2|(1ull<<20),1,0);
    render_case(fs,pso,1|(1ull<<20),2|(1ull<<20),0,1);
    compute_case(cs,cps,0);
    compute_case(cs,cps,1);
    cross_sub_case(cs,cps,&t[0]);
    for (int c = 0; c < 2; c++) { tex_t tx; id<MTLTexture> tex=texture(&tx,2,1); if(!tex)return 2; [tex replaceRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0 withBytes:values[0] bytesPerRow:8]; tx.mem=mem+0x5000+0x1000*c; tx.L.size=8; memcpy((void *)tx.mem,values[0],8); mtl_reg_tex(4+c,&tx,NULL); trans_case(cs,cps,&tx,4+c,c); }
    if (getenv("T_HTAB_BENCH")) bench();
    printf("t_htab_update: %d checks, %d failed\n",checks,failed);return failed!=0;
} }
