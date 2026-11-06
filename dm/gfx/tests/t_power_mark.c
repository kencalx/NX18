// The iOS frame-rate counter's heat / Low Power mark (../../host/power_mark.h), on any machine: when the frame rate cap's mark says heat or Low Power Mode holds the frame rate
// (only above a 30 target and without a movie for a frame-step game; 60 for a 120 fps limiter), and the note the counter shows for it and for MetalFX held back, whose cause
// heat wins. hle_nvn.c's and nvn_mtl.m's use of it run in t_thermal (Mac)
#include "../../host/power_mark.h"
#include <string.h>

static int checks, failed;
#define EXPECT(name, want, got) do { long long w_ = (want), g_ = (got); checks++; if (w_ != g_) { fprintf(stderr, "%s: expected %lld, got %lld\n", name, w_, g_); failed++; } } while (0)
#define EXPECT_S(name, want, got) do { checks++; if (strcmp((want), (got)) != 0) { fprintf(stderr, "%s: expected \"%s\", got \"%s\"\n", name, (want), (got)); failed++; } } while (0)

static char why[16], what[48];
static int note(int cap, int fx) { why[0] = what[0] = 0; return pm_note(cap, fx, why, sizeof why, what, sizeof what); }

int main(void) {
    EXPECT("no cause: no mark", 0, pm_frame_cap(0, 30));
    EXPECT("heat at 30", PM_HEAT << 8 | 30, pm_frame_cap(PM_HEAT, 30));
    EXPECT("a 120 fps limiter held at 60 by Low Power Mode", PM_LOW_POWER << 8 | 60, pm_frame_cap(PM_LOW_POWER, 60));
    EXPECT("frame step at 60, hot: 30 is held", PM_HEAT << 8 | 30, pm_step_cap(PM_HEAT, 0, 60));
    EXPECT("frame step at 60, both causes", (PM_HEAT | PM_LOW_POWER) << 8 | 30, pm_step_cap(PM_HEAT | PM_LOW_POWER, 0, 60));
    EXPECT("a 30 target is its own 30, whatever the heat", 0, pm_step_cap(PM_HEAT, 0, 30));
    EXPECT("a movie is its own 30", 0, pm_step_cap(PM_LOW_POWER, 1, 60));
    EXPECT("calm: nothing held", 0, pm_step_cap(0, 0, 60));

    EXPECT("nothing held back: no note", 0, note(0, 0));
    EXPECT("heat holding 30: the thermometer", PM_HEAT, note(pm_step_cap(PM_HEAT, 0, 60), 0));
    EXPECT_S("  Hot", "Hot", why); EXPECT_S("  30 fps cap", "30 fps cap", what);
    EXPECT("Low Power holding a 120 fps limiter at 60: the battery", PM_LOW_POWER, note(pm_frame_cap(PM_LOW_POWER, 60), 0));
    EXPECT_S("  Low Power", "Low Power", why); EXPECT_S("  60 fps cap", "60 fps cap", what);
    EXPECT("MetalFX held by Low Power Mode alone", PM_LOW_POWER, note(0, PM_LOW_POWER));
    EXPECT_S("  no MetalFX", "no MetalFX", what);
    EXPECT("both held, heat for MetalFX and Low Power for the cap: heat wins", PM_HEAT, note(pm_frame_cap(PM_LOW_POWER, 30), PM_HEAT));
    EXPECT_S("  Hot", "Hot", why); EXPECT_S("  both", "30 fps cap, no MetalFX", what);
    EXPECT("a game the host does not pace: MetalFX only", PM_HEAT, note(0, PM_HEAT | PM_LOW_POWER));
    EXPECT_S("  no MetalFX", "no MetalFX", what);
    char small[4]; pm_note(pm_frame_cap(PM_HEAT, 30), PM_HEAT, small, sizeof small, small, sizeof small);
    EXPECT("a short buffer is cut, not overrun", 3, (long long)strlen(small));
    printf("t_power_mark: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
