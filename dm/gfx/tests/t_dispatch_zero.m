// A direct grid with any zero dimension does no work, even with no program bound.
// It must leave pending clears, write epochs and encoders alone (nvn_mtl.m dispatch; ported from upstream NXNative a3e25ed40, PR #1696). An indirect
// argument address is not a direct zero grid: its dimensions belong to the GPU.
// Empty direct draws and 0-byte buffer copies do the same (upstream NXNative 816889e5d): a 0-length lookup was an unknown extent to big_lookup and made a whole chunked pool resident.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
int main(void) { @autoreleasepool {
    mtl_init();
    uint64_t writes = g_wr_epoch, indices = g_mdx_epoch;
    const uint32_t dims[][3] = {{0, 8, 1}, {8, 0, 1}, {8, 8, 0}, {0, 0, 1}};
    for (unsigned i = 0; i < sizeof dims / sizeof *dims; i++) {
        p_dispatch d = {0}; d.x = dims[i][0]; d.y = dims[i][1]; d.z = dims[i][2];
        dispatch(&d);
        if (g_wr_epoch != writes || g_mdx_epoch != indices || g_cb || g_enc || g_blit) {
            fprintf(stderr, "FAIL: empty grid changed replay state\n"); return 1;
        }
    }
    uint64_t draws = g_stat_draw, mdraws = g_cm_mdraws;
    p_draw_idx di = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .itype = 1, .count = 0, .instances = 1, .ibuf = 0x1000};
    draw(NULL, &di);
    di.count = -1; di.itype = 2; draw(NULL, &di);
    p_draw dw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 0, .instances = 1};
    draw(&dw, NULL);
    if (g_stat_draw != draws || g_cm_mdraws != mdraws || g_cb || g_enc || g_blit || g_wr_epoch != writes) { fprintf(stderr, "FAIL: empty direct draw changed replay state\n"); return 1; }
    enum { GB = 1 << 30 };
    uint8_t *um = mmap(NULL, GB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (um == MAP_FAILED) abort();
    mtl_pool_add(um, GB);
    int pools = g_npool; uint64_t at = (uint64_t)(uintptr_t)um + 100 * (1 << 20) + 16;
    mtl_sub_copy(at, at + 4096, 0);
    if (g_npool != pools || g_blit || g_mdx_epoch != indices) { fprintf(stderr, "FAIL: 0-byte buffer copy looked up a buffer or opened an encoder (pools %d -> %d)\n", pools, g_npool); return 1; }
    puts("t_dispatch_zero: four zero-dimensional grids, three empty direct draws and a 0-byte copy leave replay state untouched");
    return 0;
} }
