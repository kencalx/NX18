// now_ns's ticks-to-ns multiply (dm_tbconv.h, DM_NOW_MUL) gives the old divide's result bit for bit: edge values and random ticks for Apple silicon's timebase (125 / 3), Intel's
// (1 / 1) and others. Negative control: a 32.32 fixed-point multiplier (the obvious cheaper conversion) is caught differing from the divide by the same checks.
// --bench: ns per conversion, divide vs multiply, best of 5
#include "../dm_tbconv.h"
#include <assert.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <string.h>

static uint64_t rng = 0x9e3779b97f4a7c15ull;
static uint64_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }

static long g_checked;
static void same(const dm_tbconv_t *c, uint64_t t) {
    uint64_t want = dm_tbconv_div(c, t), got = dm_tbconv(c, t);
    if (want != got) { fprintf(stderr, "FAIL %u/%u t=%llu: divide %llu, multiply %llu\n", c->numer, c->denom, (unsigned long long)t, (unsigned long long)want, (unsigned long long)got); assert(0); }
    g_checked++;
}
static void check(uint32_t numer, uint32_t denom, int expect_mul) {
    dm_tbconv_t c; dm_tbconv_init(&c, numer, denom, 1);
    if (expect_mul >= 0) assert(c.mul == expect_mul);
    const uint64_t edge[] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 23, 24, 25, 1000, 24000000, 1ull << 31, 1ull << 32, (1ull << 32) + 1, 1ull << 40, 1ull << 50, 1ull << 56, 1ull << 57,
                              c.lim - 2, c.lim - 1, c.lim, c.lim + 1, c.lim + 2, UINT64_MAX / 2, UINT64_MAX - 1, UINT64_MAX };
    for (unsigned i = 0; i < sizeof edge / sizeof edge[0]; i++) same(&c, edge[i]);
    // around multiples of the denominator, where the floor changes, near the top of the range and spread over it
    for (int i = 0; i < 200000; i++) {
        uint64_t m = c.lim / c.denom; uint64_t q = rnd() % (m + 1), base = q * c.denom;
        for (uint32_t k = 0; k < 3 && k < c.denom; k++) { same(&c, base + k); if (base >= k + 1) same(&c, base - k - 1); }
        same(&c, c.lim - (rnd() & 0xffffff));
        same(&c, rnd() >> (rnd() % 64));   // every magnitude
        same(&c, c.lim == UINT64_MAX ? rnd() : rnd() % (c.lim + 1));
        same(&c, rnd());                   // the full 64-bit range, past lim too (divide kept, wrap included)
    }
    // uptimes as the host sees them: the first 30 days at 24 MHz, every tick of a few windows
    for (uint64_t t = 0; t < 1000000; t++) same(&c, t);
    for (uint64_t t = 24000000ull * 86400 * 30 - 500000; t < 24000000ull * 86400 * 30 + 500000; t++) same(&c, t);
}

static uint64_t fixed32(uint64_t t) { return (uint64_t)(((unsigned __int128)t * ((125ull << 32) / 3)) >> 32); }   // the 32.32 multiplier the code check sketched

static double bench(int mul) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    dm_tbconv_t c; dm_tbconv_init(&c, tb.numer, tb.denom, mul);
    enum { N = 50000000 };
    double best = 1e9;
    for (int r = 0; r < 5; r++) {
        uint64_t t0 = mach_absolute_time(), acc = 0, t = t0;
        for (int i = 0; i < N; i++) { acc += dm_tbconv(&c, t); t += 7 + (acc & 1); __asm__ volatile("" : "+r"(acc), "+r"(t)); }
        uint64_t t1 = mach_absolute_time();
        double ns = (double)dm_tbconv_div(&c, t1 - t0) / N; if (ns < best) best = ns;
        if (acc == 42) puts("");
    }
    return best;
}
static double bench_clock(int mul) {   // the whole now_ns: mach_absolute_time and the conversion
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    dm_tbconv_t c; dm_tbconv_init(&c, tb.numer, tb.denom, mul);
    enum { N = 20000000 };
    double best = 1e9;
    for (int r = 0; r < 5; r++) {
        uint64_t t0 = mach_absolute_time(), acc = 0;
        for (int i = 0; i < N; i++) { acc += dm_tbconv(&c, mach_absolute_time()); __asm__ volatile("" : "+r"(acc)); }
        double ns = (double)dm_tbconv_div(&c, mach_absolute_time() - t0) / N; if (ns < best) best = ns;
        if (acc == 42) puts("");
    }
    return best;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--bench")) {
        printf("conversion only: divide %.2f ns, multiply %.2f ns\n", bench(0), bench(1));
        printf("now_ns (mach_absolute_time + conversion): divide %.2f ns, multiply %.2f ns\n", bench_clock(0), bench_clock(1));
        return 0;
    }
    check(125, 3, 1);        // Apple silicon
    check(1, 1, 1);          // Intel Macs and the simulator on them
    check(3, 125, -1);
    check(1000000000, 24000000, -1);
    check(83, 2, 1);
    check(41, 1, 1);
    check(1, 3, -1);
    for (int i = 0; i < 40; i++) { uint32_t n = (uint32_t)(rnd() % 100000) + 1, d = (uint32_t)(rnd() % 100000) + 1; check(n, d, -1); }
    // DM_NOW_MUL=0: the divide itself
    { dm_tbconv_t c; dm_tbconv_init(&c, 125, 3, 0); assert(!c.mul); for (int i = 0; i < 1000; i++) { uint64_t t = rnd(); assert(dm_tbconv(&c, t) == t * 125 / 3); } }
    // Negative control: the checks above catch a conversion that is only close
    { int caught = 0; for (int i = 0; i < 1000000 && !caught; i++) { uint64_t t = rnd() % (UINT64_MAX / 125); caught = fixed32(t) != t * 125 / 3; } assert(caught); }
    printf("now_ns multiply: same as the divide over %ld values (and a 32.32 multiplier caught differing) passed\n", g_checked);
    return 0;
}
