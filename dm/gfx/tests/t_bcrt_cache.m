// The shadow cache of render targets in depth and compressed textures (nvn_mtl.m bcrt_slot): a pass that draws into a D16 texture through an R16 view, or into a BC4 texture through
// an RGBA16UI view, draws into a colour shadow that its blocks are copied into before the pass and back out of after it. The cache used to be indexed by the attachment's number in the
// pass, so Luigi's Mansion 3, whose D16 shadow maps of 1024, 512 and 256 square are drawn one per pass, made the shadow of attachment 0 again about 3 times a frame. Now it is keyed by
// format and size. Each case clears its targets through the production replay (mtl_exec, one clear-only pass per target set: DM_NVN_LAZY_CLEAR=0 here, so a clear does not wait for
// a later pass) and reads every base texture back:
//   a. three D16 sizes cycled 20 times in one submission, then once in each of 3 more: 3 shadows made in all, and each base holds its own last value;
//   b. two D16 textures of one size attached in one pass: two shadows, both values land; the same pass again reuses both;
//   c. nine sizes cycled through the eight entries: least recently used entries go (behind the open submission's fence; with DM_RES_CHECK=1 nothing is released too early), values right;
//   d. a 32x32x32 BC4 3D texture through an RGBA16UI view, one pass per depth plane: 1 shadow, every plane's blocks right;
//   e. six 2048-wide D16 sizes, 16 MiB of shadow and buffer each: the cache keeps at most its 64 MiB, values right;
//   f. the idle trim and the memory trim: an entry whose last use is moved back past 5 s goes at the next submission's start and the others stay; then dm_gfx_trim (mtl_trim_at, as
//      going to the background does) lets every entry go: none left, 'retired' rises by them, the bytes kept fall to 0 and the trim returns at least their bytes.
// Case a also checks the residency site table (g_rs_site, the residency line's 'line N' counts): the res_add line of bcrt_slot adds 2 allocations per shadow made and no more, so
// the 6 of 3 shadows where the old cache added 2 per pass.
// With DM_NVN_BCRT_CACHE=0 (the old behaviour, by attachment number) the counts checked are the old ones: a shadow made at every change of size.
// Run by make check_t_bcrt_cache with DM_NVN_ENC_THREAD=0 and =1 under MTL_DEBUG_LAYER=1 DM_RES_CHECK=1, and once with DM_NVN_BCRT_CACHE=0
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL (line %d): ", __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

// A command list built record by record: {op, size including the header, 8-aligned} + payload, ending in OP_END
typedef struct { uint8_t *p; size_t n, cap; } ops_t;
static void op_put(ops_t *o, uint32_t op, const void *payload, size_t len) {
    size_t sz = (sizeof(op_hdr) + len + 7) & ~(size_t)7;
    if (o->n + sz > o->cap) { o->cap = (o->n + sz) * 2; o->p = realloc(o->p, o->cap); if (!o->p) abort(); }
    memset(o->p + o->n, 0, sz); op_hdr h = {op, (uint32_t)sz}; memcpy(o->p + o->n, &h, sizeof h);
    if (len) memcpy(o->p + o->n + sizeof h, payload, len);
    o->n += sz;
}
// Targets: n textures, each through a view of format fmt (and the one layer / depth plane layer[i] when layer[i] >= 0)
static void op_rt(ops_t *o, int n, tex_t *const *t, uint16_t fmt, const int *layer) {
    p_set_rt r = {.n = n};
    for (int i = 0; i < n; i++) { r.color[i] = t[i]; r.has_cview[i] = 1; r.cview[i].set_format = 1; r.cview[i].format = fmt;
        if (layer && layer[i] >= 0) { r.cview[i].set_layers = 1; r.cview[i].min_layer = (uint16_t)layer[i]; r.cview[i].nlayers = 1; } }
    op_put(o, OP_SET_RT, &r, sizeof r);
}
static void op_clear(ops_t *o, int index, float r, float g, float b, float a) {
    p_clear_color c = {.index = index, .mask = 0xf, .rgba = {r, g, b, a}};
    op_put(o, OP_CLEAR_COLOR, &c, sizeof c);
}
static void run(ops_t *o, const char *what) {
    op_put(o, OP_END, NULL, 0);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    mtl_exec(o->p); mtl_sub_commit(); mtl_drain();
    CHECK(!mtl_last_commit_error(), "%s: the submission completes without a GPU error", what);
    o->n = 0;
}
static float unorm16(uint16_t v) { return (float)(v / 65535.0); }   // the value whose R16 unorm conversion is exactly v

