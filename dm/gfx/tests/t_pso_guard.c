// The crash guard of the bundled pipeline archive (../nvn/nvn_pso_guard.h), on any machine: a record in a temporary folder through the sequences of starts the guard tells
// apart (a start that crashes, one that gets past its window, one in the background, inactive or in the graceful exit, a clean exit), with one early end or two in a row needed
// (a profile that sets pso_mtl4 on), records of another archive or system build, a record that cannot be written, the present path racing the background hook (make
// t_pso_guard_tsan), and whole sequences of starts against devices on which the archive, the device's own build of the bases (in its window or after it), both or neither crash:
// launches settle and never alternate between crashing and not. nvn_mtl.m's use of it, with a real archive, is t_pso_bundle.m's
#define _DEFAULT_SOURCE   // mkdtemp under -std=c11 on Linux (macOS declares it anyway)
#include "../nvn/nvn_pso_guard.h"
#include <pthread.h>
#include <stdlib.h>
#include <sys/stat.h>

static int checks, failed;
#define EXPECT(name, want, got) do { long long w_ = (want), g_ = (got); checks++; if (w_ != g_) { fprintf(stderr, "%s: expected %lld, got %lld\n", name, w_, g_); failed++; } } while (0)

static char dir[256], rec[512];
static pg_guard g = PG_GUARD_INIT;
static int need = 1;   // starts in a row with the archive that end early before one leaves it out: 2 for a profile that sets pso_mtl4 on
static const char *OS = "24A335", *ARCH = "applegpu_g19p.mtl4a 734003200 0123456789abcdef host 00112233445566778899aabbccddeeff";

static int on_disk(void) { return pg_load(&g); }   // the record's state for this archive and system build, as the next start reads it
static int exists(void) { struct stat st; return !stat(rec, &st); }
static void plant(int st) { char buf[2048]; pg_format(buf, sizeof buf, st, OS, ARCH); FILE *f = fopen(rec, "w"); if (!f) abort(); fputs(buf, f); fclose(f); }
static void plant_text(const char *txt) { FILE *f = fopen(rec, "w"); if (!f) abort(); fputs(txt, f); fclose(f); }
static int start(void) { return pg_begin(&g, rec, OS, ARCH, need).use; }   // a start: 1 = it uses the archive
static int frames_to_end(void) { int n = 1; while (n <= PG_FRAMES_MAX + 1 && !pg_frame(&g)) n++; return n; }   // frames presented until one ends the window
static int pass(void) {   // the start's prepare step ends, then its first frames: the frame that ends the window, and pg_pass as nvn_mtl.m calls it
    pg_mark(&g);
    EXPECT("window: ends PG_FRAMES frames after the mark", PG_FRAMES, frames_to_end());
    int err = 0, was = pg_pass(&g, &err);
    EXPECT("window: the record written", 0, err);
    return was;
}

static void *frames(void *arg) { (void)arg; for (int i = 0; i < 20000; i++) if (atomic_load(&g.watching) && pg_frame(&g)) { int err; pg_pass(&g, &err); } return NULL; }
static void *away(void *arg) {
    (void)arg;
    for (int i = 0; i < 2000; i++) { int err; pg_away(&g, PG_AWAY_INACTIVE, 1, &err); pg_away(&g, PG_AWAY_BACKGROUND, 1, &err); pg_away(&g, PG_AWAY_BACKGROUND, 0, &err); pg_away(&g, PG_AWAY_INACTIVE, 0, &err); }
    return NULL;
}

// A device: a start with the archive crashes in its window (with), one without it does (without), or one without it crashes only after its window (late: the guard sees a start
// past its window, the player a crash all the same)
typedef struct { int with, without, late; } device;
// One start on it, with an unrelated early end in its window when extra: 1 = the player saw a crash
static int one_start(device d, int extra) {
    int use = start();
    if (extra || (use ? d.with : d.without)) return 1;   // a crash in the window: nothing more runs, the record stays as written
    if (atomic_load(&g.watching)) { pg_mark(&g); while (!pg_frame(&g)) {} int err; pg_pass(&g, &err); }
    return !use && d.late;
}
// n starts from no record, with unrelated early ends at the starts in the bits of extra: the crashes, as a bit string (start 0 in bit 0)
static unsigned starts(int n, device d, unsigned extra) {
    unlink(rec); unsigned bits = 0;
    for (int i = 0; i < n; i++) if (one_start(d, (int)(extra >> i & 1))) bits |= 1u << i;
    return bits;
}

