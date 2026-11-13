// The freeze detector (stall.c, DM_STALL_LOG) driven by a fake present clock: dm_present_done_ns and the time of each look are set here, the focus, the menu and the dumps are
// stand-ins that count. Checks: no line before the first present or under the threshold; one line and one dump at the threshold, and only one per stall; "presents resumed" with the
// stall's length; at least 30 s between lines and at most 3 a run; nothing out of focus, in the background, with a library applet open or with the in-game menu open, and the time
// counted again from the return to focus, from the menu's closing and from the guest clock's restart (a text box up); "busy" when the guest thread table's locks stay held; the switch's values; off means never.
// Then DM_WATCH_STALL's 1 s dump in crash.c, which never fired while crash_watch_pregame_done had no caller: one present, then no progress for over a second, dumps once.
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#define DM_LOG_IMPL   // dm.h leaves dm_log's definition out: this file's records the lines
#include "../stall.c"

static uint64_t fake_now, fake_focus_in, fake_thawed; static int fake_focus = 1, fake_frozen, dumps, thread_dumps, table_busy;
int guest_clock_frozen(uint64_t *thawed) { *thawed = fake_thawed; return fake_frozen; }
uint64_t now_ns(void) { return fake_now; }
int dm_focus_seen(void) { return fake_focus; }
uint64_t dm_focus_in_since(void) { return fake_focus_in; }
void mtl_stall_dump(void) { dumps++; }
int svc_thread_dump_try(unsigned wait_ms) { (void)wait_ms; if (table_busy) return 0; thread_dumps++; return 1; }
static char lines[64][400]; static int nlines;
void dm_log(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    if (nlines < 64) vsnprintf(lines[nlines++], sizeof lines[0], fmt, ap);
    va_end(ap);
}
static int checks, failures;
#define CHECK(v, why) do { checks++; if (!(v)) { failures++; printf("FAIL: %s\n", why); } } while (0)
#define S(x) ((uint64_t)((x) * 1e9))
static int has(const char *text) { for (int i = 0; i < nlines; i++) if (strstr(lines[i], text)) return 1; return 0; }
static void reset(unsigned threshold_s) {
    memset(&g_stall, 0, sizeof g_stall); g_stall.threshold_ns = threshold_s * 1000000000ull;
    nlines = dumps = thread_dumps = table_busy = fake_frozen = 0; fake_focus = 1; fake_focus_in = fake_thawed = 0; fake_now = 0;
    atomic_store(&dm_present_done_ns, 0); atomic_store(&g_stall_menu, 0); atomic_store(&g_stall_menu_closed, 0);
}
static int look(double t) { fake_now = S(t); return stall_poll(fake_now); }   // one look at t seconds
static void looks(double from, double to) { for (int k = (int)(from * 2); k < (int)(to * 2); k++) look(k / 2.0); }   // a look every half second in [from, to)
static void present(double t) { atomic_store(&dm_present_done_ns, S(t)); look(t); }   // a present completes at t, and the detector looks then (it looks twice a second)

// crash.c's watchdog, linked beside this file (its dump hook counts)
void crash_install(void); void crash_set_dump_hook(void (*fn)(void));
static _Atomic int watch_dumps;
static void watch_hook(void) { atomic_fetch_add(&watch_dumps, 1); }