// A texture of the host's own making (tex_desc), known to the replay by its serial
static id<MTLTexture> mk_tex(tex_t *t, uint64_t serial, int target, uint32_t format, int w, int h, int d) {
    memset(t, 0, sizeof *t); t->magic = MAGIC('T','E','X',0); t->serial = serial;
    t->d = (nvn_texdesc){.target = target, .format = format, .width = w, .height = h, .depth = d, .levels = 1, .samples = 1};
    MTLTextureDescriptor *desc = tex_desc(t, 0); id<MTLTexture> m = desc ? [g_dev newTextureWithDescriptor:desc] : nil;
    if (!m) { fprintf(stderr, "FAIL: cannot make a %dx%dx%d texture of NVN format %#x\n", w, h, d, format); exit(1); }
    res_add(m); mtl_tex_init(t); serial_put(t->serial, m);
    return m;
}
// One plane (z) of level 0 copied into a shared buffer: rows of row bytes, h rows (in blocks for a compressed format)
static id<MTLBuffer> read_back(id<MTLTexture> m, NSUInteger z, NSUInteger row, NSUInteger rows) {
    id<MTLBuffer> out = [g_dev newBufferWithLength:row * rows options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); t4_use(cb, m); t4_use(cb, out);
    id<MTL4ComputeCommandEncoder> b = t4_copy(cb);
    [b copyFromTexture:m sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, z) sourceSize:MTLSizeMake(m.width, m.height, 1)
              toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * rows];
    t4_end(cb, b); t4_wait(cb);
    if (cb->status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "FAIL: read-back command buffer failed\n"); failed++; }
    return out;
}
// Every texel of a D16 texture holds want
static int d16_holds(id<MTLTexture> m, uint16_t want) {
    id<MTLBuffer> out = read_back(m, 0, m.width * 2, m.height); const uint16_t *v = out.contents;
    for (NSUInteger i = 0; i < m.width * m.height; i++) if (v[i] != want) { fprintf(stderr, "  %lux%lu D16: texel %lu holds %#x, want %#x\n", (unsigned long)m.width, (unsigned long)m.height, (unsigned long)i, v[i], want); return 0; }
    return 1;
}
static void counters_reset(void) { atomic_store(&g_bcrt_passes, 0); atomic_store(&g_bcrt_made, 0); atomic_store(&g_bcrt_reused, 0); atomic_store(&g_bcrt_retired, 0); }
static uint64_t made(void) { return atomic_load(&g_bcrt_made); }
static uint64_t reused(void) { return atomic_load(&g_bcrt_reused); }
static uint64_t passes(void) { return atomic_load(&g_bcrt_passes); }
static uint64_t retired(void) { return atomic_load(&g_bcrt_retired); }
static int entries(void) { int n = 0; for (int i = 0; i < BCRT_CACHE; i++) n += g_bcrtc[i].sh != nil; return n; }
// The additions the residency site table holds for bcrt_slot's res_add line since the last mtl_res_stats (which empties the table)
static uint64_t bcrt_site_adds(void) {
    uint64_t n = 0; pthread_mutex_lock(&g_res_mu);
    for (int k = 0; k < RS_SITES; k++) if (g_bcrt_res_line && g_rs_site[k].line == g_bcrt_res_line) n = g_rs_site[k].n;
    pthread_mutex_unlock(&g_res_mu); return n;
}
static void site_table_empty(void) { char rs[512]; mtl_res_stats(rs, sizeof rs); }   // also zeroes the shadow counters, as counters_reset does
// Between cases: every entry goes (no submission is open), so each case counts from an empty cache. With DM_NVN_BCRT_CACHE=0 nothing is trimmed, as before
static void cache_empty(void) { int n; bcrt_trim(0, g_fence, &n); counters_reset(); }

