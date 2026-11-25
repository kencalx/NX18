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
// N s" says how long the picture stood. The guest clock frozen holds it off too: the inline keyboard's text box (hle_swkbd.c) stops the game's thread with the clock frozen and
// no library applet, so the game still sees focus 1 while the player types. The time counts from the latest of the last present, the return to focus, the menu's closing and the
// guest clock's restart, so a picture that stood while out of focus, behind the menu or behind the text box is not a stall.
//
// A residency commit that does not come back from the kernel is named sooner, at about 1 s (STALL_COMMIT_NS, looked at twice a second, in or out of focus): Ocarina of Time on the
// iPhone 18 Pro Max (build 431d5d18) froze with the replay thread 16.5 s in iokit_user_client_trap under res_commit, holding the residency commit lock, and this said so only at its
// 5 s mark. "[RED] stall: <the commit> (presents wait behind it; a dump follows)", once per commit and at most STALL_LINES a run (commit_step); the 5 s line for the same freeze then
// says the dump is above instead of writing it again. nvn_mtl.m mtl_res_commit_stuck reads it without a lock.
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
uint64_t mtl_res_commit_stuck(uint64_t min_ns, char *out, size_t n);   // nvn_mtl.m: a residency commit in the kernel for min_ns or more (when it began; 0: none)
#define STALL_COMMIT_NS 1000000000ull

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
    int commit_lines;        // residency commit lines written
    uint64_t commit_for;     // the commit (its start) the last one was written for, while it is still in the kernel (0: none)
} stall_t;
// One look for a residency commit in the kernel: at, its start as mtl_res_commit_stuck returns it for STALL_COMMIT_NS (0: none so long). 1: write its line and the dump
static int commit_step(stall_t *s, uint64_t at) {
    if (!at) { s->commit_for = 0; return 0; }
    if (!s->threshold_ns || at == s->commit_for || s->commit_lines >= STALL_LINES) return 0;
    s->commit_lines++; s->commit_for = at;
    return 1;
}
// One look at time now: present is the last completed present (0: none yet), focus the oe focus state the game sees, menu whether the in-game menu is open or the guest clock
// frozen, since the latest of the return to focus, the menu's closing and the clock's restart. Returns STALL_FIRE (write a stall line and the dump; *secs: seconds since the last present) or STALL_RESUMED (presents came back after a
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
void dm_stall_dump(void) { stall_dump(); }   // also after a suspend whose drain did not finish (hle_nvn.c dm_gfx_suspend), on a utility queue
// One look by the detector's thread (t_stall calls it with its own clock)
static int stall_poll(uint64_t now) {
    uint64_t present = atomic_load(&dm_present_done_ns), since = dm_focus_in_since(), closed = atomic_load(&g_stall_menu_closed), thawed = 0;
    if (closed > since) since = closed;
    // The guest clock frozen (the inline keyboard's text box, hle_os.c guest_clock_frozen) holds it off as the menu does, and the time counts again from the clock's restart
    int frozen = guest_clock_frozen(&thawed);
    if (thawed > since) since = thawed;
    int focus = dm_focus_seen(), menu = atomic_load(&g_stall_menu) || frozen; double secs = 0;
    char rk[300] = "";
    if (commit_step(&g_stall, mtl_res_commit_stuck(STALL_COMMIT_NS, rk, sizeof rk))) {
        LOG("[RED] stall: %s (presents wait behind it; residency commit line %d of at most %d; a dump follows; DM_STALL_LOG=0 turns this off)", rk, g_stall.commit_lines, STALL_LINES);
        stall_dump();
        LOG("stall dump: end");
    }
    int r = stall_step(&g_stall, now, present, focus, menu, since, &secs);
    if (r == STALL_FIRE) {
        int above = g_stall.commit_for != 0;   // the commit named above is still in the kernel: its dump says it
        LOG("[RED] stall: no present for %.1f s while the game is in focus (line %d of at most %d; %s; DM_STALL_LOG=0 turns this off)", secs, g_stall.lines, STALL_LINES,
            above ? "the residency commit named above is still in the kernel, its dump is above" : "a dump follows");
        if (!above) { stall_dump(); LOG("stall dump: end"); }
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
