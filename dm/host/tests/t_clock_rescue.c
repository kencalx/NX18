// The GPU clock rescue's decisions (../../gfx/nvn/nvn_rescue.h): when a game stuck below 60 with the GPU's clock low gets its 3D views smaller, for how long, and the back-off;
// its factor through the render scale's setter (../../gfx/nvn/nvn_heat.h nvn_scale, hle_nvn.c scale_set) beside the heat ladder's, for a render-scale stub and for the Mario Kart
// World family's GPU time stretch, and the target it judges a game without a frame step against (Donkey Kong Bananza's controller)
#include <stdio.h>
#include <math.h>
#include "../../gfx/nvn/nvn_heat.h"
#include "../../gfx/nvn/nvn_rescue.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL line %d: ", __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); fails++; } } while (0)

// n ticks from *t at fps and ratio; the step results into out (when given); the number of starts
static int run(nvn_rescue *r, double *t, int n, double fps, double target, double ratio, int held, int *out) {
    int starts = 0;
    for (int i = 0; i < n; i++, *t += 1) {
        nvn_rescue_in in = { .now = *t, .fps = fps, .target = target, .ratio = ratio, .held = held };
        int s = nvn_rescue_step(r, &in); if (out) out[i] = s; starts += s == RESCUE_START;
    }
    return starts;
}

