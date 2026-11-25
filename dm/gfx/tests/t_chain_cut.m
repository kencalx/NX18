// The frame's serial chain (the replay, the encode thread, the GPU), measured: a submission of P render passes of D draws each through the production replay (mtl_exec), the replay's
// translation cost stood in for by a spin of S ns at every command (the safe-point hook between commands, g_exec_yield), each draw a full-target fragment loop that keeps the GPU busy
// about as long as the replay takes to translate it. Per frame it prints the critical path (the submission's start to its fence completing), the replay's own time, the tail after it
// (the encode thread's and the GPU's work left when the replay is done) and the segment cuts made (sub_cut; DM_NVN_CUT_EVENT). Checks: every frame completes without a commit error,
// and the last target holds the closed-form colour of the last draw.
//   make -C dm/gfx/tests GAME=<id> check_t_chain_cut       (DM_NVN_ENC_THREAD=1 with DM_NVN_CUT_HOLD and DM_NVN_CUT_EVENT off and on, then without the encode thread)
//   ./t_chain_cut [passes draws spin_ns frames fragment_loop]   (defaults 12 96 1500 40 3; the GPU clock follows its load, so compare alternating runs)
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(n,w,v) do { uint64_t a_=(w), b_=(v); count++; if(a_!=b_) { printf("%s expected %llu → got %llu ✗\n",n,(unsigned long long)a_,(unsigned long long)b_); fail++; } } while(0)
typedef struct { uint8_t *p; size_t n, cap; } chain;
static chain make_chain(size_t cap) { chain c={0,0,cap}; if(posix_memalign((void **)&c.p,getpagesize(),cap)) abort(); memset(c.p,0,cap); mtl_pool_add(c.p,cap); return c; }
static void emit(chain *c, unsigned op, const void *a, size_t n) {
    size_t sz=(8+n+7)&~7ull; if(c->n+sz>c->cap) abort();
    op_hdr h={op,(uint32_t)sz}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=sz;
}
static void state(chain *c, int kind, const void *s, size_t n) { p_bind_state b={.kind=kind}; if(n>sizeof b.bytes) abort(); memcpy(b.bytes,s,n); emit(c,OP_BIND_STATE,&b,sizeof b); }
enum { W=512 };
static tex_t texture(void) {
    static uint64_t ser=7000; tex_t t={.magic=MAGIC('T','E','X',0), .serial=ser, .off=(int64_t)(ser-7000)<<22}; ser++;
    t.d.width=t.d.height=W; t.d.depth=t.d.samples=1; t.d.levels=1; t.d.target=NVN_TEXTURE_TARGET_2D; t.d.format=NVN_FORMAT_RGBA8; return t;
}
static prog_t pg[2];
static volatile uint64_t g_spin_ns;
static void spin_hook(void) { uint64_t t0=bp_now(); while(bp_now()-t0<g_spin_ns) __builtin_arm_yield(); }
static void frame_chain(chain *c, const tex_t *t, int passes, int draws) {
    c->n=0;
    // blended, so the GPU's hidden surface removal does not drop the covered draws' fragments (the last draw's alpha 1 leaves its own colour)
    color_st col={1,NVN_LOGIC_OP_COPY,NVN_ALPHA_FUNC_ALWAYS}; state(c,1,&col,sizeof col);
    blend_st bl={0,NVN_BLEND_FUNC_SRC_ALPHA,NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA,NVN_BLEND_FUNC_ONE,NVN_BLEND_FUNC_ZERO,NVN_BLEND_EQUATION_ADD,NVN_BLEND_EQUATION_ADD}; state(c,0,&bl,sizeof bl);
    for(int k=0;k<passes;k++) {
        p_set_rt r={.n=1}; r.color[0]=&t[k&1]; emit(c,OP_SET_RT,&r,sizeof r);
        p_viewports v={.n=1}; v.v[0][2]=v.v[0][3]=W; emit(c,OP_VIEWPORTS,&v,sizeof v);
        p_clear_color cl={.index=0,.mask=15,.rgba={0,0,0,1}}; emit(c,OP_CLEAR_COLOR,&cl,sizeof cl);
        for(int i=0;i<draws;i++) {
            p_bind_program b={&pg[i==draws-1],3}; emit(c,OP_BIND_PROGRAM,&b,sizeof b);
            p_scissor sc={0,0,W,W}; emit(c,OP_SCISSOR,&sc,sizeof sc);
            p_draw d={NVN_DRAW_PRIMITIVE_TRIANGLES,0,3}; emit(c,OP_DRAW,&d,sizeof d);
        }
    }
    emit(c,OP_END,NULL,0);
}
int main(int argc,char **argv) { @autoreleasepool {
    setvbuf(stdout,NULL,_IONBF,0);
    int passes=argc>1?atoi(argv[1]):12, draws=argc>2?atoi(argv[2]):96, frames=argc>4?atoi(argv[4]):40, iters=argc>5?atoi(argv[5]):3;
    g_spin_ns=argc>3?(uint64_t)atoll(argv[3]):1500;
    mtl_init();
    NSString *src=[NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
      "vertex float4 v(uint n [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[n],0,1);}\n"
      "fragment float4 heavy(float4 q [[position]]){float a=q.x*0.001; for(int i=0;i<%d;i++) a=fract(sin(a)*1.0001+0.1); return float4(a*0.001,0,0,1);}\n"
      "fragment float4 last(){return float4(0.25,0.502,0.75,1);}\n", iters];
    NSError *err=nil; id<MTLLibrary> lib=t4_lib(src,nil,&err); if(!lib) { fprintf(stderr,"%s\n",err.localizedDescription.UTF8String); return 2; }
    NSString *fn[2]={@"heavy",@"last"};
    for(int i=0;i<2;i++) { NvProg *p=[NvProg new]; p->sh[0]=[NvShader new]; p->sh[0]->fn=t4_fn(lib,@"v"); p->sh[1]=[NvShader new]; p->sh[1]->fn=t4_fn(lib,fn[i]); p->sh[1]->stage=1;
        pg[i].serial=4100+i; serial_put(pg[i].serial,p); }
    tex_t t[2]={texture(),texture()};
    chain c=make_chain((size_t)passes*draws*128+65536);
    g_exec_yield=spin_hook;
    const int warm=5; double crit=0, rep=0, tail=0, cmax=0; uint64_t cs0[4]={0}, cs1[4];
    for(int f=0;f<warm+frames;f++) {
        if(f==warm) mtl_cut_stats(cs0);
        frame_chain(&c,t,passes,draws); state_reset(); memset(&R,0,sizeof R);
        uint64_t t0=bp_now();
        atomic_store(&g_exec_yield_want,1);
        mtl_sub_begin(); mtl_exec(c.p);
        atomic_store(&g_exec_yield_want,0);
        uint64_t fence=mtl_sub_commit(), t1=bp_now();
        EXPECT("frame completed",1,mtl_wait(fence,10000000000ull)); EXPECT("no commit error",0,mtl_last_commit_error());
        uint64_t t2=bp_now();
        if(f>=warm) { double cp=(t2-t0)/1e6; crit+=cp; rep+=(t1-t0)/1e6; tail+=(t2-t1)/1e6; if(cp>cmax) cmax=cp; }
    }
    mtl_cut_stats(cs1);
    // the last pass (target passes-1 & 1) ends with the closed-form draw
    id<MTLBuffer> rb=[g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    state_reset(); memset(&R,0,sizeof R); mtl_sub_begin();
    [blit() copyFromTexture:tex_mtl(&t[(passes-1)&1]) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(7,7,0) sourceSize:MTLSizeMake(1,1,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
    EXPECT("readback completed",1,mtl_wait(mtl_sub_commit(),5000000000ull));
    const uint8_t *px=rb.contents; EXPECT("last draw's colour R",64,px[0]); EXPECT("G",128,px[1]); EXPECT("B",191,px[2]); EXPECT("A",255,px[3]);
    const char *ce=getenv("DM_NVN_CUT_EVENT"), *ch=getenv("DM_NVN_CUT_HOLD");
    printf("t_chain_cut bench (%d passes x %d draws, replay spin %llu ns a command, fragment loop %d, %d frames; encode thread %s, DM_NVN_CUT_EVENT=%s, DM_NVN_CUT_HOLD=%s): critical path %.3f ms a frame (max %.3f), "
           "replay %.3f ms, tail after the replay %.3f ms; segment cuts a frame %.2f (%.2f held for the GPU, %.2f early by the event), boundaries kept open with work running %.2f\n",
           passes,draws,(unsigned long long)g_spin_ns,iters,frames,rec_on()?"on":"off",ce?ce:"(default)",ch?ch:"(default)",crit/frames,cmax,rep/frames,tail/frames,
           (double)(cs1[0]-cs0[0])/frames,(double)(cs1[3]-cs0[3])/frames,(double)(cs1[1]-cs0[1])/frames,(double)(cs1[2]-cs0[2])/frames);
    printf("== %d checks, %d failed ==\n",count,fail); return fail!=0;
} }
