// Exercise the production frame-cap getter with a controlled clock and thermal
// source. No game files or GPU; concurrent readers model acquire and present.
#include "../../host/hle.h"
#include "../nvn/nvn_heat.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int nvn_game_fps(void);
void nvn_engine_hold_tick(uint64_t presents);   // hle_nvn.c: heat and Low Power Mode for an engine limiter the host writes (the weak dm_fps_lock_engine says there is one)
void nvn_heat_tick(uint64_t presents);   // hle_nvn.c: the heat ladder's present call site, for every game (nvn_heat.h)
void nvn_heat_frame(int verdict, double vsyncs, int fit60, int kmin);   // hle_nvn.c: the frame step's part, once per frame (fstep_tick): "60 not holding" and its window
int nvn_heat_rung(void);   // hle_nvn.c: the ladder's rungs on, for frame generation (nvn_framegen.inc fg_power_why)
const char *nvn_fps_hold_why(void);
void dm_low_power_cap_set(int on);   // the in-game menu's Low Power Mode at 30 fps
void dm_gfx_suspend(int on);   // hle_nvn.c: the app goes to the background (1) and comes back (0); no GPU work here, so the drain has nothing to wait for
static _Alignas(8) uint8_t fps_state[0x40];
uint8_t *dm_fps_state = fps_state;
static _Atomic uint64_t test_now, test_slept;
static _Atomic int test_thermal = -1, thermal_reads;
uint64_t now_ns(void) { return atomic_load(&test_now); }
// hle_os.c's clock that counts the device's sleep (mach_continuous_time), which the heat hold's timers use: now_ns (mach_absolute_time) stops while the device sleeps, this does not
uint64_t now_cont_ns(void) { return atomic_load(&test_now) + atomic_load(&test_slept); }
static void device_sleeps(int seconds) { atomic_fetch_add(&test_slept, (uint64_t)seconds * 1000000000ull); }   // the phone locked and asleep: now_ns stands still
int dm_thermal_now(void) { atomic_fetch_add(&thermal_reads, 1); return atomic_load(&test_thermal); }
static _Atomic int test_low_power, low_power_reads;
int dm_low_power_now(void) { atomic_fetch_add(&low_power_reads, 1); return atomic_load(&test_low_power); }   // front_ios.m: NSProcessInfo lowPowerModeEnabled
static void low_power(int on) { atomic_store(&test_low_power, on); }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
// hle_fpslock.c's answer: a limiter the host writes, unless T_THERMAL_NO_ENGINE=1 (a main with none: with DM_PRESENT_INTERVAL=display the cap is the present interval alone, Red Dead Redemption).
// timer_inside: the front end's 1 s timer (dm_heat_timer_tick) runs here once, as it can on the main thread while the first nvn_heat_tick works out whether the host paces the
// game (the first engine_hold_applies asks this through present_cap_base, where nothing asked for the present cap before: first_present_case)
static int timer_inside, timer_ran;
int dm_fps_lock_engine(void) {
    if (timer_inside) { timer_inside = 0; timer_ran = 1; dm_heat_timer_tick(); }
    const char *e = getenv("T_THERMAL_NO_ENGINE"); return !(e && !strcmp(e, "1"));
}

static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
// The rungs this game can take (hle_nvn.c's weak dm_heat_can: the resolution rungs where the render scale has a live lever). Elsewhere a game with none, so the checks below
// see the hold alone as before. T_THERMAL_LADDER=1 runs ladder_cases alone, as a game with a lever: a render-scale stub that reads +0x14 (LIVE_SCALE: Breath of the Wild's), or
// with a GAME of the stretch family (heat_gpu_stretch on: Mario Kart World, Donkey Kong Bananza) the GPU time stretch, so dm_heat_can is hle_nvn.c's own answer for it (85% and
// 70%): a ladder whose 30 fps hold waits behind 70%, so the caller's "60 not holding" window and its resets (heat_sample at a rung change, nvn_heat_frame at a cap change)
// decide what the checks see, and each resolution rung reaches the lever through the render scale's setter (scale_set)
static int ladder_on(void) { const char *e = getenv("T_THERMAL_LADDER"); return e && !strcmp(e, "1"); }
int nvn_heat_can_lever(int rung);   // hle_nvn.c: the rungs the game's render scale lever allows
double nvn_render_scale_now(double *stretch);   // hle_nvn.c: the composed render scale once it changed, and the GPU time's stretch
int dm_render_scale_stub(void) { return ladder_on(); }   // loader.c: a render-scale stub (+0x10)
int dm_live_scale_stub(void) { return ladder_on(); }   // loader.c: that also reads the host's factor at +0x14 (LIVE_SCALE)
int dm_heat_can(int rung) { return ladder_on() && nvn_heat_can_lever(rung); }
// The lever's state now: +0x14 (a stub's live factor; 0 = never set) and the stretch (1 where the lever is +0x14)
static float live_factor(void) { float f; memcpy(&f, fps_state + 0x14, 4); return f; }
static double stretch_now(void) { double k = 1; (void)nvn_render_scale_now(&k); return k; }
double mtl_gpu_stretch_now(void);   // nvn_mtl.m: the stretch post_run applies, as scale_set handed it over (0: none in this game)
double nvn_gpu_time_scale(void);   // hle_nvn.c: the GPU time scale in force (profile gpu_time_scale: Donkey Kong Bananza 0.6144; 1 elsewhere)
// The wire from hle_nvn.c to nvn_mtl.m: the stretch post_run applies is the setter's times the GPU time scale (the stretch family), or none at all (0: a +0x14 game)
static double want_scale(void) { const char *e = getenv("DM_GPU_TIME_SCALE"); double v; return e && nvn_gpu_time_scale_parse(e, &v) == 0 ? v : DM_GAME_GPU_TIME_SCALE; }   // the profile's, or DM_GPU_TIME_SCALE's
static int wired(int stretch) { double m = mtl_gpu_stretch_now(), k = stretch_now(), b = nvn_gpu_time_scale(); return stretch ? m == b * k && b == want_scale() && m >= b : m == 0 && b == 1; }
// The hold's state for the system's performance traces (state_report.h; hle_nvn.c's weak one does nothing): the reports so far and those naming a hold
static int state_reports, state_holds;
void dm_state_report(int domain, const char *label) { if (domain != 1 || !label) return; state_reports++; state_holds += strstr(label, "hold") != NULL; }
// The log lines (stderr, hle_bigstack.c dm_log) between log_start and log_end, echoed when it ends; count: the lines that contain s
static char log_buf[1 << 16]; static FILE *log_f; static int log_fd = -1;
static void log_start(void) { fflush(stderr); log_f = tmpfile(); log_fd = dup(2); dup2(fileno(log_f), 2); }
static const char *log_end(void) {
    fflush(stderr); dup2(log_fd, 2); close(log_fd); rewind(log_f);
    size_t n = fread(log_buf, 1, sizeof log_buf - 1, log_f); log_buf[n] = 0; fclose(log_f); fputs(log_buf, stderr);
    return log_buf;
}
static int count(const char *log, const char *s) { int n = 0; for (const char *p = log; (p = strstr(p, s)); p += strlen(s)) n++; return n; }
// The heat hold's calm wait doubles for a hold that starts within 10 min of the last one's end (nvn_heat.h rearm, 10 min): rest() moves the clock past that, so each
// group of cases below starts from the first wait (30 s) as before the back-off; the back-off's own cases come after them
static uint64_t t0;   // seconds: at() counts from here
static void at(int seconds, int thermal) {
    atomic_store(&test_thermal, thermal);
    atomic_store(&test_now, (t0 + (uint64_t)seconds) * 1000000000ull);
}
static void rest(void) { t0 = atomic_load(&test_now) / 1000000000ull + 1000; }   // at(s) is now more than 10 min after the clock, with no heat hold between (call it with none in force)
static void target(float fps) {
    uint32_t bits; memcpy(&bits, &fps, sizeof bits);
    __atomic_store_n((uint32_t *)fps_state, bits, __ATOMIC_RELAXED);
}
static _Atomic int test_movie, test_movie_fps;
int dm_movie_playing(void) { return atomic_load(&test_movie); }   // hle_movie.c: a movie's pictures are being handed out
int dm_movie_fps(void) { return atomic_load(&test_movie) ? atomic_load(&test_movie_fps) : 0; }   // its pictures a second (0: the movie::Decoder path's, not known)
static void movie(int on) { atomic_store(&test_movie, on); }
static void movie_fps(int fps) { atomic_store(&test_movie_fps, fps); }

