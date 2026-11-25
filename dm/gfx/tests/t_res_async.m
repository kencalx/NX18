// Residency commits off the replay thread (DM_NVN_RES_ASYNC, nvn_mtl.m res_commit_soon / rca_queue_guard). Ocarina of Time's area loads spent 142-300 ms of a load frame in
// residency commits on the replay thread; with the switch on the replay hands its commits to the residency commit worker and goes on, and the encode thread commits what is left
// just before each queue commit, so a resource is still in the committed set before the GPU runs a command buffer that uses it. Checks, with real Metal allocations, a pool
// over the test's own memory and the host's own buffer copy (mtl_sub_copy, whose pool lookups make the pools resident), while another thread holds the commit lock as a long
// commit holds it (250 ms):
//  - on: the replay's lookup returns at once with the pool not yet in the committed set; with the encode thread the submission returns at once too and the GPU does not run it
//    before the lock is free (the encode thread's queue commit waits behind the residency commit); without it the submission's own commit waits, as before;
//  - off (=0): the lookup waits for the lock, as before;
//  - either way the copy lands (read back), the pool is in the set and no command buffer failed;
//  - 64 pools looked up while the lock is held are committed by the worker in at most two commits, and the residency line says where the commits ran (on only).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; printf("FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static double ms_since(uint64_t t0) { return (bp_now() - t0) / 1e6; }
// The commit lock held on a thread of its own for hold_ms, as a long commit holds it; returns once it is held. *rel_at: when it was let go (bp_now)
static dispatch_semaphore_t hold_lock(int hold_ms, _Atomic uint64_t *rel_at) {
    dispatch_semaphore_t held = dispatch_semaphore_create(0), done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        res_commit_lock(); dispatch_semaphore_signal(held); usleep((useconds_t)hold_ms * 1000);
        atomic_store(rel_at, bp_now()); res_commit_unlock(); dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(held, DISPATCH_TIME_FOREVER);
    return done;
}
static id<MTLBuffer> pool_buf_of(uint64_t a) { mu_lock(); int i = pool_peek(a); id<MTLBuffer> b = i >= 0 ? g_pools[i].buf : nil; pthread_mutex_unlock(&g_mu); return b; }
static int committed(id<MTLBuffer> b) { res_commit_lock(); int r = b && [g_res containsAllocation:b]; res_commit_unlock(); return r; }

