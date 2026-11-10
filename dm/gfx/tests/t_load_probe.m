// The load-skip probe (DM_NVN_LOADPROBE) reads back an attachment whose load was skipped and counts the sentinel pixels the pass left. Its readback is a one-off command buffer
// on the Metal 4 queue, made while the probed pass is still in the replay's open command buffer: lp_finish commits that first, so the readback runs after the pass. Here the
// target holds the sentinel colour before the pass and one full-screen triangle covers it: a readback that ran before the pass saw 64 sentinel pixels left (both encode modes)
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
#define P(name) ((NVNT_##name)nvn_lookup(#name))
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, label) do { checks++; if (!(c)) { fails++; fprintf(stderr,"FAIL: %s\n",label); } } while (0)
static uint8_t commands[8192] __attribute__((aligned(8))); static size_t used;
static void emit(unsigned op, const void *p, size_t n) {
    size_t size = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)size};
    memcpy(commands + used, &h, 8); if (n) memcpy(commands + used + 8, p, n); used += size;
}
int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "1", 1); setenv("DM_NVN_LOADPROBE", "2", 1);   // 2: the fixed sentinel colour on every format, the one the first submission clears to
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct I { float4 p [[attribute(0)]]; };\n"
        "vertex float4 v(I i [[stage_in]]) { return i.p; }\n"
        "fragment float4 f() { return float4(0,1,0,1); }\n"
        options:nil error:&error];
    CHECK(library != nil,"test shaders compile"); if (!library) return 1;
    static prog_t pg = {.serial=930001}; NvProg *program = [NvProg new];
    NvShader *vs = [NvShader new]; vs->fn = [library newFunctionWithName:@"v"];
    vs->rf.nv = 1; vs->rf.v[0].ct = NVN_CT_FLOAT;
    memset(vs->rf.v[0].sh,0xff,sizeof vs->rf.v[0].sh);
    vs->rf.pos_attr = 0; vs->rf.pos_w1 = 1; program->sh[0] = vs;
    NvShader *fs = [NvShader new]; fs->fn = [library newFunctionWithName:@"f"];
    fs->stage = 1; fs->rf.color_mask = 1; program->sh[1] = fs; serial_put(pg.serial,program);
    tex_t target = {.magic=MAGIC('T','E','X',0),.serial=930002};
    target.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=8,.height=8,.depth=1,.levels=1,.samples=1};
    void *vertices = NULL; CHECK(!posix_memalign(&vertices,getpagesize(),65536),"vertex storage allocated");
    if (!vertices) return 1; memset(vertices,0,65536); mtl_pool_add(vertices,65536);
    static NVNdevice device; static NVNqueue queue; NVNdeviceBuilder db = {0};
    P(nvnDeviceBuilderSetDefaults)(&db); CHECK(P(nvnDeviceInitialize)(&device,&db),"device initialized");
    NVNqueueBuilder qb = {0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb,&device);
    CHECK(P(nvnQueueInitialize)(&queue,&qb),"queue initialized");
    float positions[3][4] = {{-1,-1,.5,1},{3,-1,.5,1},{-1,3,.5,1}};
    memcpy(vertices,positions,sizeof positions);
    for (int sub=0;sub<2;sub++) {
        state_reset(); memset(&R,0,sizeof R); used=0;
        p_set_rt rt = {.n=1}; rt.color[0]=&target; emit(OP_SET_RT,&rt,sizeof rt);
        if (!sub) { p_clear_color clear = {.rgba={0.777f,0.222f,0.555f,0.888f},.mask=15}; emit(OP_CLEAR_COLOR,&clear,sizeof clear); }   // the sentinel, before the pass
        else {   // a pass with no clear whose first draw covers the target: its load is skipped, so the probe clears it to the sentinel and checks it at the pass end
            p_bind_program bp = {.prog=&pg,.stages=3}; emit(OP_BIND_PROGRAM,&bp,sizeof bp);
            ds_st ds = {.df=NVN_DEPTH_FUNC_ALWAYS}; p_bind_state bs = {.kind=5}; memcpy(bs.bytes,&ds,sizeof ds); emit(OP_BIND_STATE,&bs,sizeof bs);
            poly_st poly = {.cull=NVN_FACE_NONE,.mode=NVN_POLYGON_MODE_FILL}; bs.kind=4; memcpy(bs.bytes,&poly,sizeof poly); emit(OP_BIND_STATE,&bs,sizeof bs);
            struct { int32_t first,n; va_st attr; } attr = {0,1,{.fmt=NVN_FORMAT_RGBA32F}}; emit(OP_BIND_VATTR,&attr,sizeof attr);
            struct { int32_t first,n; vs_st stream; } stream = {0,1,{.stride=16}}; emit(OP_BIND_VSTREAM,&stream,sizeof stream);
            p_bind_vbuf1 vb = {.index=0,.size=sizeof positions,.addr=(uint64_t)vertices}; emit(OP_BIND_VBUF1,&vb,sizeof vb);
            p_draw draw = {.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1}; emit(OP_DRAW,&draw,sizeof draw);
        }
        static uint64_t list; list = ctl_e(CTL_CHUNK,commands,used) | CTL_LAST;   // the records' control list: one piece (nvn_obj.h ctl_e)
        NVNcommandHandle handle = (NVNcommandHandle)&list;
        P(nvnQueueSubmitCommands)(&queue,1,&handle); P(nvnQueueFinish)(&queue);
    }
    mtl_drain();
    for (int i = 0; i < 500 && !atomic_load(&g_lp_checked); i++) usleep(10000);   // the check runs on the feedback queue
    CHECK(atomic_load(&g_lp_checked) == 1,"the probe read back the one attachment whose load was skipped");
    CHECK(atomic_load(&g_lp_bad) == 0,"the probe's readback ran after the pass it checks (no sentinel pixels left)");
    mtl_pool_del(vertices); free(vertices);
    printf("load probe: %d checks, %d failed\n",checks,fails); return fails != 0;
} }
