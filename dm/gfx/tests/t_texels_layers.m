// WriteTexels into one layer of a 2D array (hle_nvn.c write_texels_prepare) unprotects that layer's level only, so the other layers' pages stay protected and unwritten; the re-upload
// it causes deswizzles only what was written and keeps the rest (nvn_mtl.m pkg_upload_, part_reupload_on): copied from the texture it replaces into a new one, or kept in the spare it
// is made into. Every readback must hold all the bytes the CPU wrote, in every layer and level, and each staged upload makes one no-copy source buffer over the storage, not two (up_big_src).
// NieR:Automata writes small regions into layers 0 and 1 of two 16-layer arrays every frame; the whole 48 MB was unprotected and re-uploaded each time (dm/games/010056B015FE8000/README.md)
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } else printf("PASS: %s\n", label); } while (0)

enum { W = 128, H = 128, L = 8, LW = W / 2, LH = H / 2 };
static uint8_t want0[L][H][W][4], want1[L][LH][LW][4];   // what levels 0 and 1 of each layer must read back
static NVNtexture tex, alias; static NVNmemoryPool tpool, cpool; static uint8_t *tmem, *cmem; static NVNtextureView level1;
static NVNcommandBuffer cmd;
// The upload batches' feedback has come back too (pkg_upload_ builds on a texture only once its batch has: up_seq_back)
static void settle(void) { for (int i = 0; i < 5000 && atomic_load(&g_up_pending); i++) usleep(1000); pthread_mutex_lock(&g_mu); g_done = g_fence; pthread_mutex_unlock(&g_mu); defer_drain(); }
// The texture as the GPU has it now: both levels of every layer copied into the command pool, through the replay (which resolves it, uploading what changed)
static int readback_ok(const char *label) {
    NVNcopyRegion r0 = {0, 0, 0, W, H, L}, r1 = {0, 0, 0, LW, LH, L};
    uint64_t dst0 = (uint64_t)(uintptr_t)(cmem + (1 << 20)), dst1 = dst0 + sizeof want0;
    h_nvnCommandBufferBeginRecording(&cmd);
    h_nvnCommandBufferCopyTextureToBuffer(&cmd, &tex, NULL, &r0, dst0, 0);
    h_nvnCommandBufferCopyTextureToBuffer(&cmd, &tex, &level1, &r1, dst1, 0);
    NVNcommandHandle h = h_nvnCommandBufferEndRecording(&cmd);
    memset((void *)(uintptr_t)dst0, 0xcd, sizeof want0 + sizeof want1);
    mtl_sub_begin(); mtl_exec(nvn_rec_linear(h, NULL));   // the records as the queue submits them (upstream f02d0474: the handle is a control list)
    int ok = mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error();
    settle();
    int same0 = !memcmp((void *)(uintptr_t)dst0, want0, sizeof want0), same1 = !memcmp((void *)(uintptr_t)dst1, want1, sizeof want1);
    if (!same0 || !same1) { const uint8_t *g = (const uint8_t *)(uintptr_t)dst0, *w = &want0[0][0][0][0]; size_t i = 0; while (i < sizeof want0 && g[i] == w[i]) i++;
        unsigned bad = 0; for (unsigned y = 0; y < L; y++) if (memcmp(g + (size_t)y * W * H * 4, w + (size_t)y * W * H * 4, (size_t)W * H * 4)) bad |= 1u << y;
        fprintf(stderr, "%s: level 0 %s (first difference at layer %zu, layers differing %#x), level 1 %s\n", label, same0 ? "same" : "differs", i / (W * H * 4), bad, same1 ? "same" : "differs"); }
    return ok && same0 && same1;
}
// A GPU buffer-to-texture copy into a level 0 region of one layer of dst (the texture, or another texture object over its storage), run in a submission of its own. The copy reaches the
// storage on the GPU (gsb_store_buf), which the CPU's page tracking does not see
static int gpu_copy(NVNtexture *dst, int layer, int x, int y, int w, int h, uint8_t seed) {
    uint8_t *src = cmem + (3 << 20);
    for (int i = 0; i < w * h * 4; i++) src[i] = (uint8_t)(seed + i * 13);
    for (int yy = 0; yy < h; yy++) memcpy(&want0[layer][y + yy][x][0], src + (size_t)yy * w * 4, (size_t)w * 4);
    NVNcopyRegion r = {x, y, layer, w, h, 1};
    h_nvnCommandBufferBeginRecording(&cmd);
    h_nvnCommandBufferCopyBufferToTexture(&cmd, (uint64_t)(uintptr_t)src, dst, NULL, &r, 0);
    NVNcommandHandle hd = h_nvnCommandBufferEndRecording(&cmd);
    mtl_sub_begin(); mtl_exec(nvn_rec_linear(hd, NULL));
    int ok = mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error();
    settle(); return ok;
}
// The storage's level 0 of one layer, deswizzled on the CPU, against what it must hold
static int storage_layer_ok(int layer) {
    tex_t *t = (tex_t *)&tex; static uint8_t lin[H][W][4];
    return !nvn_deswizzle(&t->d, 0, (unsigned)layer, t->mem, &lin[0][0][0], W * 4) && !memcmp(lin, want0[layer], sizeof lin);
}
// A region of one level of one layer written from the CPU, into the texture and the expected copy
static void write_region(int level, int layer, int x, int y, int w, int h, uint8_t seed) {
    static uint8_t px[W * H * 4];
    for (int i = 0; i < w * h * 4; i++) px[i] = (uint8_t)(seed + i * 7);
    for (int yy = 0; yy < h; yy++) memcpy(level ? &want1[layer][y + yy][x][0] : &want0[layer][y + yy][x][0], px + (size_t)yy * w * 4, (size_t)w * 4);
    NVNtextureView v; h_nvnTextureViewSetDefaults(&v); h_nvnTextureViewSetLevels(&v, level, 1);
    NVNcopyRegion r = {x, y, layer, w, h, 1};
    h_nvnTextureWriteTexels(&tex, level ? &v : NULL, &r, px);
}
static NvPkg *pkg(void) { id o = tex_get(((tex_t *)&tex)->serial); return [o isKindOfClass:[NvPkg class]] ? o : nil; }
// Which layers' level 0 storage counts as written since the last upload
static unsigned written_layers(void) {
    tex_t *t = (tex_t *)&tex; NvPkg *pk = pkg(); unsigned m = 0;
    for (unsigned y = 0; y < L; y++) if (nvn_dirty_since(t->mem + (uint64_t)y * t->L.layer_size, nvn_tex_level_offset(&t->d, 1), pk ? pk->stamp : 0)) m |= 1u << y;
    return m;
}
int main(void) { @autoreleasepool {
    mtl_init();
    int part_on = part_reupload_on();
    printf("partial re-upload %s (DM_NVN_REUPLOAD_PART)\n", part_on ? "on" : "off");
    const size_t tlen = 4 << 20, clen = 4 << 20;
    tmem = mmap(NULL, tlen, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); cmem = mmap(NULL, clen, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (tmem == MAP_FAILED || cmem == MAP_FAILED) abort();
    pool_builder_t pb = {.mem = tmem, .size = tlen, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};   // a pool of its own, as NieR's arrays (flags 0x22)
    CHECK(h_nvnMemoryPoolInitialize(&tpool, (const NVNmemoryPoolBuilder *)&pb), "texture pool initialized");
    pool_builder_t cb = {.mem = cmem, .size = clen, .flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize(&cpool, (const NVNmemoryPoolBuilder *)&cb), "command pool initialized");
    CHECK(h_nvnCommandBufferInitialize(&cmd, NULL), "command buffer initialized");
    h_nvnCommandBufferAddCommandMemory(&cmd, &cpool, 0, 262144);
    NVNtextureBuilder tb; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D_ARRAY); h_nvnTextureBuilderSetWidth(&tb, W); h_nvnTextureBuilderSetHeight(&tb, H); h_nvnTextureBuilderSetDepth(&tb, L);
    h_nvnTextureBuilderSetLevels(&tb, 2); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8); h_nvnTextureBuilderSetStorage(&tb, &tpool, 0);
    CHECK(h_nvnTextureInitialize(&tex, &tb), "2D array texture initialized");
    tex_t *t = (tex_t *)&tex;
    printf("storage %llu bytes, layer %llu, level 1 at %llu; host page %d\n", (unsigned long long)t->L.size, (unsigned long long)t->L.layer_size, (unsigned long long)nvn_tex_level_offset(&t->d, 1), getpagesize());
    CHECK(t->L.layer_size >= (uint64_t)4 * getpagesize(), "each layer spans several host pages");
    h_nvnTextureViewSetDefaults(&level1); h_nvnTextureViewSetLevels(&level1, 1, 1);
    for (int y = 0; y < L; y++) { write_region(0, y, 0, 0, W, H, (uint8_t)(y * 31)); write_region(1, y, 0, 0, LW, LH, (uint8_t)(y * 17 + 5)); }
    CHECK(readback_ok("first upload"), "first upload: every layer and level reads back as written");
    NvPkg *pk = pkg();
    CHECK(pk != nil, "the texture is uploaded from its storage (an NvPkg)");
    // One layer's region: only that layer's level 0 is unprotected
    write_region(0, 1, 10, 20, 28, 28, 0x40);
    CHECK(written_layers() == 1u << 1, "WriteTexels into layer 1 leaves the other layers' pages unwritten (still protected)");
    uint64_t srcs0 = g_up_big_srcs, part0 = g_part_reuploads, kept0 = g_part_kept, up0 = g_part_up, re0 = g_pkg_reuploads;
    id<MTLTexture> first = pk->tex;
    CHECK(readback_ok("re-upload 1"), "re-upload into a new texture: every layer and level reads back as written");
    CHECK(g_pkg_reuploads == re0 + 1 && pk->tex != first, "one re-upload, into another texture (the first is now the spare)");
    CHECK(g_up_big_srcs - srcs0 == 1, "the staged re-upload made one no-copy source buffer over the storage, not two");
    printf("no-copy source buffers for the re-upload: %llu\n", (unsigned long long)(g_up_big_srcs - srcs0));
    if (part_on) CHECK(g_part_reuploads == part0 + 1 && g_part_kept - kept0 == 2 * L - 1 && g_part_up - up0 == 1, "partial: 15 levels of layers copied from the old texture, 1 deswizzled");
    else CHECK(g_part_reuploads == part0, "partial re-upload off: none made");
    // Another layer and a level 1 region: the spare (idle now) is made the texture; it holds the first upload, so layer 1 and these come from the storage, the rest stays
    write_region(0, 5, 100, 0, 28, 64, 0x90); write_region(1, 6, 3, 4, 20, 9, 0x11);
    CHECK((written_layers() & ~(1u << 6)) == 1u << 5, "a level 1 write unprotects no other layer's level 0");
    id<MTLTexture> spare = pk->spare; srcs0 = g_up_big_srcs; part0 = g_part_reuploads; kept0 = g_part_kept; up0 = g_part_up;
    CHECK(readback_ok("re-upload 2"), "re-upload into the spare: every layer and level reads back as written");
    CHECK(pk->tex == spare, "the spare was reused");
    CHECK(g_up_big_srcs - srcs0 == 1, "again one no-copy source buffer");
    if (part_on) CHECK(g_part_reuploads == part0 + 1 && g_part_up - up0 == 3 && g_part_kept - kept0 == 2 * L - 3, "partial into the spare: what was written since its own upload (3 levels of layers), the rest kept");
    // Once more: the other texture becomes the spare again; a write of every layer's level 0 deswizzles them all
    for (int y = 0; y < L; y++) write_region(0, y, 0, 0, 16, 16, (uint8_t)(0x60 + y));
    CHECK(written_layers() == (1u << L) - 1, "a write into every layer unprotects every layer");
    CHECK(readback_ok("re-upload 3"), "re-upload after writes into every layer reads back as written");
    // A whole re-write of one layer through a region the size of the level, and nothing else: the readback still matches
    write_region(0, 7, 0, 0, W, H, 0x77);
    CHECK(readback_ok("re-upload 4"), "a whole-layer rewrite reads back as written");
    CHECK(readback_ok("no write"), "with nothing written, the texture is not re-uploaded and still reads back as written");
    // Two re-uploads in one submission: the second goes into a new texture while the first one's copies are still in the open upload batch, whose copies have no order among
    // them, so it must not copy from the first: it is uploaded whole
    uint64_t pr0 = g_part_reuploads, rr0 = g_pkg_reuploads;
    mtl_sub_begin();
    write_region(0, 2, 5, 5, 40, 40, 0xa0); CHECK(tex_mtl(t) != nil, "first re-upload in the submission");
    write_region(0, 4, 50, 60, 30, 30, 0xb0); CHECK(tex_mtl(t) != nil, "second re-upload in the same submission");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission with two re-uploads completes"); settle();
    CHECK(g_pkg_reuploads == rr0 + 2, "two re-uploads were made");
    if (part_on) CHECK(g_part_reuploads - pr0 <= 1, "the second does not copy from a texture whose upload is still in the open batch");
    CHECK(readback_ok("two in one batch"), "after two re-uploads in one batch every layer and level reads back as written");
    // A dropped batch of another texture, which is then freed: the record's count stays as it was until it is taken again, and it held back every partial re-upload while it was not 0. The
    // record is looked up for the texture the re-upload builds on instead, and its count taken again then
    @autoreleasepool { id<MTLTexture> other = [g_dev newTextureWithDescriptor:tex_desc(t, 1)]; up_lost_add(@[other]); }
    CHECK(atomic_load(&g_up_lost_n) == 1, "another texture's dropped upload is in the record");
    write_region(0, 3, 7, 9, 30, 20, 0xc0); pr0 = g_part_reuploads; rr0 = g_pkg_reuploads;
    CHECK(readback_ok("another texture dropped"), "with another texture's upload dropped, every layer and level reads back as written");
    CHECK(g_pkg_reuploads == rr0 + 1, "one re-upload");
    if (part_on) CHECK(g_part_reuploads == pr0 + 1, "another texture's dropped upload leaves this re-upload partial");
    if (part_on) CHECK(atomic_load(&g_up_lost_n) == 0, "the record's count was taken again: the freed texture is gone from it");
    // This texture's upload dropped (its texture never written: one of the same shape that nothing wrote stands for it), with no spare: the next use finds it clean and in the record and uploads
    // it again (up_lost_take). That re-upload must not build on the texture it redoes: copied from it, every level of every layer was kept as nothing had been written since, from a texture
    // nothing had written, and its record was used up
    id<MTLTexture> blank = [g_dev newTextureWithDescriptor:tex_desc(t, 1)]; res_add(blank);
    { id<MTLTexture> old = pk->tex; pk->tex = blank; defer_obj_release(old); if (pk->spare) { defer_obj_release(pk->spare); pk->spare = nil; } }
    up_lost_add(@[blank]); pthread_mutex_lock(&g_smu); g_ser_gen++; pthread_mutex_unlock(&g_smu);   // as the feedback handler of a dropped batch does
    pr0 = g_part_reuploads; rr0 = g_pkg_reuploads; uint64_t redo0 = atomic_load(&g_up_lost_redo);
    CHECK(readback_ok("dropped upload redone"), "a texture whose upload was dropped is uploaded again and reads back as written");
    CHECK(atomic_load(&g_up_lost_redo) == redo0 + 1 && g_pkg_reuploads == rr0 + 1, "it was redone once");
    CHECK(g_part_reuploads == pr0, "the redo is whole: it does not copy from the texture it redoes");
    // Image use given by tex_upgrade (the texture bound as an image), then a write and a re-upload in the same submission: the upgraded texture is filled by the submission's own blit, after
    // the upload batch, so the re-upload must not copy from it (only render-target and format-view use carried over, so image use was missed)
    uint64_t up0b = g_part_reuploads; rr0 = g_pkg_reuploads;
    mtl_sub_begin();
    id<MTLTexture> before_up = pk->tex; tex_upgrade(t, pk->tex, MTLTextureUsageShaderWrite, pk->tex.pixelFormat);
    CHECK(pk->tex != before_up && (pk->tex.usage & MTLTextureUsageShaderWrite), "the upgrade gave the texture image use");
    write_region(0, 1, 60, 70, 40, 30, 0xd0); CHECK(tex_mtl(t) != nil, "re-upload in the submission that upgraded it");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission with the upgrade and the re-upload completes"); settle();
    CHECK(g_pkg_reuploads == rr0 + 1 && g_part_reuploads == up0b, "the re-upload after an image-use upgrade is whole");
    CHECK(readback_ok("after an image-use upgrade"), "after an image-use upgrade and a re-upload every layer and level reads back as written");
    // A re-upload into a new texture while the batch that wrote the texture it replaces has not come back (the GPU held by a shared event): that batch may yet be dropped, so the re-upload
    // is whole. Copied from it, a drop reported after the copy left the copied layers unwritten for good, as only the replaced texture went into the record
    write_region(0, 0, 1, 2, 30, 30, 0xe0); CHECK(readback_ok("before the held batch"), "a re-upload before the held one reads back as written");
    id<MTLSharedEvent> gate = [g_dev newSharedEvent]; if (!gate) abort();
    pthread_mutex_lock(&g_sub_mu); pthread_mutex_lock(&g_res_mu); [g_q4 waitForEvent:gate value:1]; pthread_mutex_unlock(&g_res_mu); pthread_mutex_unlock(&g_sub_mu);
    mtl_sub_begin(); write_region(0, 5, 8, 8, 24, 24, 0xe8); CHECK(tex_mtl(t) != nil, "re-upload A, its batch held"); uint64_t fa = mtl_sub_commit();
    pr0 = g_part_reuploads; uint64_t un0 = g_part_unsure; id<MTLTexture> a_tex = pk->tex;
    mtl_sub_begin(); write_region(0, 6, 9, 9, 24, 24, 0xf0); CHECK(tex_mtl(t) != nil, "re-upload B, building on A's texture"); uint64_t fb = mtl_sub_commit();
    CHECK(pk->tex != a_tex, "B is a new texture (A's spare is still in use)");
    if (part_on) CHECK(g_part_reuploads == pr0 && g_part_unsure == un0 + 1, "B is whole: the batch that wrote A's texture had not come back");
    gate.signaledValue = 1;
    CHECK(mtl_wait(fa, 5000000000ull) && mtl_wait(fb, 5000000000ull), "both submissions complete once the GPU is let go"); settle();
    CHECK(readback_ok("after the held batch"), "after the held batch every layer and level reads back as written");
    write_region(0, 4, 3, 3, 16, 16, 0xf8); pr0 = g_part_reuploads;
    CHECK(readback_ok("after the batch came back"), "a re-upload once that batch has come back reads back as written");
    if (part_on) CHECK(g_part_reuploads == pr0 + 1, "and is partial again");
    // A spare no re-upload uses for PKG_SPARE_IDLE submissions is let go (pkg_spare_trim): out of the residency set, counted for the memory line; the next re-upload makes a new texture
    // and, partial re-upload on, copies what was not written from the one it replaces. DM_NVN_PKG_SPARE_IDLE=0 keeps it
    CHECK(pk->spare != nil, "the texture has a spare after its re-uploads");
    uint64_t freed0 = atomic_load(&g_pkg_spare_freed), spare_bytes = pk->spare.allocatedSize; __weak id<MTLTexture> idle_spare = pk->spare;
    for (int i = 0; i < PKG_SPARE_IDLE + PKG_SPARE_SCAN + 2; i++) { @autoreleasepool { mtl_sub_begin(); if (!mtl_wait(mtl_sub_commit(), 5000000000ull)) { CHECK(0, "idle submission completes"); break; } } }
    settle(); @autoreleasepool { mtl_sub_begin(); mtl_wait(mtl_sub_commit(), 5000000000ull); } settle(); res_commit();
    int spare_resident; @autoreleasepool { id<MTLTexture> sp = idle_spare; pthread_mutex_lock(&g_res_mu); spare_resident = sp && [g_res_objects containsObject:sp]; pthread_mutex_unlock(&g_res_mu); }
    printf("after %d idle submissions: spare %s, spares alive %llu (%llu KB), let go %llu (%llu KB of %llu KB)\n", PKG_SPARE_IDLE + PKG_SPARE_SCAN + 2, pk->spare ? "kept" : "let go",
           (unsigned long long)atomic_load(&g_pkg_spare_n), (unsigned long long)(atomic_load(&g_pkg_spare_bytes) >> 10), (unsigned long long)(atomic_load(&g_pkg_spare_freed) - freed0), (unsigned long long)(atomic_load(&g_pkg_spare_freed_bytes) >> 10), (unsigned long long)(spare_bytes >> 10));
    if (pkg_spare_idle_on()) {
        CHECK(pk->spare == nil && pk->spare_stamp == 0 && pk->spare_seq == 0, "an idle spare is let go");
        CHECK(!spare_resident, "and leaves the residency set");
        CHECK(atomic_load(&g_pkg_spare_freed) == freed0 + 1 && atomic_load(&g_pkg_spare_n) == 0 && atomic_load(&g_pkg_spare_bytes) == 0, "the memory line's counts: one let go, none alive");
    } else {
        CHECK(pk->spare != nil && spare_resident && atomic_load(&g_pkg_spare_freed) == freed0, "DM_NVN_PKG_SPARE_IDLE=0: the spare is kept");
        CHECK(atomic_load(&g_pkg_spare_n) == 1 && atomic_load(&g_pkg_spare_bytes) == spare_bytes, "the memory line counts the spare kept");
    }
    write_region(0, 2, 11, 13, 20, 20, 0x2c); pr0 = g_part_reuploads; rr0 = g_pkg_reuploads; id<MTLTexture> before_idle = pk->tex;
    CHECK(readback_ok("after the spare went idle"), "a re-upload after the spare went idle reads back as written");
    CHECK(g_pkg_reuploads == rr0 + 1 && pk->tex != before_idle && pk->spare == before_idle, "one re-upload into another texture, the one it replaced the spare again");
    if (part_on) CHECK(g_part_reuploads == pr0 + 1, "and it is partial, copying the rest from the texture it replaces");
    write_region(0, 6, 1, 1, 8, 8, 0x3d);
    CHECK(readback_ok("into the new spare"), "the next re-upload, into the new spare, reads back as written");
    // A GPU copy into layer 5 of the texture itself reaches its storage on the GPU (gsb_store_buf), unseen by the page tracking, and its record counts it (stored). The spare was read before it,
    // so a re-upload into the spare is whole (nvn_mtl.m tex_mtl_: pk->stored); one into a new texture may copy layer 5 from the texture it replaces, which the copy wrote
    CHECK(gpu_copy(&tex, 5, 16, 16, 32, 32, 0x55), "a GPU copy into layer 5 of the texture runs");
    CHECK(pk->stored > 0, "its record counts the store into its storage");
    CHECK(storage_layer_ok(5), "the copy reached the storage");
    CHECK(readback_ok("after a GPU copy"), "after the GPU copy, with no CPU write, the texture reads back with it");
    write_region(0, 2, 3, 3, 20, 20, 0x22); pr0 = g_part_reuploads; rr0 = g_pkg_reuploads; id<MTLTexture> spare_before = pk->spare;
    CHECK(readback_ok("re-upload after a GPU store"), "a CPU write after the store: the re-upload reads back with both");
    CHECK(g_pkg_reuploads == rr0 + 1, "one re-upload");
    printf("re-upload after the texture's own store: %s, %s\n", spare_before && pk->tex == spare_before ? "into the spare" : "into a new texture", g_part_reuploads == pr0 ? "whole" : "partial");
    if (part_on && spare_before && pk->tex == spare_before) CHECK(g_part_reuploads == pr0, "into the spare, which lacks the store: whole");
    CHECK(pk->stored == 0, "the re-upload read the store: the count starts again");
    for (int y = 3; y <= 4; y++) { char lb[48]; snprintf(lb, sizeof lb, "CPU write into layer %d after the store", y); write_region(0, y, 3, 3, 20, 20, (uint8_t)(0x30 + y)); CHECK(readback_ok(lb), lb); }
    // Another texture object over the same storage (RGBA8UI: another description, another record) takes a GPU copy into layer 7, which reaches the shared storage on the GPU. This
    // texture's record sees no store and its pages stay clean; a CPU write into another layer then re-uploads it, and the re-upload must carry layer 7 as the storage holds it: a partial
    // re-upload kept the layer's content from the spare (or the texture it replaces) for good, as no CPU write ever marked its pages. Into the spare first, then into a new texture
    NVNtextureBuilder ab; h_nvnTextureBuilderSetDefaults(&ab);
    h_nvnTextureBuilderSetTarget(&ab, NVN_TEXTURE_TARGET_2D_ARRAY); h_nvnTextureBuilderSetWidth(&ab, W); h_nvnTextureBuilderSetHeight(&ab, H); h_nvnTextureBuilderSetDepth(&ab, L);
    h_nvnTextureBuilderSetLevels(&ab, 2); h_nvnTextureBuilderSetFormat(&ab, NVN_FORMAT_RGBA8UI); h_nvnTextureBuilderSetStorage(&ab, &tpool, 0);
    CHECK(h_nvnTextureInitialize(&alias, &ab), "an RGBA8UI texture over the same storage initialized");
    for (int pass = 0; pass < 2; pass++) {
        const char *how = pass ? "into a new texture" : "into the spare";
        if (pass && pk->spare) { defer_obj_release(pk->spare); pk->spare = nil; pk->spare_stamp = 0; pk->spare_seq = 0; }   // no spare: the re-upload copies the rest from the texture it replaces
        int layer = pass ? 6 : 7, other = pass ? 0 : 2;
        CHECK(gpu_copy(&alias, layer, 16 + 8 * pass, 16, 32, 32, (uint8_t)(0x77 + pass)), "a GPU copy into the other texture object runs");
        CHECK(pk->stored == 0, "this texture's record does not see the other object's store");
        CHECK(storage_layer_ok(layer), "the other object's copy reached the shared storage");
        write_region(0, other, 40, 40, 12, 12, (uint8_t)(0x5a + pass)); pr0 = g_part_reuploads; rr0 = g_pkg_reuploads; id<MTLTexture> sp = pk->spare;
        char lb[96]; snprintf(lb, sizeof lb, "other object's store, re-upload %s", how);
        CHECK(readback_ok(lb), "after the other object's GPU copy and a CPU write into another layer, the re-upload carries the storage's copy");
        CHECK(g_pkg_reuploads == rr0 + 1 && (pass ? sp == nil : pk->tex == sp), pass ? "one re-upload, into a new texture" : "one re-upload, into the spare");
        printf("re-upload %s after the other object's store: %s\n", how, g_part_reuploads == pr0 ? "whole" : "partial");
        if (part_on) CHECK(g_part_reuploads == pr0 + 1, "still partial: only the layers written on the CPU or stored into on the GPU are deswizzled");
    }
    h_nvnTextureFinalize(&alias);
    printf("partial re-uploads %llu, levels of layers kept %llu / deswizzled %llu, %.2f MB kept; no-copy source buffers %llu\n", (unsigned long long)g_part_reuploads,
           (unsigned long long)g_part_kept, (unsigned long long)g_part_up, g_part_kept_bytes / 1048576.0, (unsigned long long)g_up_big_srcs);
    h_nvnTextureFinalize(&tex); h_nvnCommandBufferFinalize(&cmd); h_nvnMemoryPoolFinalize(&tpool); h_nvnMemoryPoolFinalize(&cpool); settle();
    printf("t_texels_layers: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
