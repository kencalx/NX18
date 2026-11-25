// Whole CPU reads of texture storage the CPU cannot read (nvn_mtl.m tex_src; ported from S2Arm 90bda409, 5eb20239, f94ab7f1, 19710ac2, Apache-2.0, whose
// t_nvn_ph_hash ④ and t_nvn_pkg_unreadable cases these are, on this tree's upload and readback paths). Expected values are worked out by hand, not by the code under test:
// - mem_readable: a last page with no access, a start inside the range, an unmapped last page.
// - A texture whose pool pointer is set but whose storage is a page with no access next to the pool (the case behind "not in a memory pool; falling back to the CPU"):
//   pkg_upload makes the 16x16 texture with every texel 0 and one red line, no SIGBUS. Before the port the CPU deswizzle read the page and the process stopped with a bus error.
// - The same storage through ReadTexels (read_texels_storage): zeros, no fault.
// - A page that was written (resident) and then made inaccessible: tex_src gives a copy of zeros; made readable again, a copy that matches it byte for byte (out of the pools).
// - A page whose protection reads but whose backing file was truncated (MAP_SHARED): tex_src gives zeros, no fault.
// - Storage in a registered pool with every page readable: tex_src uses the storage itself, no copy, no red line.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#include <sys/mman.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static void tex16(tex_t *t, uint8_t *mem, pool_t *pool, uint64_t serial) {
    memset(t, 0, sizeof *t);
    *t = (tex_t){.magic = MAGIC('T', 'E', 'X', 0), .has_layout = 1, .serial = serial};
    t->d = (nvn_texdesc){.target = 1, .format = NVN_FORMAT_RGBA8, .width = 16, .height = 16, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t->d, &t->L); t->mem = mem; t->pool = pool;
}
static int all_zero(const uint8_t *p, size_t n) { for (size_t i = 0; i < n; i++) if (p[i]) return 0; return 1; }
static int texels_zero(id<MTLTexture> tex) {   // the 16x16 RGBA8 texture read back on the GPU
    id<MTLBuffer> rb = [g_dev newBufferWithLength:16 * 16 * 4 options:MTLResourceStorageModeShared];
    memset(rb.contents, 0xee, rb.length);
    T4 *cb = t4_begin(); t4_use(cb, tex); t4_use(cb, rb);
    id<MTL4ComputeCommandEncoder> ce = t4_copy(cb);
    [ce copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(16, 16, 1) toBuffer:rb destinationOffset:0
        destinationBytesPerRow:16 * 4 destinationBytesPerImage:16 * 16 * 4 options:MTLBlitOptionNone];
    t4_end(cb, ce);
    return t4_wait(cb) == MTLCommandBufferStatusCompleted && all_zero(rb.contents, rb.length);
}

