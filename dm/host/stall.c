// The freeze detector (DM_STALL_LOG; on by default on the iPhone, the iPad and the Mac, player builds included; logging only, it changes nothing a game does).
// Ocarina of Time's test 3 (baf45a97) on an iPhone 18 Pro Max froze once about 13 s after a save load, as Link stepped into water: presents stopped (no frame, long-frame or power
// tick line after about 126 s) while audio went on, with no [RED] line and no crash; the owner then closed it from the app switcher, and a second run through the same water did not
// freeze. The log could not say where it stood: a command buffer that never completes logs nothing, the game's SyncWait sleeps on the GPU event for up to an hour, the host's own
// waits (rec_drain, ubc_wait, up_wait_zero, the present waits) have no limit and had no line (they now say so once at 10 s: nvn_mtl.m wait_say), and the watchdog in crash.c is off
// unless DM_WATCH / DM_WATCH_STALL is set.
//
// So a thread of its own, at utility QoS, looks twice a second at when the last present completed on the GPU (dm_present_done_ns, stamped by nvn_mtl.m's present feedback handler).
// When the game is in focus (the oe focus state the game sees is 1: not out of focus, not in the background, no library applet open), the in-game menu is closed, the game has
// presented at least once and no present has completed for the threshold (default 5 s; DM_STALL_LOG=<seconds> sets it, DM_STALL_LOG=0 turns the detector off), it writes one
// "[RED] stall: no present for N s" line and a dump: the graphics side's state (nvn_mtl.m mtl_stall_dump: fences submitted and completed, the feedback queue's heartbeat, the
// residency locks' holders, the upload slots, the encode thread, the present queue, the waits in progress, mtl_wait_state_dump) and the guest thread table (svc_thread_dump, which
// also lists the host threads with their frames). At most 3 lines a run, at least 30 s apart, once per stall; when presents come back after a line, "stall: presents resumed after
// N s" says how long the picture stood. The time counts from the latest of the last present, the return to focus and the menu's closing, so a picture that stood while out of
// focus or behind the menu is not a stall.
//
// It takes no lock the render, replay, present or feedback paths can hold: the clock it reads is an atomic, the focus and the menu are atomics, the graphics dump reads only
// atomics and notes, and the guest thread table is dumped under locks it only tries (svc_thread_dump_try; "busy" when one stays held). A dump during a freeze therefore cannot
// wait on the freeze. The step (stall_step) is a pure function of the clock and the state, which t_stall drives with a fake present clock.
#include "dm.h"
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

_Atomic uint64_t dm_present_done_ns;   // nvn_mtl.m: when the last present completed on the GPU (host now_ns), 0 until the first
static _Atomic int g_stall_menu;       // the in-game menu is open (iOS DmGamepad.m), and when it last closed (now_ns)
static _Atomic uint64_t g_stall_menu_closed;
void dm_stall_menu(int open) {
    if (!open) atomic_store(&g_stall_menu_closed, now_ns());
    atomic_store(&g_stall_menu, !!open);
}
void mtl_stall_dump(void);   // nvn_mtl.m

enum { STALL_QUIET, STALL_FIRE, STALL_RESUMED };
enum { STALL_LINES = 3 };
#define STALL_GAP_NS 30000000000ull   // at least this between two stall lines
typedef struct {
    uint64_t threshold_ns;   // 0: off
    uint64_t eligible_since; // when the last look found the game in focus with the menu closed (0: it did not)
    int lines;               // stall lines written
    uint64_t last_line;      // when the last one was written
    uint64_t open_present;   // the last present before the stall a line was written for, until presents resume (0: none open)
    uint64_t fired_for;      // the present the last line was written for (one line per stall)
} stall_t;
// One look at time now: present is the last completed present (0: none yet), focus the oe focus state the game sees, menu whether the in-game menu is open, since the latest of the
// return to focus and the menu's closing. Returns STALL_FIRE (write a stall line and the dump; *secs: seconds since the last present) or STALL_RESUMED (presents came back after a
// line; *secs: seconds between the last present before the stall and the first after it), else STALL_QUIET
static int stall_step(stall_t *s, uint64_t now, uint64_t present, int focus, int menu, uint64_t since, double *secs) {
    if (s->open_present && present != s->open_present) {
        *secs = present > s->open_present ? (present - s->open_present) / 1e9 : 0;
        s->open_present = 0;
        return STALL_RESUMED;
    }
    if (!s->threshold_ns || !present || focus != 1 || menu) { s->eligible_since = 0; return STALL_QUIET; }
    if (!s->eligible_since) s->eligible_since = now;
    uint64_t from = present;
    if (s->eligible_since > from) from = s->eligible_since;
    if (since > from) from = since;
    if (now < from || now - from < s->threshold_ns) return STALL_QUIET;
    if (s->fired_for == present || s->lines >= STALL_LINES || (s->last_line && now - s->last_line < STALL_GAP_NS)) return STALL_QUIET;
    s->lines++; s->last_line = now; s->fired_for = s->open_present = present;
    *secs = (now - present) / 1e9;
    return STALL_FIRE;
}

static stall_t g_stall;
static void stall_dump(void) {
    mtl_stall_dump();
    if (!svc_thread_dump_try(1000)) LOG("stall dump: guest thread table busy (its lock or the log's stayed held for 1 s)");
}
// One look by the detector's thread (t_stall calls it with its own clock)
static int stall_poll(uint64_t now) {
    uint64_t present = atomic_load(&dm_present_done_ns), since = dm_focus_in_since(), closed = atomic_load(&g_stall_menu_closed);
    if (closed > since) since = closed;
    int focus = dm_focus_seen(), menu = atomic_load(&g_stall_menu); double secs = 0;
    int r = stall_step(&g_stall, now, present, focus, menu, since, &secs);
    if (r == STALL_FIRE) {
        LOG("[RED] stall: no present for %.1f s while the game is in focus (line %d of at most %d; a dump follows; DM_STALL_LOG=0 turns this off)", secs, g_stall.lines, STALL_LINES);
        stall_dump();
        LOG("stall dump: end");
    } else if (r == STALL_RESUMED) LOG("stall: presents resumed after %.1f s", secs);
    return r;
}
static void *stall_main(void *arg) {
    (void)arg;
    pthread_setname_np("dm stall log");
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
    for (;;) { usleep(500000); stall_poll(now_ns()); }
    return NULL;
}
// DM_STALL_LOG: unset 5 s, =<seconds> that threshold, =0 (or anything not a positive number) off
static unsigned stall_threshold(const char *e) { if (!e) return 5; int v = atoi(e); return v > 0 ? (unsigned)v : 0; }
void dm_stall_start(void) {
    static int started; if (started++) return;
    const char *e = getenv("DM_STALL_LOG");
    unsigned s = stall_threshold(e);
    if (!s) { LOG("stall log: off (DM_STALL_LOG=%s)", e); return; }
    g_stall.threshold_ns = s * 1000000000ull;
    LOG("stall log: a red line and a state dump when no present completes for %u s while the game is in focus (DM_STALL_LOG=0 turns it off)", s);
    pthread_t th;
    if (pthread_create(&th, NULL, stall_main, NULL)) { LOG("[RED] stall log: its thread could not start"); return; }
    pthread_detach(th);
}
