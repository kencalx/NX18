// A memory pool's Finalize ends every texture made on its storage (nvn_mtl.m pool_finalize_locked, mtl_alias_drop_pool; upstream NXNative 13c35e90a, whose t_serial_owner cases
// these are, on this tree's in-file tables; NX 18 has no nvn_owner.m). On NVN the pool's memory goes, whether or not the game has finalized the texture objects yet: Ocarina of Time
// finalizes its 12288x12288 shadow target's pool at one area load and the texture object only at the next, and the object's entry kept the old 300 MB heap through the field.
// - Sharing-table textures: the pool's live objects lose their entries (the pool index, g_pool_tex), and so do a finalized serial's entry (ghost) and another live serial's entry that
//   name one of its textures or a view of one, each a note; another pool's texture keeps its entries; a pin still holds its texture, which a look then finds (tex_made); a look at a
//   live object of the gone pool makes nothing; the objects' own Finalize later ends nothing; the entries that went are counted for the memory line.
// - Packaged textures, which the sharing table never names: a live object's entry holding a package, a finalized serial's entry holding the package's texture (the GPU's first write
//   over its storage hands it to the package's serials), and a finalized serial's entry holding a package of the pool that no live object holds (g_pkg_share) all go; the other pool's
//   Finalize later ends its own texture's entry, and the index is empty.
// - Render targets drawn over (DM_NVN_RT_DEAD, tu_pass): one a pressure pass released before its pool's Finalize is not released again by the Finalize (its heap freed, not also
//   waiting), and the target over it, which the Finalize ends, waits once; a pool finalized first leaves the next pass nothing to release and its records go.
// - Resolutions racing the Finalize: a walk holding g_rmu while a game thread finalizes the pool resolves the texture it had, as the IDs go gone and the entries end in one hold of
//   g_rmu (with the entries ended first, a walk in between made the texture again and kept it under the serial and in the sharing table under the dead pool's key until the object's own
//   Finalize); a resolution that found the magic still set just before the Finalize cleared it makes the texture for its use and keeps no entry (g_pool_ended), and a package made
//   then neither, while a part of a package another holder keeps is left to it; the object's own Finalize or its initialization again ends the mark. With the Finalize run where a
//   resolution has just read the pool as live (g_pool_read_after), whatever has become of the serial (live, finalized before its pool, finalized between), what a resolution makes
//   keeps no entry and is retired (a made target in a recycled heap, an allocation of its own, a buffer texture, a package, an upgrade's new parent): the finalize count it read before
//   the magic tells it (pool_fin_since), and the table of finalized pools stays bounded.
// The pool index is checked against the live texture objects after every step (pool_index_ok).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static void target(tex_t *t, pool_t *pool, uint64_t serial, uint64_t off, NVNformat format, unsigned w) {   // a texture object of the pool, initialized where it lives (g_tex_live keeps its address)
    *t = (tex_t){.magic = MAGIC('T','E','X',0), .serial = serial, .pool = pool, .mem = pool->mem + off, .off = (int64_t)off};
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = w, .height = w, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t->d, &t->L); mtl_tex_init(t);
}
static id live(uint64_t k) { pthread_mutex_lock(&g_smu); id o = hm_get_id(&g_by_serial, &k); pthread_mutex_unlock(&g_smu); return o; }   // without a use
static id ghost(uint64_t k) { pthread_mutex_lock(&g_smu); id o = hm_get_id(&g_ghost, &k); pthread_mutex_unlock(&g_smu); return o; }
static int holds(id o) { pthread_mutex_lock(&g_smu); int r = entry_holds((__bridge void *)o); pthread_mutex_unlock(&g_smu); return r; }
static int shared(id o) { pthread_mutex_lock(&g_smu); int r = o && g_alias_set && CFSetContainsValue(g_alias_set, (__bridge const void *)o); pthread_mutex_unlock(&g_smu); return r; }
static uint64_t pool_entries(void) { pthread_mutex_lock(&g_smu); uint64_t n = g_alias_pool_entries; pthread_mutex_unlock(&g_smu); return n; }
static uint64_t gen(void) { return atomic_load(&g_ser_gen); }
static int noted_since(uint64_t serial, uint64_t g0) {   // the serial table's note log holds a note for serial after generation g0 (ser_note)
    int hit = 0; os_unfair_lock_lock(&g_snote_lk);
    for (uint64_t g = g0 + 1; g <= g_ser_gen && !hit; g++) hit = g_ser_log[g % SER_LOG].gen == g && g_ser_log[g % SER_LOG].serial == serial;
    os_unfair_lock_unlock(&g_snote_lk); return hit;
}
static unsigned pool_set_n(const void *pool) {   // how many live serials the index holds for pool
    pthread_mutex_lock(&g_smu); uintptr_t pk = (uintptr_t)pool; CFSetRef set = g_pool_tex.n ? nvn_hm_get(&g_pool_tex, &pk) : NULL;
    unsigned n = set ? (unsigned)CFSetGetCount(set) : 0; pthread_mutex_unlock(&g_smu); return n;
}
// The pool index against the live texture objects: each indexed serial is a live object's and lies in its pool's set, no set is empty, and every set holds only serials indexed
// under that pool (upstream's own_check_locked, this part)
static int pool_index_ok(char *why, size_t n) {
    int ok = 1; uint64_t in_sets = 0;
    pthread_mutex_lock(&g_smu);
    for (uint32_t i = 0; ok && i < g_pool_tex.cap; i++) {
        CFSetRef set = g_pool_tex.vals[i]; if (!set) continue;
        uintptr_t pool; memcpy(&pool, g_pool_tex.keys + (size_t)i * g_pool_tex.klen, sizeof pool);
        CFIndex m = CFSetGetCount(set); in_sets += (uint64_t)m;
        if (!m) { snprintf(why, n, "pool %#lx has an empty set of live textures", (unsigned long)pool); ok = 0; break; }
        const void **vs = malloc((size_t)m * sizeof *vs); if (!vs) abort(); CFSetGetValues(set, vs);
        for (CFIndex j = 0; ok && j < m; j++) {
            uint64_t serial = (uint64_t)(uintptr_t)vs[j];
            if ((uintptr_t)nvn_hm_get(&g_tex_pool, &serial) != pool) { snprintf(why, n, "serial %llu is in pool %#lx's set but indexed under another", (unsigned long long)serial, (unsigned long)pool); ok = 0; }
            else if (!nvn_hm_get(&g_tex_live, &serial)) { snprintf(why, n, "serial %llu is in pool %#lx's set but not live", (unsigned long long)serial, (unsigned long)pool); ok = 0; }
        }
        free(vs);
    }
    if (ok && in_sets != g_tex_pool.n) { snprintf(why, n, "%llu serials in the pools' sets, %u indexed", (unsigned long long)in_sets, g_tex_pool.n); ok = 0; }
    pthread_mutex_unlock(&g_smu);
    return ok;
}
static void step(const char *what) { char why[200] = ""; int ok = pool_index_ok(why, sizeof why); char l[300]; snprintf(l, sizeof l, "the pool index after %s%s%s", what, ok ? "" : ": ", why); CHECK(ok, l); }
// The released textures' fences pass, the deferred releases run, the drains kicked off the submit thread included (defer_kick_group: their residency commit drops the last reference,
// on a utility thread), and the residency set lets go of what left it (as t_depth_lazy's settle)
static void settle(void) {
    mtl_sub_commit(); mtl_drain(); mtl_sub_begin(); mtl_sub_commit(); mtl_drain();
    rec_drain(); dispatch_sync(g_feedback_q, ^{}); dispatch_sync(res_commit_q(), ^{});
    if (dispatch_group_wait(defer_kick_group(), dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) { checks++; failed++; fprintf(stderr, "FAIL: the drains kicked off the submit thread end within 10 s\n"); }
    while (defer_drain()) {}   // entries handed back while another thread held g_smu are taken again
    res_commit(); mtl_sub_begin();
}
static void pool_finalize(pool_t *p) { p->magic = 0; mtl_alias_drop_pool(p); }   // nvnMemoryPoolFinalize (hle_nvn.c): the magic goes, then the replay forgets the pool
static void *pool_finalize_thread(void *p) { pool_finalize(p); return NULL; }   // on a game thread
static id<MTLTexture> by_id(int tid) { os_unfair_lock_lock(&g_rmu); id<MTLTexture> t = tex_by_id(tid); os_unfair_lock_unlock(&g_rmu); return t; }   // a binding
static unsigned alias_pool_n(const void *pool) {   // the sharing table's entries under pool's key
    unsigned n = 0; pthread_mutex_lock(&g_smu);
    for (uint32_t i = 0; i < g_alias.cap; i++) if (g_alias.vals[i]) { alias_key k; memcpy(&k, g_alias.keys + (size_t)i * g_alias.klen, sizeof k); n += k.pool == (uint64_t)(uintptr_t)pool; }
    pthread_mutex_unlock(&g_smu); return n;
}
static int ended(uint64_t serial) { pthread_mutex_lock(&g_smu); int r = pool_ended(serial); pthread_mutex_unlock(&g_smu); return r; }
// A packaged-texture entry, as a resolution puts it
static void pkg_put(const tex_t *t, NvPkg *pk) {
    NvPkgRef *r = [NvPkgRef new]; r->pkg = pk;
    pthread_mutex_lock(&g_smu); pkg_share_put_locked(t, fin_snap(), r); pthread_mutex_unlock(&g_smu);   // NOLINT(clang-analyzer-osx.cocoa.RetainCount): g_pkg_share retains r (hm_put_id, a C hash table the analyzer does not model)
}
static id<MTLTexture> plain(void) {   // a texture of the host's own, as a package's
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; return [g_dev newTextureWithDescriptor:d];
}
// DM_NVN_RT_DEAD's clock and passes (as t_dead_targets)
static void at(uint32_t now) { g_tu_now = now; }
static void submissions(void) { for (int k = 0; k <= ALIAS_IDLE; k++) { CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completes"); mtl_sub_begin(); } }   // past ALIAS_IDLE: no lookup found them lately
static int covered(id o) { tu_rec u; return tu_use_of(o, &u); }
static unsigned waiting(void) { os_unfair_lock_lock(&g_rh_lk); unsigned n = g_rh_n; os_unfair_lock_unlock(&g_rh_lk); return n; }
static int rh_waits(id h) { int w = 0; os_unfair_lock_lock(&g_rh_lk); for (unsigned i = 0; h && i < g_rh_n && !w; i++) w = g_rh[i].heap == (__bridge void *)h; os_unfair_lock_unlock(&g_rh_lk); return w; }
static int resident(id o) { pthread_mutex_lock(&g_res_mu); int r = o && [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }
// A game thread's Finalize of race_pool landing once a resolution has read it as live, before the resolution puts anything (g_pool_read_after), once; and the texture object's own
// Finalize right after it when race_tex is set (the object finalized between its pool's Finalize and the resolution's put)
static pool_t *race_pool; static tex_t *race_tex; static int raced;
static void race_finalize(const void *pool) {
    if (!race_pool || pool != race_pool) return;
    pool_t *p = race_pool; race_pool = NULL; raced++;
    pool_finalize(p);
    if (race_tex) { mtl_tex_release(race_tex); race_tex = NULL; }
}
static void race(pool_t *p, tex_t *t) { race_pool = p; race_tex = t; raced = 0; }
// A resolution of rc->t (tex_mtl), on the calling thread or on one of its own, what it made left only to the retirement once its pool has drained
typedef struct { tex_t *t; pool_t *pool; int heap, own, kept; } res_case;
static __weak id<MTLTexture> g_rc_w; static __weak id<MTLHeap> g_rc_wh;
static void *resolve_case(void *p) { res_case *rc = p; @autoreleasepool {
    id<MTLTexture> t = tex_mtl(rc->t); g_rc_w = t; g_rc_wh = t.heap;
    rc->heap = t && t.heap; rc->own = t && !t.heap && resident(t);
    rc->kept = live(rc->t->serial) || ghost(rc->t->serial) || holds(t) || shared(t) || alias_pool_n(rc->pool);
} return NULL; }

int main(void) { @autoreleasepool {
    unsetenv("DM_NVN_RT_DEAD");   // on, the default
    mtl_init(); mtl_sub_begin(); g_tu_manual = 1; g_tu_idle = 30; g_tu_every = 10;
    void *mem = NULL; posix_memalign(&mem, 16384, 64 << 20); memset(mem, 0, 64 << 20);
    const int gpu_only = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE;
    pool_t P = {.magic = MAGIC('P','O','O','L'), .flags = gpu_only, .mem = mem, .size = 16 << 20}, Q = P; Q.mem = (uint8_t *)mem + (16 << 20);
    step("the start");

    // ---- Sharing-table textures and the entries that name them
    __weak id<MTLTexture> wa, wf, wv, wp;
    tex_t a, f, p, q; target(&a, &P, 97001, 0, NVN_FORMAT_RGBA8, 64); target(&f, &P, 97002, 1 << 20, NVN_FORMAT_RGBA8, 64); target(&p, &P, 97003, 2 << 20, NVN_FORMAT_RGBA8, 64);
    target(&q, &Q, 97004, 0, NVN_FORMAT_RGBA8, 64);
    tex_t x = {.magic = MAGIC('T','E','X',0), .serial = 97005}, y = x; y.serial = 97006; mtl_tex_init(&x); mtl_tex_init(&y);   // live objects of no pool
    id<MTLTexture> tq = nil;
    @autoreleasepool {
        id<MTLTexture> ta = tex_mtl(&a), tf = tex_mtl(&f), tp = tex_mtl(&p); tq = tex_mtl(&q);
        CHECK(ta && tf && tp && tq && shared(ta) && shared(tf) && shared(tp) && shared(tq), "four shared textures, three of them of pool P");
        mtl_tex_release(&f);
        CHECK(tex_mtl(&f) == tf && ghost(f.serial) == tf && !live(f.serial), "a finalized object's texture looked up again: its entry is a ghost one");
        // Another live serial names P's texture, and another a view of one (an sRGB twin), neither of them one of P's texture objects: as an object made again over a pool
        // made at the same address would
        id<MTLTexture> v = [ta newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
        serial_put(x.serial, ta); serial_put(y.serial, v);
        mtl_tex_pin(p.serial);   // a queued descriptor of p
        wa = ta; wf = tf; wv = v; wp = tp;
    }
    CHECK(pool_set_n(&P) == 2 && pool_set_n(&Q) == 1, "the index holds P's two live texture objects (f is finalized) and Q's one");
    step("the textures made");
    {
        uint64_t g0 = gen(), e0 = pool_entries(), ev0 = g_alias_evicted;
        pool_finalize(&P);
        CHECK(!live(a.serial) && !live(p.serial), "P's Finalize ends its live texture objects' entries");
        CHECK(!ghost(f.serial), "and the finalized serial's entry that holds one of its textures");
        CHECK(!live(x.serial) && !live(y.serial), "and every other live entry that names one of them, or a view of one");
        CHECK(noted_since(a.serial, g0) && noted_since(p.serial, g0) && noted_since(f.serial, g0) && noted_since(x.serial, g0) && noted_since(y.serial, g0), "each one a note");
        CHECK(pool_entries() == e0 + 5 && g_alias_evicted == ev0 + 3, "the five entries counted for the memory line, beside P's three sharing-table entries");
        CHECK(!shared(wa) && !shared(wf) && !shared(wp) && shared(tq) && live(q.serial) == tq, "P's textures leave the sharing table; Q's texture keeps its entries");
        CHECK(!holds(wa) && !holds(wf) && holds(wp), "no entry holds P's textures but the pin");
        CHECK(pool_set_n(&P) == 0 && pool_set_n(&Q) == 1, "P's serials leave the index");
        step("P's Finalize");
        @autoreleasepool {
            CHECK(tex_mtl(&a) == nil && !live(a.serial), "a look at a live texture object of a pool that is gone makes nothing");
            CHECK(tex_mtl(&p) == wp && wp, "a pin still holds its texture, and a look finds it there");
        }
        settle();
        CHECK(!wa && !wf && !wv, "once the submission in flight completes, P's textures are freed though their objects live on");
        CHECK(wp, "the pinned one stays");
        mtl_tex_unpin(p.serial); settle();
        CHECK(!wp, "unpinned, it goes too");
        uint64_t e1 = pool_entries();
        mtl_tex_release(&a); mtl_tex_release(&p); mtl_tex_release(&x); mtl_tex_release(&y);
        CHECK(!live(a.serial) && !live(p.serial) && pool_entries() == e1, "the objects' own Finalize, later, finds nothing to end");
        step("the objects' own Finalize");
    }

    // ---- Packaged textures: a pool's live object holding a package, a finalized serial holding the package's texture (cpu_unc_drop hands it to the package's serials), and a
    // finalized serial holding a package of the pool that no live object holds (g_pkg_share)
    {
        pool_t R = {.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = (uint8_t *)mem + (32 << 20), .size = 16 << 20}, S = R;
        S.mem = (uint8_t *)mem + (48 << 20);
        NvPkg * __weak wpk, * __weak wpk2; __weak id<MTLTexture> wptex;
        tex_t l, g, h, o2; target(&l, &R, 97020, 0, NVN_FORMAT_RGBA8, 16); target(&g, &R, 97021, 1 << 16, NVN_FORMAT_RGBA8, 16); target(&h, &R, 97022, 2 << 16, NVN_FORMAT_RGBA8, 16);
        target(&o2, &S, 97023, 0, NVN_FORMAT_RGBA8, 16);
        id<MTLTexture> other = plain();
        @autoreleasepool {
            NvPkg *pk = [NvPkg new], *pk2 = [NvPkg new]; pk->tex = plain(); pk2->tex = plain();
            tex_put(l.serial, pk); pkg_put(&l, pk);
            mtl_tex_release(&g); tex_put(g.serial, pk->tex);   // finalized before its pool, and its entry holds the package's texture
            pkg_put(&h, pk2); mtl_tex_release(&h); tex_put(h.serial, pk2);   // a package no live object holds
            tex_put(o2.serial, other);
            wpk = pk; wpk2 = pk2; wptex = pk->tex;
        }
        @autoreleasepool { CHECK(live(l.serial) == wpk && ghost(g.serial) == wptex && ghost(h.serial) == wpk2 && live(o2.serial) == other, "R's live object, two finalized ones, and S's live object"); }   // (what a look returns is autoreleased)
        CHECK(pool_set_n(&R) == 1 && pool_set_n(&S) == 1, "the index holds R's one live object and S's");
        step("the packages made");
        uint64_t g0 = gen(), e0 = pool_entries(), ev0 = g_alias_evicted;
        pool_finalize(&R);
        CHECK(!live(l.serial) && !ghost(g.serial) && !ghost(h.serial), "R's Finalize ends its live object's entry and the finalized serials' entries that hold its package, a part of one, or a package of R");
        CHECK(noted_since(l.serial, g0) && noted_since(g.serial, g0) && noted_since(h.serial, g0), "each one a note, though the sharing table names none of them");
        CHECK(!holds(wpk) && !holds(wptex) && !holds(wpk2), "no entry holds them");
        CHECK(pool_entries() == e0 + 3 && g_alias_evicted == ev0, "three entries counted, no sharing-table entry");
        CHECK(live(o2.serial) == other, "S's texture keeps its entry");
        CHECK(!pkg_shared(&l) && !pkg_shared(&h), "R's packages leave the packaged-texture table");
        step("R's Finalize");
        settle();
        CHECK(!wpk && !wpk2 && !wptex, "once the submission in flight completes, they are freed");
        uint64_t e1 = pool_entries();
        mtl_tex_release(&l);
        CHECK(!live(l.serial) && pool_entries() == e1, "the object's own Finalize, later: nothing left to end");
        pool_finalize(&S);
        CHECK(!live(o2.serial) && pool_entries() == e1 + 1, "S's Finalize ends its texture's entry in turn");
        mtl_tex_release(&o2);
        pool_finalize(&Q); mtl_tex_release(&q); tq = nil;
        step("every pool finalized");
        pthread_mutex_lock(&g_smu); int empty = !g_pool_tex.n && !g_tex_pool.n; pthread_mutex_unlock(&g_smu);
        CHECK(empty, "the index is empty");
    }

    // ---- Render targets drawn over (DM_NVN_RT_DEAD): a pool's Finalize and a pass each release a texture once
    {
        pool_t T = {.magic = MAGIC('P','O','O','L'), .flags = gpu_only, .mem = (uint8_t *)mem + (32 << 20), .size = 16 << 20};
        __weak id<MTLTexture> wu, wun; __weak id<MTLHeap> wuh, wunh;
        at(100);
        tex_t u, un; target(&u, &T, 97030, 0, NVN_FORMAT_RGBA16F, 256); target(&un, &T, 97031, 0, NVN_FORMAT_R32F, 256);   // un over u's bytes
        @autoreleasepool {
            id<MTLTexture> tu = tex_mtl(&u); tu_wrote(tu); at(110); id<MTLTexture> tun = tex_mtl(&un); tu_wrote(tun);
            CHECK(tu && tun && tu.heap && tun.heap && tu.heap != tun.heap && covered(tu) && covered(tun) && shared(tu) && shared(tun), "two covered targets over the same bytes, each in a recycled heap");
            wu = tu; wun = tun; wuh = tu.heap; wunh = tun.heap;
        }
        submissions();
        os_unfair_lock_lock(&g_rh_lk); for (unsigned i = 0; i < g_rh_n; i++) g_rh[i].t -= RH_IDLE_NS; os_unfair_lock_unlock(&g_rh_lk);
        mtl_sub_commit(); mtl_drain(); mtl_sub_begin();   // the heaps the cases above left waiting go (rh_trim), so the count below is this case's alone
        unsigned w0 = waiting(); uint64_t n0 = g_tu_n, e0 = pool_entries();
        CHECK(w0 == 0, "no heap waits before the case");
        at(200); g_tu_last = 190; tu_dead_stats st = tu_pass_at(30, 2);   // a pressure pass (a memory warning's): what it releases has its heap freed, not kept for reuse
        CHECK(st.n == 1 && g_tu_n == n0 + 1 && !shared(wu) && !live(u.serial) && shared(wun), "the pressure pass releases the target drawn over, with its entry");
        pool_finalize(&T);
        CHECK(!shared(wun) && !live(un.serial) && pool_entries() == e0 + 1, "the pool's Finalize ends the target over it, and only that one: the released one has no entry left to end");
        settle();
        CHECK(!wu && !wun, "both are freed");
        CHECK(!rh_waits(wuh) && (!wuh || !resident(wuh)), "the released target's heap is freed, not also kept for reuse");
        CHECK(wunh && rh_waits(wunh) && waiting() == w0 + 1, "the other's heap waits for the next target, once");
        mtl_tex_release(&u); mtl_tex_release(&un);
        CHECK(!live(u.serial) && !live(un.serial) && waiting() == w0 + 1, "the objects' own Finalize frees nothing more");
        // The other order: a pool finalized while its target is covered, then a pass
        pool_t T2 = T; T2.magic = MAGIC('P','O','O','L'); T2.mem = (uint8_t *)mem + (48 << 20);
        at(300);
        tex_t v, vn; target(&v, &T2, 97032, 0, NVN_FORMAT_RGBA16F, 64); target(&vn, &T2, 97033, 0, NVN_FORMAT_R32F, 64);
        id<MTLTexture> tv = tex_mtl(&v); tu_wrote(tv); at(310); id<MTLTexture> tvn = tex_mtl(&vn); tu_wrote(tvn);
        CHECK(tv && tvn && covered(tv) && covered(tvn), "two more covered targets");
        submissions();
        pool_finalize(&T2);
        CHECK(!shared(tv) && !shared(tvn) && !live(v.serial) && !live(vn.serial), "their pool's Finalize ends both");
        uint64_t n1 = g_tu_n; at(400); g_tu_last = 390; tu_pass();
        CHECK(g_tu_n == n1 && !covered(tv) && !covered(tvn), "the next pass releases nothing, and their records go");
        tv = tvn = nil; mtl_tex_release(&v); mtl_tex_release(&vn);
        step("the render targets' pools");
    }
    // ---- Resolutions racing the Finalize
    {
        // A walk (pool_gpu, a handle binding: holding g_rmu) while a game thread finalizes the pool
        pool_t V = {.magic = MAGIC('P','O','O','L'), .flags = gpu_only, .mem = mem, .size = 16 << 20};
        __weak id<MTLTexture> w1, w2;
        tex_t s; target(&s, &V, 97040, 0, NVN_FORMAT_RGBA16F, 1024); mtl_reg_tex(700, &s, NULL);
        @autoreleasepool { id<MTLTexture> t1 = by_id(700); w1 = t1; CHECK(t1 && live(s.serial) == t1 && alias_pool_n(&V) == 1, "a target resolves by ID: a live entry and a sharing-table entry"); }
        os_unfair_lock_lock(&g_rmu);
        pthread_t th; CHECK(!pthread_create(&th, NULL, pool_finalize_thread, &V), "the Finalize starts on another thread");
        for (int i = 0; i < 5000 && V.magic; i++) usleep(1000);   // started: the magic goes first
        usleep(100000);   // then it runs as far as it can while the walk holds g_rmu
        CHECK(V.magic == 0 && live(s.serial) == w1 && alias_pool_n(&V) == 1 && !g_treg[700].gone, "while a walk holds g_rmu the Finalize has cleared the magic, but ended no entry and marked no ID");
        @autoreleasepool { id<MTLTexture> t2 = tex_by_id(700); w2 = t2; CHECK(t2 && t2 == w1, "the walk resolves the texture it had and makes none"); }
        os_unfair_lock_unlock(&g_rmu);
        pthread_join(th, NULL);
        @autoreleasepool { CHECK(!by_id(700) && g_treg[700].gone, "after the Finalize the ID is gone and reads as an empty slot"); }
        CHECK(!live(s.serial) && alias_pool_n(&V) == 0 && ended(s.serial), "no entry is left: none under the serial, none under the dead pool's key");
        settle();
        CHECK(!w1 && !w2, "the texture is freed once the submission in flight completes, its object still live");
        mtl_reg_tex(700, NULL, NULL); mtl_tex_release(&s);
        CHECK(!ended(s.serial), "the object's own Finalize ends the mark");
        step("a walk during the Finalize");

        // The IDs go gone and the entries end in one hold of g_rmu, so no reader resolves in between. With the IDs marked in a hold of their own first, a binding in between took
        // tex_made, found the entry still there and cached a view of it (vc_put), which kept the texture until the object's own Finalize. The Finalize is held where its entry
        // ends (this thread holds ser_note's lock), found there by g_smu staying busy, and g_rmu is tried then
        pool_t Y = {.magic = MAGIC('P','O','O','L'), .flags = gpu_only, .mem = (uint8_t *)mem + (48 << 20), .size = 16 << 20};
        tex_t y; target(&y, &Y, 97044, 0, NVN_FORMAT_RGBA8, 64);
        @autoreleasepool { CHECK(tex_mtl(&y) && live(y.serial), "a texture with its entry"); }
        os_unfair_lock_lock(&g_snote_lk);
        CHECK(!pthread_create(&th, NULL, pool_finalize_thread, &Y), "its pool's Finalize starts on another thread");
        int busy = 0;
        for (int i = 0; i < 2000 && busy < 5; i++) { if (pthread_mutex_trylock(&g_smu)) busy++; else { busy = 0; pthread_mutex_unlock(&g_smu); } usleep(2000); }
        int rmu_free = os_unfair_lock_trylock(&g_rmu); if (rmu_free) os_unfair_lock_unlock(&g_rmu);
        os_unfair_lock_unlock(&g_snote_lk);
        pthread_join(th, NULL);
        CHECK(busy >= 5 && !rmu_free, "as the Finalize ends the entries, it still holds g_rmu");
        CHECK(!live(y.serial) && ended(y.serial), "and the entry is gone");
        mtl_tex_release(&y);

        // A texture object resolved outside g_rmu by a reader that found the magic still set just before the Finalize cleared it: the Finalize as that reader sees it
        pool_t W = {.magic = MAGIC('P','O','O','L'), .flags = gpu_only, .mem = (uint8_t *)mem + (16 << 20), .size = 16 << 20};
        __weak id<MTLTexture> w3, w4; __weak id<MTLHeap> wh4;
        tex_t u; target(&u, &W, 97041, 0, NVN_FORMAT_RGBA16F, 1024);
        @autoreleasepool { id<MTLTexture> t3 = tex_mtl(&u); w3 = t3; CHECK(t3 && live(u.serial) == t3, "a target made, with its entry"); }
        mtl_alias_drop_pool(&W);
        @autoreleasepool {
            id<MTLTexture> t4 = tex_mtl(&u); w4 = t4; wh4 = t4.heap;
            CHECK(t4 && t4 != w3 && t4.heap, "the late reader makes the texture again for its use, in a recycled heap");
            CHECK(!live(u.serial) && !holds(t4) && !shared(t4) && alias_pool_n(&W) == 0, "and keeps no entry: none under the serial, none in the sharing table under the dead pool's key");
        }
        res_commit();   // the residency set's queued change lets go of it: from here only the retirement holds it
        CHECK(w4 && !rh_waits(wh4), "what it made is retired: kept until the submission in flight completes, its heap not handed out for reuse before that");
        W.magic = 0;
        settle();
        CHECK(!w3 && !w4, "both are freed once the submission in flight completes, the object still live");
        // The same serial initialized again, on a new pool: the mark goes, and its texture is kept again
        pool_t W2 = W; W2.magic = MAGIC('P','O','O','L');
        target(&u, &W2, 97041, 0, NVN_FORMAT_RGBA16F, 64);
        @autoreleasepool { id<MTLTexture> t5 = tex_mtl(&u); CHECK(!ended(u.serial) && t5 && live(u.serial) == t5 && alias_pool_n(&W2) == 1, "initialized again on another pool, it keeps its entry"); }
        step("a resolution that read the magic just before the Finalize");

        // A package made for such a serial is kept by nothing and leaves no packaged-texture entry under the dead pool's key; a part of a package another holder keeps (cpu_unc_drop
        // hands the package's texture to its serials) is refused but left to that holder
        pool_t X = {.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = (uint8_t *)mem + (32 << 20), .size = 16 << 20};
        tex_t m1, m2; target(&m1, &X, 97042, 0, NVN_FORMAT_RGBA8, 16); target(&m2, &X, 97043, 1 << 16, NVN_FORMAT_RGBA8, 16);
        NvPkg * __weak wkeep, * __weak wnew; __weak id<MTLTexture> wkt, wnt;
        @autoreleasepool {
            NvPkg *keep = [NvPkg new]; keep->tex = plain(); res_add(keep->tex);
            tex_put(m1.serial, keep); mtl_tex_pin(m1.serial);   // a queued descriptor holds m1's package
            wkeep = keep; wkt = keep->tex;
        }
        mtl_alias_drop_pool(&X);
        @autoreleasepool {
            CHECK(ended(m1.serial) && ended(m2.serial) && !live(m1.serial), "the Finalize ends m1's entry and marks both serials");
            CHECK(!tex_put(m1.serial, wkt) && !live(m1.serial), "the package's texture handed to m1 is refused");
            NvPkg *np = [NvPkg new]; np->tex = plain(); res_add(np->tex); wnew = np; wnt = np->tex;
            CHECK(!tex_put_made(&m2, fin_snap(), np) && !live(m2.serial), "a package made for m2 is refused");
            pkg_put(&m2, np);
            CHECK(!pkg_shared(&m2), "and is no packaged texture under the dead pool's key");
        }
        X.magic = 0;
        settle();
        CHECK(wkeep && wkt && resident(wkt), "the pinned package keeps its texture, resident");
        CHECK(!wnew && !wnt, "the package made for m2 is freed with its texture once the submission in flight completes");
        mtl_tex_unpin(m1.serial); settle();
        CHECK(!wkeep && !wkt, "unpinned, the package goes too");
        mtl_tex_release(&m1); mtl_tex_release(&m2); mtl_tex_release(&u); pool_finalize(&W2);
        step("packages after the Finalize");
        pthread_mutex_lock(&g_smu); int none = !g_pool_ended.n && !g_pool_tex.n && !g_tex_pool.n; pthread_mutex_unlock(&g_smu);
        CHECK(none, "no mark is left, and the index is empty");
    }
    // ---- Resolutions that read the pool as live just before a game thread's Finalize cleared its magic, and do the rest after the Finalize (it runs at g_pool_read_after):
    // whatever has become of the serial meanwhile (live, finalized before its pool, finalized between), nothing they make keeps an entry, under the serial or under the dead pool's
    // key, and what they made is retired: kept until the submission in flight completes (a recycled heap not handed out for reuse before that), then freed, out of the residency set.
    // The finalize count each read before the magic (fin_snap) is what tells them (pool_fin_since): g_pool_ended marks only the serials live at the Finalize, while they live
    g_pool_read_after = race_finalize;
    {
        const int cpu_vis = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED;
        static pool_t rp[8];
        char l[300];
        // Made textures: a target in a recycled heap whose object was finalized before its pool (the usual NVN teardown order), resolved off the submit thread (the present thread, a
        // ReadTexels thread: no fill of the new texture there, whose upload batch would hold it too); one of a pool the CPU can read (an allocation of its own, which the residency set
        // holds by itself) whose object is finalized between; and one whose object lives on
        struct { const char *what; int flags, obj; NVNformat fmt; unsigned w; } cs[] = {
            {"a target finalized before its pool, resolved off the submit thread", gpu_only, 0, NVN_FORMAT_RGBA16F, 1024},
            {"a texture finalized between its pool's Finalize and the put", cpu_vis, 1, NVN_FORMAT_RGBA8, 64},
            {"a texture whose object lives on", cpu_vis, 2, NVN_FORMAT_RGBA8, 64},
        };
        for (int c = 0; c < 3; c++) {
            pool_t *G = &rp[c]; *G = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = cs[c].flags, .mem = mem, .size = 16 << 20};
            tex_t g; target(&g, G, 97050 + (uint64_t)c, 0, cs[c].fmt, cs[c].w);
            if (cs[c].obj == 0) mtl_tex_release(&g);
            race(G, cs[c].obj == 1 ? &g : NULL);
            res_case rc = {&g, G};
            if (c == 0) { pthread_t th; CHECK(!pthread_create(&th, NULL, resolve_case, &rc), "a thread of its own"); pthread_join(th, NULL); } else resolve_case(&rc);
            snprintf(l, sizeof l, "%s: the Finalize lands as it resolves, and it makes the texture for its use (%s)", cs[c].what, c ? "an allocation of its own, resident" : "in a recycled heap");
            CHECK(raced == 1 && G->magic == 0 && (c ? rc.own : rc.heap), l);
            snprintf(l, sizeof l, "%s: it keeps no entry, live or finalized, and none in the sharing table under the dead pool's key", cs[c].what);
            CHECK(!rc.kept, l);
            res_commit();   // the residency set's queued change lets go of it: from here only the retirement holds it
            snprintf(l, sizeof l, "%s: what it made is retired, kept until the submission in flight completes%s", cs[c].what, c ? "" : ", its heap not handed out for reuse before that");
            CHECK(g_rc_w && !rh_waits(g_rc_wh), l);
            settle();
            snprintf(l, sizeof l, "%s: then freed, out of the residency set", cs[c].what);
            CHECK(!g_rc_w, l);
            if (cs[c].obj == 2) mtl_tex_release(&g);
        }
        // A buffer texture (a view on the pool's buffer, resident by itself): refused and retired as well
        {
            void *bm = NULL; posix_memalign(&bm, 16384, 1 << 20); memset(bm, 0, 1 << 20);
            pool_t *B = &rp[3]; *B = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = cpu_vis, .mem = bm, .size = 1 << 20};
            mtl_pool_add(B->mem, B->size);
            tex_t b = {.magic = MAGIC('T','E','X',0), .serial = 97053, .pool = B, .mem = B->mem, .off = 0};
            b.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32F, .width = 1024, .height = 1, .depth = 1, .levels = 1, .samples = 1};
            nvn_tex_layout(&b.d, &b.L); mtl_tex_init(&b);
            race(B, NULL); __weak id<MTLTexture> w;
            @autoreleasepool { id<MTLTexture> t = tex_mtl(&b); w = t; CHECK(raced == 1 && t && t.buffer && !live(b.serial) && !holds(t), "a buffer texture resolved as its pool's Finalize lands: made for its use, no entry"); }
            CHECK(w, "the buffer texture is kept until the submission in flight completes");
            settle();
            CHECK(!w, "then freed, out of the residency set");
            mtl_tex_release(&b); mtl_pool_del(B->mem); settle(); free(bm);
        }
        // A package made for a serial finalized before its pool, taken from its storage: the serial's entry and the packaged-texture entry are put in one hold or not at all
        {
            pool_t *C = &rp[4]; *C = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = cpu_vis, .mem = (uint8_t *)mem + (32 << 20), .size = 16 << 20};
            tex_t k = {.magic = MAGIC('T','E','X',0), .serial = 97054, .pool = C, .mem = C->mem, .off = 0};
            k.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 16, .height = 16, .depth = 1, .levels = 1, .samples = 1};
            nvn_tex_layout(&k.d, &k.L); mtl_tex_init(&k); mtl_tex_cpu_written(&k); mtl_tex_release(&k);   // CPU-written, its object finalized first
            race(C, NULL); __weak id<MTLTexture> w;
            @autoreleasepool {
                id<MTLTexture> t = tex_mtl(&k); w = t;
                CHECK(raced == 1 && t && !ghost(k.serial) && !holds(t) && !pkg_shared(&k), "a package made for a finalized serial as its pool's Finalize lands: no entry under the serial, none in the packaged-texture table");
            }
            CHECK(w, "its texture is kept until the submission in flight completes");
            settle();
            CHECK(!w, "then freed with its package");
        }
        // An sRGB view a queued descriptor holds, its pool and then its object finalized, upgraded (tex_upgrade: a format view of it wanted): the upgrade finds the pool gone, makes
        // the view again on a new parent for its use and keeps it under no serial; the new parent is retired with it
        {
            pool_t *U = &rp[5]; *U = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = gpu_only, .mem = mem, .size = 16 << 20};
            tex_t ua, uv; target(&ua, U, 97055, 0, NVN_FORMAT_RGBA8, 64); target(&uv, U, 97056, 0, NVN_FORMAT_RGBA8_SRGB, 64);
            __weak id<MTLTexture> wp;
            @autoreleasepool {
                id<MTLTexture> tb = tex_mtl(&ua), v = tex_mtl(&uv);
                CHECK(tb && v && v.parentTexture == tb && live(uv.serial) == v, "an sRGB view of a target, under its own serial");
            }
            mtl_tex_pin(uv.serial); pool_finalize(U); mtl_tex_release(&uv);
            @autoreleasepool {
                id<MTLTexture> held = tex_get(uv.serial);
                id<MTLTexture> up = tex_upgrade(&uv, held, MTLTextureUsagePixelFormatView, MTLPixelFormatRGBA8Unorm); wp = up.parentTexture;
                CHECK(held && up && up != held && wp && wp != held.parentTexture, "the pinned view upgraded after its pool's Finalize: made again on a new parent");
                CHECK(!live(uv.serial) && !ghost(uv.serial) && !holds(up) && !holds(wp), "and kept under no serial, live or finalized");
            }
            CHECK(wp, "the new parent is kept until the submission in flight completes");
            mtl_tex_unpin(uv.serial); settle();
            CHECK(!wp, "then freed, out of the residency set");
            mtl_tex_release(&ua);
        }
        // The finalized pools' table stays bounded: past POOL_FIN_KEEP addresses it keeps the newest half, and a reading older than those let go counts as finalized since
        {
            enum { NP = POOL_FIN_KEEP + 1000 }; static pool_t many[NP]; pool_t never = {.magic = MAGIC('P','O','O','L')};
            uint64_t fs0 = fin_snap(), fs1 = 0;
            for (int i = 0; i < NP; i++) { many[i].magic = MAGIC('P','O','O','L'); if (i == NP - 1) fs1 = fin_snap(); pool_finalize(&many[i]); }
            uint64_t fs2 = fin_snap();
            pthread_mutex_lock(&g_smu);
            unsigned n = g_pool_fin.n; uint64_t fl = g_pool_fin_floor;
            int old = pool_fin_since(&never, fs0), fresh = pool_fin_since(&never, fs2), last = pool_fin_since(&many[NP - 1], fs1), last_now = pool_fin_since(&many[NP - 1], fs2);
            pthread_mutex_unlock(&g_smu);
            CHECK(fs2 == fs0 + NP && n > 0 && n <= POOL_FIN_KEEP && fl > fs0, "the finalized pools' table stays within POOL_FIN_KEEP addresses");
            CHECK(old && !fresh, "a reading older than the addresses let go counts as finalized since, a fresh one does not");
            CHECK(last && !last_now, "a pool finalized after a reading is found so; one finalized before it is not");
        }
        step("the resolutions that read the pool before its Finalize");
        pthread_mutex_lock(&g_smu); int none = !g_pool_ended.n && !g_pool_tex.n && !g_tex_pool.n; pthread_mutex_unlock(&g_smu);
        CHECK(none, "no mark is left, and the index is empty, again");
    }
    g_pool_read_after = NULL;
    mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "no GPU error");
    free(mem);
    printf("t_pool_finalize: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
