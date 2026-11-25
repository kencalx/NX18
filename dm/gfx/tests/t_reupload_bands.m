// Coalesced re-uploads of a texture taken from guest memory (nvn_mtl.m reup_coalesce_on; DM_NVN_REUPLOAD_COALESCE=0 is the old behaviour): banded re-uploads (only the block-row bands of
// an image whose storage was written since are deswizzled, the other bands kept from the texture it replaces or in the spare it goes into) and deferred ones (a use in a submission
// re-uploads only the writes the game made before it submitted that submission: mtl_sub_cpu_limit, nvn_dirty_needed). Through the production lookup (tex_mtl), as a draw's bind resolves a
// texture: every texture a lookup returns is read back whole and compared with what the game had written by that submission's submit, so a draw reads exactly what the game wrote before
// it, never less. Ocarina of Time re-uploaded a whole single-level atlas several times a frame for a few written pages (NX18-X2.0 oot-alldata-analysis.md, fix 4)
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
static void finish(void) { CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completes"); CHECK(!mtl_last_commit_error(), "GPU has no submission error"); up_wait_zero(&g_up_pending, WS_DIAG); }
static int g_on;   // reup_coalesce_on() in this run

typedef struct {
    tex_t t; pool_t pool; void *mem; size_t poolsize;
    unsigned levels, layers, bpb, bw, bh;
    size_t bytes, *at, *len;   // per image (level * layers + layer): its place in the linear reference
    uint8_t *ref;   // what the game has written so far (linear, every image)
    unsigned fill;
} fix_t;
static unsigned img(const fix_t *f, unsigned l, unsigned a) { return l * f->layers + a; }
static void geom(const fix_t *f, unsigned l, unsigned *w, unsigned *h, size_t *pitch, size_t *rows) {
    *w = MAX(f->t.d.width >> l, 1u); *h = MAX(f->t.d.height >> l, 1u);
    *pitch = (size_t)((*w + f->bw - 1) / f->bw) * f->bpb; *rows = (*h + f->bh - 1) / f->bh;
}
static fix_t *make(int target, NVNformat format, unsigned w, unsigned h, unsigned depth, unsigned levels, void *share) {
    static uint64_t serial = 98000;
    fix_t *f = calloc(1, sizeof *f); int bw, bh;
    f->t = (tex_t){.magic = MAGIC('T','E','X',0), .has_layout = 1, .serial = serial++};
    f->t.d = (nvn_texdesc){.target = target, .format = format, .width = w, .height = h, .depth = depth, .levels = levels, .samples = 1};
    nvn_tex_layout(&f->t.d, &f->t.L);
    f->bpb = (unsigned)nvn_fmt_bpb(format, &bw, &bh); f->bw = (unsigned)bw; f->bh = (unsigned)bh; f->levels = levels;
    f->layers = target == NVN_TEXTURE_TARGET_2D_ARRAY ? depth : target == NVN_TEXTURE_TARGET_CUBEMAP ? 6 : 1;
    unsigned n = levels * f->layers; f->at = calloc(n, sizeof *f->at); f->len = calloc(n, sizeof *f->len);
    for (unsigned l = 0; l < levels; l++) for (unsigned a = 0; a < f->layers; a++) {
        unsigned lw, lh; size_t pitch, rows; geom(f, l, &lw, &lh, &pitch, &rows);
        unsigned i = img(f, l, a); f->at[i] = f->bytes; f->len[i] = pitch * rows; f->bytes += f->len[i];
    }
    f->ref = calloc(1, f->bytes);
    if (share) { f->mem = share; f->t.mem = share; return f; }   // another texture object over the same storage (another description: another record)
    size_t pg = (size_t)getpagesize(); f->poolsize = (f->t.L.size + pg + pg - 1) & ~(pg - 1);
    if (posix_memalign(&f->mem, pg, f->poolsize)) abort();
    memset(f->mem, 0, f->poolsize);
    f->pool = (pool_t){.magic = MAGIC('P','O','O','L'), .mem = f->mem, .size = f->poolsize, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    f->t.pool = &f->pool; f->t.mem = f->mem;
    mtl_pool_add(f->mem, f->poolsize); nvn_dirty_add_range(f->mem, f->poolsize);
    return f;
}
static void drop(fix_t *f, int owner) {
    mtl_tex_release(&f->t); mtl_drain();
    if (owner) { mtl_alias_drop_pool(&f->pool); nvn_dirty_remove_range(f->mem); mtl_pool_del(f->mem); mtl_drain(); free(f->mem); }
    free(f->ref); free(f->at); free(f->len); free(f);
}
// The game writes block rows [r0, r1) of one image: new bytes in the reference, and into the storage only the bytes that change (a swizzle of the image into a copy, compared), each
// changed run's pages counted as written as a host write counts them (dm_guest_write_prepare)
static void write_rows(fix_t *f, unsigned l, unsigned a, unsigned r0, unsigned r1) {
    unsigned i = img(f, l, a), w, h; size_t pitch, rows; geom(f, l, &w, &h, &pitch, &rows);
    if (r1 > rows) r1 = (unsigned)rows;
    uint8_t *p = f->ref + f->at[i]; unsigned k = ++f->fill;
    for (size_t b = r0 * pitch; b < r1 * pitch; b++) p[b] = (uint8_t)(b * 131u + (b >> 8) * 17u + a * 29u + l * 71u + k * 83u + 1);
    uint8_t *tmp = malloc(f->t.L.size); memcpy(tmp, f->t.mem, f->t.L.size);
    CHECK(!nvn_swizzle(&f->t.d, l, a, p, (uint32_t)pitch, tmp), "reference swizzle succeeds");
    for (size_t o = 0; o < f->t.L.size; ) {
        if (tmp[o] == ((uint8_t *)f->t.mem)[o]) { o++; continue; }
        size_t e = o; while (e < f->t.L.size && tmp[e] != ((uint8_t *)f->t.mem)[e]) e++;
        dm_guest_write_prepare((uint8_t *)f->t.mem + o, e - o); memcpy((uint8_t *)f->t.mem + o, tmp + o, e - o); o = e;
    }
    free(tmp);
}
static void write_image(fix_t *f, unsigned l, unsigned a) { unsigned w, h; size_t pitch, rows; geom(f, l, &w, &h, &pitch, &rows); write_rows(f, l, a, 0, (unsigned)rows); }
// Every image of the texture against `want` (a snapshot of the reference)
static int content_either(fix_t *f, id<MTLTexture> image, const uint8_t *want, const uint8_t *or_now);
static int content_is(fix_t *f, id<MTLTexture> image, const uint8_t *want) { return content_either(f, image, want, want); }
// Every byte as `want` or as `or_now`: a re-upload's deswizzle reads the storage when its batch runs (pkg_upload_), so a write made since the submission's submit may be seen early, as a
// console GPU that had not run it yet would; what was written before it never lacks
static int content_either(fix_t *f, id<MTLTexture> image, const uint8_t *want, const uint8_t *or_now) {
    if (!image) return 0;
    id<MTLBuffer> rb = [g_dev newBufferWithLength:f->bytes + 512 options:MTLResourceStorageModeShared]; if (!rb) return 0;
    memset(rb.contents, 0xcd, rb.length);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> ce = t4_copy(cb); t4_use(cb, image); t4_use(cb, rb);
    for (unsigned l = 0; l < f->levels; l++) for (unsigned a = 0; a < f->layers; a++) {
        unsigned w, h; size_t pitch, rows; geom(f, l, &w, &h, &pitch, &rows);
        [ce copyFromTexture:image sourceSlice:a sourceLevel:l sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:rb destinationOffset:256 + f->at[img(f, l, a)] destinationBytesPerRow:pitch destinationBytesPerImage:pitch * rows];
    }
    t4_end(cb, ce); t4_wait(cb);
    if (cb->status != MTLCommandBufferStatusCompleted) return 0;
    const uint8_t *got = (const uint8_t *)rb.contents + 256; int ok = 1;
    for (size_t i = 0; i < f->bytes && ok; i++) ok = got[i] == want[i] || got[i] == or_now[i];
    if (!ok) for (unsigned i = 0; i < f->levels * f->layers; i++) {
        unsigned w, h; size_t pitch, rows; geom(f, i / f->layers, &w, &h, &pitch, &rows); size_t b = 0; while (b < f->len[i] && (got[f->at[i] + b] == want[f->at[i] + b] || got[f->at[i] + b] == or_now[f->at[i] + b])) b++;
        if (b == f->len[i]) continue;
        fprintf(stderr, "  %s (%s): level %u layer %u differs from block row %zu\n", g_case, g_mode, i / f->layers, i % f->layers, b / pitch); }
    return ok;
}
static uint8_t *snap(const fix_t *f) { uint8_t *s = malloc(f->bytes); memcpy(s, f->ref, f->bytes); return s; }
// A submission the game made when the reference was `want` (its dirty clock then: lim); the lookups in it as a draw's binds
typedef struct { uint64_t lim; uint8_t *want; } sub_t;
static sub_t submit(const fix_t *f) { return (sub_t){nvn_dirty_now(), snap(f)}; }
static void begin(const sub_t *s) { mtl_sub_begin(); if (s) mtl_sub_cpu_limit(s->lim); }
static void end(sub_t *s) { (void)s; finish(); mtl_sub_cpu_limit(UINT64_MAX); }   // the upload batch runs with the submission: a texture is read back after it
static void done(sub_t *s) { free(s->want); s->want = NULL; }
static id<MTLTexture> look(fix_t *f, const sub_t *s, const char *what) {
    id<MTLTexture> image = tex_mtl(&f->t); char label[200];
    snprintf(label, sizeof label, "%s: resolves", what); CHECK(image != nil, label);
    return image;
}
static void holds(fix_t *f, id<MTLTexture> image, const uint8_t *want, const char *what) {
    char label[200]; snprintf(label, sizeof label, "%s: every image holds what the game wrote before its submission", what); CHECK(content_either(f, image, want, f->ref), label);
}

// Banded: a few rows of a large single-level image, the first re-upload copying the clean bands from the texture it replaces, the next going into the spare; then rows in two bands
// apart, then rows of an array's layers and levels beside whole images kept
static void banded(const char *name, int target, NVNformat format, unsigned w, unsigned h, unsigned depth, unsigned levels) {
    g_case = name;
    fix_t *f = make(target, format, w, h, depth, levels, NULL);
    for (unsigned l = 0; l < levels; l++) for (unsigned a = 0; a < f->layers; a++) write_image(f, l, a);
    mtl_sub_begin(); id<MTLTexture> t0 = look(f, NULL, "first upload"); end(NULL); holds(f, t0, f->ref, "first upload");
    unsigned w0, h0; size_t pitch, rows; geom(f, 0, &w0, &h0, &pitch, &rows);
    unsigned mid = f->layers / 2;
    struct { unsigned l, a, r0, r1, r2, r3; const char *what; } steps[] = {
        {0, mid, (unsigned)rows / 2 + 3, (unsigned)rows / 2 + 7, 0, 0, "a few rows of level 0 (from the texture it replaces)"},
        {0, mid, 1, 2, 0, 0, "one row at the top (into the spare)"},
        {0, mid, 0, 2, (unsigned)rows - 2, (unsigned)rows, "rows in the first and last bands"},
        {levels > 1 ? 1u : 0u, f->layers - 1, 0, 3, 0, 0, "rows of a smaller level in the last layer"},
    };
    for (unsigned i = 0; i < sizeof steps / sizeof *steps; i++) {
        uint64_t b0 = mtl_upload_bytes(), r0 = g_pkg_reuploads, n0 = g_band_reuploads;
        write_rows(f, steps[i].l, steps[i].a, steps[i].r0, steps[i].r1);
        if (steps[i].r3) write_rows(f, steps[i].l, steps[i].a, steps[i].r2, steps[i].r3);
        mtl_sub_begin(); id<MTLTexture> t = look(f, NULL, steps[i].what); end(NULL);
        holds(f, t, f->ref, steps[i].what);
        CHECK(g_pkg_reuploads == r0 + 1, "one re-upload");
        uint64_t read = mtl_upload_bytes() - b0; char label[240];
        int banded_now = g_band_reuploads != n0;
        if (g_on && g_nvn_deswz_gpu && part_reupload_on() && i < 3) { snprintf(label, sizeof label, "%s: banded, read %llu of %zu bytes", steps[i].what, (unsigned long long)read, f->bytes); CHECK(banded_now && read < pitch * rows, label); }
        if (!g_on) CHECK(!banded_now, "nothing banded with the switch off");
    }
    // Every band of an image written: whole image, still correct
    write_image(f, 0, 0); mtl_sub_begin(); id<MTLTexture> t = look(f, NULL, "a whole image written"); end(NULL); holds(f, t, f->ref, "a whole image written");
    printf("t_reupload_bands: %s (%s): %ux%u x %u layers, %u levels, %zu bytes; banded re-uploads %llu so far, %.1f MB kept\n", name, g_mode, w, h, f->layers, levels, f->bytes,
           (unsigned long long)g_band_reuploads, g_band_kept_bytes / 1048576.0);
    drop(f, 1);
}

// Deferred: the replay runs behind the game. Submissions A, B, C made with writes between them; each lookup must hold exactly what was written before its submission's submit, and a
// write made after a submission was submitted (the game ahead, or a write landing between two draws of the submission being replayed) does not re-upload in it
static void deferred(const char *name, NVNformat format, unsigned w, unsigned h) {
    g_case = name;
    fix_t *f = make(NVN_TEXTURE_TARGET_2D, format, w, h, 1, 1, NULL);
    write_image(f, 0, 0);
    mtl_sub_begin(); id<MTLTexture> t0 = look(f, NULL, "first upload"); end(NULL);
    size_t pitch, rows; unsigned lw, lh; geom(f, 0, &lw, &lh, &pitch, &rows);
    // The game: submits A, writes, submits B, writes twice, submits C, then writes again (for a later submission)
    sub_t a = submit(f);
    write_rows(f, 0, 0, 2, 4);
    sub_t b = submit(f);
    write_rows(f, 0, 0, (unsigned)rows / 2, (unsigned)rows / 2 + 1); write_rows(f, 0, 0, (unsigned)rows - 3, (unsigned)rows - 1);
    sub_t c = submit(f);
    write_rows(f, 0, 0, 5, 6);
    uint8_t *after = snap(f);
    // The replay: A's draws read what was there before the writes
    uint64_t r0 = g_pkg_reuploads, d0 = g_reup_deferred;
    begin(&a); id<MTLTexture> ta = look(f, &a, "submission A"), ta2 = look(f, &a, "submission A, second draw");
    end(&a); holds(f, ta, a.want, "submission A"); if (g_on) CHECK(content_is(f, ta, a.want), "A reads exactly what was written before it"); done(&a);
    if (g_on) { CHECK(g_pkg_reuploads == r0 && ta == t0 && ta2 == ta, "A keeps its texture: every write came after its submit"); CHECK(g_reup_deferred > d0, "A's re-upload counted as deferred"); }
    else CHECK(g_pkg_reuploads == r0 + 1, "switch off: A re-uploads");
    // B: the write before its submit; one re-upload, and a write landing between B's draws waits for a later submission
    r0 = g_pkg_reuploads;
    begin(&b); id<MTLTexture> tb = look(f, &b, "submission B");
    uint64_t r1 = g_pkg_reuploads;
    write_rows(f, 0, 0, 7, 8);   // the game writes while B is replayed (after B's submit)
    id<MTLTexture> tb2 = look(f, &b, "submission B, after a write between its draws");
    end(&b);
    holds(f, tb, b.want, "submission B");
    if (g_on) { holds(f, tb2, b.want, "submission B's second draw"); CHECK(tb2 == tb && g_pkg_reuploads == r1, "a write after B's submit does not re-upload within B"); CHECK(r1 == r0 + 1, "B re-uploads once"); }
    done(&b);
    // C: its two writes came before the replay began, so B's re-upload read them already (the storage as it was then): C has nothing to re-upload, and the write made during B's
    // replay came after C's submit, so it waits too. A draw in C may see what came after its submit early (as on the console), never lack what came before
    uint8_t *now_ref = snap(f);
    r0 = g_pkg_reuploads;
    begin(&c); id<MTLTexture> tc = look(f, &c, "submission C"), tc2 = look(f, &c, "submission C, second draw");
    if (g_on) CHECK(g_pkg_reuploads == r0 && tc2 == tc && tc == tb, "C needs nothing B's re-upload did not read");
    end(&c);
    CHECK(content_either(f, tc, c.want, now_ref), "submission C holds every write before it"); done(&c);
    // D, submitted after the write made during B's replay: one re-upload for it, then E with nothing written since: none
    sub_t d = submit(f); r0 = g_pkg_reuploads;
    begin(&d); id<MTLTexture> td = look(f, &d, "submission D"); end(&d); CHECK(content_is(f, td, d.want), "submission D holds the write made during B's replay"); CHECK(g_on ? g_pkg_reuploads == r0 + 1 : g_pkg_reuploads <= r0 + 1, "D re-uploads once (off: B's second draw re-uploaded it already)"); done(&d);
    sub_t e0 = submit(f); r0 = g_pkg_reuploads;
    begin(&e0); id<MTLTexture> te0 = look(f, &e0, "submission E"); end(&e0); holds(f, te0, e0.want, "submission E"); CHECK(g_pkg_reuploads == r0 && te0 == td, "nothing written since: no re-upload"); done(&e0);
    // Multiple writes in one frame, each before its own submission: every submission re-uploads (they each need their write)
    for (int k = 0; k < 4; k++) {
        write_rows(f, 0, 0, (unsigned)(k * 9) % (unsigned)rows, (unsigned)(k * 9) % (unsigned)rows + 1);
        sub_t e = submit(f); r0 = g_pkg_reuploads;
        begin(&e); id<MTLTexture> te = look(f, &e, "a frame's submission after its write"); end(&e); holds(f, te, e.want, "a frame's submission after its write"); CHECK(g_pkg_reuploads == r0 + 1, "a write before the submission re-uploads in it"); done(&e);
    }
    // Outside a queue submission (no limit): every write re-uploads at once
    write_rows(f, 0, 0, 1, 2); r0 = g_pkg_reuploads;
    mtl_sub_begin(); id<MTLTexture> tn = look(f, NULL, "no limit"); end(NULL); holds(f, tn, f->ref, "no limit"); CHECK(g_pkg_reuploads == r0 + 1, "no limit: re-uploads");
    // Texture-ID caches kept the deferred texture while the clock stood still: the next limit moves the clock (nvn_dirty_tick)
    sub_t g = submit(f); write_rows(f, 0, 0, 3, 4); sub_t h2 = submit(f);
    begin(&g); look(f, &g, "G (deferred)"); uint64_t clk = nvn_dirty_now(); end(&g); done(&g);
    begin(&h2); if (g_on) CHECK(nvn_dirty_now() != clk, "the clock moved at the next limit after a deferral"); id<MTLTexture> th = look(f, &h2, "H"); end(&h2); holds(f, th, h2.want, "H, after a deferral in G"); done(&h2);
    free(after); free(now_ref);
    drop(f, 1);
}

// Another upload's protect hides a write's time: X and Y (another description, another record) over the same storage. The game writes a page (before submission A), Y re-uploads and
// protects it again, the game writes the page again after A's submit: X's use in A must still re-upload (the first write is A's), not defer on the page's later generation
static void hidden(void) {
    g_case = "write hidden by another upload's protect";
    fix_t *x = make(NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 256, 256, 1, 1, NULL);
    fix_t *y = make(NVN_TEXTURE_TARGET_2D, NVN_FORMAT_R32UI, 256, 256, 1, 1, x->mem);
    y->t.pool = &x->pool;
    write_image(x, 0, 0);
    mtl_sub_begin(); look(x, NULL, "X first"); look(y, NULL, "Y first"); end(NULL);
    write_rows(x, 0, 0, 10, 12);   // before A
    sub_t a = submit(x);
    mtl_sub_begin(); look(y, NULL, "Y re-upload"); end(NULL);   // Y's re-upload protects the written pages again
    write_rows(x, 0, 0, 11, 12);   // after A, on the same page
    free(a.want); a.want = NULL;
    // A must hold the write before it: the reference minus the later write is not kept here; the later one may be seen early, so compare with the reference as it is now
    uint64_t r0 = g_pkg_reuploads;
    begin(&a); id<MTLTexture> t = look(x, &a, "X in A"); end(&a);
    CHECK(g_pkg_reuploads == r0 + 1, "X re-uploads in A: the page's first write since its upload was hidden");
    CHECK(content_is(x, t, x->ref), "X in A holds the write made before A");
    drop(y, 0); drop(x, 1);
}

int main(void) { @autoreleasepool {
    mtl_init();
    g_on = reup_coalesce_on();
    int gpu = g_nvn_deswz_gpu;
    CHECK(gpu, "the GPU deswizzle pipeline loads");
    static const char *modes[] = {"GPU deswizzle", "CPU deswizzle"};
    for (int mode = 0; mode < 2; mode++) {
        g_mode = modes[mode]; g_direct_upload_on = 0; g_nvn_deswz_gpu = mode == 0 ? gpu : 0;
        uint64_t nb = g_band_reuploads;
        banded("RGBA8 atlas", NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 1024, 1024, 1, 1);
        banded("BC7 atlas", NVN_TEXTURE_TARGET_2D, NVN_FORMAT_BPTC_UNORM, 2048, 2048, 1, 1);
        banded("RGBA8 array with levels", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_RGBA8, 512, 512, 4, 3);
        banded("R16 cube", NVN_TEXTURE_TARGET_CUBEMAP, NVN_FORMAT_R16, 512, 512, 1, 2);
        if (mode == 1) CHECK(g_band_reuploads == nb, "the CPU deswizzle uploads whole");
        deferred("deferred RGBA8", NVN_FORMAT_RGBA8, 512, 512);
        deferred("deferred BC1", NVN_FORMAT_RGBA_DXT1, 1024, 512);
        hidden();
    }
    g_nvn_deswz_gpu = gpu;
    printf("t_reupload_bands: coalescing %s; deferred %llu (%.1f MB), banded %llu (%llu images, %.1f MB kept); %d checks, %d failed\n", g_on ? "on" : "off",
           (unsigned long long)g_reup_deferred, g_reup_deferred_bytes / 1048576.0, (unsigned long long)g_band_reuploads, (unsigned long long)g_band_images, g_band_kept_bytes / 1048576.0, checks, failed);
    return failed != 0;
} }
