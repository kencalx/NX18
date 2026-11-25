// Frame generation's decision and tick sequencer (nvn_framegen.h): every reason it stays off, the reset of the interpolator's history, and the order of generated and real
// frames on the display link's ticks for a game at 30 fps on the 60 Hz link: steady, a hitch (three ticks), a movie, a size change, a stalled tick and a suspend; and the real
// frames' on-screen intervals less the one-tick shift generation gives them, which reads two ticks wherever generation starts or stops
#include <stdio.h>
#include <string.h>
#include "../nvn/nvn_framegen.h"
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static fg_in eligible(void) {
    return (fg_in){.enabled = 1, .supported = 1, .ready = 1, .period = 2, .link_mode = 1, .fps30 = 1, .snap = 1, .upscale = 1, .history = 1, .depth = 1, .motion = 1, .crop_full = 1};
}
static void reasons(void) {
    fg_gate g = {0}; fg_in in = eligible(); fg_out o = fg_decide(&g, &in);
    CHECK(o.gen && o.why == FG_GEN, "an eligible frame is generated");
    CHECK(!o.reset_history, "the very first decision with history needs no reset");
    struct { const char *name; int why; void (*set)(fg_in *); } c[] = {
        {"switch off", FG_OFF, NULL}, {"no MetalFX interpolator", FG_UNSUPPORTED, NULL}, {"movie", FG_MOVIE, NULL}, {"in-game menu", FG_MENU, NULL},
        {"screenshot", FG_SHOT, NULL}, {"thermal", FG_THERMAL, NULL}, {"Battery Saver", FG_BATTERY, NULL}, {"no 30 fps cap", FG_FPS, NULL}, {"30 Hz link", FG_LINK, NULL}, {"rescue", FG_LINK, NULL},
        {"60 fps (period 1)", FG_PERIOD, NULL}, {"hitch (period 3)", FG_PERIOD, NULL}, {"no snapshot", FG_NO_SNAP, NULL}, {"no upscale", FG_NO_UPSCALE, NULL},
        {"capture overwritten", FG_STALE, NULL}, {"key changed", FG_KEY, NULL}, {"no depth", FG_NO_DEPTH, NULL}, {"no motion", FG_NO_MOTION, NULL},
        {"crop out of bounds", FG_CROP, NULL}, {"interpolator failed", FG_UNSUPPORTED, NULL}, {"interpolator being made", FG_MAKING, NULL}, {"no history", FG_NO_HISTORY, NULL},
    };
    for (unsigned i = 0; i < sizeof c / sizeof *c; i++) {
        in = eligible();
        switch (i) {
            case 0: in.enabled = 0; break; case 1: in.supported = 0; break; case 2: in.movie = 1; break; case 3: in.menu = 1; break; case 4: in.shot = 1; break;
            case 5: in.thermal = 1; break; case 6: in.battery = 1; break; case 7: in.fps30 = 0; break; case 8: in.link_mode = 3; break; case 9: in.rescue = 1; break;
            case 10: in.period = 1; break; case 11: in.period = 3; break; case 12: in.snap = 0; break; case 13: in.upscale = 0; break; case 14: in.stale = 1; break;
            case 15: in.key_changed = 1; break; case 16: in.depth = 0; break; case 17: in.motion = 0; break; case 18: in.crop_full = 0; break; case 19: in.failed = 1; break;
            case 20: in.ready = 0; break; case 21: in.history = 0; break;
        }
        fg_gate gi = {0}; o = fg_decide(&gi, &in);
        char label[120]; snprintf(label, sizeof label, "%s: real frame only, reason %s", c[i].name, fg_why_name[c[i].why]);
        CHECK(!o.gen && o.why == c[i].why && gi.why[c[i].why] == 1 && gi.real == 1, label);
        in = eligible(); o = fg_decide(&gi, &in);
        snprintf(label, sizeof label, "%s, then eligible: generated with the history reset", c[i].name);
        CHECK(o.gen && o.reset_history, label);
        o = fg_decide(&gi, &in);
        snprintf(label, sizeof label, "%s, then eligible twice: the second keeps the history", c[i].name);
        CHECK(o.gen && !o.reset_history, label);
    }
    in = eligible(); in.thermal = 1; in.battery = 1; o = fg_decide(&g, &in);
    CHECK(!o.gen && o.why == FG_THERMAL, "heat comes before Battery Saver in the count");
    in = eligible(); o = fg_decide(&g, &in);
    in = eligible(); in.reset = 1; o = fg_decide(&g, &in);
    CHECK(o.gen && o.reset_history, "the upscaler's own reset resets the interpolator's history");
    for (int i = 0; i < FG_WHY_N; i++) CHECK(fg_why_name[i] && *fg_why_name[i], "every reason has a name");
    fg_gate u = {0}; in = eligible(); fg_decide(&u, &in); fg_undo(&u);
    CHECK(u.gen == 0 && u.real == 1 && u.why[FG_ENCODE] == 1, "an encode that failed counts as a real frame");
    o = fg_decide(&u, &in); CHECK(o.gen && o.reset_history, "after a failed encode the next generated frame resets the history");
}
// A small display link: frames of a 30 fps game arrive every `every` ticks (a hitch spreads one to 3), each is held for its period; returns the sequence of actions,
// 'g' generated, 'p' pending real shown, 'r' real without generation, 'h' held, '.' empty. stall: a tick index that never calls back (the link was silent).
// g_shown / g_shift: the tick each real frame reached the screen on, and its shift (1: shown on the tick after the one that took it, its generated frame's; nvn_framegen.inc
// fg_shift_note, which hle_nvn.c takes out of the on-screen intervals it judges)
typedef struct { const char *arrive; int period[64]; fg_in in[64]; int stall; int flush_at; } scenario;
static int g_shown[64], g_shift[64], g_nshown;
static void run(const scenario *sc, char *out, int nt, fg_gate *g, uint64_t *flushed) {
    fg_seq s = {0}; int queued = 0, held_until = 0, frame = 0; uint64_t tk = 0;
    g_nshown = 0;
    for (int t = 0; t < nt; t++) {
        if (sc->arrive[t] == '1') { queued++; frame++; }
        if (t == sc->flush_at) { *flushed = fg_flush(&s); queued = 0; }
        if (t == sc->stall) { out[t] = 'x'; continue; }
        int held = t < held_until;
        int a = fg_tick(&s, queued > 0, held, 0);
        if (a == FG_A_REAL) {   // the frame this tick takes: decide
            fg_in in = sc->in[frame - queued]; fg_out o = fg_decide(g, &in);
            if (o.gen) a = FG_A_GEN;
            queued--; tk++; held_until = t + sc->period[frame - 1 - queued];
            if (a == FG_A_GEN) fg_pend(&s, tk);
        }
        out[t] = a == FG_A_GEN ? 'g' : a == FG_A_PENDING ? 'p' : a == FG_A_REAL ? 'r' : a == FG_A_HELD ? 'h' : '.';
        if ((a == FG_A_REAL || a == FG_A_PENDING) && g_nshown < 64) { g_shown[g_nshown] = t; g_shift[g_nshown++] = a == FG_A_PENDING; }
    }
    out[nt] = 0;
}
// The real frames' on-screen intervals in ticks as the screen shows them (raw) and less the shift (as hle_nvn.c pres_shifted_ms judges them), as digits
static void intervals(char *raw, char *judged) {
    int k = 0;
    for (int i = 1; i < g_nshown && i < 32; i++, k++) { raw[k] = (char)('0' + g_shown[i] - g_shown[i - 1]); judged[k] = (char)('0' + (g_shown[i] - g_shift[i]) - (g_shown[i - 1] - g_shift[i - 1])); }
    raw[k] = judged[k] = 0;
}
static void sequences(void) {
    scenario sc = {.stall = -1, .flush_at = -1}; char out[65]; fg_gate g = {0}; uint64_t fl = 0;
    for (int i = 0; i < 64; i++) { sc.period[i] = 2; sc.in[i] = eligible(); }
    sc.in[0].history = 0;   // the first frame has no previous one
    sc.arrive = "1010101010101010";
    run(&sc, out, 16, &g, &fl);
    printf("steady 30 -> 60: %s\n", out);
    CHECK(!strcmp(out, "r.gpgpgpgpgpgpgp"), "steady: after the first real frame each tick alternates generated and real (60 presents a second)");
    CHECK(g.gen == 7 && g.real == 1 && g.why[FG_NO_HISTORY] == 1, "steady: 7 generated, the first frame real for lack of history");
    char raw[33], judged[33]; intervals(raw, judged);
    printf("steady: real frames' intervals on screen %s, less the shift %s\n", raw, judged);
    CHECK(!strcmp(raw, "3222222") && !strcmp(judged, "2222222"), "steady: the switch to generation shows the first real frame a tick late, which the shift takes out");
    // A hitch: frame 4 takes three ticks (the game was late): the generated frame is still shown first, the real frame holds its extra tick as it does today
    g = (fg_gate){0}; sc.period[3] = 3; sc.in[3].period = 3;
    sc.arrive = "1010100101010101";
    run(&sc, out, 16, &g, &fl);
    printf("hitch at k=3: %s\n", out);
    CHECK(!strcmp(out, "r.gpgp.r.hgpgpgp"), "hitch: the frame held 3 ticks is shown real only, then generation resumes");
    CHECK(g.why[FG_PERIOD] == 1, "hitch: counted as period not 2");
    intervals(raw, judged);
    printf("hitch: real frames' intervals on screen %s, less the shift %s\n", raw, judged);
    CHECK(!strcmp(judged, "223322"), "hitch: less the shift, only the late frame and the frame held 3 ticks stay over 2 ticks");
    // A movie from frame 3 to 5: real frames only, and the first generated frame after it resets the history
    g = (fg_gate){0}; sc.period[3] = 2; sc.in[3] = eligible();
    for (int i = 2; i < 5; i++) sc.in[i].movie = 1;
    sc.arrive = "1010101010101010";
    run(&sc, out, 16, &g, &fl);
    printf("movie frames 3-5: %s\n", out);
    CHECK(!strcmp(out, "r.gpr.r.r.gpgpgp"), "movie: its frames are real only");
    CHECK(g.why[FG_MOVIE] == 3, "movie: three frames counted");
    intervals(raw, judged);
    printf("movie: real frames' intervals on screen %s, less the shift %s\n", raw, judged);
    CHECK(!strcmp(raw, "3122322") && !strcmp(judged, "2222222"), "movie: generation stopping (one tick) and starting (three) reads as two ticks less the shift");
    for (int i = 2; i < 5; i++) sc.in[i] = eligible();
    // A size change at frame 4: that frame real (no matching history), then generation again
    g = (fg_gate){0}; sc.in[3].key_changed = 1;
    run(&sc, out, 16, &g, &fl);
    CHECK(!strcmp(out, "r.gpgpr.gpgpgpgp") && g.why[FG_KEY] == 1, "a size change shows that frame real, then generation resumes");
    intervals(raw, judged);
    CHECK(!strcmp(judged, "2222222"), "a size change: two ticks every frame less the shift");
    sc.in[3] = eligible();
    // A silent tick right after a generated frame: its real frame comes on the next tick, before the next frame, which then waits out the hold
    g = (fg_gate){0}; sc.stall = 5;
    run(&sc, out, 16, &g, &fl);
    printf("stalled tick 5: %s\n", out);
    CHECK(out[4] == 'g' && out[5] == 'x' && out[6] == 'p', "a missed tick: the pending real frame is shown on the next tick, never dropped");
    CHECK(out[7] == 'g' && out[8] == 'p', "a missed tick: the following frame is generated again");
    sc.stall = -1;
    // A suspend between a generated frame and its real one: the pending real frame is flushed (its ticket handed back for accounting), nothing shows it afterwards
    g = (fg_gate){0}; sc.flush_at = 5; fl = 0;
    run(&sc, out, 16, &g, &fl);
    printf("suspend at tick 5: %s (flushed ticket %llu)\n", out, (unsigned long long)fl);
    CHECK(fl == 3 && out[5] != 'p', "a suspend flushes the pending real frame and reports its ticket");
    fg_seq s = {0}; CHECK(fg_flush(&s) == 0, "nothing pending: the flush reports no ticket");
    // A 60 fps game (period 1): no generation, a real frame each tick
    g = (fg_gate){0}; for (int i = 0; i < 64; i++) { sc.period[i] = 1; sc.in[i].period = 1; } sc.flush_at = -1;
    sc.arrive = "11111111";
    run(&sc, out, 8, &g, &fl);
    CHECK(!strcmp(out, "rrrrrrrr") && g.gen == 0, "a 60 fps game is shown as it is");
}
int main(void) {
    reasons();
    sequences();
    printf("t_framegen: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