int main(void) { @autoreleasepool {
    alarm(120); setvbuf(stdout, NULL, _IONBF, 0);
    mtl_init();
    int on = rca_mode() == 1, enc = rec_on();
    printf("t_res_async: DM_NVN_RES_ASYNC %s, encode thread %s\n", on ? "on" : "off", enc ? "on" : "off");
    const size_t len = 1u << 20, n = 64u << 10;
    uint8_t *src = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), *dst = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (src == MAP_FAILED || dst == MAP_FAILED) abort();
    for (size_t i = 0; i < len; i++) src[i] = (uint8_t)(i * 7 + 3);
    mtl_pool_add(src, len); mtl_pool_add(dst, len);
    mtl_sub_begin(); CHECK("a first submission completes (the encode thread runs)", mtl_wait(mtl_sub_commit(), 5000000000ull));

    // One copy between two pools no lookup has made resident yet, while another thread's commit holds the lock for 250 ms
    { _Atomic uint64_t rel_at = 0; uint64_t t_hold = bp_now();
      dispatch_semaphore_t done = hold_lock(250, &rel_at);
      mtl_sub_begin();
      uint64_t t0 = bp_now(), t_copy = t0; mtl_sub_copy((uint64_t)(uintptr_t)src, (uint64_t)(uintptr_t)dst, n); double copy_ms = ms_since(t0);
      id<MTLBuffer> sb = pool_buf_of((uint64_t)(uintptr_t)src), db = pool_buf_of((uint64_t)(uintptr_t)dst);
      int early = atomic_load(&rel_at) == 0 && (pthread_mutex_trylock(&g_res_commit_mu) ? 1 : (pthread_mutex_unlock(&g_res_commit_mu), 0));   // the holder still has it
      int in_set = sb && [g_res containsAllocation:sb];   // read without the lock: its holder changes nothing
      t0 = bp_now(); uint64_t fence = mtl_sub_commit(); double sub_ms = ms_since(t0);
      int ran_early = mtl_wait(fence, 1000000ull) && atomic_load(&rel_at) == 0;
      printf("  copy %.1f ms, submission %.1f ms, with the lock held for 250 ms from %.1f ms before them\n", copy_ms, sub_ms, (t_copy - t_hold) / 1e6);
      if (on) {
          CHECK("the replay's pool lookup hands its commit off and returns while another commit holds the lock", copy_ms < 100 && early);
          CHECK("the pool is not in the committed set yet", !in_set);
          if (enc) {
              CHECK("with the encode thread the submission returns while the lock is held", sub_ms < 100);
              CHECK("and the GPU does not run it before the residency commit (the encode thread's queue commit waits)", !ran_early);
          } else CHECK("without the encode thread the submission's own commit waits for the lock, as before", sub_ms > 50 || copy_ms + sub_ms > 150);
      } else CHECK("off: the lookup waits for the lock, as before", copy_ms > 150);
      CHECK("the copy's submission completes", mtl_wait(fence, 5000000000ull));
      dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
      CHECK("no command buffer failed (nothing ran non-resident)", !mtl_last_commit_error());
      CHECK("the copy landed (read back)", !memcmp(dst, src, n));
      CHECK("both pools are in the committed set", committed(sb) && committed(db));
      CHECK("no pool add left open", atomic_load(&g_pool_res_open) == 0); }

    // 64 pools looked up while the lock is held: one or two worker runs commit them all, and the residency line says where
    { enum { NP = 64 }; const size_t pl = 64u << 10; uint8_t *p[NP];
      for (int i = 0; i < NP; i++) { p[i] = mmap(NULL, pl, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (p[i] == MAP_FAILED) abort(); memset(p[i], 0x40 + i, pl); mtl_pool_add(p[i], pl); }
      char line[4096]; mtl_res_stats(line, sizeof line);   // the counts start here
      _Atomic uint64_t rel_at = 0; dispatch_semaphore_t done = hold_lock(200, &rel_at);
      mtl_sub_begin();
      uint64_t t0 = bp_now();
      for (int i = 0; i < NP; i++) mtl_sub_copy((uint64_t)(uintptr_t)p[i], (uint64_t)(uintptr_t)dst + (uint64_t)i * 256, 256);
      double ms = ms_since(t0);
      uint64_t fence = mtl_sub_commit();
      CHECK("the 64 copies' submission completes", mtl_wait(fence, 5000000000ull));
      dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
      dispatch_sync(res_commit_q(), ^{});   // the worker's runs are over
      int ok = 1; for (int i = 0; i < NP; i++) for (int k = 0; k < 256; k++) ok &= dst[i * 256 + k] == (uint8_t)(0x40 + i);
      CHECK("every copy landed", ok && !mtl_last_commit_error());
      res_mu_lock(); uint64_t wn = g_rca_n[1], qn = g_rca_n[2]; res_mu_unlock();
      uint64_t kicks = atomic_load(&g_rca_kicks), soon = atomic_load(&g_rca_soon);
      printf("  64 lookups %.1f ms: hand-offs %llu, worker runs %llu, worker commits %llu, queue-commit commits %llu\n", ms, (unsigned long long)soon, (unsigned long long)kicks, (unsigned long long)wn, (unsigned long long)qn);
      mtl_res_stats(line, sizeof line); printf("  %s\n", line);
      if (on) {
          CHECK("the 64 lookups return while the lock is held", ms < 100);
          CHECK("64 hand-offs, at most two worker runs and at most two commits there with changes", soon >= NP && kicks <= 2 && wn >= 1 && wn <= 2);
          CHECK("the residency line gives the commits by where they ran", strstr(line, "on the commit worker ") && strstr(line, "the replay handed off "));
      } else {
          CHECK("off: each lookup waits for the lock as before (the first for the rest of the hold)", ms > 100);
          CHECK("off: no hand-off, and the line is as before", !soon && !kicks && !strstr(line, "on the commit worker"));
      }
      for (int i = 0; i < NP; i++) { mtl_pool_del(p[i]); munmap(p[i], pl); } }

    mtl_pool_del(src); mtl_pool_del(dst);
    printf("t_res_async: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
