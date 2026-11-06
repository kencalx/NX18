// The largest block of address space this process can reserve: the iOS app's boot line (dm/ios/Sources/main.m, before anything reserves the guest's block) and the line a
// failed guest reservation dies with (hle_svc.c mem_init_once). A binary search over PROT_NONE reservations (MAP_PRIVATE | MAP_ANON | MAP_NORESERVE), each released at once:
// no memory is taken, nothing is left behind, and the guest's block lands where it would have without the search (the kernel finds the same hole again; t_as_ceiling checks
// it). To AS_GRAN, at most AS_CAP (a Mac reserves terabytes): 13 tries, expected well under a millisecond (not yet measured on iOS; the boot line logs the time). Plain C
// (dm/host/tests/t_as_ceiling.c).
// A block that fits is necessary for a game's guest block, not sufficient: the memory the game touches, Metal's own address space and a Switch 2 game's alias mappings come on
// top (Splatoon Raiders peaks at about +8.5 GB of alias mappings, docs/reference/memory.md). So "fits" here says only that the reservation itself would not fail.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>

#define AS_GRAN ((uint64_t)256 << 20)   // a quarter of a GB: the blocks below are whole quarters
#define AS_CAP ((uint64_t)1 << 40)      // 1 TB; a ceiling at the cap reads "at least"

typedef int (*as_try_fn)(uint64_t bytes, void *ctx);   // 1 when a block of that many bytes can be reserved (and it is given back)
static inline int as_try_mmap(uint64_t bytes, void *ctx) {
    (void)ctx;
    if (!bytes || bytes > SIZE_MAX) return 0;
    void *p = mmap(NULL, (size_t)bytes, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED) return 0;
    munmap(p, (size_t)bytes);
    return 1;
}
// The largest multiple of gran, up to cap, that try_fn reserves (0 when not even gran does). It takes a size that fits to mean that every smaller one does (the largest hole
// in the address space holds it). *tries: how many reservations it asked for
static inline uint64_t as_ceiling(as_try_fn try_fn, void *ctx, uint64_t gran, uint64_t cap, int *tries) {
    uint64_t lo = 0, hi = gran ? cap / gran : 0;   // lo grans fit (none always does); hi grans: asked first, then known not to fit
    int n = 0;
    if (hi) { n++; if (try_fn(hi * gran, ctx)) lo = hi; }
    while (hi - lo > 1) { uint64_t mid = lo + (hi - lo) / 2; n++; if (try_fn(mid * gran, ctx)) lo = mid; else hi = mid; }
    if (tries) *tries = n;
    return lo * gran;
}

// The guest blocks that keep games Mac-only on address space alone (their profiles' mem_reserve, docs/reference/memory.md; dm/tools/tests/test_as_ceiling.py checks them
// against the profiles), so that one boot of any game on a device says which of them that device would reserve
typedef struct { const char *name; uint64_t bytes; } as_block;   // each row's comment: the game's title ID, which test_as_ceiling.py checks the size against (no title IDs in host code: test_architecture)
static const as_block k_as_blocks[] = {
    {"EA SPORTS FC 27", 0x1c0000000ull},   // 0100C49025D3E000
    {"Splatoon Raiders", 0x550000000ull},   // 0400380020056000
    {"Fire Emblem Fortune's Weave", 0x550000000ull},   // 04007EF01F8AE000
    {"Star Fox", 0x550000000ull},   // 0400E88025B1A000
    {"Mario Tennis Fever", 0x650000000ull},   // 0400D4201C6EA000
};
// "7.00 GB (EA SPORTS FC 27) fits; 21.25 GB (Splatoon Raiders, Fire Emblem Fortune's Weave, Star Fox) does not fit; ...": each size once, in the table's order, with its games
static inline void as_fit_text(uint64_t ceiling, char *out, size_t n) {
    size_t o = 0, nb = sizeof k_as_blocks / sizeof *k_as_blocks;
    if (n) out[0] = 0;
    for (size_t i = 0; i < nb && o < n; i++) {
        int seen = 0; for (size_t j = 0; j < i; j++) seen |= k_as_blocks[j].bytes == k_as_blocks[i].bytes;
        if (seen) continue;
        int w = snprintf(out + o, n - o, "%s%.2f GB (", o ? "; " : "", k_as_blocks[i].bytes / 1073741824.0);
        for (size_t j = i, first = 1; j < nb && w >= 0 && o + (size_t)w < n; j++) if (k_as_blocks[j].bytes == k_as_blocks[i].bytes) {
            int x = snprintf(out + o + (size_t)w, n - o - (size_t)w, "%s%s", first ? "" : ", ", k_as_blocks[j].name); if (x < 0) { w = x; break; } w += x; first = 0; }
        if (w >= 0 && o + (size_t)w < n) { int x = snprintf(out + o + (size_t)w, n - o - (size_t)w, ") %s", k_as_blocks[i].bytes <= ceiling ? "fits" : "does not fit"); if (x >= 0) w += x; }
        if (w < 0) break;
        o += (size_t)w;
    }
}