int main(void) { @autoreleasepool {
    mtl_init();
    size_t pg = (size_t)getpagesize();
    {   // mem_readable, by hand: three pages, the last with no access → 2 pages from the start, 1 from the second; the last unmapped → 2
        uint8_t *m = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (m == MAP_FAILED) abort();
        CHECK("all three pages read", mem_readable(m, 3 * pg) == 3 * pg);
        mprotect(m + 2 * pg, pg, PROT_NONE);
        CHECK("a last page with no access: two pages", mem_readable(m, 3 * pg) == 2 * pg);
        CHECK("from the second page: one", mem_readable(m + pg, 2 * pg) == pg);
        munmap(m, 3 * pg);
        uint8_t *q = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (q == MAP_FAILED) abort();
        munmap(q + 2 * pg, pg);
        CHECK("an unmapped last page: two pages", mem_readable(q, 3 * pg) == 2 * pg);
        munmap(q, 2 * pg);
    }
    {   // the storage a page with no access just before the pool, the pool pointer set
        uint8_t *reg = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (reg == MAP_FAILED) abort();
        if (mprotect(reg, pg, PROT_NONE)) abort();
        static pool_t pool; pool.magic = MAGIC('P', 'O', 'O', 'L'); pool.mem = reg + pg; pool.size = 2 * pg;
        static tex_t t; tex16(&t, reg, &pool, 91001);
        CHECK("the layout fits in the page", t.L.size <= pg);
        int red0 = g_red_once[180];
        mtl_sub_begin();
        id<MTLTexture> mt = pkg_upload(&t, NULL, nil, 0, NULL);
        CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
        CHECK("unreadable storage: the 16x16 texture is made", mt && mt.width == 16 && mt.height == 16);
        CHECK("  every texel 0", mt && texels_zero(mt));
        CHECK("  one red line", g_red_once[180] == red0 + 1);
        uint8_t px[16 * 4]; memset(px, 0xee, sizeof px);
        NVNcopyRegion r = {0, 0, 0, 16, 1, 1};
        read_texels_storage(&t, 0, 0, &r, px, sizeof px, sizeof px);
        CHECK("ReadTexels of it: zeros, no fault", all_zero(px, sizeof px));
        munmap(reg, 3 * pg);
    }
    {   // written (resident), then no access: a copy of zeros; readable again: a copy equal to it (out of the pools, so never used in place)
        uint8_t *r2 = mmap(NULL, 2 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (r2 == MAP_FAILED) abort();
        memset(r2, 0x5a, 2 * pg); if (mprotect(r2, pg, PROT_NONE)) abort();
        static pool_t p2; p2.mem = r2; p2.size = 2 * pg;
        static tex_t t2; tex16(&t2, r2, &p2, 91002);
        uint8_t *pp = NULL; const uint8_t *ss = tex_src(&t2, t2.L.size, &pp);
        CHECK("resident but no access: a copy, all 0", ss != t2.mem && pp && all_zero(ss, t2.L.size));
        free(pp);
        if (mprotect(r2, pg, PROT_READ | PROT_WRITE)) abort();
        ss = tex_src(&t2, t2.L.size, &pp);
        CHECK("readable again, out of the pools: a copy equal to the storage", ss && pp && !memcmp(ss, t2.mem, t2.L.size));
        free(pp); munmap(r2, 2 * pg);
    }
    {   // protection reads, the file behind it is gone: zeros, no SIGBUS
        char fp[] = "/tmp/t_tex_unreadable_XXXXXX"; int fd = mkstemp(fp); if (fd < 0) abort(); unlink(fp); if (ftruncate(fd, (off_t)(2 * pg))) abort();
        uint8_t *r3 = mmap(NULL, 2 * pg, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); if (r3 == MAP_FAILED) abort();
        memset(r3, 0x77, 2 * pg); if (ftruncate(fd, 0)) abort();
        static pool_t p3; p3.mem = r3; p3.size = 2 * pg;
        static tex_t t3; tex16(&t3, r3, &p3, 91003);
        uint8_t *pp = NULL; const uint8_t *s3 = tex_src(&t3, t3.L.size, &pp);
        CHECK("readable protection over a truncated file: a copy of zeros", s3 != t3.mem && pp && all_zero(s3, t3.L.size));
        free(pp); munmap(r3, 2 * pg); close(fd);
    }
    {   // in a registered pool, every page readable: the storage itself
        uint8_t *m4 = mmap(NULL, 4 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (m4 == MAP_FAILED) abort();
        memset(m4, 0x33, 4 * pg);
        mtl_pool_add(m4, 4 * pg);
        static pool_t p4; p4.mem = m4; p4.size = 4 * pg;
        static tex_t t4; tex16(&t4, m4 + pg, &p4, 91004);
        int red0 = g_red_once[180];
        uint8_t *pp = (uint8_t *)1; const uint8_t *s4 = tex_src(&t4, t4.L.size, &pp);
        CHECK("in a pool and readable: no copy", s4 == t4.mem && !pp);
        CHECK("  no red line", g_red_once[180] == red0);
        mtl_pool_del(m4);
    }
    printf("%s t_tex_unreadable: %d checks, %d failed\n", failed ? "✗" : "✓", checks, failed);
    return failed != 0;
} }
