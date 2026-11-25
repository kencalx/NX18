// Packaged texture edges left out when their pages are not in memory (DM_NVN_EDGE_COLD): pages_incore says in memory for pages just written and not for a file's pages never read,
// and a range over pages of both kinds is not in memory; a range past four pages is taken as in memory (the old behaviour), as is one mincore refuses
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
int main(void) { @autoreleasepool {
    size_t pg = getpagesize(), n = 16 * pg;
    const char *td = getenv("TMPDIR"); char path[512]; snprintf(path, sizeof path, "%s/t_edge_cold.XXXXXX", td && *td ? td : "/tmp");
    int fd = mkstemp(path); if (fd < 0) abort(); unlink(path);
    if (ftruncate(fd, (off_t)n)) abort();
    uint8_t *m = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); if (m == MAP_FAILED) abort(); close(fd);
    m[0] = 1; m[pg + 100] = 2;   // pages 0 and 1 in memory; the rest never touched
    CHECK("a page just written: in memory", pages_incore((uintptr_t)m + 10, (uintptr_t)m + 200));
    CHECK("two written pages", pages_incore((uintptr_t)m + pg - 8, (uintptr_t)m + pg + 8));
    CHECK("a page never read: out", !pages_incore((uintptr_t)m + 5 * pg + 4, (uintptr_t)m + 5 * pg + 64));
    CHECK("one written page and one never read: out", !pages_incore((uintptr_t)m + 2 * pg - 8, (uintptr_t)m + 2 * pg + 8));
    CHECK("more than four pages: taken as in memory", pages_incore((uintptr_t)m + 6 * pg, (uintptr_t)m + 12 * pg));
    CHECK("an empty range: in memory", pages_incore((uintptr_t)m + 6 * pg, (uintptr_t)m + 6 * pg));
    CHECK("on by default", edge_cold_on());
    printf("t_edge_cold: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}}