static _Atomic int ready, start;
static void *reader(void *unused) {
    (void)unused; atomic_fetch_add(&ready, 1);
    while (!atomic_load(&start)) sched_yield();
    for (int i = 0; i < 10000; i++) {
        atomic_fetch_add(&test_now, 1000000ull);
        (void)nvn_game_fps();
    }
    return NULL;
}

// One second of a frame-step game's frames at hold 1 (nvn_heat_frame as fstep_tick calls it): `late` of the 60 not holding (GPU-bound), the rest on time; with blip, the
// cap's fastest hold goes to 2 for the 30th frame and back to 1 for the 31st (a cap change: the window starts again). Then the second's sample at state th (nvn_heat_tick)
static uint64_t ladder_presents;
static void ladder_second(int t, int th, int late, int blip) {
    for (int i = 0; i < 60; i++) nvn_heat_frame(i < late ? 1 : 0, 1.0, 0, blip && i == 29 ? 2 : 1);
    at(t, th); nvn_heat_tick(++ladder_presents);
}
// The caller's resets of "60 not holding" (hle_nvn.c; nvn_heat.h's controller reads the share it is given): at each rung or cap change in a sample, and at each change of
// the frame step's kmin. Frames late at 70% must be frames drawn there (D15 (a)), and each state-1 step's evidence its own
static int ladder_cases(void) {
    // 30 s of frames a third late at 100% at state 0, then state 2: 85% and 70% go on, and the 30 fps hold waits 15 s behind 70%. The frames at 70% hold; the window
    // started again at the push, so the late frames from before it never count. Without that reset they still filled 20 of the window's 30 s once 70% had been on 10 s
    // (HEAT_LATE_ON), 22% not holding, and 30 came at 41 s
    const int stretch = DM_GAME_HEAT_GPU_STRETCH;   // the GAME's lever: the stretch, else the +0x14 stub
    log_start();
    CHECK(stretch ? "ladder: a game of the stretch family can take 85% and 70% (dm_heat_can), not effects or 40 fps" : "ladder: a build with the +0x14 stubs can take 85% and 70% (dm_heat_can), not effects or 40 fps",
          nvn_heat_can_lever(HEAT_R1) && nvn_heat_can_lever(HEAT_R2) && !nvn_heat_can_lever(HEAT_RE) && !nvn_heat_can_lever(HEAT_R3) && !nvn_heat_can_lever(HEAT_R4));
    for (int t = 1; t <= 30; t++) ladder_second(t, 0, 20, 0);
    int rung0 = nvn_heat_rung();
    int untouched = live_factor() == 0 && stretch_now() == 1 && wired(stretch) && (!stretch || mtl_gpu_stretch_now() == want_scale());
    ladder_second(31, 2, 0, 0); int none = nvn_game_fps() == 60, rung2 = nvn_heat_rung();
    int at70 = (stretch ? stretch_now() > 2.04 && stretch_now() < 2.05 && live_factor() == 0 : fabsf(live_factor() - 0.70f) < 1e-6f) && wired(stretch);
    int held = 1; for (int t = 32; t <= 45; t++) { ladder_second(t, 2, 0, 0); held &= nvn_game_fps() == 60; }
    ladder_second(46, 2, 0, 0);
    CHECK("ladder: late frames before 70% went on are not frames at 70%: 30 fps 15 s after it (D15 (a)), not 10 s", none && held && nvn_game_fps() == 30);
    // Frame generation's reader (nvn_heat_rung, the rungs on): 0 before, 2 with 85% and 70% while the game still holds 60 (it steps aside from the first rung, not only at 30),
    // 3 with the 30 fps hold over them
    CHECK("  frame generation's rung reader: 0, then 85% and 70% (2) before the hold, then the hold over them (3)", rung0 == 0 && rung2 == 2 && nvn_heat_rung() == 3);
    CHECK(stretch ? "  the lever: no stretch before any rung, then the GPU time read x2.04 at state 2 (85% and 70% in one change), in post_run too (mtl_gpu_stretch_now)"
                  : "  the lever: +0x14 never written before any rung, then 0.70 at state 2 (85% and 70% in one change); post_run stretches nothing", untouched && at70);
    for (int t = 47; t <= 300; t++) ladder_second(t, 0, 0, 0);   // every rung back (30, 70%, 85%)
    CHECK("  and 0 once every rung is back", nvn_heat_rung() == 0);
    const char *lg0 = log_end();
    int back = (stretch ? stretch_now() == 1 && mtl_gpu_stretch_now() == want_scale() : live_factor() == 1.0f) && wired(stretch);
    CHECK(stretch ? "  every rung back: the stretch back at x1" : "  every rung back: +0x14 at 1.0 (the stubs keep applying it: the game's own scale at once)", back);
    CHECK("  one render scale line for each change: 0.70 at state 2, 0.85 and 1.00 on the way back", count(lg0, " = player ") == 3 && count(lg0, "[heat] render scale 0.70 = player 1.00 × heat 0.70") == 1
          && count(lg0, "[heat] render scale 0.85 = ") == 1 && count(lg0, "[heat] render scale 1.00 = ") == 1 && count(lg0, "[heat] render scale lever: ") == 1);
    // State 1 with a third of the frames late: 85% at 311 s; the window starts again there, so 70% needs 10 s of frames at 85% (to 321 s) and 30 s of evidence: 351 s
    // (50 s at state 1). A cap change at 331 s (kmin 1 → 2 → 1: a movie of one frame) starts it again, without the frames before it: 10 s more of frames (341 s), then the
    // 30 s: 371 s, 70 s at state 1. Without that reset 70% came at 50 s
    log_start();
    for (int t = 301; t <= 400; t++) ladder_second(t, 1, 20, t == 331);
    const char *lg = log_end();
    CHECK("ladder: 85% after 10 s at state 1", count(lg, "(resolution 85%): thermal 1 for 10 s") == 1);
    CHECK(stretch ? "  the lever: x1.38 at 85%, then x2.04 at 70%" : "  the lever: +0x14 0.85 at 85%, then 0.70 at 70%",
          count(lg, stretch ? "(heat ladder: resolution 85%): the GPU time its dynamic resolution reads ×1.38" : "(heat ladder: resolution 85%): state +0x14 0.850") == 1
          && count(lg, stretch ? "(heat ladder: resolution 70%): the GPU time its dynamic resolution reads ×2.04" : "(heat ladder: resolution 70%): state +0x14 0.700") == 1
          && (stretch ? stretch_now() > 2.04 && stretch_now() < 2.05 : fabsf(live_factor() - 0.70f) < 1e-6f) && wired(stretch));
    CHECK("  a cap change in its evidence starts the window again: 70% at 70 s of state 1, not 50", count(lg, "(resolution 70%): thermal 1 for 70 s") == 1 && !count(lg, "(resolution 70%): thermal 1 for 50 s"));
    CHECK("  frame generation's rung reader at state 1 with 85% and 70% on: 2 (a fair phone on the ladder counts, not only a serious one)", nvn_heat_rung() == 2);
    printf("== %d checks, %d failed ==\n", checks, failed);
    return failed != 0;
}

