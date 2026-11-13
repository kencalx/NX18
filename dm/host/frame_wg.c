// The frame workgroup (frame_wg.h; profile key frame_wg, DM_FRAME_WG=1, armed by hle_nvn.c frame_wg_on, which needs DM_RT on). One os_workgroup interval of the audio type, made by
// AudioWorkIntervalCreate (the public way for an app to get an interval of its own; for frames it is off-label, os/workgroup_interval.h), told each frame's start and deadline by the
// thread that acquires the window texture: finished just before the acquire's pacing wait and started just after it, once per frame (hle_nvn.c). The acquiring thread joins it
// when its time-constraint policy is first set (set_time_constraint_comp), the replay threads at their first declaration (rtw_declare). It is the only public lever on the
// performance controller beside the time-constraint policy; whether a deadline keeps the burst clocks is what the test measures (docs/reference/frame-rate.md, A frame deadline
// told through a work interval). libdispatch's rules, each of which ends the process with os_crash when broken:
// - os_workgroup_interval_start / _finish on a thread that is not a member: only a thread whose own os_workgroup_join returned 0 calls them (t_state, thread-local); on any other
//   neither is called, and the frame is counted as skipped (once, at its begin)
// - a second join on a member thread returns EALREADY: each thread joins once, and keeps the first answer
// - releasing the last reference while an interval is started: the interval is made once and never released
// - a thread that exits still a member ("Thread exiting without leaving workgroup"): a key destructor of this file leaves on the way out. Destructors of keys made with
//   pthread_key_create run before libdispatch's own (t_framewg checks it on a thread that joins and ends). A member never leaves otherwise
// Start and deadline are mach_absolute_time ticks (OS_CLOCK_MACH_ABSOLUTE_TIME); a start after now, or a deadline before the start, is EINVAL
#include "frame_wg.h"
#include "dm.h"
#include <AudioToolbox/AudioWorkInterval.h>
#include <os/workgroup.h>
#include <mach/mach_time.h>
#include <stdatomic.h>

static os_workgroup_interval_t g_wg;   // made once, never released
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static pthread_key_t g_leave_key; static int g_leave_ok;   // the thread's join token, left by leave_on_exit when the thread ends
static mach_timebase_info_data_t g_tb;
static __thread int t_state, t_err;   // this thread: 0 = no join tried, 1 = a member, -1 = the join failed (t_err)
static _Atomic uint64_t g_started, g_finished, g_late, g_skipped, g_start_err, g_finish_err;
static _Atomic int g_last_err;
static _Atomic int g_open; static _Atomic uint64_t g_deadline;   // an interval is started (and its deadline, in ticks); only the acquiring thread starts and finishes, one acquire at a time

static void leave_on_exit(void *p) {
    os_workgroup_join_token_t tok = p;
    os_workgroup_leave(g_wg, tok); free(tok);
}
static void create(void) {
    mach_timebase_info(&g_tb);
    g_leave_ok = pthread_key_create(&g_leave_key, leave_on_exit) == 0;
    g_wg = g_leave_ok ? AudioWorkIntervalCreate("nx18-frame", OS_CLOCK_MACH_ABSOLUTE_TIME, NULL) : NULL;   // without the key a member that ends would crash: no interval then
    LOG("[nvn] frame workgroup: interval 'nx18-frame' (AudioWorkIntervalCreate, mach absolute time) %s", g_wg ? "made" : g_leave_ok ? "not made: threads will not join" : "not made: no thread key for leaving at thread exit");
}
int dm_frame_wg_join(const char *who) {
    if (t_state) return t_state > 0 ? 0 : t_err;
    pthread_once(&g_once, create);
    int r = -1;
    if (g_wg) {
        os_workgroup_join_token_t tok = calloc(1, sizeof *tok);
        r = tok ? os_workgroup_join(g_wg, tok) : ENOMEM;
        if (!r && pthread_setspecific(g_leave_key, tok)) { os_workgroup_leave(g_wg, tok); r = ENOMEM; }   // not a member without a way to leave at thread exit
        if (r) free(tok);
    }
    t_state = r ? -1 : 1; t_err = r;
    LOG("[nvn] frame workgroup: '%s' %s (%d%s%s)", who ? who : "?", r ? "did not join; its starts and finishes are skipped" : "joined", r, r > 0 ? ": " : "", r > 0 ? strerror(r) : r < 0 ? ": no interval" : "");
    return r;
}
void dm_frame_wg_end(void) {
    if (t_state <= 0 || !atomic_load_explicit(&g_open, memory_order_acquire)) return;   // not a member: counted once a frame, at its begin
    uint64_t now = mach_absolute_time();
    int r = os_workgroup_interval_finish(g_wg, NULL);
    if (r) { atomic_fetch_add_explicit(&g_finish_err, 1, memory_order_relaxed); atomic_store_explicit(&g_last_err, r, memory_order_relaxed);
        if (r == EINVAL) atomic_store_explicit(&g_open, 0, memory_order_release);   // no interval started (os/workgroup_interval.h): the next begin starts one rather than every frame failing here
        return; }   // EBUSY (another member in a start or finish): still open, the next frame's finish tries again
    atomic_fetch_add_explicit(&g_finished, 1, memory_order_relaxed);
    if (now > atomic_load_explicit(&g_deadline, memory_order_relaxed)) atomic_fetch_add_explicit(&g_late, 1, memory_order_relaxed);
    atomic_store_explicit(&g_open, 0, memory_order_release);
}
void dm_frame_wg_begin(uint64_t period_ns) {
    if (t_state <= 0) { atomic_fetch_add_explicit(&g_skipped, 1, memory_order_relaxed); return; }   // one skip a frame (its end counts none)
    if (atomic_load_explicit(&g_open, memory_order_acquire)) return;   // the last finish failed with EBUSY (counted there): a start would be EINVAL
    uint64_t s = mach_absolute_time(), d = s + period_ns * g_tb.denom / g_tb.numer;   // ticks, as the interval's clock: nanoseconds would put the deadline about 41 times as far on an iPhone (24 MHz ticks)
    int r = os_workgroup_interval_start(g_wg, s, d, NULL);
    if (r) { atomic_fetch_add_explicit(&g_start_err, 1, memory_order_relaxed); atomic_store_explicit(&g_last_err, r, memory_order_relaxed); return; }
    atomic_fetch_add_explicit(&g_started, 1, memory_order_relaxed);
    atomic_store_explicit(&g_deadline, d, memory_order_relaxed); atomic_store_explicit(&g_open, 1, memory_order_release);
}
void dm_frame_wg_counts_read(dm_frame_wg_counts *c) {
    c->started = atomic_load_explicit(&g_started, memory_order_relaxed); c->finished = atomic_load_explicit(&g_finished, memory_order_relaxed);
    c->late = atomic_load_explicit(&g_late, memory_order_relaxed); c->skipped = atomic_load_explicit(&g_skipped, memory_order_relaxed);
    c->start_err = atomic_load_explicit(&g_start_err, memory_order_relaxed); c->finish_err = atomic_load_explicit(&g_finish_err, memory_order_relaxed);
    c->last_err = atomic_load_explicit(&g_last_err, memory_order_relaxed);
}
