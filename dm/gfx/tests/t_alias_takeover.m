// alias_take_over (nvn_mtl.m): when a new shared texture takes over storage, an entry a live texture object still resolves to stays, and one nothing resolves to any more goes once
// no lookup has found it for ALIAS_IDLE submissions. Whether a live object resolves to it is one lookup in g_by_serial_held, which every writer of g_by_serial keeps (serial_put,
// serial_del, tex_put and the upgrade's in-place replacement): two serials naming one object count twice and the object stays held until both go. Last, a takeover past 1,000
// held entries with 20,000 serials in the table, which walked the serial table for each entry before (it prints the time).
// The candidates come from an index by pool and 64 KB cell (alias_index), which alias_put and alias_del keep: an entry that starts in an earlier cell is found, one in the same
// cell that ends before the new texture is not, one that spans several of the new texture's cells goes once, another pool's entries are not met, and a removal or a pool drop
// leaves no cell behind. Last, a takeover with 100,000 entries in the table, which walked the table's whole capacity before (it prints the time).
// The memory line's count of what only the sharing table keeps (alias_unheld_locked, upstream NXNative fb4da077a): each texture's bytes once however many keys name it, the part
// made to be drawn into, the longest any has gone without a lookup; textures a serial or a view's serial holds are left out.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static tex_t tex(uint64_t serial, NVNformat format, int w) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = w, .height = w, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L);
    return t;
}
static int shared(id<MTLTexture> t) { pthread_mutex_lock(&g_smu); int r = alias_has(t); pthread_mutex_unlock(&g_smu); return r; }
static int held(id o) { pthread_mutex_lock(&g_smu); int r = serial_table_holds((__bridge void *)o); pthread_mutex_unlock(&g_smu); return r; }
static alias_key akey(const void *pool, int64_t off, NVNformat format, int w) { alias_key k; memset(&k, 0, sizeof k); k.pool = (uint64_t)(uintptr_t)pool; k.off = off; k.d = tex(0, format, w).d; return k; }
static int64_t ksize(const alias_key *k) { nvn_texlayout L; nvn_tex_layout(&k->d, &L); return (int64_t)L.size; }
static void idle_put(const alias_key *k, id o) { alias_put(k, o); nvn_hm_del(&g_alias_seen, k); }   // an entry no lookup found lately. Under g_smu
static int has(const alias_key *k) { return nvn_hm_get(&g_alias, k) != NULL; }
static void next_submission(void) { CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completes"); mtl_sub_begin(); }

int main(void) { @autoreleasepool {
    mtl_init(); mtl_sub_begin();
    tex_t a = tex(91001, NVN_FORMAT_RGBA8, 64), b = tex(91002, NVN_FORMAT_R32F, 64), c = tex(91003, NVN_FORMAT_RG16F, 64);
    mtl_tex_init(&a); mtl_tex_init(&b); mtl_tex_init(&c);
    id<MTLTexture> ta = tex_mtl(&a);
    CHECK(ta && shared(ta) && held(ta), "a live object's shared texture is counted as held");
    id<MTLTexture> tb = tex_mtl(&b);
    CHECK(tb && tb != ta && shared(ta) && shared(tb), "another description over the storage leaves the texture a live object resolves to");
    mtl_tex_release(&a);
    CHECK(!held(ta) && shared(ta), "the finalized object's texture is no longer held, and stays shared until its storage is taken");
    for (int i = 0; i <= ALIAS_IDLE; i++) next_submission();
    id<MTLTexture> tc = tex_mtl(&c);
    CHECK(tc && !shared(ta), "a texture nothing resolves to goes when another description takes its storage");
    CHECK(shared(tb) && shared(tc), "the live objects' textures stay");

    {   // Sample count 0 and 1 are both single-sampled: an image object with 0 and a sampled object with 1 over one storage resolve to one Metal texture (ported from S2Arm 5863a69c)
        tex_t w = tex(91004, NVN_FORMAT_RGBA16F, 32), r = tex(91005, NVN_FORMAT_RGBA16F, 32), f = tex(91006, NVN_FORMAT_RGBA8, 32);
        w.off = r.off = f.off = 1 << 20; w.d.samples = 0; w.d.flags |= NVN_TEXTURE_FLAGS_IMAGE;
        mtl_tex_init(&w); mtl_tex_init(&r); mtl_tex_init(&f);
        id<MTLTexture> tw = tex_mtl(&w), tr = tex_mtl(&r), tf = tex_mtl(&f);
        CHECK(tw && tw == tr, "sample count 0 and 1 over one storage share one texture");
        CHECK(tf && tf != tw, "another format over the storage stays its own texture");
        mtl_tex_release(&w); mtl_tex_release(&r); mtl_tex_release(&f);
    }

    // Two serials naming one object: held until both go
    id o = [NSObject new]; uint64_t s1 = (1ull << 62) + 1, s2 = s1 + 1;
    tex_put(s1, o); tex_put(s2, o);
    serial_del(s1);
    CHECK(held(o), "an object two serials name stays held when one of them goes");
    serial_del(s2);
    CHECK(!held(o), "and is not held once both have gone");
    tex_put(s1, o); serial_put(s1, tb);
    CHECK(!held(o) && held(tb), "replacing a serial's object moves the count");
    serial_del(s1);

    {   // The cost: 1,000 held entries over the storage of a 1024 x 1024 texture, 20,000 serials in the table
        enum { NS = 20000, NA = 1000 };
        NSMutableArray *keep = [NSMutableArray array];
        pthread_mutex_lock(&g_smu);
        for (int i = 0; i < NA; i++) {
            id e = [NSObject new]; [keep addObject:e];
            alias_key k = akey(NULL, (int64_t)i * 4096, NVN_FORMAT_RGBA8, 32);
            idle_put(&k, e);   // not looked up lately, so only the serial table keeps it
        }
        pthread_mutex_unlock(&g_smu);
        for (int i = 0; i < NS; i++) tex_put((1ull << 62) + 100 + i, i < NA ? keep[i] : [NSObject new]);
        tex_t big = tex(91010, NVN_FORMAT_RGBA8, 1024); alias_key nk; memset(&nk, 0, sizeof nk); nk.d = big.d;
        pthread_mutex_lock(&g_smu);
        uint32_t before = g_alias.n; uint64_t t0 = bp_now();
        alias_take_over(&nk);
        double ms = (bp_now() - t0) / 1e6; uint32_t after = g_alias.n;
        pthread_mutex_unlock(&g_smu);
        printf("a takeover past %d held entries with %u serials in the table: %.3f ms\n", NA, g_by_serial.n, ms);
        CHECK(after == before, "held entries are kept");
        CHECK(ms < 1, "the takeover asks each entry in one lookup (under 1 ms; walking the serial table for each took 4.3 ms on an M5 Max)");
        for (int i = 0; i < NS; i++) serial_del((1ull << 62) + 100 + i);
    }
    {   // The index: which entries a takeover meets
        static pool_t pl, other; const void *P = &pl, *Q = &other;   // zeroed pools: only their addresses are used
        NSMutableArray *keep = [NSMutableArray array]; id (^obj)(void) = ^{ id e = [NSObject new]; [keep addObject:e]; return e; };
        pthread_mutex_lock(&g_smu);
        uint32_t cells0 = g_alias_cells.n, n0 = g_alias.n;
        alias_key big = akey(P, 0, NVN_FORMAT_RGBA8, 512); int64_t bs = ksize(&big), last = (bs - 1) >> ALIAS_CELL;
        CHECK(last >= 4, "the large texture spans several cells");
        idle_put(&big, obj());
        CHECK(g_alias_cells.n == cells0 + (uint32_t)last + 1, "an entry lies in every cell its bytes reach");
        alias_key far = akey(Q, 0, NVN_FORMAT_RGBA8, 512); idle_put(&far, obj());   // the same bytes of another pool
        alias_key tail = akey(P, last << ALIAS_CELL, NVN_FORMAT_R32F, 16);
        CHECK(ksize(&tail) <= 0x8000 && bs > tail.off, "the small texture fits half a cell and lies in the large one's last");
        alias_take_over(&tail); alias_put(&tail, obj());
        CHECK(!has(&big), "an entry that starts in an earlier cell and reaches into the new texture's goes");
        CHECK(has(&far), "another pool's entry over the same offsets stays");
        CHECK(g_alias_cells.n == cells0 + (uint32_t)last + 1 + 1, "the entry taken over left every cell it lay in");
        nvn_hm_del(&g_alias_seen, &tail);
        alias_key after = akey(P, tail.off + 0x8000, NVN_FORMAT_RGBA8, 16);
        alias_take_over(&after); idle_put(&after, obj());
        CHECK(has(&tail), "an entry in the same cell that ends before the new texture stays");
        alias_key before = akey(P, tail.off, NVN_FORMAT_RGBA8, 16);   // the small one's bytes under another description
        alias_take_over(&before); idle_put(&before, obj());
        CHECK(!has(&tail) && has(&after), "and goes when its bytes are taken");
        alias_key big2 = akey(P, 0, NVN_FORMAT_R32F, 512); int over = after.off < ksize(&big2);   // its last cell holds the two small entries
        alias_take_over(&big2); idle_put(&big2, obj());
        CHECK(!has(&before) && has(&after) == !over, "a larger texture takes the entries in its cells that it overlaps");
        alias_key big3 = akey(P, 0, NVN_FORMAT_RG16F, 512); uint64_t t2 = g_alias_taken; uint32_t n2 = g_alias.n;
        alias_take_over(&big3);
        CHECK(!has(&big2) && g_alias_taken - t2 == n2 - g_alias.n && n2 - g_alias.n == 1u + (has(&after) ? 0 : !over), "an entry that spans several of the new texture's cells is taken once");
        alias_put(&big3, obj());
        {   // a spared entry (looked up in this submission) that spans every cell of the new texture is looked at once, not once per cell (upstream NXNative d664d3172)
            alias_key big4 = akey(P, 0, NVN_FORMAT_RGBA16F, 512); uint64_t l0 = g_alias_looks; int64_t cells = ((ksize(&big4) < ksize(&big3) ? ksize(&big4) : ksize(&big3)) - 1) >> ALIAS_CELL;
            alias_take_over(&big4);
            CHECK(cells >= 4 && has(&big3), "the entry looked up lately stays");
            CHECK(g_alias_looks - l0 == 1u + (has(&after) && after.off < ksize(&big4)), "and is looked at once, though it lies in every cell of the new texture");
        }
        pthread_mutex_unlock(&g_smu);
        mtl_alias_drop_pool(P);
        pthread_mutex_lock(&g_smu);
        CHECK(!has(&big3) && !has(&after) && has(&far), "a pool drop takes that pool's entries only");
        CHECK(g_alias_cells.n == cells0 + (uint32_t)((ksize(&far) - 1) >> ALIAS_CELL) + 1, "and leaves none of its cells");
        alias_del(&far);
        CHECK(g_alias_cells.n == cells0 && g_alias.n == n0, "a removal leaves the index as it was");
        CHECK(!alias_del(&far), "removing an entry that is not there does nothing");
        pthread_mutex_unlock(&g_smu);
    }
    {   // The cost: 100,000 entries in the table, one per cell of a pool, and a texture over 16 of them that were looked up lately (so they stay)
        enum { NA = 100000 };
        static pool_t pl; const void *P = &pl;
        NSMutableArray *keep = [NSMutableArray arrayWithCapacity:NA];
        pthread_mutex_lock(&g_smu);
        for (int i = 0; i < NA; i++) { id e = [NSObject new]; [keep addObject:e]; alias_key k = akey(P, (int64_t)i << ALIAS_CELL, NVN_FORMAT_RGBA8, 32); alias_put(&k, e); }
        alias_key nk = akey(P, 5000ll << ALIAS_CELL, NVN_FORMAT_R32F, 512);
        uint32_t before = g_alias.n; uint64_t t0 = bp_now();
        for (int i = 0; i < 100; i++) alias_take_over(&nk);
        double ms = (bp_now() - t0) / 1e6 / 100; uint32_t after = g_alias.n;
        printf("a takeover with %u entries in the table (capacity %u): %.4f ms\n", g_alias.n, g_alias.cap, ms);
        CHECK(after == before, "entries looked up lately are kept");
        CHECK(ms < 0.1, "the takeover reads only its own cells (under 0.1 ms; walking the table took 0.65 ms on an M6)");
        pthread_mutex_unlock(&g_smu);
        mtl_alias_drop_pool(P);
        pthread_mutex_lock(&g_smu); CHECK(g_alias.n == before - NA, "the pool's entries go with it"); pthread_mutex_unlock(&g_smu);
    }
    {   // the memory line's unheld count (issue #2629)
        static uint8_t Q[1];   // a pool of its own: its address is the keys' pool
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead; id<MTLTexture> rd = [g_dev newTextureWithDescriptor:d], hold = [g_dev newTextureWithDescriptor:d], parent = [g_dev newTextureWithDescriptor:d];
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; id<MTLTexture> rt = [g_dev newTextureWithDescriptor:d];
        id<MTLTexture> view = [parent newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
        alias_key k1 = akey(Q, 0, NVN_FORMAT_RGBA8, 64), k2 = akey(Q, 1ll << ALIAS_CELL, NVN_FORMAT_RGBA8, 64), k3 = akey(Q, 2ll << ALIAS_CELL, NVN_FORMAT_RGBA8, 64),
                  k4 = akey(Q, 3ll << ALIAS_CELL, NVN_FORMAT_RGBA8, 64), k5 = akey(Q, 4ll << ALIAS_CELL, NVN_FORMAT_RGBA8, 64);
        pthread_mutex_lock(&g_smu);
        alias_unheld u0 = alias_unheld_locked();
        alias_put(&k1, rd); alias_put(&k2, rd); alias_put(&k3, rt); alias_put(&k4, hold); alias_put(&k5, parent);
        const uint64_t now = g_fence + 1;
        nvn_hm_put(&g_alias_seen, &k1, (void *)(uintptr_t)1); nvn_hm_put(&g_alias_seen, &k2, (void *)(uintptr_t)2); nvn_hm_put(&g_alias_seen, &k3, (void *)(uintptr_t)3);   // the oldest stamps there can be
        pthread_mutex_unlock(&g_smu);
        serial_put(970001, hold); serial_put(970002, view);
        pthread_mutex_lock(&g_smu); alias_unheld u = alias_unheld_locked(); pthread_mutex_unlock(&g_smu);
        printf("unheld: %u entries, %llu bytes, %llu writable, oldest idle %llu submissions\n", u.entries - u0.entries, (unsigned long long)(u.bytes - u0.bytes), (unsigned long long)(u.writable_bytes - u0.writable_bytes), (unsigned long long)u.oldest_idle); printf("(now %llu)\n", (unsigned long long)now);
        CHECK(u.entries - u0.entries == 3, "the unheld count takes the sharing table's entries no serial or view holds (two keys of one texture, a render target)");
        CHECK(u.bytes - u0.bytes == rd.allocatedSize + rt.allocatedSize, "their bytes count each texture once, leaving out the serial-held one and the parent of a held view");
        CHECK(u.writable_bytes - u0.writable_bytes == rt.allocatedSize, "the part made to be drawn into is the render target's");
        CHECK(now > 3 && u.oldest_idle == now - 1, "the oldest idle age is the longest since any unheld entry's last lookup");
        serial_del(970001); serial_del(970002);
        pthread_mutex_lock(&g_smu); u = alias_unheld_locked(); pthread_mutex_unlock(&g_smu);
        CHECK(u.entries - u0.entries == 5 && u.bytes - u0.bytes == rd.allocatedSize + rt.allocatedSize + hold.allocatedSize + parent.allocatedSize, "once their serials go, the held texture and the view's parent count too");
        pthread_mutex_lock(&g_smu); alias_del(&k1); alias_del(&k2); alias_del(&k3); alias_del(&k4); alias_del(&k5); u = alias_unheld_locked(); pthread_mutex_unlock(&g_smu);
        CHECK(u.entries == u0.entries && u.bytes == u0.bytes, "the entries gone, the count is what it was");
    }
    mtl_tex_release(&b); mtl_tex_release(&c);
    next_submission(); defer_drain();
    printf("t_alias_takeover: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