// T_THERMAL_LADDER=1 T_THERMAL_PLAYER=<Render scale>: the player's scale at state +0x10 as the loader writes it, then a warm start to state 2 with frames on time. With the
// +0x14 stubs only the resolution rungs that lower this player's scale are offered (heat_sample, nvn_heat_can_res): at 0.5 neither, so the 30 fps hold comes in the first
// state-2 sample, as before the rungs; at 0.55 and 0.60 85% alone, and 30 at once beside it (70% would give 0.50 under 0.50 or 0.51). The stretch family's scale has no
// player in it, so there 85% and 70% go on and 30 comes 15 s later whatever the player's scale
static int player_cases(float p) {
    const int stretch = DM_GAME_HEAT_GPU_STRETCH, r1 = stretch || p > 0.52f, r2 = stretch || p > 0.62f;
    log_start();
    for (int t = 1; t <= 30; t++) ladder_second(t, 0, 0, 0);
    ladder_second(31, 2, 0, 0); const int fps31 = nvn_game_fps(); const float lf31 = live_factor();
    for (int t = 32; t <= 46; t++) ladder_second(t, 2, 0, 0);
    const int fps46 = nvn_game_fps();
    const char *lg = log_end();
    char name[240];
    snprintf(name, sizeof name, "player %.2f%s: the rungs offered are %s (the heat ladder's first line)%s", p, stretch ? " (the stretch: no player in its scale)" : "",
             r2 ? "85% and 70%" : r1 ? "85% alone" : "none", r1 && r2 ? "" : ", and a line says which are not offered");
    CHECK(name, count(lg, r2 ? "rungs this game can take: 85% 70% 30 fps" : r1 ? "rungs this game can take: 85% 30 fps" : "rungs this game can take: 30 fps") == 1
          && count(lg, " not offered (with the 0.5 floor") == !(r1 && r2) && count(lg, r1 ? "resolution 70% not offered" : "resolution 85% and 70% not offered") == !(r1 && r2));
    snprintf(name, sizeof name, "  at state 2 the 30 fps hold comes %s", r2 ? "15 s behind 70%" : r1 ? "at once beside 85%" : "at once (no resolution rung)");
    CHECK(name, r2 ? fps31 == 60 && fps46 == 30 : fps31 == 30 && fps46 == 30);
    char line[96]; const double at85 = p * 0.85 < 0.5 ? 0.5 : p * 0.85;   // 85%'s render scale line: the player's x 85%, at least 0.5
    snprintf(line, sizeof line, "[heat] render scale %.2f = player %.2f × heat 0.85 ", at85, p);
    snprintf(name, sizeof name, "  the rung lines and the lever: 85%% %d, 70%% %d%s", r1, r2, stretch ? ", the stretch x2.04" : r1 ? ", +0x14 so that the player's x it is 85%'s scale (at least 0.5)" : ", +0x14 never written");
    CHECK(name, count(lg, "(resolution 85%): thermal 2") == r1 && count(lg, "(resolution 70%): thermal 2") == r2 && count(lg, "(resolution 70%)") == r2
          && (stretch ? stretch_now() > 2.04 && stretch_now() < 2.05
                      : r1 ? lf31 > 0 && lf31 <= 1 && p * lf31 >= 0.5f && fabs((double)(p * lf31) - at85) < 1e-6 && count(lg, line) == 1 : lf31 == 0 && !count(lg, " = player ")));
    printf("== %d checks, %d failed ==\n", checks, failed);
    return failed != 0;
}