int main(void) {
    snprintf(dir, sizeof dir, "%s/t_pso_guard.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(dir)) abort();
    snprintf(rec, sizeof rec, "%s/pso_bundle_guard.tsv", dir);

    // a first start uses the archive and is watched; past its window the record goes
    EXPECT("first start: uses the archive", 1, start());
    EXPECT("first start: found none", PG_NONE, g.found);
    EXPECT("first start: watched with it", PG_WITH, g.armed);
    EXPECT("first start: on disk", PG_WITH, on_disk());
    EXPECT("first start: past its window", PG_WITH, pass());
    EXPECT("first start: the record goes", 0, exists());
    EXPECT("first start: no longer watched", 0, atomic_load(&g.watching));

    // without the end of the prepare step and its prebuild, the window ends after PG_FRAMES_MAX frames, once
    start(); EXPECT("no mark: PG_FRAMES_MAX frames", PG_FRAMES_MAX, frames_to_end());
    EXPECT("no mark: a later frame does not report again", 0, pg_frame(&g));
    { int err; EXPECT("no mark: past its window", PG_WITH, pg_pass(&g, &err)); EXPECT("no mark: written", 0, err); }
    { int err; EXPECT("pass twice: nothing watched", PG_NONE, pg_pass(&g, &err)); }
    // frames before the mark (a prewarm in the background) do not count toward PG_FRAMES; a second mark changes nothing
    start(); for (int i = 0; i < 100; i++) pg_frame(&g);
    pg_mark(&g); for (int i = 0; i < 7; i++) pg_frame(&g); pg_mark(&g);
    EXPECT("frames before the mark: PG_FRAMES after the first mark", PG_FRAMES - 7, frames_to_end());
    { int err; pg_pass(&g, &err); }

    // the background and back: the record goes (an app killed while suspended is no crash), then is written again; a second call changes nothing
    start(); { int err;
        EXPECT("background: was watched", PG_WITH, pg_away(&g, PG_AWAY_BACKGROUND, 1, &err)); EXPECT("background: no record", 0, exists());
        EXPECT("background twice: nothing written", PG_NONE, pg_away(&g, PG_AWAY_BACKGROUND, 1, &err));
        EXPECT("foreground: was watched", PG_WITH, pg_away(&g, PG_AWAY_BACKGROUND, 0, &err)); EXPECT("foreground: written again", PG_WITH, on_disk());
        // inactive (the app switcher), then the background, then back in two steps: the record comes back only when neither holds
        EXPECT("inactive: was watched", PG_WITH, pg_away(&g, PG_AWAY_INACTIVE, 1, &err)); EXPECT("inactive: no record", 0, exists());
        EXPECT("inactive, then background: nothing written", PG_NONE, pg_away(&g, PG_AWAY_BACKGROUND, 1, &err));
        EXPECT("foreground, still inactive: nothing written", PG_NONE, pg_away(&g, PG_AWAY_BACKGROUND, 0, &err)); EXPECT("still inactive: no record", 0, exists());
        EXPECT("active: written again", PG_WITH, pg_away(&g, PG_AWAY_INACTIVE, 0, &err)); EXPECT("active: on disk", PG_WITH, on_disk()); }
    // a crash now: the next start leaves the archive out and is watched without it
    EXPECT("after a crash: leaves it out", 0, start());
    EXPECT("after a crash: found with", PG_WITH, g.found);
    EXPECT("after a crash: watched without it", PG_WITHOUT, g.armed);
    EXPECT("after a crash: on disk", PG_WITHOUT, on_disk());
    // that start in the background: the record says a start with the archive failed and none without it got past its window, so a kill there changes nothing
    { int err; pg_away(&g, PG_AWAY_BACKGROUND, 1, &err); EXPECT("without, background: with", PG_WITH, on_disk());
      pg_away(&g, PG_AWAY_BACKGROUND, 0, &err); EXPECT("without, foreground: without again", PG_WITHOUT, on_disk()); pg_away(&g, PG_AWAY_BACKGROUND, 1, &err); }
    g.away = 0;   // killed in the background: the next process starts in the foreground (nothing is written as it ends)
    EXPECT("killed in the background: leaves it out", 0, start());
    EXPECT("killed in the background: found with", PG_WITH, g.found);
    EXPECT("killed in the background: watched without it", PG_WITHOUT, g.armed);
    // past its window: the archive stays out for this archive and system build, start after start, unwatched
    EXPECT("without: past its window", PG_WITHOUT, pass());
    EXPECT("without: skip", PG_SKIP, on_disk());
    for (int i = 0; i < 3; i++) {
        EXPECT("skip: leaves it out", 0, start()); EXPECT("skip: found skip", PG_SKIP, g.found); EXPECT("skip: not watched", PG_NONE, g.armed);
        EXPECT("skip: record kept", PG_SKIP, on_disk());
    }
    { int err; EXPECT("skip: the background writes nothing", PG_NONE, pg_away(&g, PG_AWAY_BACKGROUND, 1, &err)); EXPECT("skip: still skip", PG_SKIP, on_disk()); pg_away(&g, PG_AWAY_BACKGROUND, 0, &err); }
    // another system build, and a rebuilt app (another archive, or the same archive with another host): no record, the archive is tried again
    { pg_start s = pg_begin(&g, rec, "24B83", ARCH, 1);
      EXPECT("another system build: uses it", 1, s.use); EXPECT("another system build: found none", PG_NONE, s.found); EXPECT("another system build: watched", PG_WITH, s.armed); }
    plant(PG_SKIP);
    { pg_start s = pg_begin(&g, rec, OS, "applegpu_g19p.mtl4a 734003712 fedcba9876543210 host 00112233445566778899aabbccddeeff", 1);
      EXPECT("a rebuilt archive: uses it", 1, s.use); EXPECT("a rebuilt archive: found none", PG_NONE, s.found); }
    plant(PG_SKIP);
    EXPECT("another host build: uses it", 1, pg_begin(&g, rec, OS, "applegpu_g19p.mtl4a 734003200 0123456789abcdef host ffeeddccbbaa99887766554433221100", 1).use);

    // the start without the archive that does not get past its window either: the archive is not shown to be the cause; the next start uses it again, watched as a first start
    plant(PG_WITHOUT);
    EXPECT("both ended early: uses it", 1, start());
    EXPECT("both ended early: found without", PG_WITHOUT, g.found);
    EXPECT("both ended early: watched with it", PG_WITH, g.armed);
    EXPECT("both ended early: on disk", PG_WITH, on_disk());
    { int err; pg_away(&g, PG_AWAY_BACKGROUND, 1, &err); EXPECT("both ended early, then away: none (not shown to be the cause)", 0, exists()); pg_away(&g, PG_AWAY_BACKGROUND, 0, &err); }
    EXPECT("both ended early, then past its window", PG_WITH, pass());
    EXPECT("both ended early, then past: no record", 0, exists());

    // need 2 (a profile that sets pso_mtl4 on): one start with the archive that ended early is followed by another start with it, watched; two in a row leave it out
    need = 2;
    plant(PG_WITH);
    { pg_start s = pg_begin(&g, rec, OS, ARCH, need);
      EXPECT("need 2, one ended early: uses it", 1, s.use); EXPECT("need 2: found with", PG_WITH, s.found); EXPECT("need 2: watched as the second in a row", PG_WITH2, s.armed); }
    EXPECT("need 2: on disk", PG_WITH2, on_disk());
    { int err; pg_away(&g, PG_AWAY_INACTIVE, 1, &err); EXPECT("need 2, inactive: back to one ended early", PG_WITH, on_disk());
      pg_away(&g, PG_AWAY_INACTIVE, 0, &err); EXPECT("need 2, active: the second in a row again", PG_WITH2, on_disk()); }
    EXPECT("need 2, the second past its window", PG_WITH2, pass());
    EXPECT("need 2, the second past: no record", 0, exists());
    plant(PG_WITH); start(); pg_exit(&g); EXPECT("need 2, a clean exit of the second: one ended early, as before it", PG_WITH, on_disk());
    plant(PG_WITH2);
    EXPECT("need 2, two in a row: leaves it out", 0, start());
    EXPECT("need 2, two in a row: watched without it", PG_WITHOUT, g.armed);
    { int err; pg_away(&g, PG_AWAY_EXIT, 1, &err); EXPECT("need 2, without, in the graceful exit: two in a row, as before it", PG_WITH2, on_disk()); g.away = 0; }
    start(); EXPECT("need 2, without again: past its window", PG_WITHOUT, pass());
    EXPECT("need 2: skip", PG_SKIP, on_disk());
    EXPECT("need 2, skip: leaves it out", 0, start());
    plant(PG_WITH); EXPECT("need 1 reads one ended early as leave it out", 0, pg_begin(&g, rec, OS, ARCH, 1).use);
    need = 1;

    // records that are no record: garbage, an unknown state, a missing field, another archive or system build
    const char *junk[] = {"", "garbage", "state\tbogus\nos\t24A335\narchive\tapplegpu_g19p.mtl4a 734003200 0123456789abcdef host 00112233445566778899aabbccddeeff\n",
                          "state\tskip\narchive\tapplegpu_g19p.mtl4a 734003200 0123456789abcdef host 00112233445566778899aabbccddeeff\n", "state\tskip\nos\t24A335\n",
                          "state\tnone\nos\t24A335\narchive\tapplegpu_g19p.mtl4a 734003200 0123456789abcdef host 00112233445566778899aabbccddeeff\n",
                          "state\tskip\nos\t24A33\narchive\tapplegpu_g19p.mtl4a 734003200 0123456789abcdef host 00112233445566778899aabbccddeeff\n",
                          "state\tskip\nos\t24A335\narchive\tapplegpu_g19p.mtl4a 734003200 0123456789abcdef host 00112233445566778899aabbccddeeff0\n",
                          "state\tskip\nstate\tbogus\nos\t24A335\narchive\tapplegpu_g19p.mtl4a 734003200 0123456789abcdef host 00112233445566778899aabbccddeeff\n",
                          "state\twith2x\nos\t24A335\narchive\tapplegpu_g19p.mtl4a 734003200 0123456789abcdef host 00112233445566778899aabbccddeeff\n"};
    for (unsigned i = 0; i < sizeof junk / sizeof *junk; i++) { plant_text(junk[i]); EXPECT("not a record of this archive: uses it", 1, start()); EXPECT("not a record: found none", PG_NONE, g.found); }
    EXPECT("parse: no os given", PG_NONE, pg_parse("state\twith\nos\t\narchive\tx\n", "", "x"));
    EXPECT("parse: without a final newline", PG_SKIP, pg_parse("state\tskip\nos\tA\narchive\tx", "A", "x"));
    EXPECT("parse: comments", PG_WITH, pg_parse("# state\tskip\nstate\twith\nos\tA\narchive\tx\n", "A", "x"));
    for (int st = PG_WITH; st < PG_STATES; st++) { char buf[2048]; pg_format(buf, sizeof buf, st, OS, ARCH); EXPECT("format and parse agree", st, pg_parse(buf, OS, ARCH)); }

    // an archive Metal does not open after all: no evidence, the record goes back to what the start found
    unlink(rec); start(); pg_unused(&g); EXPECT("unused: no record", 0, exists()); EXPECT("unused: not watched", 0, atomic_load(&g.watching));
    plant(PG_WITHOUT); start(); pg_unused(&g); EXPECT("unused after both ended early: without again", PG_WITHOUT, on_disk());
    plant(PG_WITH); pg_begin(&g, rec, OS, ARCH, 2); pg_unused(&g); EXPECT("unused, need 2: one ended early again", PG_WITH, on_disk());
    // a clean exit leaves the record as the start's end would
    unlink(rec); start(); pg_exit(&g); EXPECT("clean exit with it: no record", 0, exists());
    plant(PG_WITH); start(); pg_exit(&g); EXPECT("clean exit without it: with", PG_WITH, on_disk());
    // an app already away when the archive opens (inactive at its first submission): the record as the start's end would leave it until the app is back
    unlink(rec); { int err; pg_away(&g, PG_AWAY_INACTIVE, 1, &err);
      EXPECT("away at the start: uses it", 1, start()); EXPECT("away at the start: watched", PG_WITH, g.armed); EXPECT("away at the start: no record", 0, exists());
      EXPECT("back: written", PG_WITH, pg_away(&g, PG_AWAY_INACTIVE, 0, &err)); EXPECT("back: on disk", PG_WITH, on_disk()); pass(); }
    // the graceful exit (dm_gfx_exiting, before the background hook and its waits): the record as the start's end would leave it; the background hook after it writes nothing
    unlink(rec); start(); { int err;
      EXPECT("graceful exit: was watched", PG_WITH, pg_away(&g, PG_AWAY_EXIT, 1, &err)); EXPECT("graceful exit: no record", 0, exists());
      EXPECT("graceful exit, then the background hook: nothing written", PG_NONE, pg_away(&g, PG_AWAY_BACKGROUND, 1, &err)); g.away = 0; }

    // a record that cannot be written (its folder is gone): the start is not watched, and the archive is used as the record says
    { char nowhere[600]; snprintf(nowhere, sizeof nowhere, "%s/gone/pso_bundle_guard.tsv", dir);
      pg_start s = pg_begin(&g, nowhere, OS, ARCH, 1);
      EXPECT("unwritable: uses it", 1, s.use); EXPECT("unwritable: an errno", ENOENT, s.err); EXPECT("unwritable: not watched", PG_NONE, s.armed);
      EXPECT("unwritable: no frame ends a window", 0, atomic_load(&g.watching)); }

    // whole sequences of starts (bit i: start i crashed), with one early end needed (most games) and two in a row (a profile that sets pso_mtl4 on)
    for (need = 1; need <= 2; need++) {
        // the archive crashes, the device's own build does not (#640): one crash (two with need 2), then never again
        EXPECT("archive crashes: one crash per early end needed, then none", need == 1 ? 0x1 : 0x3, starts(12, (device){1, 0, 0}, 0));
        EXPECT("archive crashes: then skip", PG_SKIP, on_disk());
        // neither crashes, one unrelated crash in the first start's window: that crash only. Need 1: then the device's own archive (skip), as the game was before the archive
        // became the default; need 2: the next start uses the archive again, and keeps it
        EXPECT("a wrong verdict: one crash", 0x1, starts(12, (device){0, 0, 0}, 0x1));
        if (need == 1) EXPECT("a wrong verdict, need 1: skip", PG_SKIP, on_disk()); else EXPECT("a wrong verdict, need 2: no record", 0, exists());
        { unlink(rec); for (int i = 0; i < 5; i++) one_start((device){0, 0, 0}, 0); EXPECT("no crash: never a record", 0, exists()); }
        // the device's own build crashes in its window, the archive does not (13 Sentinels on an A20 Pro), after one unrelated crash with the archive: need 1, two crashes, then
        // the archive for good; need 2, that crash only
        EXPECT("only the archive works, a wrong verdict: crashes", need == 1 ? 0x3 : 0x1, starts(12, (device){0, 1, 0}, 0x1));
        EXPECT("only the archive works: then no record", 0, exists());
        // the same game, but its crash without the archive comes after the window. Need 1: every start crashes from then on (the limit the header names: before the archive
        // became the default, such a game crashed at every start too); need 2: that crash only
        EXPECT("only the archive works, a late crash without it", need == 1 ? 0xfff : 0x1, starts(12, (device){0, 0, 1}, 0x1));
        // both crash: every start does whatever the guard does (no verdict makes it worse)
        EXPECT("both crash: every start", 0xfff, starts(12, (device){1, 1, 0}, 0));
    }
    need = 2;
    // need 2, two unrelated early ends in a row on a game whose crash without the archive comes after its window: from then on every start crashes (the limit, nvn_pso_guard.h)
    EXPECT("need 2, two wrong verdicts in a row, a late crash without it: every start", 0xfff, starts(12, (device){0, 0, 1}, 0x3));
    // the start without the archive ended early once for another reason (iOS ended it for memory in the foreground) on a device where the archive crashes: it settles on leaving
    // it out (need 1: three crashes; need 2: five)
    EXPECT("need 2, archive crashes, one early end without it: five crashes", 0x1f, starts(12, (device){1, 0, 0}, 0x4)); EXPECT("then skip", PG_SKIP, on_disk());
    need = 1;
    EXPECT("need 1, archive crashes, one early end without it: three crashes", 0x7, starts(12, (device){1, 0, 0}, 0x2)); EXPECT("then skip", PG_SKIP, on_disk());

    // the present path (pg_frame, pg_pass) against the background and inactive hooks, from two threads (TSan: make t_pso_guard_tsan): the window ends once, and the record is as
    // one of them left it
    for (int round = 0; round < 20; round++) {
        unlink(rec); start(); pg_mark(&g);
        pthread_t a, b; pthread_create(&a, NULL, frames, NULL); pthread_create(&b, NULL, away, NULL); pthread_join(a, NULL); pthread_join(b, NULL);
        EXPECT("race: past its window", 0, atomic_load(&g.watching));
        EXPECT("race: the record went", 0, exists());
        EXPECT("race: back in the foreground", 0, g.away);
    }

    unlink(rec); char tmp[600]; snprintf(tmp, sizeof tmp, "%s.tmp", rec); unlink(tmp); rmdir(dir);
    printf("t_pso_guard: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
