// Host ticks to nanoseconds without a 64-bit divide (now_ns / now_cont_ns, hle_os.c; DM_NOW_MUL). The clock used to compute ticks * numer / denom on every read: on Apple
// silicon the timebase is 125 / 3, and the divide was about a quarter of now_ns's cost (M4 Max, 9.2 vs 7.1 ns a call), on a clock the host reads millions of times a second.
// The same result, bit for bit, comes from a 128-bit multiply: with K = ceil(numer * 2^64 / denom), split as K = hi * 2^64 + lo,
//   floor(t * numer / denom) = t * hi + floor(t * lo / 2^64)   for every t with t * numer < 2^64 (the range where the old product did not wrap)
// Proof: let d = K * denom - numer * 2^64 (0 <= d < denom), x = t * numer = q * denom + r (0 <= r < denom). Then t * K / 2^64 = x / denom + t * d / (denom * 2^64), and its floor
// is q exactly when r + t * d / 2^64 < denom, which holds when t * d < 2^64; with d <= numer that follows from t * numer < 2^64 (125 / 3: d = 1; 1 / 1: K = 2^64, d = 0).
// A timebase with d > numer keeps the divide, and so does a t past that range (194 years of uptime at 24 MHz), where the old product wrapped: the result stays the old one there too.
// tests/t_now_mul.c checks it against the divide over edge values and random ticks for several timebases
#pragma once
#include <stdint.h>

typedef struct { uint64_t hi, lo, lim; uint32_t numer, denom; int mul; } dm_tbconv_t;

static inline void dm_tbconv_init(dm_tbconv_t *c, uint32_t numer, uint32_t denom, int mul) {
    c->numer = numer; c->denom = denom ? denom : 1; c->lim = numer ? UINT64_MAX / numer : UINT64_MAX;
    unsigned __int128 k = ((((unsigned __int128)numer) << 64) + c->denom - 1) / c->denom;
    c->hi = (uint64_t)(k >> 64); c->lo = (uint64_t)k;
    unsigned __int128 d = k * c->denom - (((unsigned __int128)numer) << 64);
    c->mul = mul && numer && d <= numer;
}
static inline uint64_t dm_tbconv_div(const dm_tbconv_t *c, uint64_t t) { return t * c->numer / c->denom; }   // the old conversion, wrap included
static inline uint64_t dm_tbconv(const dm_tbconv_t *c, uint64_t t) {
    if (c->mul && t <= c->lim) return t * c->hi + (uint64_t)(((unsigned __int128)t * c->lo) >> 64);
    return dm_tbconv_div(c, t);
}
