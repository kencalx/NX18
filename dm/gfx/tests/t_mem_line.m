// The 300-frame memory line (mtl_mem_stat) gives what memory really holds beside GPU allocated: "graphics ledger N MB" (the kernel's graphics ledger, what Metal holds) and
// "guest charged N MB" (the guest block's dirty pages, each VM object counted once, file-backed pages left out; only with DM_MEM_GUEST=1, as the walk stalled Ocarina's frames), right after "GPU allocated N MB", the text scripts/devlog.py reads.
// A guest block of its own (mem_line_guest.c's svc_guest_range): 64 MB written, a second mapping of 32 MB of those pages (counted once), 16 MB of a written file (not counted), and
// two no-copy Metal buffers over the 64 MB that raise GPU allocated by 128 MB and the graphics ledger by about nothing. NieR:Automata read GPU allocated 4,020 MB with 1,477 MB in the ledger
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
extern uint8_t *g_t_guest_base; extern size_t g_t_guest_size;
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } else printf("PASS: %s\n", label); } while (0)
enum { MB = 1 << 20, BLOCK = 256 * MB, WRITTEN = 64 * MB, ALIAS_AT = 128 * MB, ALIAS = 32 * MB, FILE_AT = 192 * MB, FILE_MB = 16 * MB };
// The memory line as mtl_mem_stat prints it, read back from stderr
static int mem_line(char *out, size_t cap, unsigned long long frame) {
    char path[] = "/tmp/t_mem_line.XXXXXX"; int fd = mkstemp(path); if (fd < 0) return 0;
    fflush(stderr); int saved = dup(2); dup2(fd, 2);
    task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT; task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n);
    mtl_mem_stat(frame, vi.phys_footprint >> 20);
    dispatch_sync(g_mem_q, ^{});   // the line is printed on its own queue, after the guest block's walk
    fflush(stderr); dup2(saved, 2); close(saved);
    FILE *f = fopen(path, "r"); unlink(path); close(fd); if (!f) return 0;
    char line[8192]; int got = 0; while (fgets(line, sizeof line, f)) if (strstr(line, "memory up to frame")) { strlcpy(out, line, cap); got = 1; }
    fclose(f); return got;
}
int main(void) { @autoreleasepool {
    mtl_init();
    // The guest block: reserved whole, the first 64 MB written
    uint8_t *g = mmap(NULL, BLOCK, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (g == MAP_FAILED) abort();
    memset(g, 0x5a, WRITTEN);
    // A second mapping of the first 32 MB (MapMemory's alias does this): the same pages, counted once
    vm_address_t alias = (vm_address_t)(g + ALIAS_AT); vm_prot_t cur, max;
    kern_return_t kr = vm_remap(mach_task_self(), &alias, ALIAS, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)g, FALSE, &cur, &max, VM_INHERIT_NONE);
    CHECK(kr == KERN_SUCCESS && alias == (vm_address_t)(g + ALIAS_AT), "a second mapping of 32 MB of the written pages inside the block");
    // A file mapped into the block and written (DM_GUEST_FILE): its pages are not in the footprint, so not charged
    char fpath[] = "/tmp/t_mem_line_file.XXXXXX"; int ffd = mkstemp(fpath); unlink(fpath); if (ffd < 0 || ftruncate(ffd, FILE_MB)) abort();
    uint8_t *fm = mmap(g + FILE_AT, FILE_MB, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, ffd, 0); if (fm != g + FILE_AT) abort();
    memset(fm, 0x33, FILE_MB);
    g_t_guest_base = g; g_t_guest_size = BLOCK;
    uint64_t charged = mem_guest_charged() / MB;
    printf("guest charged %llu MB (64 MB written, 32 MB of it mapped twice, 16 MB of a file)\n", (unsigned long long)charged);
    CHECK(charged >= 64 && charged <= 66, "guest charged: the written 64 MB, the second mapping counted once, the file's pages left out");
    // The cost of the walk with the block split into a region per protection run, as dirty-page tracking splits it: every other 16 KB page of the 64 MB read-only
    for (size_t o = 0; o < WRITTEN; o += 2 * 16384) mprotect(g + o, 16384, PROT_READ);
    uint64_t t0 = now_ns(); uint64_t split = mem_guest_charged() / MB; uint64_t walk_ns = now_ns() - t0;
    printf("guest charged with 4,096 protection runs: %llu MB in %.2f ms\n", (unsigned long long)split, walk_ns / 1e6);
    CHECK(split == charged, "guest charged is the same with the block split into protection runs");
    for (size_t o = 0; o < WRITTEN; o += 2 * 16384) mprotect(g + o, 16384, PROT_READ | PROT_WRITE);
    // Two no-copy buffers over the written pages, as overlapping pool chunks are: GPU allocated rises by both, the graphics ledger by about nothing
    // The first command buffer on a queue charges the ledger once for Metal's own setup (about 160 MB on an M4 Max, at the first blit): a small one before the figures are taken
    { id<MTLBuffer> s = [g_dev newBufferWithLength:16384 options:MTLResourceStorageModePrivate]; T4 *w = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(w);
      t4_use(w, s), [e fillBuffer:s range:NSMakeRange(0, 16384) value:1]; t4_end(w, e); t4_wait(w); }
    uint64_t gpu0 = g_dev.currentAllocatedSize, led0 = mem_graphics_ledger();
    id<MTLBuffer> w1 = [g_dev newBufferWithBytesNoCopy:g length:WRITTEN options:MTLResourceStorageModeShared deallocator:nil];
    id<MTLBuffer> w2 = [g_dev newBufferWithBytesNoCopy:g length:WRITTEN options:MTLResourceStorageModeShared deallocator:nil];
    CHECK(w1 && w2, "two no-copy buffers over the guest's written pages");
    // 64 MB of private memory the GPU writes: the graphics ledger rises by it
    id<MTLBuffer> priv = [g_dev newBufferWithLength:WRITTEN options:MTLResourceStorageModePrivate];
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> b = t4_copy(cb); t4_use(cb, priv), [b fillBuffer:priv range:NSMakeRange(0, WRITTEN) value:7]; t4_end(cb, b); t4_wait(cb);
    uint64_t gpu1 = g_dev.currentAllocatedSize, led1 = mem_graphics_ledger();
    printf("GPU allocated +%lld MB, graphics ledger +%lld MB\n", ((long long)gpu1 - (long long)gpu0) / MB, ((long long)led1 - (long long)led0) / MB);
    CHECK(gpu1 - gpu0 >= 3ull * WRITTEN, "GPU allocated counts the no-copy windows and the private buffer: 192 MB or more");
    CHECK(led1 >= led0 + WRITTEN - 8 * MB && led1 <= led0 + WRITTEN + 32 * MB, "the graphics ledger rises by the private buffer alone");
    // By default the line has the graphics ledger and no guest charged: the guest block's walk is not run
    char line[8192] = "";
    unsetenv("DM_MEM_GUEST");
    CHECK(mem_line(line, sizeof line, 300), "the memory line is printed");
    printf("%s", line);
    unsigned long long res = 0, gpu = 0, led = 0, gst = 0; const char *p = strstr(line, "memory up to frame");
    int n0 = p ? sscanf(p, "memory up to frame %*u: resident %llu MB, GPU allocated %llu MB, graphics ledger %llu MB, deferred-release queue", &res, &gpu, &led) : 0;
    CHECK(n0 == 3 && !strstr(line, "guest charged"), "by default the line reads \"GPU allocated N MB, graphics ledger N MB, deferred-release queue\", with no guest charged");
    // With DM_MEM_GUEST=1: both fields, right after GPU allocated, with the figures just read (a line 3,000 frames on, which the line's own rate limit lets through)
    setenv("DM_MEM_GUEST", "1", 1);
    CHECK(mem_line(line, sizeof line, 3300), "the memory line is printed with DM_MEM_GUEST=1");
    unsetenv("DM_MEM_GUEST");
    printf("%s", line);
    res = gpu = led = 0; p = strstr(line, "memory up to frame");
    int n = p ? sscanf(p, "memory up to frame %*u: resident %llu MB, GPU allocated %llu MB, graphics ledger %llu MB, guest charged %llu MB, deferred-release queue", &res, &gpu, &led, &gst) : 0;
    CHECK(n == 4, "with DM_MEM_GUEST=1 the line reads \"GPU allocated N MB, graphics ledger N MB, guest charged N MB, deferred-release queue\"");
    CHECK(gst == charged, "the line's guest charged is the guest block's charged pages");
    uint64_t led_now = mem_graphics_ledger() / MB;
    CHECK(led + 16 >= led_now && led <= led_now + 16, "the line's graphics ledger is the kernel's graphics ledger");
    CHECK((long long)gpu - (long long)led >= ((long long)gpu0 - (long long)led0) / MB + 120, "the line shows the overcount: the two no-copy windows raised GPU allocated 128 MB more than the graphics ledger");
    CHECK(led > 0 && led <= res, "the graphics ledger is part of the resident footprint");
    (void)w1; (void)w2; (void)priv;
    printf("t_mem_line: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
