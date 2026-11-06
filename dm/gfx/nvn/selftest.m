// Start-up self-tests: checks that need this device's own GPU, asked for with DM_SELFTEST=<name>[,<name>...] (Documents/env.txt on an iPhone or iPad; on the Mac the
// environment, or a Mac app's env.txt in ~/Library/Application Support/nxnative/<title ID>/). main.c reads the switch: without it nothing here runs and nothing is called. With it,
// dm_selftest_start runs them once, on a thread of their own started before the host's loading ends (on iOS that loading has usually finished behind the launcher), and
// dm_selftest_wait holds the game's first instruction until they are done (at most 20 s), so they share no thread, queue or frame with the game. Each logs one line.
//   hmma: the HMMA.16816 body the shader build writes for Ampere's matrix instructions with an f16 accumulator (dm/gfx/tools/dmsh_build.py hmma_msl: the simdgroup_matrix code of
//         agl's upscaler networks), compiled when the host was built exactly as this platform's game shaders are (dm/gfx/tools/hmma_selftest.py through host_msl.py: iOS with
//         ios_metal.py's flags, the Mac with dmsh_build.py's), four calls a lane in a row on one scratch block (each D the next call's C) over 256 tiles of random fragments (a
//         fixed seed), eight runs, against the CPU reference of PTX mma.m16n8k16 that dm/gfx/tests/test_dmsh_hmma.py uses on the Mac (hmma_check.h, one copy):
//         `self-test hmma: <GPU> (<architecture>, highest Apple family N): 256 tiles x 4 chained calls, 8 runs: worst output at W% of its bound ...: ok; compiled by <command>`,
//         or the same line starting `[RED] ` with OVER BOUND or RUNS DIFFER in place of ok, or `[RED] self-test hmma: ... not run: <why>`
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "host_msl.h"
#include "hmma_check.h"
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define STLOG(...) do { flockfile(stderr); fprintf(stderr, "[dm] " __VA_ARGS__); fputc('\n', stderr); funlockfile(stderr); } while (0)   // one line under one lock, as LOG (dm.h)

enum { SELFTEST_HMMA = 1 };
static unsigned g_selftest_want;           // written before the thread starts, read only by it
static dispatch_semaphore_t g_selftest_done;   // main.c's thread only: made by dm_selftest_start, waited for by dm_selftest_wait

static void selftest_hmma(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();   // the process's one device, which the graphics layers use too
    if (!dev) { STLOG("[RED] self-test hmma: not run: no Metal device"); return; }
    char gpu[256]; hmma_check_gpu(dev, gpu, sizeof gpu);
    unsigned long len = 0; const char *record = "";
    const unsigned char *bytes = host_msl_chain_lib("hmma_selftest", &len, &record);
    if (!bytes) { STLOG("[RED] self-test hmma: %s: not run: the host has no kernel for it (%s)", gpu, record); return; }
    NSError *e = nil;
    dispatch_data_t data = dispatch_data_create(bytes, len, NULL, ^{});   // static bytes: nothing to free
    id<MTLLibrary> lib = data ? [dev newLibraryWithData:data error:&e] : nil;
    if (!lib) {
        const char *why = e.localizedDescription.UTF8String;
        STLOG("[RED] self-test hmma: %s: not run: its library does not load (%s; compiled by %s)", gpu, why ? why : "no error", record); return;
    }
    char line[768]; struct hmma_check_result r;
    int ran = hmma_check_run(dev, lib, &r, line, sizeof line);   // the compile record on the line too: which language and flags this device measured
    STLOG("%sself-test hmma: %s; compiled by %s", !ran || hmma_check_failed(&r) ? "[RED] " : "", line, record);
}

static void *selftest_thread(void *done) {
    dispatch_semaphore_t sem = (__bridge_transfer dispatch_semaphore_t)done;
    @autoreleasepool {
        if (g_selftest_want & SELFTEST_HMMA) selftest_hmma();
    }
    dispatch_semaphore_signal(sem);
    return NULL;
}

void dm_selftest_start(const char *names) {
    static atomic_int once;
    if (!names || atomic_exchange(&once, 1)) return;
    for (const char *p = names + strspn(names, ", "); *p; p += strspn(p, ", ")) {
        size_t n = strcspn(p, ", ");
        if (n == 4 && !strncmp(p, "hmma", 4)) g_selftest_want |= SELFTEST_HMMA;
        else STLOG("[RED] self-test %.*s: no such self-test (DM_SELFTEST takes hmma)", (int)n, p);
        p += n;
    }
    if (!g_selftest_want) return;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    pthread_attr_t a; pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    pthread_attr_set_qos_class_np(&a, QOS_CLASS_USER_INITIATED, 0);
    pthread_t th; void *arg = (__bridge_retained void *)done;   // the thread's own reference, so a wait that gives up leaves it a live semaphore
    int err = pthread_create(&th, &a, selftest_thread, arg);
    pthread_attr_destroy(&a);
    if (err) {
        dispatch_semaphore_t unused = (__bridge_transfer dispatch_semaphore_t)arg; (void)unused;   // the thread's reference back to ARC, which drops it
        STLOG("[RED] self-test: not run: no thread for it (%s)", strerror(err)); return;
    }
    g_selftest_done = done;
}

void dm_selftest_wait(void) {
    if (!g_selftest_done) return;
    if (dispatch_semaphore_wait(g_selftest_done, dispatch_time(DISPATCH_TIME_NOW, 20 * (int64_t)NSEC_PER_SEC)))
        STLOG("[RED] self-test: not finished after 20 s; the game starts without waiting for it");
    g_selftest_done = nil;
}
