// A shared buffer over file-backed pages joins the residency set with its pages already resident, wired through the CPU's fault path (mlock) by the commit before [g_res commit],
// and that wiring is given back once the commit has made the pages resident for the GPU (port of NXNative 2261a388, with its test). With the guest's memory in files (DM_GUEST_FILE) the commit
// itself paged the file in from the GPU driver's wiring path; on upstream's M1 iPad that page-in waited for good on an APFS lock, and Ocarina of Time froze the same way on the
// iPhone 18 Pro Max: sound and no picture (docs/reference/memory.md, "The residency commit froze over the guest's files"). Anonymous memory is not touched. NX 18's own checks:
// res_add wires nothing (its callers may hold g_mu, the pool table's lock: a page-in there stalled every pool lookup), the commit wires the pages under its mark, so a page-in
// that sticks is named as a commit in the kernel would be, the residency line counts what was wired, nothing is left marked as a commit in the kernel once the commit is back
// (mtl_res_commit_stuck), and an mlock the system refuses (RLIMIT_MEMLOCK) leaves the commit to page the file in as before, with one red line that gives the reason. The page-in
// runs in calls of g_fwire_call bytes, each after the last (one call over a pool held the guest's mprotects on all of it until it returned), with its progress in the mark, and a
// slow call is said once and counted, and the calls go on: stopping would send the rest through the commit's own page-in, the path that froze, with the commit no shorter.
// The add stays cheap and waits for nothing: whether a buffer is file-backed comes from the guest's layout inside its block and from one short kernel look outside it, never
// from a walk of the map entry around the buffer (Donkey Kong Bananza's first load spent 428.5 ms of a frame in such walks), an add made while a commit wires returns at once,
// and the read-ahead goes in batches of merged ranges
#include "../nvn/nvn_mtl.m"
#include <mach/mach_vm.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
// The smallest and largest user wiring count over [p, p + n)
static void wired(const void *p, size_t n, unsigned *lo, unsigned *hi) {
    mach_vm_address_t a = (mach_vm_address_t)p, e = a + n; *lo = ~0u; *hi = 0;
    while (a < e) {
        mach_vm_size_t sz = 0; natural_t depth = 0; vm_region_submap_info_data_64_t info; mach_msg_type_number_t c = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (mach_vm_region_recurse(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &c) || a >= e) break;
        if (info.user_wired_count < *lo) *lo = info.user_wired_count;
        if (info.user_wired_count > *hi) *hi = info.user_wired_count;
        a += sz;
    }
}
static int all_resident(const void *p, size_t n) {
    size_t pg = getpagesize(), np = n / pg; char *v = malloc(np); int ok = !mincore(p, n, v);
    for (size_t i = 0; ok && i < np; i++) ok = v[i] & MINCORE_INCORE;
    free(v); return ok;
}
// What the commit had done just before [g_res commit] (g_res_commit_before): the user wiring over [at_p, at_p + at_n), whether it was resident, and the commit's mark; and the
// largest user wiring over a second range, [at2_p, at2_p + at2_n), when one is set
static const void *at_p, *at2_p; static size_t at_n, at2_n; static unsigned at_lo, at_hi, at2_hi; static int at_res, at_calls; static char at_mark[300];
static void before_commit(void) {
    at_calls++; at_lo = at_hi = at2_hi = 0; at_res = 0; at_mark[0] = 0;
    if (at_p) { wired(at_p, at_n, &at_lo, &at_hi); at_res = all_resident(at_p, at_n); }
    if (at2_p) { unsigned lo2; wired(at2_p, at2_n, &lo2, &at2_hi); }
    mtl_res_commit_stuck(0, at_mark, sizeof at_mark);
}
// Each mlock call of a commit's page-in (g_fwire_call_before): how many there were, the mark at the third, whether before each call k exactly the k calls before it had wired their
// pages, and a delay that makes call slow_at slow (its time counts as the call's)
static int call_n, call_ok, call_slow_at = -1; static size_t call_sz; static char call_mark[300];
static void before_call(void) {
    unsigned lo, hi;
    if (call_n) { wired(at_p, call_n * call_sz, &lo, &hi); if (lo != 1 || hi != 1) call_ok = 0; }
    if ((size_t)call_n * call_sz < at_n) { wired((const char *)at_p + call_n * call_sz, at_n - call_n * call_sz, &lo, &hi); if (hi) call_ok = 0; }
    if (call_n == 2) mtl_res_commit_stuck(0, call_mark, sizeof call_mark);
    if (call_n == call_slow_at) usleep(120000);   // over g_fwire_slow_ns as the test sets it (50 ms), which a page-in of a quarter of the buffer stays far under
    call_n++;
}
// The read-ahead of a range res_add notes (g_fwire_advise_hook, for dm_guest_file_advise): the ranges asked for, on which thread, and a hold (adv_hold) that keeps the next one waiting
// until the test lets it go (so a res_add that waited for it would be seen)
static const void *adv_p[8]; static size_t adv_n[8]; static _Atomic int adv_k, adv_hold; static pthread_t adv_th; static dispatch_semaphore_t adv_go;
static uint64_t advise_rec(const void *p, size_t n) {
    int k = atomic_load(&adv_k); if (k < 8) { adv_p[k] = p; adv_n[k] = n; } adv_th = pthread_self();
    if (atomic_exchange(&adv_hold, 0) && adv_go) dispatch_semaphore_wait(adv_go, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    atomic_fetch_add(&adv_k, 1);
    return n;
}
// The guest's block as the host's layout gives it (g_fwire_backed_hook, for dm_guest_file_backed): [gb_lo, gb_hi) in the guest's files (gb_files) or anonymous; -1 outside it
static uintptr_t gb_lo, gb_hi; static int gb_files;
static int backed_rec(const void *p, size_t n) { uintptr_t a = (uintptr_t)p; return a >= gb_lo && a < gb_hi && n <= gb_hi - a ? gb_files : -1; }
// A commit on a thread of its own whose first mlock call waits until the test lets it go (wire_go), having said it began (wire_in): adds made meanwhile must not wait for it
static dispatch_semaphore_t wire_in, wire_go; static _Atomic int wire_calls;
static void before_call_held(void) { if (!atomic_fetch_add(&wire_calls, 1)) { dispatch_semaphore_signal(wire_in); dispatch_semaphore_wait(wire_go, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)); } }
static void *commit_thread(void *arg) { (void)arg; @autoreleasepool { res_commit(); } return NULL; }
static uint64_t ns_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
// A slow call (20 ms) that counts how many run at once (DM_NVN_PREWIRE_JOBS)
static _Atomic int par_in, par_max;
static void par_call(void) { int k = atomic_fetch_add(&par_in, 1) + 1; for (int m = atomic_load(&par_max); k > m && !atomic_compare_exchange_weak(&par_max, &m, k);) {} usleep(20000); atomic_fetch_sub(&par_in, 1); }
static uint64_t looks(void) { return atomic_load(&g_fwire_looks); }
static int in_set(id<MTLAllocation> b) { res_mu_lock(); int r = [g_res_objects containsObject:b]; res_mu_unlock(); return r; }
// What fn writes to stderr (MLOG)
static char g_out[8192];
static void logged(void (^fn)(void)) {
    char path[] = "/tmp/t_file_wire_log.XXXXXX"; int fd = mkstemp(path); g_out[0] = 0; if (fd < 0) { fn(); return; }
    fflush(stderr); int saved = dup(2); dup2(fd, 2); fn(); fflush(stderr); dup2(saved, 2); close(saved);
    FILE *f = fopen(path, "r"); unlink(path); close(fd); if (!f) return;
    char line[2048]; while (fgets(line, sizeof line, f)) strlcat(g_out, line, sizeof g_out);   // NOLINT(clang-analyzer-unix.BlockInCriticalSection): no lock is held here; the analyzer counts lft_lock's failed trylock as a second take that is never released
    fclose(f);
}
int mtl_fwire_stats(char *out, size_t n);
// The residency line and the page-in's own line together (mtl_fwire_stats has the page-in counts since the split): what the checks below read
static void res_line(char *out, size_t n) { mtl_res_stats(out, n); size_t o = strlen(out); if (o + 2 < n) { out[o++] = ','; out[o++] = ' '; out[o] = 0; mtl_fwire_stats(out + o, n - o); } }
int main(void) { @autoreleasepool {
    mtl_init();
    g_pw_jobs = 1;   // DM_NVN_PREWIRE_JOBS=1: the cases above follow one call after another (the parallel page-in has its own case at the end)
    size_t pg = getpagesize(), n = 256 * pg;
    char path[] = "/tmp/t_file_wire.XXXXXX"; int fd = mkstemp(path); if (fd < 0) abort(); unlink(path);
    if (ftruncate(fd, (off_t)n)) abort();
    uint8_t *m = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); if (m == MAP_FAILED) abort();
    memset(m, 0x5a, n / 2);   // half written, half holes
    msync(m, n, MS_SYNC); msync(m, n, MS_INVALIDATE);   // written out and dropped: the next touch is a page-in
    mprotect(m + 16 * pg, 16 * pg, PROT_READ);   // as the write tracking leaves a texture's pages
    unsigned lo, hi; char line[1024];
    res_line(line, sizeof line);   // the counts start from here

    g_res_commit_before = before_commit; g_fwire_advise_hook = advise_rec; adv_go = dispatch_semaphore_create(0);
    id<MTLBuffer> b = [g_dev newBufferWithBytesNoCopy:m length:n options:MTLResourceStorageModeShared deallocator:nil];
    atomic_store(&adv_hold, 1);
    pthread_mutex_lock(&g_mu); res_add(b); pthread_mutex_unlock(&g_mu);   // as pool_res and gmem_map add a pool, under the pool table's lock
    CHECK("res_add does not wait for the read-ahead", atomic_load(&adv_k) == 0);
    dispatch_semaphore_signal(adv_go); dispatch_sync(fwire_adv_q(), ^{});
    CHECK("the buffer's pages are asked for ahead, once, on the read-ahead queue", atomic_load(&adv_k) == 1 && adv_p[0] == m && adv_n[0] == n && !pthread_equal(adv_th, pthread_self()));
    wired(m, n, &lo, &hi);
    CHECK("res_add wires nothing: under g_mu it pages nothing in", hi == 0);
    CHECK("the buffer is in the set", in_set(b));
    at_p = m; at_n = n; at_calls = 0;
    res_commit();
    CHECK("the commit wires the file pages before [g_res commit]", at_calls == 1 && at_lo == 1 && at_hi == 1);
    CHECK("and they are resident: [g_res commit] has nothing to page in", at_res);
    { char want[96]; snprintf(want, sizeof want, " changes, %.0f MB of file pages wired for it)", n / 1048576.0);   // with what mtl_init queued before it
      CHECK("the commit is marked through [g_res commit], with the MB wired for it", !strncmp(at_mark, "a residency commit ([g_res commit], ", 36) && strstr(at_mark, want) != NULL); }
    wired(m, n, &lo, &hi);
    CHECK("the commit gives the user wiring back", lo == 0 && hi == 0);
    CHECK("the bytes are the file's", m[0] == 0x5a && m[n - 1] == 0);
    CHECK("no commit is marked as in the kernel once it is back", !mtl_res_commit_stuck(0, NULL, 0));
    res_line(line, sizeof line);
    { char want[96]; snprintf(want, sizeof want, "file-backed buffers wired before their commit 1, %.0f MB", n / 1048576.0);
      CHECK("the residency line counts the wired buffer", strstr(line, want) != NULL);
      snprintf(want, sizeof want, "), read ahead %.0f MB", n / 1048576.0);
      CHECK("and what was asked for ahead", strstr(line, want) != NULL); }

    // Wiring someone else holds over the range is left as it was (mlock counts)
    mlock(m, 8 * pg);
    id<MTLBuffer> b2 = [g_dev newBufferWithBytesNoCopy:m length:n options:MTLResourceStorageModeShared deallocator:nil];
    res_add(b2); res_commit();
    wired(m, 8 * pg, &lo, &hi);
    CHECK("an mlock taken outside stays", lo == 1 && hi == 1);
    munlock(m, 8 * pg);

    // Added twice before one commit: wired once, given back once
    id<MTLBuffer> b3 = [g_dev newBufferWithBytesNoCopy:m + 128 * pg length:64 * pg options:MTLResourceStorageModeShared deallocator:nil];
    res_add(b3); res_add(b3);
    at_p = m + 128 * pg; at_n = 64 * pg;
    res_commit();
    CHECK("a second res_add of a buffer in the set wires nothing more", at_lo == 1 && at_hi == 1);
    wired(m + 128 * pg, 64 * pg, &lo, &hi);
    CHECK("and the commit leaves nothing wired", lo == 0 && hi == 0);

    // In calls of a quarter of the buffer (8 MB in the host): before each call the calls before it have wired their pages and nothing after them is wired (one call over a pool held
    // the guest's mprotects on all of it), the mark counts the progress, and the whole range is wired before [g_res commit] and given back after it
    res_line(line, sizeof line);   // the counts start from here
    g_fwire_call = call_sz = n / 4; call_n = 0; call_ok = 1; call_mark[0] = 0; g_fwire_call_before = before_call;
    msync(m, n, MS_INVALIDATE);
    id<MTLBuffer> b5 = [g_dev newBufferWithBytesNoCopy:m length:n options:MTLResourceStorageModeShared deallocator:nil];
    at_p = m; at_n = n;
    res_add(b5); res_commit();
    CHECK("the page-in runs in calls of g_fwire_call bytes, each after the last", call_n == 4 && call_ok);
    { char want[160]; snprintf(want, sizeof want, "%.0f MB wired so far in calls of %.0f MB, the current call 0.0 s in)", 2 * call_sz / 1048576.0, call_sz / 1048576.0);
      CHECK("the mark says how far the page-in got and how long the current call has been in", strstr(call_mark, "a residency commit's page-in (mlock of ") && strstr(call_mark, want)); }
    CHECK("the whole range is wired before [g_res commit]", at_lo == 1 && at_hi == 1 && at_res);
    wired(m, n, &lo, &hi);
    CHECK("and given back after it", lo == 0 && hi == 0);
    res_line(line, sizeof line);
    { char want[96]; snprintf(want, sizeof want, "file-backed buffers wired before their commit 1, %.0f MB", n / 1048576.0);
      CHECK("the residency line counts it once", strstr(line, want) && strstr(line, "(refused 0)")); }

    // A slow call (here the second, made slow by the hook) is said once and counted with the longest, and the calls go on: the whole range is wired before [g_res commit], whose own
    // page-in (the driver's wiring, the path that froze) has nothing left to bring in
    g_fwire_slow_ns = 50000000; call_slow_at = 1; call_n = 0; call_ok = 1;
    msync(m, n, MS_INVALIDATE);
    id<MTLBuffer> b6 = [g_dev newBufferWithBytesNoCopy:m length:n options:MTLResourceStorageModeShared deallocator:nil];
    logged(^{ res_add(b6); res_commit(); });
    CHECK("a slow call does not end the buffer's wiring: the calls after it run", call_n == 4 && call_ok);
    CHECK("the whole range is wired and resident before [g_res commit]", at_lo == 1 && at_hi == 1 && at_res);
    { char want[160]; snprintf(want, sizeof want, "(over 50 ms), %.1f of that buffer's %.1f MB wired by then: the calls go on", 2 * call_sz / 1048576.0, n / 1048576.0);
      CHECK("one line says so", strstr(g_out, "residency: an mlock of ") && strstr(g_out, want) && !strstr(g_out, "[RED] residency: an mlock")); }   // not red: nothing is left undone
    CHECK("the buffer joins the set with its bytes", in_set(b6) && m[0] == 0x5a && m[n - 1] == 0);
    wired(m, n, &lo, &hi);
    CHECK("and nothing stays wired", lo == 0 && hi == 0);
    res_line(line, sizeof line);
    { const char *pre = "(refused 0, calls over 50 ms ", *s = strstr(line, pre); unsigned long long k = 0; double ms = 0;   // 1 (more only if the machine stalls a call)
      CHECK("the residency line counts the slow call and gives the longest", s && sscanf(s + strlen(pre), "%llu, the longest %lf ms)", &k, &ms) == 2 && k >= 1 && ms >= 115);
      char want[96]; snprintf(want, sizeof want, "file-backed buffers wired before their commit 1, %.0f MB", n / 1048576.0);
      CHECK("and the buffer as wired whole", strstr(line, want) != NULL); }
    call_n = 0; call_ok = 1;
    id<MTLBuffer> b7 = [g_dev newBufferWithBytesNoCopy:m + 64 * pg length:192 * pg options:MTLResourceStorageModeShared deallocator:nil];   // three calls
    at_p = m + 64 * pg; at_n = 192 * pg;
    logged(^{ res_add(b7); res_commit(); });
    CHECK("a second slow buffer is wired whole and not said again", call_n == 3 && call_ok && at_lo == 1 && at_hi == 1 && !strstr(g_out, "residency: an mlock of "));
    res_line(line, sizeof line);
    CHECK("its slow call is counted", strstr(line, "(refused 0, calls over 50 ms ") != NULL);
    g_fwire_slow_ns = 100000000; call_slow_at = -1; g_fwire_call_before = NULL; g_fwire_call = 8u << 20; at_p = NULL;

    // Anonymous memory: no wiring at all
    uint8_t *a = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (a == MAP_FAILED) abort();
    id<MTLBuffer> ab = [g_dev newBufferWithBytesNoCopy:a length:n options:MTLResourceStorageModeShared deallocator:nil];
    int adv0 = atomic_load(&adv_k);
    res_add(ab);
    wired(a, n, &lo, &hi);
    CHECK("an anonymous range is not wired by res_add", hi == 0);
    dispatch_sync(fwire_adv_q(), ^{});
    CHECK("nor asked for ahead", atomic_load(&adv_k) == adv0);
    res_commit();
    id<MTLBuffer> own = [g_dev newBufferWithLength:n options:MTLResourceStorageModeShared];
    res_add(own); res_commit();
    CHECK("a buffer Metal allocated goes in as before", in_set(own));

    // A wired limit met (RLIMIT_MEMLOCK under the range: EAGAIN, as the system's limit at about 80% of RAM gives): the buffer goes in as before, the commit pages the file in itself,
    // one red line gives the wired count and the limits, the next buffer of the same commit is not tried, nor any at a commit while the wired count leaves no room for a call, and
    // they are wired again once it does
    struct rlimit old; getrlimit(RLIMIT_MEMLOCK, &old);
    struct rlimit small = {pg, old.rlim_max}; int lim_ok = !setrlimit(RLIMIT_MEMLOCK, &small);
    id<MTLBuffer> b4 = [g_dev newBufferWithBytesNoCopy:m length:n options:MTLResourceStorageModeShared deallocator:nil];
    id<MTLBuffer> b8 = [g_dev newBufferWithBytesNoCopy:m + 128 * pg length:64 * pg options:MTLResourceStorageModeShared deallocator:nil];
    id<MTLBuffer> b9 = [g_dev newBufferWithBytesNoCopy:m + 64 * pg length:64 * pg options:MTLResourceStorageModeShared deallocator:nil];
    id<MTLBuffer> b10 = [g_dev newBufferWithBytesNoCopy:m + 192 * pg length:64 * pg options:MTLResourceStorageModeShared deallocator:nil];
    if (lim_ok && mlock(m, 2 * pg)) {   // the limit holds here: the refusal case runs
        msync(m, n, MS_INVALIDATE);
        at_p = m; at_n = n;
        logged(^{ res_add(b4); res_add(b8); res_commit(); });
        CHECK("a refused mlock wires nothing, nor the next buffer", at_hi == 0);
        CHECK("EAGAIN is a wired limit met: one red line with the wired count and the limits", strstr(g_out, "[RED] residency: a wired-memory limit was reached") && strstr(g_out, "refused with EAGAIN")
              && strstr(g_out, "Wired now ") && strstr(g_out, "GB of ") && strstr(g_out, "vm.global_user_wire_limit ") && strstr(g_out, "vm.user_wire_limit ") && strstr(g_out, "RLIMIT_MEMLOCK 0.0 MB")
              && strstr(g_out, "refusals over the system's / a task's limit since boot ") && strstr(g_out, "a task's limit has its room back at each commit")
              && !strstr(g_out, "[RED] residency: file pages under a buffer of"));
        CHECK("the mark counts no MB wired for it", strstr(at_mark, "0 MB of file pages wired for it") != NULL);
        CHECK("the buffers still join the set", in_set(b4) && in_set(b8));
        CHECK("and the commit pages them in itself", m[0] == 0x5a);
        res_line(line, sizeof line);
        CHECK("the residency line counts the refusal and the buffer not tried", strstr(line, "(refused 1, not tried with no wired room 1)") != NULL);
        setrlimit(RLIMIT_MEMLOCK, &old);
        g_fwire_call = (size_t)1 << 50;   // a call no wired room could hold: still no room
        at_p = m + 64 * pg; at_n = 64 * pg;
        logged(^{ res_add(b9); res_commit(); });
        CHECK("no room for a call: a later commit tries nothing either", at_hi == 0 && !strstr(g_out, "[RED]"));
        res_line(line, sizeof line);
        CHECK("and counts it", strstr(line, "(refused 0, not tried with no wired room 1)") != NULL);
        g_fwire_call = 8u << 20;
        at_p = m + 192 * pg; at_n = 64 * pg;
        logged(^{ res_add(b10); res_commit(); });
        CHECK("room again (the wired count under vm.global_user_wire_limit by a call): wired again, nothing said", at_lo == 1 && at_hi == 1 && !strstr(g_out, "[RED]"));
        res_line(line, sizeof line);
        CHECK("and counted as wired", strstr(line, "wired before their commit 1, ") && strstr(line, "(refused 0)"));

        // A task's limit held across commits (RLIMIT_MEMLOCK at half the range, two calls of a quarter): it counts only the task's own mlocks, which each commit gives back, not the
        // set's wiring of the buffers over the same pages, so each commit wires up to it again (two calls), the call past it is refused, and only the rest of that commit goes in
        // unwired; nothing is said again
        struct rlimit half = {n / 2, old.rlim_max};
        id<MTLBuffer> b11 = [g_dev newBufferWithBytesNoCopy:m length:n options:MTLResourceStorageModeShared deallocator:nil];
        id<MTLBuffer> b12 = [g_dev newBufferWithBytesNoCopy:m + 128 * pg length:64 * pg options:MTLResourceStorageModeShared deallocator:nil];
        id<MTLBuffer> b13 = [g_dev newBufferWithBytesNoCopy:m length:n options:MTLResourceStorageModeShared deallocator:nil];
        if (!setrlimit(RLIMIT_MEMLOCK, &half)) {
            g_fwire_call = n / 4; at_p = m; at_n = n / 2; at2_p = m + n / 2; at2_n = n / 2;
            for (int round = 0; round < 2; round++) {
                logged(^{ if (!round) { res_add(b11); res_add(b12); } else res_add(b13); res_commit(); });
                CHECK(round ? "the next commit has the task's room back: it wires up to the limit again" : "a task's limit: the commit wires up to it",
                      at_lo == 1 && at_hi == 1 && at2_hi == 0 && !strstr(g_out, "[RED]"));
                wired(m, n, &lo, &hi);
                CHECK("and gives that wiring back", lo == 0 && hi == 0);
                res_line(line, sizeof line);
                char want[96]; snprintf(want, sizeof want, "wired before their commit 1, %.0f MB, ", n / 2 / 1048576.0);
                CHECK(round ? "counted: wired in part, the call past the limit refused" : "counted: wired in part, refused, the commit's next buffer not tried",
                      strstr(line, want) && strstr(line, round ? "(refused 1" : "(refused 1, not tried with no wired room 1)"));
            }
            CHECK("the buffers join the set", in_set(b11) && in_set(b12) && in_set(b13));
            setrlimit(RLIMIT_MEMLOCK, &old); g_fwire_call = 8u << 20; at2_p = NULL; g_fwire_full = 0;   // as the next commit would find it: the system's wired count has room
        } else printf("t_file_wire: RLIMIT_MEMLOCK could not be set to half the range: the task's-limit case is skipped\n");
        res_remove(b11); res_remove(b12); res_remove(b13);
    } else { if (lim_ok) munlock(m, 2 * pg); printf("t_file_wire: RLIMIT_MEMLOCK does not limit mlock here: the refusal case is skipped\n"); }
    setrlimit(RLIMIT_MEMLOCK, &old);
    at_p = NULL; g_res_commit_before = NULL; g_fwire_advise_hook = NULL;

    // Any other refusal (here ENOMEM: a hole in the range) is not a wired limit: its own red line with its errno, once, and the next buffer is tried
    { uint8_t *h = mmap(NULL, 4 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (h == MAP_FAILED) abort(); munmap(h + pg, pg);
      __block fwire_t hw = {h, 4 * pg}; __block fwire_tm_t t; __block int how = -1; __block size_t got = 1;
      logged(^{ got = fwire_lock(&hw, &t, &how); });
      CHECK("another refusal wires nothing and is not a wired limit", got == 0 && how == FW_REFUSED && !g_fwire_full);
      CHECK("its red line gives the errno", strstr(g_out, "[RED] residency: file pages under a buffer of") && strstr(g_out, "errno 12"));
      logged(^{ got = fwire_lock(&hw, &t, &how); });
      CHECK("once", got == 0 && !strstr(g_out, "[RED]"));
      munmap(h, pg); munmap(h + 2 * pg, 2 * pg); }

    // The add's look at a buffer's mapping costs the same whatever the map entry around the buffer. A guest file's entry is up to 1 GB where the write tracking has not cut it,
    // and the long flavour of vm_region_recurse_64 looked up every page of it at each add, under the map's and the file's locks: Donkey Kong Bananza's first load on an iPhone
    // 18 Pro Max spent 428.5 ms of an 834.9 ms frame in 1,966 adds, 1,241 of them gmem_map's pools under g_mu, and later lone pool adds took 3.7 ms each. Here a 1 GB file
    // mapping with every page resident (read in: zero pages, nothing written to the disk), where that look took 0.4-1 ms on an M4 Max
    { size_t G = (size_t)1 << 30, bn = 16 * pg; char gp[] = "/tmp/t_file_wire_big.XXXXXX"; int gfd = mkstemp(gp);
      uint8_t *gm = gfd >= 0 && !unlink(gp) && !ftruncate(gfd, (off_t)G) ? mmap(NULL, G, PROT_READ | PROT_WRITE, MAP_SHARED, gfd, 0) : MAP_FAILED;
      if (gm != MAP_FAILED) {
          for (size_t o = 0; o < G; o += pg) (void)*(volatile uint8_t *)(gm + o);
          NSMutableArray *keep = [NSMutableArray array];
          id<MTLBuffer> (^buf_at)(size_t) = ^id<MTLBuffer>(size_t off) {
              id<MTLBuffer> x = [g_dev newBufferWithBytesNoCopy:gm + off length:bn options:MTLResourceStorageModeShared deallocator:nil]; if (x) [keep addObject:x]; return x; };
          g_res_commit_before = before_commit; g_fwire_advise_hook = advise_rec;

          // Outside the guest's block (the layout does not know it: Metal's own buffers, a sparse pool's runs, a module's data) the kernel is asked, with its short look: one a buffer
          uint64_t best = UINT64_MAX, l0 = looks();
          res_mu_lock(); size_t nf0 = g_nfwire; res_mu_unlock();
          for (int i = 0; i < 4; i++) { id<MTLBuffer> x = buf_at((size_t)(200 + 200 * i) << 20); uint64_t t0 = ns_now(); res_add(x); uint64_t dt = ns_now() - t0; if (dt < best) best = dt; }
          res_mu_lock(); size_t nf = g_nfwire - nf0; res_mu_unlock();
          CHECK("outside the guest's block: buffers in a 1 GB file mapping are noted as file-backed, one kernel look each", nf == 4 && looks() - l0 == 4);
          CHECK("and the look does not walk the pages of the map entry around the buffer (the fastest of four adds under 100 us)", best < 100000);
          if (best >= 100000) fprintf(stderr, "  the fastest of the four adds took %.1f us\n", best / 1e3);
          at_p = gm + (200u << 20); at_n = bn; at2_p = gm + (800u << 20); at2_n = bn;
          res_commit();
          CHECK("and each is wired before [g_res commit]", at_lo == 1 && at_hi == 1 && at_res && at2_hi == 1);
          wired(gm, G, &lo, &hi);
          CHECK("and given back after it", lo == 0 && hi == 0);
          at2_p = NULL;

          // Inside the guest's block, the host's layout answers (dm_guest_file_backed), with no system call: gmem_map's loop over the pools, under g_mu, as a burst of 256
          // adds and one commit. Every buffer is noted as file-backed, none asks the kernel, the burst stays far under what 256 looks at the entry took (over 100 ms), and the
          // commit wires each one before [g_res commit] and gives it back after
          gb_lo = (uintptr_t)gm; gb_hi = gb_lo + G; gb_files = 1; g_fwire_backed_hook = backed_rec;
          res_line(line, sizeof line);   // the counts start from here
          enum { BURST = 256 }; id<MTLBuffer> bb[BURST];
          for (int i = 0; i < BURST; i++) bb[i] = buf_at((size_t)i * (G / BURST) + 32 * pg);
          l0 = looks(); best = UINT64_MAX; uint64_t worst = 0, t_all = ns_now();
          pthread_mutex_lock(&g_mu);
          for (int i = 0; i < BURST; i++) { uint64_t t0 = ns_now(); res_add(bb[i]); uint64_t dt = ns_now() - t0; if (dt < best) best = dt; if (dt > worst) worst = dt; }
          pthread_mutex_unlock(&g_mu);
          t_all = ns_now() - t_all;
          res_mu_lock(); nf = g_nfwire; res_mu_unlock();
          CHECK("in the guest's block: every buffer of a burst of 256 is noted as file-backed, and none asks the kernel", nf == BURST && looks() == l0);
          CHECK("and the burst takes under 20 ms (the fastest add under 100 us)", t_all < 20000000 && best < 100000);
          if (t_all >= 20000000 || best >= 100000) fprintf(stderr, "  the burst of %d adds took %.1f ms, the fastest %.1f us, the slowest %.1f us\n", BURST, t_all / 1e6, best / 1e3, worst / 1e3);
          at_p = bb[BURST - 1].contents; at_n = bn; at2_p = bb[0].contents; at2_n = bn;
          res_commit();
          CHECK("and the commit wires them before [g_res commit]", at_lo == 1 && at_hi == 1 && at_res && at2_hi == 1);
          wired(gm, G, &lo, &hi);
          CHECK("and gives them back after it", lo == 0 && hi == 0);
          res_line(line, sizeof line);
          { char want[96]; snprintf(want, sizeof want, "file-backed buffers wired before their commit %d, %.0f MB", BURST, BURST * bn / 1048576.0);
            CHECK("the residency line counts them", strstr(line, want) != NULL); }
          at2_p = NULL;

          // The guest anonymous: a buffer in its block is not file-backed, and the kernel is not asked
          { uint8_t *an = mmap(NULL, 64 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (an == MAP_FAILED) abort();
            uintptr_t lo0 = gb_lo, hi0 = gb_hi; gb_lo = (uintptr_t)an; gb_hi = gb_lo + 64 * pg; gb_files = 0;
            id<MTLBuffer> x = [g_dev newBufferWithBytesNoCopy:an length:16 * pg options:MTLResourceStorageModeShared deallocator:nil]; l0 = looks();
            res_add(x); res_mu_lock(); nf = g_nfwire; res_mu_unlock();
            CHECK("with the guest anonymous a buffer in its block is not noted, and the kernel is not asked", nf == 0 && looks() == l0);
            res_remove(x); res_commit(); x = nil; munmap(an, 64 * pg); gb_lo = lo0; gb_hi = hi0; gb_files = 1; }

          // An add never waits for a commit's wiring: while a commit on another thread is inside its first mlock call (held there by the test), adds in the guest's block and
          // outside it, and a removal, return at once; the commit after them wires the new buffers
          { wire_in = dispatch_semaphore_create(0); wire_go = dispatch_semaphore_create(0); atomic_store(&wire_calls, 0);
            id<MTLBuffer> w0 = buf_at((size_t)300 << 20); res_add(w0);
            g_fwire_call_before = before_call_held; at_p = NULL;
            pthread_t ct; pthread_create(&ct, NULL, commit_thread, NULL);
            int in = !dispatch_semaphore_wait(wire_in, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
            id<MTLBuffer> wb[16]; for (int i = 0; i < 16; i++) wb[i] = buf_at((size_t)(310 + i) << 20);
            id<MTLBuffer> wo = [g_dev newBufferWithBytesNoCopy:m length:16 * pg options:MTLResourceStorageModeShared deallocator:nil];   // outside the block: the kernel's look
            uint64_t slow = 0, t0;
            pthread_mutex_lock(&g_mu);
            for (int i = 0; i < 16; i++) { t0 = ns_now(); res_add(wb[i]); if (ns_now() - t0 > slow) slow = ns_now() - t0; }
            pthread_mutex_unlock(&g_mu);
            t0 = ns_now(); res_add(wo); if (ns_now() - t0 > slow) slow = ns_now() - t0;
            t0 = ns_now(); res_remove(bb[0]); if (ns_now() - t0 > slow) slow = ns_now() - t0;
            int still = atomic_load(&wire_calls) == 1 && (atomic_load(&g_rk[0].ph) != 0 || atomic_load(&g_rk[1].ph) != 0);   // 1 under the lock (slot 0), 2 before it (slot 1, DM_NVN_RES_PREWIRE)
            dispatch_semaphore_signal(wire_go); pthread_join(ct, NULL); g_fwire_call_before = NULL;
            CHECK("adds and a removal made while a commit wires do not wait for it (each under 50 ms, the wire held until they are done)", in && still && slow < 50000000);
            if (slow >= 50000000) fprintf(stderr, "  the slowest took %.1f ms\n", slow / 1e6);
            CHECK("the commit that was wiring has its buffer in the set", in_set(w0));
            at_p = wb[0].contents; at_n = bn; at2_p = wo.contents; at2_n = 16 * pg;
            res_commit();
            CHECK("and the next commit wires the buffers added meanwhile before [g_res commit]", at_lo == 1 && at_hi == 1 && at_res && at2_hi == 1 && in_set(wb[15]) && in_set(wo));
            wired(gm, G, &lo, &hi);
            CHECK("and gives them back", lo == 0 && hi == 0);
            at2_p = NULL; res_remove(wo); res_commit(); }

          // The read-ahead goes in batches: while one run of the read-ahead queue waits (held by the test), the ranges added meanwhile wait on a list, and the next run asks for
          // them sorted, with ranges that touch or overlap merged into one: here three side by side and one over the first two (one ask), and one apart (another)
          { dispatch_sync(fwire_adv_q(), ^{}); atomic_store(&adv_k, 0); memset(adv_p, 0, sizeof adv_p); memset(adv_n, 0, sizeof adv_n);
            size_t A = (size_t)501 << 20, D = (size_t)701 << 20;
            id<MTLBuffer> x0 = buf_at((size_t)451 << 20), xc = buf_at(A + 2 * bn), xa = buf_at(A), xb = buf_at(A + bn), xo = buf_at(A + bn / 2), xd = buf_at(D);
            atomic_store(&adv_hold, 1);
            res_add(x0);
            for (int i = 0; i < 2000 && atomic_load(&adv_hold); i++) usleep(1000);   // the run is in the hook, held
            uint64_t t0 = ns_now(); res_add(xc); res_add(xa); res_add(xb); res_add(xo); res_add(xd); uint64_t dt = ns_now() - t0;
            CHECK("adds made while a read-ahead waits do not wait for it", dt < 50000000 && atomic_load(&adv_k) == 0);
            dispatch_semaphore_signal(adv_go); dispatch_sync(fwire_adv_q(), ^{});
            CHECK("the ranges added meanwhile are asked for in one batch: touching and overlapping ones merged, one apart on its own",
                  atomic_load(&adv_k) == 3 && adv_p[0] == gm + (451u << 20) && adv_n[0] == bn && adv_p[1] == gm + A && adv_n[1] == 3 * bn && adv_p[2] == gm + D && adv_n[2] == bn);
            if (atomic_load(&adv_k) != 3) fprintf(stderr, "  %d asks\n", atomic_load(&adv_k));
            res_commit(); }

          g_res_commit_before = NULL; g_fwire_advise_hook = NULL; g_fwire_backed_hook = NULL; at_p = NULL;
          for (id<MTLBuffer> x in keep) res_remove(x);
          res_commit(); [keep removeAllObjects];
          munmap(gm, G);
      } else printf("t_file_wire: no 1 GB file mapping in /tmp: the map-entry and layout cases are skipped\n");
      if (gfd >= 0) close(gfd); }

    // Several calls at once (DM_NVN_PREWIRE_JOBS=4): a buffer in eight slow calls is wired whole before [g_res commit] in about a quarter of the time one worker takes, with calls
    // running together, given back after it, counted as one buffer, and the line says the page-in used several workers
    { g_pw_jobs = 4; g_fwire_call = n / 8; g_fwire_call_before = par_call; g_res_commit_before = before_commit; atomic_store(&par_in, 0); atomic_store(&par_max, 0);
      msync(m, n, MS_INVALIDATE);
      res_line(line, sizeof line);   // the counts start from here
      id<MTLBuffer> bp = [g_dev newBufferWithBytesNoCopy:m length:n options:MTLResourceStorageModeShared deallocator:nil];
      at_p = m; at_n = n; uint64_t t0 = ns_now();
      res_add(bp); res_commit();
      double ms = (ns_now() - t0) / 1e6;
      printf("parallel page-in: 8 calls of 20 ms in %.1f ms, up to %d at once\n", ms, atomic_load(&par_max));
      CHECK("several workers: calls run together", atomic_load(&par_max) >= 2);
      CHECK("and the page-in takes well under the calls' summed time", ms < 8 * 20 * 0.75);
      CHECK("the whole range is wired before [g_res commit] and resident", at_lo == 1 && at_hi == 1 && at_res);
      wired(m, n, &lo, &hi);
      CHECK("and given back after it", lo == 0 && hi == 0);
      res_line(line, sizeof line);
      char want[96]; snprintf(want, sizeof want, "file-backed buffers wired before their commit 1, %.0f MB", n / 1048576.0);
      if (!strstr(line, want) || !strstr(line, "8 calls")) printf("  line: %s\n", strstr(line, "file-backed") ? strstr(line, "file-backed") : line);
      CHECK("counted as one buffer, and the line names the parallel page-in", strstr(line, want) && strstr(line, "(refused 0, 1 page-ins with up to 4 calls at once, 8 calls, their times summed)"));
      CHECK("the buffer is in the set", in_set(bp));
      res_remove(bp); res_commit();
      g_pw_jobs = 1; g_fwire_call = 8u << 20; g_fwire_call_before = NULL; g_res_commit_before = NULL; at_p = NULL; }

    // A texture's storage is read ahead at its setup (DM_NVN_TEX_READAHEAD) when the host may take its content from there: a BC1 texture in a CPU pool is asked for once, on the
    // read-ahead queue; one in a CPU_NO_ACCESS pool, one under 16 KB and any with the switch off are not; the page-in line counts it
    { static uint8_t tmem[1 << 20]; static pool_t cpu = {.flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = tmem, .size = sizeof tmem},
                                     gpu = {.flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = tmem, .size = sizeof tmem};
      g_fwire_advise_hook = advise_rec; atomic_store(&adv_k, 0); g_tra_on = 1;
      res_line(line, sizeof line);   // the counts start from here
      tex_t tx[4]; memset(tx, 0, sizeof tx);
      for (int i = 0; i < 4; i++) { tx[i].magic = MAGIC('T', 'E', 'X', 0); tx[i].serial = 970001 + i; tx[i].pool = i == 1 ? &gpu : &cpu; tx[i].off = (int64_t)i << 18; tx[i].mem = tmem + ((size_t)i << 18);
          tx[i].d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA_DXT1, .width = i == 2 ? 32 : 256, .height = i == 2 ? 32 : 256, .depth = 1, .levels = 1, .samples = 1};
          nvn_tex_layout(&tx[i].d, &tx[i].L); }
      mtl_tex_init(&tx[0]); mtl_tex_init(&tx[1]); mtl_tex_init(&tx[2]);
      g_tra_on = 0; mtl_tex_init(&tx[3]); g_tra_on = 1;
      dispatch_sync(fwire_adv_q(), ^{});
      printf("texture read-ahead: %d asks, the first %p+%zu (storage %p+%llu)\n", atomic_load(&adv_k), adv_p[0], adv_n[0], (void *)tx[0].mem, (unsigned long long)tx[0].L.size);
      CHECK("a texture the host may take from its storage is read ahead at its setup, on the read-ahead queue", atomic_load(&adv_k) == 1 && adv_p[0] == tx[0].mem && adv_n[0] == tx[0].L.size && !pthread_equal(adv_th, pthread_self()));
      res_line(line, sizeof line);
      char want[96]; snprintf(want, sizeof want, "textures read ahead at their setup 1, %.0f MB", tx[0].L.size / 1048576.0);
      CHECK("not one in a CPU_NO_ACCESS pool, under 16 KB or with the switch off; the page-in line counts it", strstr(line, want) != NULL);
      for (int i = 0; i < 4; i++) mtl_tex_release(&tx[i]);
      g_fwire_advise_hook = NULL; }

    // Page-ins by part of the replay's work (DM_NVN_PF_PARTS): pages of a file dropped from memory, read inside a named part and outside it, go to that part and to 'other'; off,
    // nothing is counted. A file of its own, which no Metal buffer covers: with the no-copy buffers made over m above still alive (taken out of the residency set or not), an
    // MS_INVALIDATE of m left all 256 of its pages in core, so its reads paged nothing in and both checks failed in every run
    { uint64_t pf[PF_N]; mtl_pf_take(pf);
      char fpath[] = "/tmp/t_file_wire_pf.XXXXXX"; int ffd = mkstemp(fpath); if (ffd < 0) abort(); unlink(fpath);
      if (ftruncate(ffd, (off_t)n)) abort();
      uint8_t *fm = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, ffd, 0); if (fm == MAP_FAILED) abort();
      memset(fm, 0x5a, n / 2); msync(fm, n, MS_SYNC);   // the half the reads below touch is written out, so dropping it leaves a page-in for each touch
      g_pf_on = 1; msync(fm, n, MS_INVALIDATE);
      volatile uint8_t sink = 0;
      mtl_pf_scope(1);
      int k = pf_enter(PF_SCAN); for (size_t o = 0; o < n / 4; o += pg) sink += fm[o]; pf_leave(k);
      for (size_t o = n / 4; o < n / 2; o += pg) sink += fm[o];
      mtl_pf_scope(0); (void)sink;
      mtl_pf_take(pf); printf("page-ins by part: scan %llu, other %llu\n", (unsigned long long)pf[PF_SCAN], (unsigned long long)pf[PF_OTHER]);
      CHECK("page-ins inside a part go to it, the rest of the scope to 'other'", pf[PF_SCAN] > 0 && pf[PF_OTHER] > 0 && !pf[PF_TEX] && !pf[PF_POOL]);
      char t[160]; nvn_pf_text(t, sizeof t, pf);
      CHECK("the long-frame line's part", !strncmp(t, "; replay page-ins by part: other ", 33) && strstr(t, ", storage scans "));
      g_pf_on = 0; msync(fm, n, MS_INVALIDATE); mtl_pf_scope(1); k = pf_enter(PF_SCAN); for (size_t o = 0; o < n / 2; o += pg) sink += fm[o]; pf_leave(k); mtl_pf_scope(0);
      mtl_pf_take(pf); uint64_t sum = 0; for (int i = 0; i < PF_N; i++) sum += pf[i];
      CHECK("off (the default), nothing is counted", sum == 0);
      munmap(fm, n); close(ffd); }
    // The slow commands (DM_NVN_PF_PARTS): a command of 1 ms counts to its type, one of a few microseconds does not, nor a call; off, nothing is timed
    { char t[200]; mtl_sop_text(t, sizeof t); g_pf_on = 1; mtl_pf_scope(1);
      sop_tick(OP_DRAW_IDX); usleep(1000); sop_tick(OP_BIND_TEX); sop_tick(OP_CALL); usleep(1000); sop_tick(OP_END);
      mtl_pf_scope(0); mtl_sop_text(t, sizeof t); printf("slow commands: '%s'\n", t);
      CHECK("a slow command counts to its type, a quick one and a call do not", strstr(t, "; slow commands (DM_NVN_PF_PARTS): draw_idx 1 / ") == t && !strstr(t, "bind_tex") && !strstr(t, "call"));
      g_pf_on = 0; mtl_pf_scope(1); mtl_pf_scope(0); mtl_sop_text(t, sizeof t); CHECK("off, nothing is timed", !t[0]); }

    // A page-in that sticks is named as the commit's, so the freeze detector and the suspend see it (the mark res_commit sets before fwire_all)
    { char t[300]; res_kcommit_in(0, 3, 512u << 20, 1); uint64_t at = mtl_res_commit_stuck(0, t, sizeof t);
      CHECK("a commit's page-in is marked, between two calls here", at && strstr(t, "a residency commit's page-in (mlock of 512 MB of file pages before [g_res commit], 3 changes; 0 MB wired so far "
                                                                         "in calls of 8 MB, between two calls) in the kernel for"));
      atomic_store(&g_rk[0].at, 0); atomic_store(&g_rk[0].ph, 0); }

    res_remove(b); res_remove(b2); res_remove(b3); res_remove(b4); res_remove(b5); res_remove(b6); res_remove(b7); res_remove(b8); res_remove(b9); res_remove(b10); res_remove(ab); res_remove(own); res_commit();
    printf("t_file_wire: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