int main(void) {
    nvn_rescue r; double t; int out[16];
    // BotW's collapse (botw-r2: about 40 fps, probe 2.9x, thermal 0): rescued on the second second below, held 3 s, then back
    nvn_rescue_init(&r); t = 300;
    CHECK(run(&r, &t, 10, 60, 60, 1.2, 0, NULL) == 0, "60 fps: no rescue");
    run(&r, &t, 6, 40, 60, 2.9, 0, out);
    CHECK(out[0] == RESCUE_NONE && out[1] == RESCUE_START && out[2] == RESCUE_NONE && out[3] == RESCUE_NONE && out[4] == RESCUE_END,
          "start at the second second below, end three seconds later: %d %d %d %d %d", out[0], out[1], out[2], out[3], out[4]);
    // A heavy scene at full clock (probe near 1x): not the clock, left alone
    nvn_rescue_init(&r); t = 0;
    CHECK(run(&r, &t, 20, 40, 60, 1.3, 0, NULL) == 0, "a heavy scene at full clock is not rescued");
    // Heat or Low Power Mode holds and movies set their own rate; 30 fps and the game's own frame step (0) are not rescued
    nvn_rescue_init(&r); t = 0;
    CHECK(run(&r, &t, 20, 25, 60, 2.9, 1, NULL) == 0, "a hold: no rescue");
    CHECK(run(&r, &t, 20, 20, 30, 2.9, 0, NULL) == 0, "a 30 fps target: no rescue");
    CHECK(run(&r, &t, 20, 20, 0, 2.9, 0, NULL) == 0, "the game's own frame step: no rescue");
    // A hold that begins during a rescue ends it at once
    nvn_rescue_init(&r); t = 0;
    run(&r, &t, 2, 40, 60, 2.9, 0, out); CHECK(out[1] == RESCUE_START, "started");
    run(&r, &t, 1, 40, 60, 2.9, 1, out); CHECK(out[0] == RESCUE_END, "a hold ends it");
    // Back-off: a scene stuck again right after waits 10 s, then 20, 40 ...; a clean minute starts it again
    nvn_rescue_init(&r); t = 0;
    int s1 = run(&r, &t, 2, 40, 60, 2.9, 0, NULL);
    run(&r, &t, 3, 40, 60, 2.9, 0, NULL);    // the rescue's 3 s
    int s2 = run(&r, &t, 9, 40, 60, 2.9, 0, NULL);   // still stuck: within the 10 s wait
    CHECK(s1 == 1 && s2 == 0 && r.count == 1, "no second rescue within the wait: %d %d", s1, s2);
    int s3 = run(&r, &t, 2, 40, 60, 2.9, 0, NULL);
    CHECK(s3 == 1 && r.wait == 20, "a rescue at the first chance doubles the wait: %d, wait %d", s3, r.wait);
    run(&r, &t, 3, 40, 60, 2.9, 0, NULL);
    CHECK(run(&r, &t, 21, 40, 60, 2.9, 0, NULL) == 1 && r.wait == 40, "then 40 s: wait %d", r.wait);
    for (int k = 0; k < 6; k++) { run(&r, &t, 3, 40, 60, 2.9, 0, NULL); run(&r, &t, 200, 40, 60, 2.9, 0, NULL); }
    CHECK(r.wait == RESCUE_WAIT_MAX_S, "the wait stops at %d s: %d", RESCUE_WAIT_MAX_S, r.wait);
    run(&r, &t, 3, 40, 60, 2.9, 0, NULL);
    run(&r, &t, 61, 60, 60, 1.1, 0, NULL);   // a clean minute at 60
    CHECK(run(&r, &t, 2, 40, 60, 2.9, 0, NULL) == 1 && r.wait == RESCUE_WAIT_S, "after a clean minute: rescued at once, wait %d", r.wait);
    // The factor through the setter (hle_nvn.c scale_set): RESCUE_SCALE while the rescue runs, 1 after it, composed under the player's Render scale and the heat ladder's
    // factor, never under 0.5; as the old +0x10 write: 0.75 of 1.0 (or an unset scale), and 0.5 for a player's 0.6
    nvn_rescue_init(&r); t = 0; nvn_scale sc; nvn_scale_init(&sc, 0);
    run(&r, &t, 2, 40, 60, 2.9, 0, out); nvn_scale_set(&sc, NVN_SCALE_RESCUE, nvn_rescue_factor(&r));
    double on1 = nvn_scale_now(&sc); nvn_scale p6; nvn_scale_init(&p6, 0.6); nvn_scale_set(&p6, NVN_SCALE_RESCUE, nvn_rescue_factor(&r));
    CHECK(out[1] == RESCUE_START && fabs(on1 - 0.75) < 1e-9 && fabs(nvn_scale_now(&p6) - 0.5) < 1e-9, "a rescue: 0.75 of the game's own size, 0.5 for a player's 0.6: %.3f %.3f", on1, nvn_scale_now(&p6));
    // The heat ladder steps to 85% during the rescue (BotW at state 1): the rescue's end leaves 85%, it does not put back the 1.0 it started from (the old +0x10 write did)
    nvn_scale_set(&sc, NVN_SCALE_HEAT, 0.85); double mid = nvn_scale_now(&sc);
    run(&r, &t, 3, 40, 60, 2.9, 0, out); int ended = out[2] == RESCUE_END; nvn_scale_set(&sc, NVN_SCALE_RESCUE, nvn_rescue_factor(&r));
    CHECK(ended && fabs(mid - 0.6375) < 1e-9 && fabs(nvn_scale_now(&sc) - 0.85) < 1e-9, "85%% under the rescue 0.64, after its end 0.85 (%.4f, %.4f)", mid, nvn_scale_now(&sc));
    // and the other way: a rescue that starts at 85% and outlives the rung leaves the game's own size, not the 85% it started on
    nvn_rescue_init(&r); t = 0; nvn_scale_init(&sc, 1.0); nvn_scale_set(&sc, NVN_SCALE_HEAT, 0.85);
    run(&r, &t, 2, 40, 60, 2.9, 0, NULL); nvn_scale_set(&sc, NVN_SCALE_RESCUE, nvn_rescue_factor(&r)); nvn_scale_set(&sc, NVN_SCALE_HEAT, 1.0);
    run(&r, &t, 3, 40, 60, 2.9, 0, NULL); nvn_scale_set(&sc, NVN_SCALE_RESCUE, nvn_rescue_factor(&r));
    CHECK(nvn_scale_now(&sc) == 1.0, "85%% back during the rescue: its end gives the game's own size, %.3f", nvn_scale_now(&sc));
    // The Mario Kart World family: no render-scale stub, so the factor is a stretch of the GPU time its own dynamic resolution reads. Donkey Kong Bananza stuck at 30 (the
    // controller's interval 2) with the GPU probe at 2.52x (bananza-r2-ctl, f5100-5700): rescued on the second second, the time read 1.78 times as long for 3 s, then as before
    nvn_rescue_init(&r); t = 0; nvn_scale_init(&sc, 1.0);
    double tgt = nvn_rescue_target(NULL, 0, 60), k[8]; int st[8];
    for (int i = 0; i < 6; i++, t += 1) { nvn_rescue_in in = {.now = t, .fps = 30, .target = tgt, .ratio = 2.52}; st[i] = nvn_rescue_step(&r, &in); nvn_scale_set(&sc, NVN_SCALE_RESCUE, nvn_rescue_factor(&r)); k[i] = nvn_scale_stretch(&sc); }
    CHECK(tgt == 60 && st[1] == RESCUE_START && k[0] == 1 && k[1] > 1.77 && k[1] < 1.78 && k[3] == k[1] && st[4] == RESCUE_END && k[4] == 1,
          "Bananza at 30 with the probe at 2.52x: stretched x%.2f from the second second for 3 s, then x%.2f", k[1], k[4]);
    nvn_scale_set(&sc, NVN_SCALE_HEAT, 0.85); nvn_scale_set(&sc, NVN_SCALE_RESCUE, RESCUE_SCALE);
    CHECK(nvn_scale_stretch(&sc) > 2.46 && nvn_scale_stretch(&sc) < 2.47, "  with the heat ladder's 85%% on (x1.38) the two compose: x%.2f", nvn_scale_stretch(&sc));
    // Its target: the frame step's where there is a state page (Mario Kart World, 60 or a player's 30); else the controller's top rate, so a cutscene's fixed interval 3 (20)
    // is not rescued; 60 where no controller was seen (Splatoon Raiders)
    float p60 = 60, p30 = 30, p0 = 0;
    CHECK(nvn_rescue_target(&p60, 0, 0) == 60 && nvn_rescue_target(&p30, 0, 60) == 30 && nvn_rescue_target(NULL, 0, 20) == 20 && nvn_rescue_target(NULL, 0, 0) == 60, "targets: 60, 30, 20, 60");
    nvn_rescue_init(&r); t = 0;
    CHECK(run(&r, &t, 20, 20, nvn_rescue_target(NULL, 0, 20), 2.9, 0, NULL) == 0, "Bananza in a cutscene (its controller fixed at interval 3, 20 fps) with the clock low: no rescue");
    // A step the game fixes itself (state +0x24): Mario Kart World's own 30 fps mode (its frame-step stub publishes 2, the host holds 2 vsyncs, page +0 still 60), Breath of the
    // Wild's VFR override at 2. iOS lowers the GPU's clock at that cadence (the probe at 2.4-3.2x), but the 30 is the game's: the target follows it (60 / step), it holds the rescue
    // off, and one under way when the step begins ends at once
    CHECK(nvn_rescue_target(&p60, 2, 0) == 30 && nvn_rescue_target(&p60, 3, 0) == 20 && nvn_rescue_target(&p60, 1, 0) == 60 && nvn_rescue_target(&p30, 2, 0) == 30
          && nvn_rescue_target(&p0, 2, 0) == 0 && nvn_rescue_target(NULL, 2, 60) == 60, "a fixed step: 60 / step under the page's target (step 1: none; DM_FPS_TARGET=0 stays 0; no page: the controller's)");
    CHECK(nvn_rescue_held(0, 0, 2, 0) && nvn_rescue_held(0, 0, 3, 0) && !nvn_rescue_held(0, 0, 1, 0) && !nvn_rescue_held(0, 0, 0, 0) && nvn_rescue_held(1, 0, 0, 0) && nvn_rescue_held(0, 1, 0, 0),
          "held: a fixed step of 2 or more, a movie, a heat or Low Power Mode hold; not a step of 0 or 1");
    nvn_rescue_init(&r); t = 0;
    int mk = run(&r, &t, 700, 30, nvn_rescue_target(&p60, 2, 0), 2.5, nvn_rescue_held(0, 0, 2, 0), NULL);
    int mk_t = run(&r, &t, 700, 30, nvn_rescue_target(&p60, 2, 0), 2.6, 0, NULL), mk_h = run(&r, &t, 700, 30, 60, 2.9, nvn_rescue_held(0, 0, 2, 0), NULL);
    CHECK(mk == 0 && mk_t == 0 && mk_h == 0 && r.count == 0, "Mario Kart World's own 30 fps mode (page 60, step 2), the probe at 2.5x: no rescue in 700 s (nor with the target alone or the hold alone)");
    nvn_rescue_init(&r); t = 0;
    run(&r, &t, 2, 40, nvn_rescue_target(&p60, 0, 0), 2.9, 0, out); int began = out[1] == RESCUE_START;
    run(&r, &t, 1, 30, nvn_rescue_target(&p60, 2, 0), 2.9, nvn_rescue_held(0, 0, 2, 0), out);
    CHECK(began && out[0] == RESCUE_END && r.left == 0, "a rescue under way when the game fixes its step (Breath of the Wild's VFR override) ends at once, not after its 3 s");
    // and a minute in the game's own 30 starts the back-off again: none of its ticks is below its target
    nvn_rescue_init(&r); t = 0;
    run(&r, &t, 200, 40, 60, 2.9, 0, NULL); int waited = r.wait;
    run(&r, &t, 61, 30, nvn_rescue_target(&p60, 2, 0), 2.9, nvn_rescue_held(0, 0, 2, 0), NULL);
    CHECK(waited > RESCUE_WAIT_S && run(&r, &t, 2, 40, 60, 2.9, 0, NULL) == 1 && r.wait == RESCUE_WAIT_S, "a minute in the game's own 30 fps mode starts the back-off again (wait %d s, then %d s)", waited, r.wait);
    // Thermal state 2 or worse as the heat ladder last read it holds the rescue off too (heat-ladder.md D15): a game with the resolution rungs (the +0x14 stubs, the stretch)
    // puts 85% and 70% on at state 2 and the 30 fps hold waits 15 s behind 70%, while iOS's heat throttle reads about 3x on the probe. Without this the rescue started about 2 s
    // in and stacked 0.75 under 70% (0.525, or x3.63 in the stretch family) and spent a back-off slot; before step 4 the hold came at once there. Below state 2, and with no
    // state (-1: DM_THERMAL_CAP=0, the Mac), the rescue runs as before
    CHECK(nvn_rescue_held(0, 0, 0, 2) && nvn_rescue_held(0, 0, 0, 3) && !nvn_rescue_held(0, 0, 0, 1) && !nvn_rescue_held(0, 0, 0, 0) && !nvn_rescue_held(0, 0, 0, -1),
          "held at thermal state 2 and 3; not at 1, 0 or with no state");
    nvn_rescue_init(&r); t = 0;
    int hot = run(&r, &t, 15, 40, 60, 3.0, nvn_rescue_held(0, 0, 0, 2), NULL);
    CHECK(hot == 0 && r.count == 0, "a game with 70%% at state 2 at 40 fps, the probe at 3x: no rescue in the 15 s before the 30 fps hold");
    nvn_rescue_init(&r); t = 0;
    run(&r, &t, 2, 40, 60, 2.9, nvn_rescue_held(0, 0, 0, 1), out); int at1 = out[1] == RESCUE_START;
    run(&r, &t, 1, 40, 60, 3.0, nvn_rescue_held(0, 0, 0, 2), out);
    CHECK(at1 && out[0] == RESCUE_END && r.left == 0, "a rescue started at state 1 ends on the first state-2 tick");
    nvn_rescue_init(&r); t = 0;
    CHECK(run(&r, &t, 2, 40, 60, 2.9, nvn_rescue_held(0, 0, 0, -1), NULL) == 1, "with no thermal state (DM_THERMAL_CAP=0) the rescue starts as before");
    // DM_CLOCK_RESCUE_S (nvn_rescue_hold_parse): whole seconds 3 to 20; unset or empty 0 (the 3 s hold, as before); anything else refused (-1, the 3 s hold)
    CHECK(nvn_rescue_hold_parse(NULL) == 0 && nvn_rescue_hold_parse("") == 0, "DM_CLOCK_RESCUE_S unset or empty: 0");
    CHECK(nvn_rescue_hold_parse("3") == 3 && nvn_rescue_hold_parse("10") == 10 && nvn_rescue_hold_parse("20") == 20, "3, 10 and 20 s taken");
    CHECK(nvn_rescue_hold_parse("2") == -1 && nvn_rescue_hold_parse("21") == -1 && nvn_rescue_hold_parse("10s") == -1 && nvn_rescue_hold_parse("-5") == -1 && nvn_rescue_hold_parse("99999999999") == -1,
          "2, 21, 10s, -5 and an overlong number refused");
    nvn_rescue_init(&r); CHECK(r.hold == RESCUE_HOLD_S, "init: the hold is %d s as before", RESCUE_HOLD_S);
    // a 10 s hold: the rescue's factor for 10 ticks, then 1; the back-off's next chance counts from its end as with 3 s
    nvn_rescue_init(&r); r.hold = 10; t = 0;
    int ten[14]; run(&r, &t, 14, 40, 60, 2.9, 0, ten);
    int under = 0; for (int i = 2; i < 11; i++) under += ten[i] == RESCUE_NONE;
    CHECK(ten[1] == RESCUE_START && under == 9 && ten[11] == RESCUE_END && r.left == 0 && r.next_ok == 1 + 10 + RESCUE_WAIT_S,
          "DM_CLOCK_RESCUE_S=10: start at the second second below, end ten ticks later, next chance %d s after its end (%g)", RESCUE_WAIT_S, r.next_ok);
    nvn_rescue_init(&r); r.hold = 10; t = 0;
    run(&r, &t, 2, 40, 60, 2.9, 0, NULL); run(&r, &t, 1, 40, 60, 2.9, 1, out);
    CHECK(out[0] == RESCUE_END, "a 10 s rescue still ends at once when a hold begins");
    // The cool-down: the floor's factor for its 8 s, then 1; a DM_CLOCK_RESCUE_S hold stands
    nvn_rescue_init(&r); nvn_rescue_cool(&r); t = 0;
    CHECK(r.hold == RESCUE_COOL_HOLD_S && nvn_rescue_factor(&r) == 1.0, "cool-down: its hold, no factor before a start (%d)", r.hold);
    { int o[16]; run(&r, &t, 12, 30, 60, 3.2, 0, o);
      CHECK(o[1] == RESCUE_START && o[9] == RESCUE_END, "cool-down: start at the second second at 30, end 8 s later: %d %d", o[1], o[9]); }
    nvn_rescue_init(&r); nvn_rescue_cool(&r); t = 0; run(&r, &t, 3, 30, 60, 3.2, 0, NULL);
    CHECK(r.left > 0 && nvn_rescue_factor(&r) == RESCUE_COOL_SCALE, "cool-down: the floor's factor while under way");
    nvn_rescue_init(&r); r.hold = 12; nvn_rescue_cool(&r); CHECK(r.hold == 12, "cool-down: DM_CLOCK_RESCUE_S's hold stands");
    if (!fails) printf("t_clock_rescue: ok\n");
    return fails != 0;
}
