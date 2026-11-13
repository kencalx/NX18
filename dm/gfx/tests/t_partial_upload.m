// Uploads of a texture taken from guest memory (nvn_mtl.m pkg_upload_), whole and partial (part_reupload_on: a re-upload deswizzles the images, a layer's level, whose pages were written
// since and copies the others from the texture it builds on), through the production lookup (tex_mtl): after each write every image of the texture the host returns is compared with a
// CPU reference, and a whole upload must count the bytes of every image as its Metal texture holds it. Run three ways: the staged GPU deswizzle, with the direct path allowed, and the
// CPU deswizzle. Upstream NXNative's t_partial_upload (d2556cff, 1D array cases from 1f35a05b), adapted to this fork's partial re-upload (kept / total_up, the spare or the texture it
// replaces) and its Metal 4 test helpers. A 1D array (NVN target 3) is one row a layer: PRAGMATA's light-profile lookup table, a 512-wide R16F 1D array of 64 layers, went up as 64 rows
// a layer into one-row slices, which Metal's API validation refuses (`(destinationOrigin.y + sourceSize.height)(64) must be <= height(1)`) and which without it wrote past each slice
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
static const char *g_case = "", *g_mode = "";
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (%s): %s (line %d)\n", g_case, g_mode, label, __LINE__); } } while (0)
// The submission has run and the upload batch's feedback has come back (a re-upload builds on a texture only once its batch has: up_seq_back)
static void finish(void) { CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completes"); CHECK(!mtl_last_commit_error(), "GPU has no submission error"); up_wait_zero(&g_up_pending, WS_DIAG); }

typedef struct {
    tex_t t; pool_t pool; void *mem; size_t poolsize;
    unsigned levels, layers, bpb, bw, bh; int d3;
    size_t bytes, *at, *len;   // per image (level * layers + layer): its place in the linear reference and its size as the Metal texture holds it
    uint8_t *expected; unsigned fill;
} fix_t;
static unsigned img(const fix_t *f, unsigned l, unsigned a) { return l * f->layers + a; }
// An image's size from the NVN description alone, as the reference holds it: a 1D array's level is one row
static void geom(const fix_t *f, unsigned l, unsigned *w, unsigned *h, unsigned *z, size_t *pitch, size_t *rows) {
    *w = MAX(f->t.d.width >> l, 1u); *h = f->t.d.target == NVN_TEXTURE_TARGET_1D_ARRAY ? 1 : MAX(f->t.d.height >> l, 1u); *z = f->d3 ? MAX(f->t.d.depth >> l, 1u) : 1;
    *pitch = (size_t)((*w + f->bw - 1) / f->bw) * f->bpb; *rows = (*h + f->bh - 1) / f->bh;
}
static fix_t *make(int target, NVNformat format, unsigned w, unsigned h, unsigned depth, unsigned levels, size_t source_offset) {
    static uint64_t serial = 97000;
    fix_t *f = calloc(1, sizeof *f); int bw, bh;
    f->t = (tex_t){.magic = MAGIC('T','E','X',0), .has_layout = 1, .serial = serial++};
    f->t.d = (nvn_texdesc){.target = target, .format = format, .width = w, .height = h, .depth = depth, .levels = levels, .samples = 1};
    nvn_tex_layout(&f->t.d, &f->t.L);
    f->bpb = (unsigned)nvn_fmt_bpb(format, &bw, &bh); f->bw = (unsigned)bw; f->bh = (unsigned)bh;
    f->d3 = target == NVN_TEXTURE_TARGET_3D; f->levels = levels;
    f->layers = target == NVN_TEXTURE_TARGET_2D_ARRAY || target == NVN_TEXTURE_TARGET_CUBEMAP_ARRAY ? depth : target == NVN_TEXTURE_TARGET_CUBEMAP ? 6 : target == NVN_TEXTURE_TARGET_1D_ARRAY ? h : 1;   // a 1D array's height counts its layers
    unsigned n = levels * f->layers; f->at = calloc(n, sizeof *f->at); f->len = calloc(n, sizeof *f->len);
    for (unsigned l = 0; l < levels; l++) for (unsigned a = 0; a < f->layers; a++) {
        unsigned lw, lh, lz; size_t pitch, rows; geom(f, l, &lw, &lh, &lz, &pitch, &rows);
        unsigned i = img(f, l, a); f->at[i] = f->bytes; f->len[i] = pitch * rows * lz; f->bytes += f->len[i];
    }
    size_t pg = (size_t)getpagesize(); f->poolsize = (f->t.L.size + source_offset + pg + pg - 1) & ~(pg - 1);
    if (posix_memalign(&f->mem, pg, f->poolsize)) abort();
    memset(f->mem, 0, f->poolsize);
    f->pool = (pool_t){.magic = MAGIC('P','O','O','L'), .mem = f->mem, .size = f->poolsize, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    f->t.pool = &f->pool; f->t.mem = (uint8_t *)f->mem + source_offset;
    mtl_pool_add(f->mem, f->poolsize); nvn_dirty_add_range(f->mem, f->poolsize);
    f->expected = malloc(f->bytes);
    return f;
}
static void drop(fix_t *f) {
    mtl_tex_release(&f->t); mtl_drain(); mtl_alias_drop_pool(&f->pool); nvn_dirty_remove_range(f->mem); mtl_pool_del(f->mem); mtl_drain();
    free(f->mem); free(f->expected); free(f->at); free(f->len); free(f);
}
// The game writes one image: new bytes in the reference, swizzled into the storage, its pages counted as written
static void write_image(fix_t *f, unsigned l, unsigned a) {
    unsigned i = img(f, l, a), w, h, z; size_t pitch, rows; geom(f, l, &w, &h, &z, &pitch, &rows);
    uint8_t *p = f->expected + f->at[i]; unsigned k = ++f->fill;
    for (size_t b = 0; b < f->len[i]; b++) p[b] = (uint8_t)(b * 131u + (b >> 8) * 17u + a * 29u + l * 71u + k * 83u);
    uint64_t lo = (uint64_t)a * f->t.L.layer_size + nvn_tex_level_offset(&f->t.d, l), hi = (uint64_t)a * f->t.L.layer_size + (l + 1 < f->levels ? nvn_tex_level_offset(&f->t.d, l + 1) : f->t.L.layer_size);
    dm_guest_write_prepare((uint8_t *)f->t.mem + lo, hi - lo);
    CHECK(!nvn_swizzle(&f->t.d, l, a, p, (uint32_t)pitch, f->t.mem), "reference swizzle succeeds");
}
static int content_ok(fix_t *f, id<MTLTexture> image) {
    if (!image) return 0;
    id<MTLBuffer> rb = [g_dev newBufferWithLength:f->bytes + 512 options:MTLResourceStorageModeShared]; if (!rb) return 0;
    memset(rb.contents, 0xcd, rb.length);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> ce = t4_copy(cb); t4_use(cb, image); t4_use(cb, rb);
    for (unsigned l = 0; l < f->levels; l++) for (unsigned a = 0; a < f->layers; a++) {
        unsigned w, h, z; size_t pitch, rows; geom(f, l, &w, &h, &z, &pitch, &rows);
        [ce copyFromTexture:image sourceSlice:a sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, z) toBuffer:rb destinationOffset:256 + f->at[img(f, l, a)] destinationBytesPerRow:pitch destinationBytesPerImage:pitch * rows];
    }
    t4_end(cb, ce); t4_wait(cb);
    if (cb->status != MTLCommandBufferStatusCompleted) return 0;
    int sh = rb_packed_shift(f->t.d.format);   // Metal's order of a packed 16-bit format, back to the guest's
    if (sh) for (unsigned l = 0; l < f->levels; l++) for (unsigned a = 0; a < f->layers; a++) { unsigned w, h, z; size_t pitch, rows; geom(f, l, &w, &h, &z, &pitch, &rows);
        rb_swap_rows((uint8_t *)rb.contents + 256 + f->at[img(f, l, a)], pitch, rows, z, pitch, pitch * rows, sh); }
    int ok = !memcmp((uint8_t *)rb.contents + 256, f->expected, f->bytes) && ((uint8_t *)rb.contents)[255] == 0xcd && ((uint8_t *)rb.contents)[256 + f->bytes] == 0xcd;
    if (!ok) for (unsigned i = 0; i < f->levels * f->layers; i++) if (memcmp((uint8_t *)rb.contents + 256 + f->at[i], f->expected + f->at[i], f->len[i])) fprintf(stderr, "  %s (%s): level %u layer %u differs\n", g_case, g_mode, i / f->layers, i % f->layers);
    return ok;
}
// One look in a submission of its own. whole: every image is expected read from guest memory, as many bytes as the Metal texture holds; otherwise at most that, and fewer when the
// re-upload was partial
static id<MTLTexture> look(fix_t *f, int whole, const char *what) {
    uint64_t b0 = mtl_upload_bytes(), r0 = g_pkg_reuploads, p0 = g_part_reuploads;
    mtl_sub_begin(); id<MTLTexture> image = tex_mtl(&f->t); finish();
    uint64_t read = mtl_upload_bytes() - b0; int part = g_part_reuploads != p0;
    char label[200];
    snprintf(label, sizeof label, "%s: resolves", what); CHECK(image != nil, label);
    if (whole || !part) { snprintf(label, sizeof label, "%s: read %llu bytes, the texture holds %zu", what, (unsigned long long)read, f->bytes); CHECK(read == f->bytes, label); }
    else { snprintf(label, sizeof label, "%s: partial, read %llu bytes of %zu", what, (unsigned long long)read, f->bytes); CHECK(read > 0 && read < f->bytes, label); }
    snprintf(label, sizeof label, "%s: counted as one re-upload", what); CHECK(g_pkg_reuploads == r0 + 1 || (whole && g_pkg_reuploads == r0), label);
    snprintf(label, sizeof label, "%s: every image holds the reference", what); CHECK(image && content_ok(f, image), label);
    return image;
}
static unsigned g_partials;   // re-uploads made partial in this mode (the copies of kept images went up as the Metal texture holds them)
static void run(const char *name, int target, NVNformat format, unsigned w, unsigned h, unsigned depth, unsigned levels, size_t source_offset) {
    g_case = name;
    fix_t *f = make(target, format, w, h, depth, levels, source_offset);
    unsigned last = f->layers - 1, mid = f->layers / 2, top = levels - 1;
    for (unsigned l = 0; l < levels; l++) for (unsigned a = 0; a < f->layers; a++) write_image(f, l, a);
    uint64_t p0 = g_part_reuploads;
    id<MTLTexture> first = look(f, 1, "first upload");
    write_image(f, 0, mid);
    id<MTLTexture> second = look(f, 0, "one image written");
    CHECK(second != first, "the texture in-flight draws read is not written");
    mtl_sub_begin(); CHECK(tex_mtl(&f->t) == second, "unchanged storage keeps its texture"); finish();
    write_image(f, top, last);
    id<MTLTexture> third = look(f, 0, "another image written");
    CHECK(third == first, "the idle spare is written");
    if (f->layers > 1) { write_image(f, 0, 0); write_image(f, top, mid); look(f, 0, "two images written"); }
    // Two looks in one submission: the second texture may not build on the first, whose copies are in the same open batch
    mtl_sub_begin();
    write_image(f, 0, last); id<MTLTexture> a = tex_mtl(&f->t);
    write_image(f, top, 0); id<MTLTexture> b = tex_mtl(&f->t);
    finish();
    CHECK(a && b && a != b, "a look after another write in the same submission takes another texture");
    CHECK(content_ok(f, b), "two re-uploads in one submission: every image holds the reference");
    write_image(f, 0, mid); look(f, 0, "one image written after two in one submission");
    for (unsigned l = 0; l < levels; l++) for (unsigned y = 0; y < f->layers; y++) write_image(f, l, y);
    look(f, 1, "every image written");
    // A 1D array's own partial re-uploads: its kept layers are copied from the texture built on, one row each (up_tcopy_add's size from tex_lsize); the total over all cases below would
    // still pass if 1D arrays stopped being re-uploaded partly, and this case would no longer test those copies
    if (g_nvn_deswz_gpu && part_reupload_on() && target == NVN_TEXTURE_TARGET_1D_ARRAY) CHECK(g_part_reuploads > p0, "a 1D array's re-uploads are partial (kept layers copied one row each)");
    g_partials += (unsigned)(g_part_reuploads - p0);
    printf("t_partial_upload: %s (%s): %u levels x %u layers, %zu bytes, %llu partial re-uploads\n", name, g_mode, levels, f->layers, f->bytes, (unsigned long long)(g_part_reuploads - p0));
    drop(f);
}
int main(void) { @autoreleasepool {
    mtl_init();
    int gpu = g_nvn_deswz_gpu;
    CHECK(gpu, "the GPU deswizzle pipeline loads");
    static const char *modes[] = {"GPU deswizzle", "GPU deswizzle, direct path allowed", "CPU deswizzle"};
    for (int mode = 0; mode < 3; mode++) {
        g_mode = modes[mode]; g_direct_upload_on = mode == 1; g_nvn_deswz_gpu = mode < 2 ? gpu : 0; g_partials = 0;
        run("R16 array", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_R16, 256, 192, 8, 1, 0);
        run("R16 array beside other data", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_R16, 256, 192, 8, 1, 4096);
        run("RGBA8 array with levels", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_RGBA8, 200, 120, 5, 6, 0);
        run("BC7 array with levels", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_BPTC_UNORM, 256, 256, 3, 5, 4096);
        run("RGBA8 cube with levels", NVN_TEXTURE_TARGET_CUBEMAP, NVN_FORMAT_RGBA8, 128, 128, 1, 5, 0);
        run("RGBA8 3D with levels", NVN_TEXTURE_TARGET_3D, NVN_FORMAT_RGBA8, 64, 64, 32, 4, 0);
        run("RGB565 array", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_RGB565, 256, 128, 4, 1, 0);
        // PRAGMATA's light-profile LUT: a 1D array is one row a layer; uploaded as height rows a layer, it was refused by validation and wrote past each slice without it
        run("R16F 1D array", NVN_TEXTURE_TARGET_1D_ARRAY, NVN_FORMAT_R16F, 512, 64, 1, 1, 0);
        run("RGBA8 1D array with levels", NVN_TEXTURE_TARGET_1D_ARRAY, NVN_FORMAT_RGBA8, 256, 8, 1, 4, 4096);
        if (mode < 2 && part_reupload_on()) CHECK(g_partials > 0, "the GPU modes made partial re-uploads (kept images copied from the texture built on)");
        if (mode == 2) CHECK(g_partials == 0, "the CPU deswizzle uploads whole");
    }
    g_nvn_deswz_gpu = gpu;
    printf("t_partial_upload: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