// T_THERMAL_FIRST=1: the first present of a game the host does not pace (no frame step, no limiter the host writes, game mode: Persona 5 Royal's own present interval), hot
// and in Low Power Mode with its setting on. The front end's 1 s timer runs while that first nvn_heat_tick works out that nothing paces the game (timer_inside): it must not
// sample before that is known, with the value "paced" has before the first present (1, for thermal_capped's own callers), or its lines say the game holds 30 fps and a hold
// state is reported in a game the host never paced (the [heat] lines and no report are a2a5fb4e's)
static int first_present_case(void) {
    setenv("T_THERMAL_NO_ENGINE", "1", 1); setenv("DM_PRESENT_INTERVAL", "game", 1); dm_low_power_cap_set(1);
    dm_fps_state = NULL; low_power(1); at(10, 3);
    dm_heat_timer_tick(); int none = !atomic_load(&thermal_reads);
    CHECK("first present: before it the 1 s timer samples nothing", none);
    log_start(); timer_inside = 1; nvn_heat_tick(1); const char *lg = log_end();
    CHECK("  the timer while the first present works out that the game is not paced: no sample with \"paced\" not known yet (no hold line, no hold state)",
          timer_ran && !count(lg, "the game holds 30 fps") && count(lg, "[heat] thermal state 3: the heat hold is on") == 1 && !state_reports);
    int reads = atomic_load(&thermal_reads); at(11, 3); dm_heat_timer_tick();
    CHECK("  after it the timer samples, still with no hold state", atomic_load(&thermal_reads) == reads + 1 && !state_reports);
    printf("== %d checks, %d failed ==\n", checks, failed);
    return failed != 0;
}

