// The in-game menu's Upscaling pick (../nvn/nvn_upscale_pick.h, as nvn_mtl.m fx_mode uses it), on any machine: DM_PRESENT_UPSCALE's values, the first present deciding the mode
// from the environment, a pick taken by the live present alone and only once, whether the live present restarts Automatic's count (a changed mode only), a capture never
// taking a pick, and a main thread posting picks while a present thread takes them (make t_upscale_pick_tsan): the present thread ends on the last pick, and its count restarts
// exactly when the mode it runs changes
#include "../nvn/nvn_upscale_pick.h"
#include <pthread.h>
#include <stdio.h>

static int checks, failed;
#define EXPECT(name, want, got) do { long long w_ = (want), g_ = (got); checks++; if (w_ != g_) { fprintf(stderr, "%s: expected %lld, got %lld\n", name, w_, g_); failed++; } } while (0)

static _Atomic int mode = -1, req = -1;
static int env_mode = UP_OFF;   // what DM_PRESENT_UPSCALE says, for the first decision
static int restarts, settle = 60;   // Automatic's count, the present thread's own (nvn_mtl.m g_fx_auto)
static int present(int live) {   // fx_mode and the restart in fx_encode, without the GPU check and the log
    int want = -1, v = up_now(&mode, &req, live, &want);
    if (v >= 0) return v;
    v = want >= 0 ? want : env_mode;
    if (up_set(&mode, v) && live) { restarts++; settle = 60; }
    return v;
}

static _Atomic int done;
static int changes;   // the modes the present thread ran, changed (its own count)
static void *present_thread(void *unused) {   // presents until the main thread's last pick is in force
    (void)unused; int last = atomic_load(&mode);
    for (;;) {
        int fin = atomic_load(&done), v = present(1);
        if (v != last) { changes++; last = v; }
        if (fin && atomic_load_explicit(&req, memory_order_relaxed) < 0 && v == UP_AUTO) break;
    }
    return NULL;
}

int main(void) {
    EXPECT("metalfx", UP_METALFX, up_parse("metalfx")); EXPECT("1 is metalfx", UP_METALFX, up_parse("1"));
    EXPECT("auto", UP_AUTO, up_parse("auto")); EXPECT("off", UP_OFF, up_parse("off")); EXPECT("0 is off", UP_OFF, up_parse("0"));
    EXPECT("unset is off", UP_OFF, up_parse(NULL)); EXPECT("empty is off", UP_OFF, up_parse(""));
    EXPECT("anything else is not a mode", -1, up_parse("sharp")); EXPECT("letter case counts, as before", -1, up_parse("MetalFX"));

    env_mode = UP_AUTO;
    EXPECT("the first present decides from the environment", UP_AUTO, present(1));
    EXPECT("the first decision restarts nothing (the count starts full)", 0, restarts);
    EXPECT("later presents keep the mode", UP_AUTO, present(1));
    up_post(&req, UP_OFF);
    EXPECT("a capture does not take the pick", UP_AUTO, present(0));
    EXPECT("the pick is still waiting", UP_OFF, atomic_load(&req));
    settle = 12;
    EXPECT("the live present takes it at its next present", UP_OFF, present(1));
    EXPECT("a changed mode restarts Automatic's count", 1, restarts); EXPECT("the count is full again", 60, settle);
    EXPECT("the pick is taken once", -1, atomic_load(&req));
    EXPECT("a capture then reads the mode in force", UP_OFF, present(0));
    up_post(&req, UP_OFF);
    EXPECT("a pick of the mode in force", UP_OFF, present(1));
    EXPECT("restarts nothing", 1, restarts);
    up_post(&req, UP_METALFX); up_post(&req, UP_AUTO);
    EXPECT("of two picks before a present the last counts", UP_AUTO, present(1));
    EXPECT("and restarts the count once", 2, restarts);

    // A main thread posting picks while the present thread presents: no race on the pick (TSan), the last pick ends in force, and the count restarts only on a change of the mode
    // the present thread runs (counted by the thread itself)
    atomic_store(&mode, UP_OFF); atomic_store(&req, -1); restarts = 0;
    pthread_t t; if (pthread_create(&t, NULL, present_thread, NULL)) return 2;
    for (int i = 0; i < 20000; i++) up_post(&req, i % 3);
    up_post(&req, UP_AUTO); atomic_store(&done, 1);
    pthread_join(t, NULL);
    EXPECT("the last pick is in force", UP_AUTO, atomic_load(&mode));
    EXPECT("no pick left waiting", -1, atomic_load(&req));
    EXPECT("the count restarted exactly when the mode the present ran changed", changes, restarts);
    printf("t_upscale_pick: %d checks, %d failed (%d restarts in the threaded run)\n", checks, failed, restarts);
    return failed != 0;
}
