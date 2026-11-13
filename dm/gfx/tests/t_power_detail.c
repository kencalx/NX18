// The power detail line's arithmetic and units (nvn_power.h, DM_POWER_DETAIL): a synthetic window split by core type, the parts a platform lacks said once, and on this Mac a live
// read whose CPU time agrees with getrusage (proc_pid_rusage's times are Mach absolute units; read as nanoseconds they would be about 42 times too small, the 125/3 timebase) and whose
// runnable time covers it but stays within the threads' wall time (converting a time already in nanoseconds would make it about 42 times too large)
#include "../nvn/nvn_power.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
static void *spin(void *a) { volatile uint64_t x = 0; uint64_t end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 300000000ull; while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) < end) x++; return a; }
static double rusage_cpu_s(void) { struct rusage ru; getrusage(RUSAGE_SELF, &ru); return ru.ru_utime.tv_sec + ru.ru_stime.tv_sec + (ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) / 1e6; }

int main(void) {
    char b[512];
    // 2 s: 1.5 s of CPU on performance cores at 3.6 GHz with 4 J, 2.5 s on efficiency cores at 1.2 GHz with 0.5 J, 1 s of waiting for a core
    nvn_pd a = {1000000000, 500000000, 2000000000, 100, 50, 7, 3};
    nvn_pd z = {a.cpu_ns + 4000000000ull, a.pcpu_ns + 1500000000ull, a.run_ns + 5000000000ull, a.cycles + 5400000000ull + 3000000000ull, a.pcycles + 5400000000ull,
                a.energy_nj + 4500000000ull, a.penergy_nj + 4000000000ull};
    nvn_pd_text(b, sizeof b, &a, &z, 2.0); puts(b);
    CHECK("performance cores: their energy, clock and cores busy", strstr(b, "performance cores 2.00 W, 3.60 GHz, 0.75 cores busy") != NULL);
    CHECK("efficiency cores: the rest of each", strstr(b, "efficiency cores 0.25 W, 1.20 GHz, 1.25 cores busy") != NULL);
    CHECK("waiting for a core: runnable minus CPU", strstr(b, "threads waited for a core 500 ms/s") != NULL);
    nvn_pd idle = z; idle.cpu_ns += 1000000000ull; idle.pcpu_ns += 1000000000ull; idle.run_ns += 1000000000ull; idle.cycles += 3000000000ull; idle.pcycles += 3000000000ull;
    nvn_pd_text(b, sizeof b, &z, &idle, 1.0); puts(b);
    CHECK("a cluster with no CPU time is idle, with no division by zero", strstr(b, "efficiency cores idle") && strstr(b, "threads waited for a core 0 ms/s"));
    nvn_pd_text(b, sizeof b, &z, &a, 1.0);
    CHECK("counters that went back read as nothing", strstr(b, "performance cores idle; efficiency cores idle") != NULL);
    char small[24]; size_t o = nvn_pd_text(small, sizeof small, &a, &z, 2.0);
    CHECK("a short buffer is cut, not overrun", o < sizeof small && strlen(small) == o);

    // The power tick over the same 2 s: energy, CPU and its share on performance cores, each cluster's clock, the frame rate, GPU time per second two ways, demoted frames
    nvn_pd_tick_text(b, sizeof b, &a, &z, 2.0, 120, 30.0, 24.0, 120, 3); puts(b);
    CHECK("tick: energy, CPU and the performance cores' share", strstr(b, "CPU energy 2.25 W; CPU 200% (100 = one core), 38% of it on performance cores;") != NULL);
    CHECK("tick: each cluster's clock", strstr(b, "performance cores 3.60 GHz, efficiency cores 1.20 GHz;") != NULL);
    CHECK("tick: frame rate and GPU time per second, labelled approximate", strstr(b, "; 60.0 fps; GPU about 15.0 ms/s summed over command buffers, about 12.0 ms/s as the union of the frames' spans (both approximate)") != NULL);
    CHECK("tick: demoted frames of the acquiring thread", strstr(b, "; acquiring thread demoted in 3 of 120 frames") != NULL);
    nvn_pd_tick_text(b, sizeof b, &z, &idle, 1.0, 60, 0, 0, 0, 0); puts(b);
    CHECK("tick: an idle cluster, and no demotion part with no frames checked", strstr(b, "efficiency cores idle;") && !strstr(b, "demoted"));
    nvn_pd_tick_text(b, sizeof b, NULL, &z, 1.0, 60, 0, 0, 0, 0);
    CHECK("tick: no RUSAGE_INFO_V6", !strncmp(b, "CPU by core type: not on this platform; 60.0 fps", 48));
    o = nvn_pd_tick_text(small, sizeof small, &a, &z, 2.0, 120, 30.0, 24.0, 120, 3);
    CHECK("tick: a short buffer is cut, not overrun", o < sizeof small && strlen(small) == o);

    // The union of the frames' spans (nvn_pd_span_add, hle_nvn.c tick_gpu). Ocarina of Time's first power tick in iPhone test 3 read about 42,556,079 ms/s and 133,359 ms/s there:
    // a frame whose start was unset counted from time 0, and a start left over from earlier counted its whole age. Both frames are left out now; real frames still make the union
    {
        double ms = 0; uint64_t end = 0, up = 42556079000000ull;   // about 42,556 s of uptime, in ns
        CHECK("span: a frame with a GPU start of 0 is left out (was 42,556,079 ms)", !nvn_pd_span_add(&ms, &end, 0, up) && ms == 0 && end == 0);
        CHECK("span: a frame with no GPU end is left out", !nvn_pd_span_add(&ms, &end, up, 0) && ms == 0 && end == 0);
        CHECK("span: a span of 133.359 s, a start left over, is left out (was 133,359 ms)", !nvn_pd_span_add(&ms, &end, up - 133359000000ull, up) && ms == 0 && end == 0);
        CHECK("span: an end before the start is left out", !nvn_pd_span_add(&ms, &end, up, up - 1000) && ms == 0 && end == 0);
        CHECK("span: a 12 ms frame counts", nvn_pd_span_add(&ms, &end, up, up + 12000000ull) && ms > 11.999 && ms < 12.001 && end == up + 12000000ull);
        CHECK("span: an overlapping frame adds only its part after the last end", nvn_pd_span_add(&ms, &end, up + 6000000ull, up + 20000000ull) && ms > 19.999 && ms < 20.001);
        CHECK("span: a frame inside the union adds nothing", nvn_pd_span_add(&ms, &end, up + 1000000ull, up + 2000000ull) && ms > 19.999 && ms < 20.001 && end == up + 20000000ull);
        CHECK("span: a frame with a start of 0 after real ones still adds nothing", !nvn_pd_span_add(&ms, &end, 0, up + 30000000ull) && ms > 19.999 && ms < 20.001 && end == up + 20000000ull);
        CHECK("span: a frame of exactly 1 s still counts", nvn_pd_span_add(&ms, &end, up + 100000000ull, up + 1100000000ull) && ms > 1019.999 && ms < 1020.001);
        nvn_pd_tick_text(b, sizeof b, &a, &z, 1.0, 60, 30.0, ms, 0, 0);
        CHECK("span: the tick prints the union of the real frames only", strstr(b, "about 1020.0 ms/s as the union of the frames' spans") != NULL);
    }

    int told = 0;
    nvn_pd_power_text(b, sizeof b, 3, 63, 1, 0, &told); puts(b);
    CHECK("battery and Low Power Mode", !strcmp(b, "battery 63%, on battery; Low Power Mode off"));
    nvn_pd_power_text(b, sizeof b, 3, 80, 4, 0, &told); puts(b);
    CHECK("plugged in but held below full", !strcmp(b, "battery 80%, plugged in, not charging; Low Power Mode off"));
    nvn_pd_power_text(b, sizeof b, 3, 80, 9, 0, &told);
    CHECK("a state out of range reads as unknown", !strcmp(b, "battery 80%, charging state unknown; Low Power Mode off"));
    nvn_pd_power_text(b, sizeof b, 3, 100, 3, 1, &told);
    CHECK("full and plugged in, Low Power Mode on", !strcmp(b, "battery 100%, full, plugged in; Low Power Mode on"));
    nvn_pd_power_text(b, sizeof b, 2, -1, 0, 0, &told); puts(b);
    CHECK("no battery: said once", !strcmp(b, "battery: not on this platform; Low Power Mode off"));
    nvn_pd_power_text(b, sizeof b, 2, -1, 0, 0, &told);
    CHECK("... and not again", !strcmp(b, "Low Power Mode off"));
    told = 0; nvn_pd_power_text(b, sizeof b, 0, -1, 0, 0, &told); nvn_pd_power_text(b, sizeof b, 0, -1, 0, 0, &told);
    CHECK("nothing known: an empty text after the first", !strcmp(b, ""));

    // Live, on this machine: four threads spin 0.3 s of wall time each (a busy machine gives them less CPU, so only the agreement is tight)
    nvn_pd l0, l1; double r0 = rusage_cpu_s();
    int ok = nvn_pd_read(&l0); uint64_t w0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    pthread_t th[4]; for (int i = 0; i < 4; i++) pthread_create(&th[i], 0, spin, 0);
    for (int i = 0; i < 4; i++) pthread_join(th[i], 0);
    ok = ok && nvn_pd_read(&l1); double r1 = rusage_cpu_s(), wall = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - w0) / 1e9;
    CHECK("RUSAGE_INFO_V6 is read", ok);
    if (ok) {
        double cpu = (l1.cpu_ns - l0.cpu_ns) / 1e9, ru = r1 - r0, run = (l1.run_ns - l0.run_ns) / 1e9;
        printf("  live: CPU %.3f s (getrusage %.3f s), of it on performance cores %.3f s, runnable %.3f s in %.3f s of wall time, %.2f GHz\n", cpu, ru, (l1.pcpu_ns - l0.pcpu_ns) / 1e9, run, wall,
               (double)(l1.cycles - l0.cycles) / (double)(l1.cpu_ns - l0.cpu_ns));
        CHECK("CPU time in nanoseconds agrees with getrusage", cpu > 0.25 && cpu < 1.5 && cpu > ru * 0.9 && cpu < ru * 1.1);
        CHECK("runnable time covers the CPU time", run >= cpu * 0.98);
        CHECK("runnable time within the threads' wall time (four spinning, the main thread joining)", run <= 5 * wall);
        CHECK("performance-core time and cycles within the totals", l1.pcpu_ns - l0.pcpu_ns <= l1.cpu_ns - l0.cpu_ns && l1.pcycles - l0.pcycles <= l1.cycles - l0.cycles);
        CHECK("a clock between 0.5 and 6 GHz", (double)(l1.cycles - l0.cycles) / (double)(l1.cpu_ns - l0.cpu_ns) > 0.5 && (double)(l1.cycles - l0.cycles) / (double)(l1.cpu_ns - l0.cpu_ns) < 6);
    }
    printf("%d checks, %d failed\n", checks, failed);
    return failed != 0;
}