int main(void) {
    setenv("DM_FPS_TARGET", "60", 1);   // whatever the profile's fps_target: the engine limiter's cases below need a 60 fps target
    target(60);
    if (ladder_on()) {
        const char *pe = getenv("T_THERMAL_PLAYER");
        if (!pe) return ladder_cases();
        float p = strtof(pe, NULL); uint32_t bits; memcpy(&bits, &p, sizeof bits);
        __atomic_store_n((uint32_t *)(fps_state + 0x10), bits, __ATOMIC_RELAXED);   // the loader's DM_RENDER_SCALE, before the lever is worked out (its first sample)
        return player_cases(p);
    }
    { const char *e = getenv("T_THERMAL_FIRST"); if (e && !strcmp(e, "1")) return first_present_case(); }
    const char *enabled = getenv("DM_THERMAL_CAP");
    // Low Power Mode at 30 fps is the player's setting (settings.tsv DM_LOW_POWER_CAP): off unless it is 1 (the launcher writes 0 or 1; on in the Battery preset)
    const char *lp_env = getenv("DM_LOW_POWER_CAP"); int lp_enabled = lp_env && !strcmp(lp_env, "1");
    if (enabled && !strcmp(enabled, "0")) {
        at(10, 3); CHECK("heat off: a critical device keeps the configured cap", nvn_game_fps() == 60);
        CHECK("heat off: no rung for frame generation either (it reads the thermal state itself)", nvn_heat_rung() == 0);
        CHECK("heat off: thermal state is never read", atomic_load(&thermal_reads) == 0);
        low_power(1); at(11, 0);
        if (lp_enabled) CHECK("heat off: Low Power Mode at 30 fps still holds 30 (its own setting)", nvn_game_fps() == 30);
        else {
            CHECK("heat off: Low Power Mode keeps the configured cap", nvn_game_fps() == 60);
            CHECK("heat off, setting off: Low Power Mode is never read", atomic_load(&low_power_reads) == 0);
        }
        low_power(0); at(12, 0); (void)nvn_game_fps(); at(42, 0); (void)nvn_game_fps();
        movie(1); CHECK("heat off: the movie cap still applies", nvn_game_fps() == 30);
        movie_fps(60); CHECK("heat off: a 60 fps movie keeps 60 fps", nvn_game_fps() == 60); movie_fps(0);
        CHECK("heat off: thermal state is still never read", atomic_load(&thermal_reads) == 0);
    } else {
        // the frame-rate cap's getter (the heat ladder's own sample at each present, nvn_heat_tick, reads the state in every game; below, where nothing is paced)
        dm_fps_state = NULL; at(1, 2);
        CHECK("no frame step: nvn_game_fps does not read the thermal state", nvn_game_fps() == 60 && !atomic_load(&thermal_reads));
        dm_fps_state = fps_state; target(0);
        CHECK("inactive frame step: nvn_game_fps does not read the thermal state", nvn_game_fps() == 60 && !atomic_load(&thermal_reads));
        target(60); at(10, -1);
        CHECK("Mac with no thermal state keeps 60 fps", nvn_game_fps() == 60);
        at(11, 1); CHECK("fair keeps 60 fps", nvn_game_fps() == 60);
        at(12, 2); CHECK("serious holds 30 fps", nvn_game_fps() == 30);
        CHECK("  the heat hold is a rung of the ladder for frame generation (nvn_heat_rung 1; 0 would let it generate)", nvn_heat_rung() == 1);
        int reads = atomic_load(&thermal_reads);
        at(12, 0); CHECK("a second call uses the cached thermal sample", nvn_game_fps() == 30 && atomic_load(&thermal_reads) == reads);
        at(13, 1); CHECK("fair starts recovery while keeping 30 fps", nvn_game_fps() == 30);
        movie(1); at(14, 2); CHECK("a serious movie keeps 30 fps", nvn_game_fps() == 30);
        CHECK("a movie still samples thermal state", atomic_load(&thermal_reads) == reads + 2);
        at(44, 2); (void)nvn_game_fps();
        movie(0); at(45, 1);
        CHECK("heat during a movie resets the earlier cooling interval", nvn_game_fps() == 30);
        at(74, 1); CHECK("29 calm seconds do not release the cap", nvn_game_fps() == 30 && nvn_heat_rung() == 1);
        at(75, 1); CHECK("30 calm seconds restore 60 fps", nvn_game_fps() == 60);
        CHECK("  and the rung frame generation reads ends with the hold, not before (its calm wait)", nvn_heat_rung() == 0);

        rest(); at(76, 3); CHECK("critical also holds 30 fps", nvn_game_fps() == 30);
        movie(1); at(77, 1); (void)nvn_game_fps();
        at(107, 1); CHECK("a calm movie keeps its own 30 fps cap", nvn_game_fps() == 30);
        movie(0); CHECK("cooling during a movie needs no additional recovery hold", nvn_game_fps() == 60);

        rest(); at(108, 2); (void)nvn_game_fps();
        target(30); at(109, 0); (void)nvn_game_fps();
        at(139, 0); CHECK("a configured 30 fps target keeps its cap", nvn_game_fps() == 30);
        target(60); CHECK("cooling at a 30 fps target is tracked before raising it", nvn_game_fps() == 60);

        rest(); at(140, 2); (void)nvn_game_fps();
        at(141, 1); (void)nvn_game_fps();
        at(170, 2); CHECK("renewed heat interrupts recovery", nvn_game_fps() == 30);
        at(171, 0); (void)nvn_game_fps();
        at(200, 0); CHECK("the restarted recovery lasts all 30 seconds", nvn_game_fps() == 30);
        at(201, 0); CHECK("recovery also completes at nominal", nvn_game_fps() == 60);

        rest(); at(202, 2);
        pthread_t threads[4];
        for (unsigned i = 0; i < 4; i++) if (pthread_create(&threads[i], NULL, reader, NULL)) return 2;
        while (atomic_load(&ready) != 4) sched_yield();
        atomic_store(&start, 1);
        for (unsigned i = 0; i < 4; i++) pthread_join(threads[i], NULL);
        CHECK("concurrent acquire/present readers retain the hot cap", nvn_game_fps() == 30);

        // Low Power Mode: the same cap and calm timer, only where heat applies (DM_LOW_POWER_CAP=0 keeps 60 in it)
        at(250, 0); (void)nvn_game_fps();
        at(280, 0); CHECK("the hot cap from the readers recovers", nvn_game_fps() == 60);
        dm_fps_state = NULL; low_power(1); at(300, 0); int lpr = atomic_load(&low_power_reads);
        CHECK("no frame step: nvn_game_fps does not read Low Power Mode", nvn_game_fps() == 60 && atomic_load(&low_power_reads) == lpr);
        dm_fps_state = fps_state; target(0);
        CHECK("inactive frame step: nvn_game_fps does not read Low Power Mode", nvn_game_fps() == 60 && atomic_load(&low_power_reads) == lpr);
        target(60);
        if (lp_enabled) {
            at(301, 0); CHECK("Low Power Mode holds 30 fps", nvn_game_fps() == 30);
            CHECK("  Low Power Mode's hold alone is no rung for frame generation (it reads Low Power Mode itself, whatever this setting)", nvn_heat_rung() == 0);
            CHECK("Low Power Mode is read with the thermal sample", atomic_load(&low_power_reads) == lpr + 1);
            low_power(0); at(301, 0); CHECK("a second call uses the cached Low Power Mode sample", nvn_game_fps() == 30 && atomic_load(&low_power_reads) == lpr + 1);
            at(302, 0); CHECK("Low Power Mode off starts the calm interval", nvn_game_fps() == 30);
            at(331, 0); CHECK("29 s after Low Power Mode went off the cap holds", nvn_game_fps() == 30);
            at(332, 0); CHECK("30 s after Low Power Mode went off 60 fps returns", nvn_game_fps() == 60);
            rest(); low_power(1); at(333, 2); CHECK("heat and Low Power Mode hold 30 fps", nvn_game_fps() == 30);
            low_power(0); at(334, 2); CHECK("Low Power Mode off while still hot keeps the cap", nvn_game_fps() == 30);
            at(335, 1); (void)nvn_game_fps();
            low_power(1); at(350, 1); CHECK("Low Power Mode during the heat calm keeps 30 fps", nvn_game_fps() == 30);
            low_power(0); at(351, 1); (void)nvn_game_fps();
            at(380, 1); CHECK("Low Power Mode restarted the calm interval", nvn_game_fps() == 30);
            at(381, 1); CHECK("the restarted calm interval ends after 30 s", nvn_game_fps() == 60);
            // The in-game menu turns the setting off while Low Power Mode holds 30: back to the cap at the next sample, no calm interval; on again: 30 at the next sample
            low_power(1); at(382, 0); CHECK("Low Power Mode holds 30 fps again", nvn_game_fps() == 30);
            dm_low_power_cap_set(0); at(383, 0); CHECK("setting turned off: 60 fps at once", nvn_game_fps() == 60);
            rest(); at(384, 2); CHECK("setting off: heat still holds 30 fps", nvn_game_fps() == 30);
            at(385, 0); (void)nvn_game_fps(); at(415, 0); CHECK("  and recovers after its calm interval", nvn_game_fps() == 60);
            dm_low_power_cap_set(1); at(416, 0); CHECK("setting turned on in Low Power Mode: 30 fps", nvn_game_fps() == 30);
            low_power(0); at(417, 0); (void)nvn_game_fps(); at(447, 0); CHECK("  and 60 fps 30 s after Low Power Mode went off", nvn_game_fps() == 60);
        } else {
            at(301, 0); CHECK("setting off: Low Power Mode keeps 60 fps", nvn_game_fps() == 60);
            CHECK("setting off: Low Power Mode is never read", atomic_load(&low_power_reads) == 0);
            rest(); at(302, 2); CHECK("setting off: heat still holds 30 fps", nvn_game_fps() == 30);
            at(303, 0); (void)nvn_game_fps(); at(333, 0); CHECK("  and recovers", nvn_game_fps() == 60);
            dm_low_power_cap_set(1); at(334, 0); CHECK("the in-game menu turns it on: Low Power Mode holds 30 fps", nvn_game_fps() == 30);
            dm_low_power_cap_set(0); at(335, 0); CHECK("  and off again: 60 fps at once", nvn_game_fps() == 60);
        }
        low_power(0);
        // A movie with its picture rate (the nn::codec path, hle_codec_video.c): one of 60 is not held at 30 (the frame step holds its fastest hold instead), one of 30 is,
        // as the movie::Decoder path's of a rate not known; the thermal cap and a 30 fps target still hold 30 during a 60 fps movie
        rest(); at(400, 0); (void)nvn_game_fps(); at(430, 0); (void)nvn_game_fps();
        movie(1); movie_fps(60); at(431, 1); CHECK("a 60 fps movie keeps the 60 fps cap", nvn_game_fps() == 60);
        movie_fps(30); CHECK("a 30 fps movie with its rate holds 30 fps", nvn_game_fps() == 30);
        movie_fps(0); CHECK("a movie of a rate not known (movie::Decoder) holds 30 fps, as before", nvn_game_fps() == 30);
        movie_fps(60); target(30); CHECK("a 60 fps movie at a 30 fps target holds 30", nvn_game_fps() == 30);
        target(60); at(432, 2); CHECK("a 60 fps movie on a serious device holds 30", nvn_game_fps() == 30);
        at(433, 1); (void)nvn_game_fps(); at(463, 1); CHECK("  and comes back to 60 after the calm interval", nvn_game_fps() == 60);
        movie(0); movie_fps(0);

        // The heat hold's calm wait backs off (nvn_heat.h r4_wait0, r4_wait_max, rearm): a hold that starts within 10 min of the last one's end
        // waits twice as long, 30, 60, 120, 240 s and no more; heat during the calm restarts it at the same wait; 10 min with no heat hold bring back 30 s. Ocarina of
        // Time's 55-minute run on an iPhone was at state 2 eight times, 50-390 s after each 30 s calm ended, a 60/30 switch every 2-6 min
        rest(); at(500, 2); CHECK("back-off: a first heat hold holds 30 fps", nvn_game_fps() == 30);
        at(501, 1); (void)nvn_game_fps();
        at(530, 1); CHECK("  29 calm seconds keep it", nvn_game_fps() == 30);
        at(531, 1); CHECK("  30 bring back 60 (the first wait)", nvn_game_fps() == 60);
        at(741, 2); CHECK("back-off: heat again 210 s after that end holds 30", nvn_game_fps() == 30);
        at(742, 1); (void)nvn_game_fps();
        at(772, 1); CHECK("  30 calm seconds no longer bring back 60", nvn_game_fps() == 30);
        at(801, 1); CHECK("  59 keep it", nvn_game_fps() == 30);
        at(802, 1); CHECK("  60 bring back 60 (the wait doubled)", nvn_game_fps() == 60);
        at(852, 2); (void)nvn_game_fps(); at(853, 1); (void)nvn_game_fps();
        at(972, 1); CHECK("back-off: a third hold within 10 min keeps 30 after 119 calm seconds", nvn_game_fps() == 30);
        at(973, 1); CHECK("  and comes back after 120", nvn_game_fps() == 60);
        at(1073, 2); (void)nvn_game_fps(); at(1074, 1); (void)nvn_game_fps();
        at(1313, 1); CHECK("back-off: a fourth keeps 30 after 239 calm seconds", nvn_game_fps() == 30);
        at(1314, 1); CHECK("  and comes back after 240", nvn_game_fps() == 60);
        at(1913, 2); (void)nvn_game_fps(); at(1914, 1); (void)nvn_game_fps();   // 599 s after that end: still within 10 min
        at(2000, 2); CHECK("back-off: heat during a fifth hold's calm keeps 30", nvn_game_fps() == 30);
        at(2001, 1); (void)nvn_game_fps();
        at(2240, 1); CHECK("  the calm restarts at 240 s, the ceiling, not 480: 239 s keep 30", nvn_game_fps() == 30);
        at(2241, 1); CHECK("  240 bring back 60", nvn_game_fps() == 60);
        at(2841, 2); CHECK("back-off: heat 10 min after the last hold ended holds 30", nvn_game_fps() == 30);
        at(2842, 1); (void)nvn_game_fps();
        at(2871, 1); CHECK("  29 calm seconds keep it", nvn_game_fps() == 30);
        at(2872, 1); CHECK("  the wait is back to 30 s", nvn_game_fps() == 60);
        if (lp_enabled) {
            // Low Power Mode keeps its own 30 s calm whatever the heat's wait: each cause has its own calm, and the hold ends when both have passed
            at(2900, 2); (void)nvn_game_fps();   // 28 s after the last end: a 60 s wait
            low_power(1); at(2901, 1); CHECK("back-off and Low Power Mode: Low Power Mode during the heat's calm keeps 30", nvn_game_fps() == 30);
            at(2961, 1); CHECK("  the heat's 60 s calm passed: Low Power Mode still holds 30", nvn_game_fps() == 30);
            low_power(0); at(2962, 1); (void)nvn_game_fps();
            at(2991, 1); CHECK("  29 s after Low Power Mode went off: 30", nvn_game_fps() == 30);
            at(2992, 1); CHECK("  30 s: 60 (Low Power Mode's own calm, not the heat's 60 s)", nvn_game_fps() == 60);
            low_power(1); at(3000, 2); (void)nvn_game_fps();   // 39 s after the heat hold ended under Low Power Mode: a 120 s wait
            low_power(0); at(3001, 1); (void)nvn_game_fps();
            at(3031, 1); CHECK("  heat and Low Power Mode end together: 30 s pass Low Power Mode's calm, the heat's 120 s still hold 30", nvn_game_fps() == 30);
            at(3120, 1); CHECK("  119 s keep it", nvn_game_fps() == 30);
            at(3121, 1); CHECK("  120 s bring back 60", nvn_game_fps() == 60);
            low_power(1); at(3200, 0); CHECK("  Low Power Mode holds 30", nvn_game_fps() == 30);
            at(3201, 2); (void)nvn_game_fps();   // heat while Low Power Mode holds is a heat hold too: 80 s after the last end, a 240 s wait
            low_power(0); at(3202, 1); (void)nvn_game_fps();
            at(3441, 1); CHECK("  a heat hold that starts under Low Power Mode doubles the wait too: 239 s keep 30", nvn_game_fps() == 30);
            at(3442, 1); CHECK("  240 s bring back 60", nvn_game_fps() == 60);
            // Any new heat hold within 10 min doubles the wait, also when Low Power Mode kept 30 from the last one's end to its start (60 never came back): the phone heats
            // again at 30, so it is hot
            rest(); low_power(1); at(10, 2); (void)nvn_game_fps(); at(11, 1); (void)nvn_game_fps();   // a first heat hold (30 s) under Low Power Mode
            at(41, 1); CHECK("back-off under Low Power Mode: the heat hold ends, Low Power Mode keeps 30", nvn_game_fps() == 30);
            at(50, 2); (void)nvn_game_fps();   // heat again 9 s later, at 30 all along
            low_power(0); at(51, 1); (void)nvn_game_fps();
            at(81, 1); CHECK("  heat again with no 60 between: Low Power Mode's 30 s passed, the heat's wait doubled to 60, 30", nvn_game_fps() == 30);
            at(110, 1); CHECK("  59 s keep it", nvn_game_fps() == 30);
            at(111, 1); CHECK("  60 s bring back 60", nvn_game_fps() == 60);
        }
        // The 10 min count the device's sleep (now_cont_ns): Breath of the Wild reaches state 2 about 4 min after a cold start, so after an hour's break with the phone locked,
        // in which now_ns (mach_absolute_time) moves a minute or so, a new heat hold is a first one again, 30 s, not the last one's doubled wait
        rest(); at(10, 2); (void)nvn_game_fps(); at(11, 1); (void)nvn_game_fps(); at(41, 1); (void)nvn_game_fps();   // a first hold: 30 s
        at(100, 2); (void)nvn_game_fps(); at(101, 1); (void)nvn_game_fps();
        at(160, 1); CHECK("sleep: a second hold within 10 min keeps 30 after 59 calm seconds", nvn_game_fps() == 30);
        at(161, 1); CHECK("  and comes back after 60", nvn_game_fps() == 60);
        dm_gfx_suspend(1); device_sleeps(3600); at(220, 0); dm_gfx_suspend(0);   // the phone locked: the app away, the device asleep
        CHECK("sleep: back after an hour asleep, 60", nvn_game_fps() == 60);
        at(461, 2); CHECK("sleep: heat 300 s of now_ns but an hour and 5 min after that end holds 30", nvn_game_fps() == 30);
        at(462, 1); (void)nvn_game_fps();
        at(491, 1); CHECK("  29 calm seconds keep it", nvn_game_fps() == 30);
        at(492, 1); CHECK("  30 bring back 60: the hour asleep counted toward the 10 min (on now_ns alone the wait was 120 s)", nvn_game_fps() == 60);
        // A stay away (dm_gfx_suspend; the heat ladder's §3.4): nothing is sampled there. The heat's calm pauses and goes on from where it was, and a stay of the longest calm
        // wait (240 s) or more that comes back at thermal state 0 ends the hold at once, dated to the stay's start: a 30-minute break on a fourth hold's 240 s wait came back to
        // 4 min at 30 on a cold phone
        rest(); at(10, 2); (void)nvn_game_fps(); at(11, 1); (void)nvn_game_fps(); at(41, 1); (void)nvn_game_fps();   // 30 s
        at(50, 2); (void)nvn_game_fps(); at(51, 1); (void)nvn_game_fps(); at(111, 1); (void)nvn_game_fps();   // 60 s
        at(120, 2); (void)nvn_game_fps(); at(121, 1); (void)nvn_game_fps(); at(241, 1); (void)nvn_game_fps();   // 120 s
        at(250, 2); CHECK("away: a fourth heat hold (240 s) holds 30", nvn_game_fps() == 30);
        dm_gfx_suspend(1); at(260, 0); device_sleeps(1790); dm_gfx_suspend(0);   // 30 min away at state 2 when it left, 10 s of them awake
        at(261, 0); CHECK("away: back at state 0 after 30 min: 60 at once, not after the 240 s wait", nvn_game_fps() == 60);
        at(300, 2); CHECK("  heat 40 s later holds 30", nvn_game_fps() == 30);
        at(301, 1); (void)nvn_game_fps();
        at(330, 1); CHECK("  its wait is 30 s (the 10 min ran from the stay's start): 29 s keep it", nvn_game_fps() == 30);
        at(331, 1); CHECK("  30 bring back 60", nvn_game_fps() == 60);
        at(340, 2); (void)nvn_game_fps(); at(341, 1); (void)nvn_game_fps(); at(351, 1); (void)nvn_game_fps();   // a 60 s wait, 10 calm seconds
        dm_gfx_suspend(1); at(400, 0); dm_gfx_suspend(0);   // 49 s on the Home Screen
        at(401, 0); CHECK("away: 49 s away during a 60 s calm: the calm paused there, 30 (on the clock alone, 60)", nvn_game_fps() == 30);
        at(449, 0); CHECK("  59 calm seconds outside the stay keep it", nvn_game_fps() == 30);
        at(450, 0); CHECK("  60 bring back 60", nvn_game_fps() == 60);
        at(460, 2); (void)nvn_game_fps(); at(461, 1); (void)nvn_game_fps();   // a 120 s wait
        dm_gfx_suspend(1); at(470, 1); device_sleeps(1200); dm_gfx_suspend(0);   // 20 min away
        at(471, 1); CHECK("away: back at state 1 after 20 min: the calm goes on from where it was, 30", nvn_game_fps() == 30);
        at(589, 1); CHECK("  119 calm seconds outside the stay keep it", nvn_game_fps() == 30);
        at(590, 1); CHECK("  120 bring back 60", nvn_game_fps() == 60);
        at(600, 2); (void)nvn_game_fps();   // a 240 s wait
        dm_gfx_suspend(1); at(839, 0); dm_gfx_suspend(0);   // 239 s away
        at(840, 0); CHECK("away: back at state 0 after 239 s, less than the longest wait: the calm starts on return, 30", nvn_game_fps() == 30);
        at(1079, 0); CHECK("  239 s keep it", nvn_game_fps() == 30);
        at(1080, 0); CHECK("  240 bring back 60", nvn_game_fps() == 60);
        if (lp_enabled) {
            at(1100, 2); (void)nvn_game_fps();   // a 240 s wait
            low_power(1); dm_gfx_suspend(1); at(1110, 0); device_sleeps(290); dm_gfx_suspend(0);   // 5 min away; Low Power Mode turned on there
            at(1111, 0); CHECK("away and Low Power Mode: back at state 0 after 5 min: the heat hold ends, Low Power Mode holds 30", nvn_game_fps() == 30);
            low_power(0); at(1112, 0); (void)nvn_game_fps();
            at(1142, 0); CHECK("  60 30 s after Low Power Mode went off, not after the heat's 240 s", nvn_game_fps() == 60);
            // Low Power Mode's calm and a long stay's end of the heat hold in one sample: the heat hold's line alone says the game is back to the frame rate cap (Low Power
            // Mode's event comes first in the sample; its line then said so too)
            at(1150, 2); (void)nvn_game_fps();   // a heat hold
            low_power(1); at(1151, 2); (void)nvn_game_fps(); low_power(0); at(1152, 2); (void)nvn_game_fps();   // Low Power Mode on and off again: its calm starts
            dm_gfx_suspend(1); at(1160, 0); device_sleeps(300); dm_gfx_suspend(0);   // 5 min away
            log_start(); at(1161, 0); int back = nvn_game_fps() == 60; const char *lg = log_end();
            CHECK("away and Low Power Mode's calm end both causes in one sample: 60, one 'back to the frame rate cap' line", back && count(lg, "back to the frame rate cap") == 1);
        }
    }
    // An engine limiter the host writes at a 60 fps target (no frame step page; hle_fpslock.c, dm_fps_lock_engine above): heat, and Low Power Mode where the setting is on,
    // hold the present cap and the limiter (nvn_fps_hold_why) at 30 together, decided once per present; 30 s of calm restore 60. Without a limiter, in display mode the hold is
    // the present cap alone (the same checks); in game mode there is no host cap, so nothing holds (the game's own interval: 60 here)
    dm_low_power_cap_set(lp_enabled); low_power(0); movie(0); movie_fps(0);
    rest(); at(1000, 0); (void)nvn_game_fps(); at(1030, 0); (void)nvn_game_fps();   // any earlier hold recovers first
    dm_fps_state = NULL;
    const char *pim = getenv("DM_PRESENT_INTERVAL");
    if (!dm_fps_lock_engine() && !(pim && !strcmp(pim, "display"))) {
        low_power(1); at(1031, 3);
        for (uint64_t p = 1; p <= 3; p++) { nvn_engine_hold_tick(p); at(1031 + (int)p, 3); }
        CHECK("no limiter, game mode: no host cap, so heat and Low Power Mode leave the game's own rate", nvn_game_fps() == 60 && !nvn_fps_hold_why());
        // The heat ladder samples such a game at each present too (nvn_heat_tick: its later rungs and hot-dim act there), but nothing holds it: the hold's lines say so as
        // [heat] lines, with no "[nvn] … the game holds 30 fps" or "back to the frame rate cap" (devlog.py's cap events), and no hold state is reported (before the ladder
        // nothing asked for the hold here, so none was)
        int sr = state_reports, sh = state_holds; uint64_t p = 0;
        low_power(0); at(1100, 0); nvn_heat_tick(++p);
        log_start();
        low_power(1); at(1101, 0); nvn_heat_tick(++p);   // Low Power Mode (where the setting is on)
        at(1102, 3); nvn_heat_tick(++p);   // and heat
        low_power(0); for (int t = 1103; t <= 1400; t++) { at(t, 0); nvn_heat_tick(++p); }   // both end
        low_power(1); at(1401, 0); nvn_heat_tick(++p); low_power(0); for (int t = 1402; t <= 1440; t++) { at(t, 0); nvn_heat_tick(++p); }   // Low Power Mode alone
        const char *lg = log_end();
        CHECK("not paced: no line says the game holds 30 fps or is back to the frame rate cap", !count(lg, "the game holds 30 fps") && !count(lg, "back to the frame rate cap"));
        CHECK("  the heat hold's [heat] lines say nothing goes to 30 fps, then that it is over",
              count(lg, "[heat] thermal state 3: the heat hold is on") == 1 && count(lg, "the heat hold is over (nothing was held in this game)") == 1);
        if (lp_enabled) CHECK("  and Low Power Mode's", count(lg, "[heat] Low Power Mode: its hold is on") == 2 && count(lg, "[heat] Low Power Mode off for 30 s: its hold is over") == 1);
        CHECK("  no hold state reported", state_holds == sh && state_reports == sr);
        printf("== %d checks, %d failed ==\n", checks, failed);
        return failed != 0;
    }
    uint64_t pr = 0;
    nvn_engine_hold_tick(++pr); CHECK("engine limiter: 60 fps while calm", nvn_game_fps() == 60 && !nvn_fps_hold_why());
    int heat = !(enabled && !strcmp(enabled, "0"));
    at(1031, 2); nvn_engine_hold_tick(++pr);
    CHECK(heat ? "engine limiter: heat holds the present cap at 30" : "engine limiter, heat off: 60 fps", nvn_game_fps() == (heat ? 30 : 60));
    CHECK(heat ? "  and the limiter's target with it" : "  and the limiter keeps 60", heat ? nvn_fps_hold_why() && !strcmp(nvn_fps_hold_why(), "thermal state serious") : !nvn_fps_hold_why());
    at(1032, 1); nvn_engine_hold_tick(++pr); at(1061, 1); nvn_engine_hold_tick(++pr);
    CHECK("engine limiter: 29 calm seconds keep the hold", nvn_game_fps() == (heat ? 30 : 60));
    at(1062, 1); nvn_engine_hold_tick(++pr);
    CHECK("engine limiter: 30 calm seconds restore 60 for both", nvn_game_fps() == 60 && !nvn_fps_hold_why());
    low_power(1); at(1063, 0); nvn_engine_hold_tick(++pr);
    CHECK(lp_enabled ? "engine limiter: Low Power Mode holds 30 (setting on)" : "engine limiter: Low Power Mode keeps 60 (setting off)", nvn_game_fps() == (lp_enabled ? 30 : 60));
    CHECK("  the limiter says why", lp_enabled ? nvn_fps_hold_why() && !strcmp(nvn_fps_hold_why(), "Low Power Mode") : !nvn_fps_hold_why());
    at(1064, 0); (void)nvn_game_fps();
    CHECK("  the present cap changes only at a present (nvn_engine_hold_tick), with the limiter", nvn_game_fps() == (lp_enabled ? 30 : 60));
    low_power(0); at(1065, 0); nvn_engine_hold_tick(++pr); at(1095, 0); nvn_engine_hold_tick(++pr);
    CHECK("engine limiter: 60 again 30 s after Low Power Mode went off", nvn_game_fps() == 60 && !nvn_fps_hold_why());
    at(1096, 2); nvn_engine_hold_tick(++pr); at(1097, 1); nvn_engine_hold_tick(++pr); at(1156, 1); nvn_engine_hold_tick(++pr);   // 34 s after the heat hold ended at 1062
    CHECK(heat ? "engine limiter: a heat hold back within 10 min keeps both at 30 after 59 calm seconds" : "engine limiter, heat off: still 60", nvn_game_fps() == (heat ? 30 : 60));
    at(1157, 1); nvn_engine_hold_tick(++pr);
    CHECK("  60 calm seconds (the doubled wait) bring back 60 for both", nvn_game_fps() == 60 && !nvn_fps_hold_why());
    printf("== %d checks, %d failed ==\n", checks, failed);
    return failed != 0;
}
