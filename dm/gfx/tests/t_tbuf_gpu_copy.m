// Buffer textures below the linear-texture alignment are read through an aligned copy made on the GPU timeline before the dispatch (or draw) that reads them (nvn_mtl.m tba_prepare,
// tba_view; ported from the S2Arm project's 8aa6f66c and 2c7f74c5). In one submission a compute dispatch writes 70,000 words into a pool at an offset the alignment refuses, then
// two dispatches read them through a buffer texture over those bytes: as a texture buffer (TBUF, tbuf_shadow's path) and as 2D rows of a wrapped 1D fetch (tbuf_as_2d's path). Both
// must read what the first dispatch wrote. With the CPU copies alone (--cpu, run with DM_NVN_TBUF_GPU_COPY=0) the copies are taken when the submission is encoded, before the
// writer ran, and read the old bytes: that run expects them, to show the check tells the two apart. A second submission after the CPU rewrites the words reads the new ones (a copy
// does not outlive its submission, and each dispatch makes its own since the one before may have written the bytes). --off <bytes> moves the texture (32 with DM_TBUF_ALIGN=64: an iPhone's case, which a
// 16-byte check used to leave in place). The bindings here have no offset table entry (tbx), so they take the copies: the fallback of the table (rendering.md, buffer textures read in place)
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { N = 70000, TID = 700 };
static prog_t g_pw = {.serial = 970001}, g_p1 = {.serial = 970002}, g_p2 = {.serial = 970003};
static NvShader *shader(id<MTLLibrary> lib, NSString *name, prog_t *pg) {
    NvProg *p = [NvProg new]; NvShader *cs = [NvShader new];
    p->sh[5] = cs; cs->stage = 5; cs->fn = t4_fn(lib, name);
    cs->arg_len = [cs->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    cs->rf.tg[0] = 64; cs->rf.tg[1] = cs->rf.tg[2] = 1;
    serial_put(pg->serial, p);
    return cs;
}
static void run(prog_t *pg, uint64_t out) {
    S.cprog = pg; S.tex[5][0] = TID;
    S.ssbo[5][0] = (p_bind_buf){.addr = out, .size = N * 4};
    p_dispatch dp = {.x = (N + 63) / 64, .y = 1, .z = 1}; dispatch(&dp);
}
static int words_are(const uint32_t *w, uint32_t mul, uint32_t add) { for (int i = 0; i < N; i++) if (w[i] != (uint32_t)i * mul + add) return 0; return 1; }
int main(int argc, char **argv) { @autoreleasepool {
    int cpu = 0; unsigned off = 8;
    for (int i = 1; i < argc; i++) { if (!strcmp(argv[i], "--cpu")) cpu = 1; else if (!strcmp(argv[i], "--off") && i + 1 < argc) off = (unsigned)atoi(argv[++i]); }
    mtl_init();
    NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct W { device uint *o [[id(0)]]; };\n"
        "kernel void wr(constant W &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { if (i < 70000) a.o[i] = i * 3 + 7; }\n"
        "struct R1 { texture_buffer<uint> t [[id(0)]]; device uint *o [[id(1)]]; };\n"
        "kernel void rd1(constant R1 &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { if (i < 70000) a.o[i] = a.t.read(i).r; }\n"
        "struct R2 { texture2d<uint, access::read> t [[id(0)]]; device uint *o [[id(1)]]; };\n"
        "kernel void rd2(constant R2 &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { if (i < 70000) a.o[i] = a.t.read(uint2(i & 0x3FFF, i >> 14)).r; }\n", nil, &error);
    CHECK(lib != nil, "the kernels compile"); if (!lib) return 1;
    NvShader *w = shader(lib, @"wr", &g_pw), *r1 = shader(lib, @"rd1", &g_p1), *r2 = shader(lib, @"rd2", &g_p2);
    w->rf.nb = 1; w->rf.b[0] = (nvn_rbind){.kind = NVN_RB_SBUFP, .rw = 1, .reg = 0, .aid = 0};
    r1->rf.nb = 2; r1->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TBUF, .dtt = MTLTextureTypeTextureBuffer, .dpf = NVN_DPF_UINT, .reg = 0, .aid = 0};
    r1->rf.b[1] = (nvn_rbind){.kind = NVN_RB_SBUFP, .rw = 1, .reg = 0, .aid = 1};
    r2->rf.nb = 2; r2->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .f1d = 1, .dtt = MTLTextureType2D, .dpf = NVN_DPF_UINT, .reg = 0, .aid = 0};
    r2->rf.b[1] = (nvn_rbind){.kind = NVN_RB_SBUFP, .rw = 1, .reg = 0, .aid = 1};
    size_t psz = 4u << 20; uint8_t *pool = NULL; if (posix_memalign((void **)&pool, getpagesize(), psz)) return 1;
    memset(pool, 0, psz); mtl_pool_add(pool, psz);
    uint32_t *data = (uint32_t *)(pool + 65536 + off), *out1 = (uint32_t *)(pool + (1u << 20)), *out2 = (uint32_t *)(pool + (2u << 20));
    for (int i = 0; i < N; i++) data[i] = (uint32_t)i * 5 + 1;   // the CPU's words before the submission
    tex_t tb = {.magic = MAGIC('T','E','X',0), .serial = 970010, .mem = (uint8_t *)data};
    tb.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32UI, .width = N, .height = 1, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&tb.d, &tb.L); mtl_tex_init(&tb); mtl_reg_tex(TID, &tb, NULL);
    id<MTLTexture> mt = tex_mtl(&tb);
    NSUInteger al = mt ? tbuf_al(mt.pixelFormat) : 0;
    CHECK(mt && mt.textureType == MTLTextureTypeTextureBuffer && !(mt.bufferOffset % tbuf_view_al(mt.pixelFormat)) && tbuf_lead(TID, mt) > 0, "the buffer texture lies below the alignment: viewed from the boundary below it, its own elements after a lead (tex_buffer, tbuf_lead)");
    // 1. One submission: the writer, then both readers
    mtl_sub_begin(); state_reset(); memset(&R, 0, sizeof R);
    run(&g_pw, (uint64_t)(uintptr_t)data); run(&g_p1, (uint64_t)(uintptr_t)out1); run(&g_p2, (uint64_t)(uintptr_t)out2);
    uint64_t f = mtl_sub_commit(); CHECK(mtl_wait(f, 5000000000ull), "the submission completes"); mtl_drain();
    CHECK(!mtl_last_commit_error(), "no GPU error");
    CHECK(words_are(data, 3, 7), "the writer ran");
    if (!cpu) {
        CHECK(words_are(out1, 3, 7), "as a texture buffer: reads what the dispatch before it wrote in the same submission");
        CHECK(words_are(out2, 3, 7), "as 2D rows: reads what the dispatch before it wrote in the same submission");
        CHECK(g_tba_copies >= 2 && g_tba_cpu == 0, "both copies made on the GPU, none on the CPU");
    } else {
        CHECK(words_are(out1, 5, 1) && words_are(out2, 5, 1), "CPU copies (DM_NVN_TBUF_GPU_COPY=0): taken at encode, before the writer ran (the gap the GPU copy closes)");
        CHECK(g_tba_copies == 0 && g_tba_cpu >= 2, "no GPU copy, the CPU copied");
    }
    // 2. The CPU rewrites the words between submissions: a reader in the next submission sees them
    for (int i = 0; i < N; i++) data[i] = (uint32_t)i * 11 + 2;
    memset(out1, 0, N * 4); memset(out2, 0, N * 4);
    uint64_t c0 = g_tba_copies;
    mtl_sub_begin(); state_reset(); memset(&R, 0, sizeof R);
    run(&g_p1, (uint64_t)(uintptr_t)out1); run(&g_p1, (uint64_t)(uintptr_t)out1); run(&g_p2, (uint64_t)(uintptr_t)out2);
    f = mtl_sub_commit(); CHECK(mtl_wait(f, 5000000000ull), "the second submission completes"); mtl_drain();
    CHECK(words_are(out1, 11, 2) && words_are(out2, 11, 2), "the next submission reads the CPU's new words");
    if (!cpu) CHECK(g_tba_copies - c0 == 3, "each dispatch copies again (a dispatch may write what a copy holds): 3 copies for 3 readers");
    printf("t_tbuf_gpu_copy%s (offset %u, alignment %lu): %d checks, %d failed; %llu GPU copies (%llu KB), %llu CPU copies\n", cpu ? " --cpu" : "", off, (unsigned long)al, checks, failed,
           (unsigned long long)g_tba_copies, (unsigned long long)(g_tba_bytes >> 10), (unsigned long long)g_tba_cpu);
    return failed != 0;
} }