int main(void) { @autoreleasepool {
    setenv("DM_NVN_LAZY_CLEAR", "0", 1);   // a clear with no draw lands in a pass of its own at the next target change, so every clear is one shadow pass
    if (!MTLCreateSystemDefaultDevice()) { puts("t_bcrt_cache: no Metal device, skipped"); return 0; }
    mtl_init();
    int cache = bcrt_cache_on();
    printf("t_bcrt_cache: shadow cache %s (DM_NVN_BCRT_CACHE), encode thread %s, residency check %s\n", cache ? "by format and size" : "by attachment number (old)",
           getenv("DM_NVN_ENC_THREAD") ? getenv("DM_NVN_ENC_THREAD") : "default", g_res_check_on ? "on" : "off");
    ops_t o = {0}; uint64_t ser = 99701;

    // a. Three D16 sizes cycled, as Luigi's Mansion 3 draws its shadow maps
    {   enum { N = 3, CYCLES = 20 }; const int side[N] = {1024, 512, 256}; tex_t t[N]; id<MTLTexture> m[N]; tex_t *one[1];
        for (int i = 0; i < N; i++) m[i] = mk_tex(&t[i], ser++, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH16, side[i], side[i], 1);
        cache_empty(); site_table_empty();
        uint16_t last[N] = {0};
        for (int c = 0; c < CYCLES; c++) for (int i = 0; i < N; i++) { one[0] = &t[i]; op_rt(&o, 1, one, NVN_FORMAT_R16, NULL); last[i] = (uint16_t)(0x1000 * (i + 1) + c); op_clear(&o, 0, unorm16(last[i]), 0, 0, 1); }
        run(&o, "a: 20 cycles in one submission");
        uint64_t p1 = passes(), m1 = made();
        printf("a: one submission: %llu shadow passes, %llu shadows made, %llu reused\n", (unsigned long long)p1, (unsigned long long)m1, (unsigned long long)reused());
        CHECK(p1 >= N * CYCLES, "a: every clear is a shadow pass (%llu of %d)", (unsigned long long)p1, N * CYCLES);
        if (cache) CHECK(m1 == N, "a: one shadow per size within a submission (made %llu, want %d)", (unsigned long long)m1, N);
        else CHECK(m1 == p1, "a (old behaviour): a shadow made at every change of size (made %llu, passes %llu)", (unsigned long long)m1, (unsigned long long)p1);
        CHECK(m1 + reused() == p1, "a: every shadow attachment is made or reused (%llu + %llu of %llu)", (unsigned long long)m1, (unsigned long long)reused(), (unsigned long long)p1);
        // The symptom itself: the residency line's count for the shadows' res_add line. 2 per shadow made (its texture and its buffer): 6 here, where the old cache added 2 a pass
        uint64_t sa = bcrt_site_adds();
        printf("a: the residency line counts %llu additions at nvn_mtl.m line %d (bcrt_slot's res_add)\n", (unsigned long long)sa, g_bcrt_res_line);
        CHECK(sa == 2 * m1, "a: the shadows' res_add line adds 2 allocations per shadow made and no more (%llu, made %llu)", (unsigned long long)sa, (unsigned long long)m1);
        if (cache) CHECK(sa == 2 * N, "a: 6 additions to the residency set for 3 sizes cycled 20 times (%llu)", (unsigned long long)sa);
        for (int i = 0; i < N; i++) CHECK(d16_holds(m[i], last[i]), "a: the %d-square D16 texture holds its own last value after one submission", side[i]);
        for (int s = 0; s < 3; s++) {
            for (int i = 0; i < N; i++) { one[0] = &t[i]; op_rt(&o, 1, one, NVN_FORMAT_R16, NULL); last[i] = (uint16_t)(0x4000 + 0x800 * i + 0x10 * s); op_clear(&o, 0, unorm16(last[i]), 0, 0, 1); }
            run(&o, "a: one cycle per submission");
        }
        printf("a: and 3 more submissions: %llu shadow passes, %llu shadows made, %llu reused, %d entries\n", (unsigned long long)passes(), (unsigned long long)made(), (unsigned long long)reused(), entries());
        if (cache) CHECK(made() == N && retired() == 0, "a: still 3 shadows across submissions, none let go (made %llu, retired %llu)", (unsigned long long)made(), (unsigned long long)retired());
        for (int i = 0; i < N; i++) CHECK(d16_holds(m[i], last[i]), "a: the %d-square D16 texture holds its own last value across submissions", side[i]);
        for (int i = 0; i < N; i++) mtl_tex_release(&t[i]);
    }

    // b. Two attachments of one size in one pass, twice
    {   tex_t t[2]; id<MTLTexture> m[2]; tex_t *both[2] = {&t[0], &t[1]};
        for (int i = 0; i < 2; i++) m[i] = mk_tex(&t[i], ser++, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH16, 64, 64, 1);
        cache_empty();
        op_rt(&o, 2, both, NVN_FORMAT_R16, NULL); op_clear(&o, 0, unorm16(0x2222), 0, 0, 1); op_clear(&o, 1, unorm16(0x3333), 0, 0, 1);
        run(&o, "b: two attachments of one size");
        printf("b: %llu shadow passes, %llu shadows made, %llu reused\n", (unsigned long long)passes(), (unsigned long long)made(), (unsigned long long)reused());
        CHECK(made() == 2, "b: two attachments of one size get two shadows (made %llu)", (unsigned long long)made());
        CHECK(d16_holds(m[0], 0x2222) && d16_holds(m[1], 0x3333), "b: both attachments' values land");
        op_rt(&o, 2, both, NVN_FORMAT_R16, NULL); op_clear(&o, 0, unorm16(0x4444), 0, 0, 1); op_clear(&o, 1, unorm16(0x5555), 0, 0, 1);
        run(&o, "b: the same pass again");
        CHECK(made() == 2 && reused() == 2, "b: the same pass again reuses both shadows (made %llu, reused %llu)", (unsigned long long)made(), (unsigned long long)reused());
        CHECK(d16_holds(m[0], 0x4444) && d16_holds(m[1], 0x5555), "b: both attachments' second values land");
        for (int i = 0; i < 2; i++) mtl_tex_release(&t[i]);
    }

    // c. Nine sizes through eight entries: the least recently used goes, within and across submissions
    {   enum { N = 9, ROUNDS = 3 }; tex_t t[N]; id<MTLTexture> m[N]; tex_t *one[1]; uint16_t last[N] = {0};
        for (int i = 0; i < N; i++) m[i] = mk_tex(&t[i], ser++, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH16, 8 * (i + 1), 8 * (i + 1), 1);
        cache_empty();
        for (int r = 0; r < ROUNDS; r++) for (int i = 0; i < N; i++) { one[0] = &t[i]; op_rt(&o, 1, one, NVN_FORMAT_R16, NULL); last[i] = (uint16_t)(0x6000 + 0x100 * i + r); op_clear(&o, 0, unorm16(last[i]), 0, 0, 1); }
        run(&o, "c: nine sizes in one submission");
        for (int i = 0; i < N; i++) { one[0] = &t[i]; op_rt(&o, 1, one, NVN_FORMAT_R16, NULL); last[i] = (uint16_t)(0x7000 + 0x100 * i); op_clear(&o, 0, unorm16(last[i]), 0, 0, 1); }
        run(&o, "c: nine sizes in the next submission");
        printf("c: %llu shadow passes, %llu shadows made, %llu reused, %llu let go, %d entries\n", (unsigned long long)passes(), (unsigned long long)made(), (unsigned long long)reused(), (unsigned long long)retired(), entries());
        CHECK(made() > BCRT_CACHE, "c: more sizes than entries make shadows again (made %llu)", (unsigned long long)made());
        if (cache) CHECK(retired() == made() - BCRT_CACHE && entries() == BCRT_CACHE, "c: every shadow made past the eight entries let one go (made %llu, let go %llu, entries %d)",
                         (unsigned long long)made(), (unsigned long long)retired(), entries());
        for (int i = 0; i < N; i++) CHECK(d16_holds(m[i], last[i]), "c: the %d-square D16 texture holds its own last value", 8 * (i + 1));
        for (int i = 0; i < N; i++) mtl_tex_release(&t[i]);
    }

    // d. A BC4 3D texture encoded one depth plane per pass through an RGBA16UI view (Tears of the Kingdom): one pixel of the view is one 8-byte block
    {   enum { S = 32, B = S / 4 }; tex_t t; tex_t *one[1] = {&t};
        id<MTLTexture> m = mk_tex(&t, ser++, NVN_TEXTURE_TARGET_3D, NVN_FORMAT_RGTC1_UNORM, S, S, S);
        cache_empty();
        for (int z = 0; z < S; z++) { int layer[1] = {z}; op_rt(&o, 1, one, NVN_FORMAT_RGBA16UI, layer); op_clear(&o, 0, (float)(z + 1), (float)(z + 100), (float)(z + 1000), (float)(z + 10000)); }
        run(&o, "d: a BC4 3D texture, one pass per plane");
        printf("d: %llu shadow passes, %llu shadows made, %llu reused\n", (unsigned long long)passes(), (unsigned long long)made(), (unsigned long long)reused());
        CHECK(passes() >= S && made() == 1, "d: one shadow for every plane (passes %llu, made %llu)", (unsigned long long)passes(), (unsigned long long)made());
        int bad = 0;
        for (int z = 0; z < S && !bad; z++) {
            id<MTLBuffer> out = read_back(m, (NSUInteger)z, B * 8, B); const uint16_t *v = out.contents;
            for (int k = 0; k < B * B && !bad; k++) { const uint16_t want[4] = {(uint16_t)(z + 1), (uint16_t)(z + 100), (uint16_t)(z + 1000), (uint16_t)(z + 10000)};
                if (memcmp(v + 4 * k, want, 8)) { bad = 1; fprintf(stderr, "  plane %d block %d: %u %u %u %u, want %u %u %u %u\n", z, k, v[4 * k], v[4 * k + 1], v[4 * k + 2], v[4 * k + 3], want[0], want[1], want[2], want[3]); } }
        }
        CHECK(!bad, "d: every plane's blocks hold the values drawn into it");
        mtl_tex_release(&t);
    }

    // e. The byte cap: six large sizes (a 2048-wide R16 shadow and its buffer, about 16 MiB a pair), one pass each in one submission
    {   enum { N = 6 }; tex_t t[N]; id<MTLTexture> m[N]; tex_t *one[1]; uint16_t last[N];
        for (int i = 0; i < N; i++) m[i] = mk_tex(&t[i], ser++, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH16, 2048, 2048 - 16 * i, 1);
        cache_empty();
        for (int i = 0; i < N; i++) { one[0] = &t[i]; op_rt(&o, 1, one, NVN_FORMAT_R16, NULL); last[i] = (uint16_t)(0x8000 + 0x111 * i); op_clear(&o, 0, unorm16(last[i]), 0, 0, 1); }
        run(&o, "e: six large sizes");
        uint64_t kept = atomic_load(&g_bcrt_bytes);
        printf("e: %llu shadows made, %llu let go, %d entries, %.1f MiB kept (cap %llu MiB)\n", (unsigned long long)made(), (unsigned long long)retired(), entries(), kept / 1048576.0, (unsigned long long)(BCRT_CAP >> 20));
        if (cache) CHECK(kept <= BCRT_CAP && retired() >= 1 && entries() < N, "e: the cache keeps at most its byte cap (%llu bytes, %llu let go, %d entries)", (unsigned long long)kept, (unsigned long long)retired(), entries());
        for (int i = 0; i < N; i++) CHECK(d16_holds(m[i], last[i]), "e: the 2048x%d D16 texture holds its own value", 2048 - 16 * i);
        for (int i = 0; i < N; i++) mtl_tex_release(&t[i]);
    }

    char rs[512]; mtl_res_stats(rs, sizeof rs); printf("residency line after e: %s\n", rs);
    CHECK(strstr(rs, "; render-target shadows: passes ") != NULL, "the residency line counts the shadows");

    // f. The idle trim (bcrt_trim_idle at a submission's start) and the memory trim (dm_gfx_trim -> mtl_trim -> mtl_trim_at -> bcrt_trim(0, ...)), with three entries kept
    {   enum { N = 3 }; tex_t t[N]; id<MTLTexture> m[N]; tex_t *one[1];
        for (int i = 0; i < N; i++) m[i] = mk_tex(&t[i], ser++, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH16, 128 << i, 128 << i, 1);
        cache_empty();
        for (int i = 0; i < N; i++) { one[0] = &t[i]; op_rt(&o, 1, one, NVN_FORMAT_R16, NULL); op_clear(&o, 0, unorm16((uint16_t)(0x9000 + i)), 0, 0, 1); }
        run(&o, "f: three sizes");
        int e0 = entries(); uint64_t r0 = retired(), b0 = atomic_load(&g_bcrt_bytes);
        printf("f: %d entries, %.1f MiB kept\n", e0, b0 / 1048576.0);
        if (cache) CHECK(e0 == N && b0 > 0, "f: three sizes keep three entries (%d, %llu bytes)", e0, (unsigned long long)b0);
        // Idle: the entry of the first size last taken more than 5 s ago (its time moved back, as if the scene had not drawn it since); an empty submission's start lets it go
        int old = -1; for (int i = 0; i < BCRT_CACHE; i++) if (g_bcrtc[i].sh && g_bcrtc[i].sh.width == 128) old = i;
        if (cache) CHECK(old >= 0, "f: the 128-square shadow has an entry");
        if (old >= 0) { uint64_t back = BCRT_IDLE_NS + 1000000000ull; g_bcrtc[old].ns = g_bcrtc[old].ns > back ? g_bcrtc[old].ns - back : 0; }
        mtl_sub_begin(); mtl_sub_commit(); mtl_drain();
        printf("f: after an idle submission start: %d entries, %llu let go, %.1f MiB kept\n", entries(), (unsigned long long)(retired() - r0), atomic_load(&g_bcrt_bytes) / 1048576.0);
        if (cache) CHECK(entries() == N - 1 && retired() == r0 + 1 && atomic_load(&g_bcrt_bytes) < b0 && (old < 0 || !g_bcrtc[old].sh),
                         "f: the entry idle for over 5 s goes at the next submission's start and the other two stay (%d entries, %llu let go)", entries(), (unsigned long long)(retired() - r0));
        else CHECK(entries() == e0, "f (old behaviour): no idle trim (%d entries, %d before)", entries(), e0);
        // The memory trim, as going to the background calls it (no submission open, the GPU drained)
        int e1 = entries(); uint64_t r1 = retired(), b1 = atomic_load(&g_bcrt_bytes);
        uint64_t got = dm_gfx_trim(4);
        printf("f: dm_gfx_trim: %llu bytes in all; %d entries, %llu let go, %.1f MiB kept\n", (unsigned long long)got, entries(), (unsigned long long)(retired() - r1), atomic_load(&g_bcrt_bytes) / 1048576.0);
        if (cache) {
            CHECK(entries() == 0, "f: the memory trim lets every entry go (%d left)", entries());
            CHECK(retired() == r1 + (uint64_t)e1, "f: 'retired' counts them (%llu, want %d)", (unsigned long long)(retired() - r1), e1);
            CHECK(atomic_load(&g_bcrt_bytes) == 0 && b1 > 0, "f: the bytes kept fall to 0 (from %llu)", (unsigned long long)b1);
            CHECK(got >= b1, "f: the trim returns at least the shadows' bytes (%llu of %llu)", (unsigned long long)got, (unsigned long long)b1);
        } else CHECK(entries() == e1, "f (old behaviour): the memory trim keeps the shadows, as before (%d entries, %d before)", entries(), e1);
        // A shadow pass after the trim makes its shadow again and its value lands
        one[0] = &t[2]; op_rt(&o, 1, one, NVN_FORMAT_R16, NULL); op_clear(&o, 0, unorm16(0x9abc), 0, 0, 1);
        run(&o, "f: a pass after the trim");
        CHECK(d16_holds(m[2], 0x9abc), "f: a pass after the trim draws through a shadow made again");
        for (int i = 0; i < N; i++) mtl_tex_release(&t[i]);
    }
    // What was let go leaves after its fence: an empty submission, then the drain, checks every release against the last use DM_RES_CHECK saw
    cache_empty(); mtl_sub_begin(); mtl_sub_commit(); mtl_drain(); defer_drain();
    if (g_res_check_on) CHECK(g_res_late == 0, "no shadow or staging buffer released before the GPU was done with it (%llu released too early)", (unsigned long long)g_res_late);
    free(o.p);
    printf("t_bcrt_cache: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
