// Hash table unit tests: random insert / overwrite / delete / clear checked against a naive array model; small key space, key lengths 8 and 20 (including a tail that is not a multiple of 8), to force long probe chains and backward-shift deletion.
#include "../nvn/nvn_hmap.h"
#include <stdio.h>

#define KS 3000
static uint64_t rng = 88172645463325252ull;
static uint64_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; }
static int run(uint32_t klen, int ops) {
    static void *ref[KS]; memset(ref, 0, sizeof ref);
    static uint32_t hint[KS]; memset(hint, 0, sizeof hint);   // nvn_hm_get_hint's remembered slots: kept across every put, delete (backward shift), grow and clear, so most go stale
    nvn_hmap m; nvn_hm_init(&m, klen);
    uint8_t k[32]; int bad = 0, live = 0; uint64_t hinted = 0, hint_hits = 0, stale = 0;
    for (int t = 0; t < ops && !bad; t++) {
        uint32_t x = (uint32_t)(rnd() % KS); memset(k, 0xab, sizeof k); memcpy(k, &x, 4);
        int op = (int)(rnd() % 10);
        if (op < 5) { void *v = (void *)(uintptr_t)(t + 1), *old = nvn_hm_put(&m, k, v); bad |= old != ref[x]; live += !ref[x]; ref[x] = v; }
        else if (op < 8) { void *old = nvn_hm_del(&m, k); bad |= old != ref[x]; live -= !!ref[x]; ref[x] = NULL; }
        else if (op == 8) bad |= nvn_hm_get(&m, k) != ref[x];
        else { uint32_t h0 = hint[x];
               if (h0 && h0 <= m.cap && m.vals[h0 - 1] && memcmp(m.keys + (size_t)(h0 - 1) * m.klen, k, m.klen)) stale++;   // negative control: the slot holds another key; taken on trust, a wrong answer
               void *v = nvn_hm_get_hint(&m, k, &hint[x]); bad |= v != ref[x]; hinted++; hint_hits += v && h0 && hint[x] == h0;
               if (v) bad |= hint[x] == 0 || hint[x] > m.cap || m.vals[hint[x] - 1] != v; }   // a found key leaves its slot behind
        if (t % 50000 == 49999) { nvn_hm_clear(&m, NULL); memset(ref, 0, sizeof ref); live = 0; }
        bad |= (int)m.n != live;
    }
    for (uint32_t x = 0; x < KS && !bad; x++) { memset(k, 0xab, sizeof k); memcpy(k, &x, 4); bad |= nvn_hm_get(&m, k) != ref[x]; }   // full comparison of the final state
    for (uint32_t x = 0; x < KS && !bad; x++) { memset(k, 0xab, sizeof k); memcpy(k, &x, 4); bad |= nvn_hm_get_hint(&m, k, &hint[x]) != ref[x]; }   // and through every (stale) hint
    printf("key length %2u: %d random operations + full comparison of %d keys at the end, expected identical → got %s (%u entries at the end, capacity %u; %llu hinted lookups, %llu from the remembered slot, %llu whose slot held another key)\n", klen, ops, KS, bad ? "different ✗" : "identical ✓", m.n, m.cap,
           (unsigned long long)hinted, (unsigned long long)hint_hits, (unsigned long long)stale);
    if (!stale) { printf("no hint went stale: the key check was not exercised ✗\n"); bad = 1; }
    if (!hint_hits) { printf("no hinted lookup took its remembered slot ✗\n"); bad = 1; }
    free(m.keys); free(m.vals);
    return bad;
}
int main(void) {
    int fail = run(8, 190000) + run(20, 190000);
    printf("== 2 checks, %d failed ==\n", fail);
    return fail != 0;
}