int main(void) {
    // The switch
    CHECK(stall_threshold(NULL) == 5, "unset: 5 s");
    CHECK(stall_threshold("12") == 12, "=12: 12 s");
    CHECK(stall_threshold("0") == 0 && stall_threshold("-3") == 0 && stall_threshold("off") == 0, "=0, a negative or a word: off");

    // Before the first present nothing is a stall, however long the boot takes
    reset(5);
    looks(0, 60.5);
    CHECK(nlines == 0 && dumps == 0, "no line before the first present");

    // One present, then none: quiet under the threshold, one line and one dump at it, none again for the same stall
    reset(5); present(10);
    look(10.5); look(14.5);
    CHECK(nlines == 0, "quiet under the threshold");
    CHECK(look(15) == STALL_FIRE, "a line at the threshold");
    CHECK(has("[RED] stall: no present for 5.0 s"), "the line says how long");
    CHECK(dumps == 1 && thread_dumps == 1, "the graphics dump and the guest thread table, once");
    CHECK(has("stall dump: end"), "the dump's end is marked");
    looks(15.5, 40);
    CHECK(dumps == 1, "one line per stall, however long it lasts");
    atomic_store(&dm_present_done_ns, S(40)); CHECK(look(40.5) == STALL_RESUMED, "presents come back");
    CHECK(has("stall: presents resumed after 30.0 s"), "with the stall's length (last present before it to the first after)");
    look(41); CHECK(dumps == 1, "said once");

    // Two stalls 30 s apart at least: the second within 30 s of the first line waits, then fires once it is due
    reset(5); present(10); look(15);   // line 1 at 15
    atomic_store(&dm_present_done_ns, S(20)); CHECK(look(20.5) == STALL_RESUMED, "resumed");
    look(25.5); look(40);
    CHECK(dumps == 1, "a second stall within 30 s of the first line has no line yet");
    CHECK(look(45) == STALL_FIRE && dumps == 2, "and gets one once 30 s have passed");
    CHECK(has("no present for 25.0 s"), "measured from its own last present");

    // At most 3 a run
    reset(5);
    for (int k = 0; k < 6; k++) { double t0 = 100.0 * k + 1; present(t0); look(t0 + 6); }
    CHECK(dumps == 3, "three lines a run at most");

    // Out of focus (2), in the background (3), an applet open (the game sees 2): never; back in focus, counted from the return
    reset(5); present(10);
    fake_focus = 2; looks(10.5, 30);
    fake_focus = 3; looks(30, 60);
    CHECK(dumps == 0, "nothing out of focus or in the background");
    fake_focus = 1; fake_focus_in = S(60);
    look(60); look(64.5);
    CHECK(dumps == 0, "back in focus: the time counts from the return");
    look(65); CHECK(dumps == 1, "and fires once the threshold has passed since");
    // A return to focus between two looks (iOS suspends the app, so the detector's thread does not run there): the front end's focus time still counts
    reset(5); present(10); look(12); fake_focus_in = S(40); look(41);
    CHECK(dumps == 0, "a picture that stood in the background is no stall");
    look(45); CHECK(dumps == 1, "counted from the front end's return to focus");

    // The in-game menu: never while open, counted from its closing
    reset(5); present(10);
    dm_stall_menu(1); looks(10.5, 30);
    CHECK(dumps == 0, "nothing with the in-game menu open");
    fake_now = S(30); dm_stall_menu(0);
    look(30); look(34.5); CHECK(dumps == 0, "after closing it, the time counts from the closing");
    look(35); CHECK(dumps == 1, "and fires once the threshold has passed since");

    // The guest clock frozen with the game in focus (the inline keyboard's text box, Monster Hunter Rise's hunter name): never while frozen, counted from the restart
    reset(5); present(10);
    fake_frozen = 1; looks(10.5, 40);
    CHECK(dumps == 0, "nothing while the guest clock stands still (a text box up)");
    fake_frozen = 0; fake_thawed = S(40);
    look(40); look(44.5); CHECK(dumps == 0, "after the restart, the time counts from it");
    look(45); CHECK(dumps == 1, "and fires once the threshold has passed since");

    // The guest thread table's locks stay held: the dump says so and goes on
    reset(5); table_busy = 1; present(10); look(15);
    CHECK(dumps == 1 && thread_dumps == 0 && has("guest thread table busy"), "busy, not a wait");

    // Another threshold, and off
    reset(12); present(10); look(21.5); CHECK(dumps == 0, "DM_STALL_LOG=12: quiet at 11.5 s"); look(22); CHECK(dumps == 1, "a line at 12 s");
    reset(0); present(10); looks(10, 200); CHECK(nlines == 0, "off: never");

    // DM_WATCH_STALL's 1 s dump (crash.c): one present, then no progress for more than a second, and the threshold (4 s) not reached
    setenv("DM_WATCH_STALL", "4", 1);
    crash_set_dump_hook(watch_hook);
    crash_install();
    crash_watch_frame();
    for (int i = 0; i < 40 && !atomic_load(&watch_dumps); i++) usleep(50000);   // up to 2 s; the dump comes after 1 s
    CHECK(atomic_load(&watch_dumps) == 1, "DM_WATCH_STALL: the 1 s dump fires after the first present");
    // The watchdog's stage stays "present frame" over later presents, which name none (it alternated with "startup" every other present)
    crash_watch_frame(); crash_watch_frame(); crash_watch_frame();
    { char path[] = "/tmp/t_stall.XXXXXX"; int fd = mkstemp(path), saved = dup(2); char text[512] = "";
      if (fd >= 0 && saved >= 0) { fflush(stderr); dup2(fd, 2); crash_dump_now("t_stall"); fflush(stderr); dup2(saved, 2);
          FILE *f = fopen(path, "r"); if (f) { size_t n = fread(text, 1, sizeof text - 1, f); text[n] = 0; fclose(f); } }
      if (fd >= 0) { close(fd); unlink(path); } if (saved >= 0) close(saved);
      CHECK(strstr(text, "tick 4 / stage present frame") != NULL, "the watchdog names the present stage and counts presents as its tick"); }
    printf("stall log: %d checks, %d failures\n", checks, failures);
    return failures != 0;   // before the watchdog's 4 s
}
