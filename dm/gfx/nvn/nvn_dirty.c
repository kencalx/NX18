// Write-protect dirty-page tracking for guest memory: pool pages of packaged textures (CPU writes, GPU reads) are set read-only after upload, and as soon as the game writes it faults -> mark dirty, unprotect;
// before use, check the write generation of the covered pages and re-upload if newer than at upload time. NVN semantics: a texture descriptor points to pool memory, and the GPU reads the current content every time
// (measured: the game writes streamed assets into texture storage that is still being sampled, without re-registering).
// Signal handler constraint: the page-fault path uses only atomic operations and mprotect, no allocation, no locks.
#include "nvn_dirty.h"
#include "../../host/dm.h"
#include <stdatomic.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <mach/mach.h>   // vm_region_64: a fault no range claims (page_writable)
#include <sched.h>

// Order of page state and mprotect: the side changing protection first sets the state to BUSY and sets the final state only after mprotect has landed; other threads wait when they see BUSY.
//   set read-only: NONE -> BUSY -> mprotect(read-only) -> PROT; unprotect: PROT -> BUSY -> mprotect(writable) -> NONE.
// Invariant: a page whose state is NONE is always writable, one whose state is PROT is always read-only. Setting read-only used to be "record PROT, then mprotect"; in between, another thread's unprotect-before-write
// (the movie decoder thread writing a frame into texture storage, a disk read into a guest buffer) could set the state back to NONE, then the mprotect landed => the page read-only with state NONE: a game thread writing it got only
// "re-execute" from the fault handler and spun forever; a host system call reading into it saw NONE in prep_write, skipped, and failed with EFAULT (reproduced by t_dirty_race).
// BUSY lasts at most one mprotect (plus a few atomic writes when setting read-only). The wait is capped at BUSY_WAIT_MS and reports red beyond it: in the fault handler it then returns "not our page" so the crash handler reports truthfully
// OPEN (nvn_dirty_open): protected, made writable for a moment without counting as written; a host write takes it as it takes a protected page.
enum { PG_NONE = 0, PG_PROT = 1, PG_BUSY = 2, PG_OPEN = 3 };
enum { BUSY_WAIT_MS = 2000 };
// Tracked ranges = the memory pools (registered by MemoryPoolInitialize). After a pool is destroyed its live=0 slot is reused; the signal handler scans without locks.
// The table grows in blocks of 1,024 slots, up to 262,144; a block is never moved or freed, so the signal handler reads it without locks. A pool past the end goes untracked: its textures count
// as dirty and are re-uploaded at every use. The table was a fixed 256 slots (Zelda has about 300 pools at the title), then a fixed 4,096, and Breath of the Wild reaches 4,006 pools in its first
// shrine. The scans only cover slots in use, so the capacity itself costs nothing
enum { BLK_SHIFT = 10, BLK = 1 << BLK_SHIFT, NBLK = 256, MAX_RANGE = BLK * NBLK };
// Ranges are rounded to host pages (16 KB) but guest memory pools are only 4 KB aligned: adjacent pools share their first / last pages, so one address can fall in several registered ranges.
// So: "is this texture tracked" looks for a range that holds its whole span; a fault / host pre-write unprotects and stamps every range covering that page; pool destruction identifies its range by the pool's exact start mem.
// (Previously the first range containing the address was always taken: two SMBW ASTC 6x5 textures whose pool's first page is shared with a small preceding pool were judged untracked and re-uploaded on every use, about 6 MB per frame)
// born: the clock when the range was registered. A page's generation starts at 0 then, so a stamp taken before that (content checked in a pool this memory held before, or while
// it was in no pool) could not see a write made in between: the old pool's pages were made writable when it was destroyed, and the game wrote the next pool's data into them
// without a fault. A stamp older than born therefore counts as written (nvn_dirty_since_cached, nvn_dirty_since_except).
// pins: the lock-free readers (the fault hook, the host pre-write hook, the dirty checks, describe) pin a slot before they read its fields past base and end, and add_range rewrites a
// retired slot for the next pool only once none holds it (pin). base and end are read before the pin, to pass over slots that cannot hold the address, so they are atomic
typedef struct { _Atomic uintptr_t base, end; uintptr_t mem; _Atomic uint8_t *state; _Atomic uint64_t *gen, *pgen; _Atomic(_Atomic uint8_t *) sparse; size_t cap; _Atomic int live, pins; _Atomic uint64_t born, last, wseq; } range_t;   // sparse: per page, protected for a placement sparse tile (nvn_dirty_protect_sparse)
// last: the largest write generation of any page of the range (raised next to every generation store, stamp_page): a range not written since a stamp answers nvn_dirty_since_last without
// reading its pages (ported from S2Arm de791716, Apache-2.0)
// wseq: moved after every generation store of the range (stamp_page), at its registration and at its removal, each time to a value of the clock no other store takes: a reader that
// found the range's span clean with wseq at w knows nothing was written there since while wseq still reads w (nvn_dirty_since_seq; nvn_mtl.m's texture IDs, DM_NVN_TEX_SEQ)
// pgen: per page, the clock when a write to it was last hidden: the page protected again after a write (nvn_dirty_protect), or stamped on a change while open (nvn_dirty_close). gen holds only
// the first write since the last protect, so after a re-protect the writes before it leave no trace; a reader that judges when a page was written (nvn_dirty_needed) treats such a page as
// written at any time unless its own upload, which read those writes, came after (pnow)
static inline uintptr_t rb(range_t *r) { return atomic_load_explicit(&r->base, memory_order_relaxed); }
static inline uintptr_t re(range_t *r) { return atomic_load_explicit(&r->end, memory_order_relaxed); }
static _Atomic(range_t *) g_blk[NBLK];
static inline range_t *rg(int i) { return &atomic_load_explicit(&g_blk[i >> BLK_SHIFT], memory_order_acquire)[i & (BLK - 1)]; }
static _Alignas(128) _Atomic int g_nr;
static uintptr_t g_pg, g_shift;
static _Alignas(128) _Atomic uint64_t g_now = 1;
static _Alignas(128) _Atomic uint64_t g_faults, g_preps;
static _Atomic uint64_t g_adds_total;
static _Atomic int g_live, g_live_peak;   // number of registered pools and peak (for the memory readout line)
void nvn_dirty_stat(int *live, int *peak, int *cap) { *live = atomic_load(&g_live); *peak = atomic_load(&g_live_peak); *cap = MAX_RANGE; }
static _Atomic int g_overflow_logged;
static _Alignas(128) pthread_mutex_t g_slot_mu = PTHREAD_MUTEX_INITIALIZER;   // Pool creation, retirement and protection serialize descriptor lifetime; the page-fault path does not touch this mutex
// Even epochs describe a stable registry. Registration and retirement make the
// epoch odd while changing descriptors, invalidating every thread's lookup cache.
// This only validates selections: lock-free users still pin the selected range.
static _Alignas(128) _Atomic uint64_t g_range_epoch;
static _Alignas(128) _Atomic uint64_t g_mp_calls, g_mp_pages, g_mp_ticks;   // This module's mprotect: call count, pages covered, time spent (mach timebase, safe in the page-fault path too)
static _Alignas(128) _Atomic uint64_t g_mp_begun, g_mp_done;   // this module's protection changes begun and finished: on_fault tells from them whether its scan saw the protection as it is
static void mp(uintptr_t a, size_t len, int prot) {
    atomic_fetch_add(&g_mp_begun, 1);
    uint64_t t = mach_absolute_time(); mprotect((void *)a, len, prot); atomic_fetch_add(&g_mp_done, 1);
    atomic_fetch_add(&g_mp_ticks, mach_absolute_time() - t); atomic_fetch_add(&g_mp_calls, 1); atomic_fetch_add(&g_mp_pages, len >> g_shift);
}

static mach_timebase_info_data_t g_tb;   // obtained when the host loads (dirty_init; the fault path only multiplies and divides)
static _Atomic int g_busy_red;
// Wait for this page to leave BUSY. Returns 1 = it has left; 0 = waited past the limit (reported red once). Usable in a signal handler: only atomic reads, mach_absolute_time and sched_yield
static int busy_wait(range_t *r, uintptr_t p) {
    uint64_t t0 = 0;
    for (unsigned n = 1; atomic_load(&r->state[p]) == PG_BUSY; n++) {
        if (n & 0x3ff) continue;
        uint64_t now = mach_absolute_time(); if (!t0) t0 = now;
        if ((now - t0) * g_tb.numer / g_tb.denom > (uint64_t)BUSY_WAIT_MS * 1000000ull) {
            if (!atomic_exchange(&g_busy_red, 1)) LOG("[RED] dirty-page tracking: page %p stuck 'busy' for over %d ms (the thread changing its protection has not finished), no longer waiting", (void *)(rb(r) + (p << g_shift)), BUSY_WAIT_MS);
            return 0; }
        sched_yield();
    }
    return 1;
}
static int live_at(int i) { return atomic_load_explicit(&rg(i)->live, memory_order_acquire); }
// Pin a slot found live, so that it is not registered again for another pool while this reader uses its fields and arrays. A reader that found it live, then had it retired and
// registered again over other memory (add_range picks the first free slot, so the one just retired), read the new pool's end with the old start: the page index went past the
// arrays (the fault hook wrote there), or a dirty check read the old born with the new zeroed generations and called a written page clean (PR #2225 follow-up; t_dirty_reuse).
// Both sides are seq_cst: the pin is counted before live is read, and nvn_dirty_remove_range clears live before add_range reads the count, so either add_range sees the pin and
// waits, or this reader sees live clear (or set again, with the new pool's fields complete). Returns 0, unpinned, when the slot is not live. Usable in the signal handler
static int pin(range_t *r) {
    atomic_fetch_add(&r->pins, 1);
    if (atomic_load(&r->live)) return 1;
    atomic_fetch_sub_explicit(&r->pins, 1, memory_order_release); return 0;
}
static void unpin(range_t *r) { atomic_fetch_sub_explicit(&r->pins, 1, memory_order_release); }
// r pinned when it is live and holds all of [a, a+len); NULL otherwise
static range_t *pin_holding(range_t *r, uintptr_t a, size_t len) {
    if (!r || !pin(r)) return NULL;
    if (a >= rb(r) && a + len <= re(r)) return r;
    unpin(r); return NULL;
}
typedef struct {
    range_t *range;
    uintptr_t base;
    uintptr_t end;
    // Exclusive bounds that keep earlier registry entries from containing a hit.
    uintptr_t start_upper_bound;
    uintptr_t end_lower_bound;
    uint64_t epoch;
} cached_span_t;

// Keep a power-of-two capacity so the insertion counter can wrap naturally.
enum { SPAN_CACHE_SIZE = 8, SPAN_CACHE_MASK = SPAN_CACHE_SIZE - 1 };

enum { IDX_HITS = 32, IDX_TRIES = 8 };
static int idx_find(uintptr_t a, uintptr_t e, uint32_t *hit);   // the address index, below

// Find the first registered range containing [start, start + length).
// Cache descriptors, never page generations or dirty/clean results.
static range_t *find_span(uintptr_t start, size_t length) {
    static _Thread_local cached_span_t recent_spans[SPAN_CACHE_SIZE];
    static _Thread_local unsigned next_cache_slot;
    uintptr_t end = start + length;
    uint64_t epoch = atomic_load_explicit(&g_range_epoch, memory_order_acquire);

    if (!(epoch & 1)) {
        // Search newest entries first; recent sparse-texture runs often share a pool.
        for (unsigned offset = 0; offset < SPAN_CACHE_SIZE; offset++) {
            unsigned slot = (next_cache_slot - 1 - offset) & SPAN_CACHE_MASK;
            const cached_span_t *entry = &recent_spans[slot];
            if (!entry->range || entry->epoch != epoch) {
                continue;
            }
            if (start < entry->base || end > entry->end) {
                continue;
            }
            // A containing range is not enough: every earlier slot must still
            // fail to contain this span, or we could read the wrong generation.
            if (start >= entry->start_upper_bound || end <= entry->end_lower_bound) {
                continue;
            }
            if (atomic_load_explicit(&g_range_epoch, memory_order_acquire) == epoch) {
                return entry->range;
            }
        }
    }

    // The address index (DM_NVN_DIRTY_INDEX) instead of a scan of every slot: the ranges overlapping the span, of which the lowest slot that holds it whole is the one
    // the scan returns (ported from S2Arm 985c4fae, Apache-2.0, where this scan was 4.5% of a phone's replay thread; about 4,300 ranges in a Mario Kart World race). Only
    // against a registry that did not change during the read (epoch even and the same after it); otherwise, or when the index cannot answer, the scan below
    if (!(epoch & 1)) {
        uint32_t hit[IDX_HITS]; int k = idx_find(start, end, hit), n = atomic_load(&g_nr);
        if (k >= 0) {
            int best = -1;
            for (int j = 0; j < k; j++) {
                int slot = (int)hit[j]; if (slot >= n || (best >= 0 && slot >= best) || !live_at(slot)) continue;
                range_t *range = rg(slot); if (start >= rb(range) && end <= re(range)) best = slot;
            }
            if (atomic_load_explicit(&g_range_epoch, memory_order_acquire) == epoch) {
                if (best < 0) return NULL;
                range_t *range = rg(best);
                // Cached for spans that hold this one: a lower slot holding such a span would hold this one too, and the index found none
                recent_spans[next_cache_slot & SPAN_CACHE_MASK] = (cached_span_t){ .range = range, .base = rb(range), .end = re(range),
                    .start_upper_bound = start + 1, .end_lower_bound = end - 1, .epoch = epoch };
                next_cache_slot++;
                return range;
            }
        }
    }

    uintptr_t start_upper_bound = UINTPTR_MAX;
    uintptr_t end_lower_bound = 0;
    int range_count = atomic_load(&g_nr);
    for (int slot = 0; slot < range_count; slot++) {
        range_t *range = rg(slot);
        if (!live_at(slot)) {
            continue;
        }
        uintptr_t base = rb(range);
        uintptr_t limit = re(range);
        if (start < base) {
            // Future hits must keep starting before this excluded range.
            if (base < start_upper_bound) {
                start_upper_bound = base;
            }
            continue;
        }
        if (end > limit) {
            // Future hits must keep ending beyond this excluded range.
            if (limit > end_lower_bound) {
                end_lower_bound = limit;
            }
            continue;
        }

        // Only cache a selection made against one unchanged, stable registry.
        if (!(epoch & 1) && atomic_load_explicit(&g_range_epoch, memory_order_acquire) == epoch) {
            recent_spans[next_cache_slot & SPAN_CACHE_MASK] = (cached_span_t){
                .range = range,
                .base = base,
                .end = limit,
                .start_upper_bound = start_upper_bound,
                .end_lower_bound = end_lower_bound,
                .epoch = epoch,
            };
            next_cache_slot++;
        }
        return range;
    }
    return NULL;
}
// find_span for a reader outside g_slot_mu: the range pinned (the caller unpins it), trying the caller's kept range first. NULL = untracked, or retired at every try
static range_t *pin_span(range_t *kept, uintptr_t a, size_t len) {
    range_t *r = pin_holding(kept, a, len);
    for (int tries = 0; !r && tries < 4; tries++) { range_t *f = find_span(a, len); if (!f) return NULL; r = pin_holding(f, a, len); }
    return r;
}
static inline void last_max(range_t *r, uint64_t g) { uint64_t c = atomic_load(&r->last); while (c < g && !atomic_compare_exchange_weak(&r->last, &c, g)) {} }   // atomics only: the fault path calls it
static void stamp_page(range_t *r, uintptr_t p) {
    uint64_t g = atomic_fetch_add(&g_now, 1) + 1;
    atomic_store(&r->gen[p], g); last_max(r, g);   // last before the clock moves again below: a checker that read the clock before this sees it moved and looks again
    // Publish completion after the generation: a checker may have cached "clean" using the incremented clock before the generation store. Both fault and host-write paths
    // must invalidate that cached clock, as the page stays writable until the next upload protects it again. The range's own sequence moves with it (wseq: a value of the clock no other store takes)
    atomic_store(&r->wseq, atomic_fetch_add(&g_now, 1) + 1);
}
static _Atomic uint64_t g_sparse_writes;   // writes to pages protected for a placement sparse tile (nvn_dirty_sparse_writes)
static void sparse_note(range_t *r, uintptr_t p) { _Atomic uint8_t *sp = atomic_load(&r->sparse); if (sp && atomic_exchange(&sp[p], 0)) atomic_fetch_add(&g_sparse_writes, 1); }
static void unprotect_page(range_t *r, uintptr_t p) {   // The caller has already changed the state from PROT to BUSY
    mp(rb(r) + (p << g_shift), g_pg, PROT_READ | PROT_WRITE);
    stamp_page(r, p); sparse_note(r, p);
    atomic_store(&r->state[p], PG_NONE);
}
// Take a protected or open page for unprotecting (-> BUSY): 1 = taken; 0 = not, with the state found in *st
static int take_page(range_t *r, uintptr_t p, uint8_t *st) {
    *st = PG_PROT;
    if (atomic_compare_exchange_strong(&r->state[p], st, PG_BUSY)) return 1;
    return *st == PG_OPEN && atomic_compare_exchange_strong(&r->state[p], st, PG_BUSY);
}
// Unprotect one page of a range: if protected, unprotect and stamp it; if another thread is changing its protection, wait for it to finish and look again -- if the other side was setting read-only, the page is PROT after the wait and still has to be unprotected
// (an unprotect-before-write never reaches the fault handler, so it must be done here). Returns 1 = this page was protected by this module and is writable now; 0 = it was already NONE or the wait on BUSY timed out
static int release_page(range_t *r, uintptr_t p, _Atomic uint64_t *count) {
    for (;;) {
        uint8_t st;
        if (take_page(r, p, &st)) { unprotect_page(r, p); if (count) atomic_fetch_add(count, 1); return 1; }
        if (st != PG_BUSY) return 0;   // already NONE: either another thread just unprotected it (on_fault checks page_writable), or a read-only protection is not this module's (claiming it would loop forever)
        if (!busy_wait(r, p)) return 0;
    }
}
// Address index of the live ranges for the fault hook and the host pre-write hook (DM_NVN_DIRTY_INDEX, on by default; =0 scans every slot as before). Both hooks scanned every slot
// in use: Ocarina of Time takes about 1.28 M write faults a run (~49 a frame) with about 5,000 pools live, each fault reading every slot's start and end on the faulting game thread
// (NX18-X2.0 oot-alldata-analysis.md, item 9). The index lists each live range as (start, end, slot), sorted by start, with the largest end of each entry and those before it
// (maxend): the ranges holding an address are found by a binary search for the last start at or below it and a walk back while maxend is past it, so overlapping ranges (adjacent
// pools share their rounded first / last host page; nested ones too) are all found, as the scan found them. It only names candidates: each is checked as before (live, pinned, its
// own start and end), so a stale entry is passed over and the claims are the scan's.
// Two buffers, rewritten under g_slot_mu by registration and retirement only (a whole copy with the one change, O(n), no sort): the change goes into the buffer readers are not
// pointed at, which then becomes current. A reader in the signal handler takes no lock and never waits for the writer: each buffer has a sequence (odd while written), and a read
// whose sequence moved (a reader still in the buffer two changes later) is made again. Buffers are reserved once for MAX_RANGE entries (virtual, only the pages used are touched)
// and never freed, so a reader can never touch freed memory; every load of an entry is atomic (relaxed) and bounded by the capacity, so a torn read is harmless and then discarded.
// No malloc, no lock, no Objective-C on the read side. A reader that cannot get a stable read in a few tries, or finds more than IDX_HITS candidates, scans the slots as before.
// Staleness: a range is in the index before nvn_dirty_add_range returns, so before anything protects a page of it; a fault read against an older index that finds no claim
// goes through on_fault's retry below (a protection change of this module since its scan began: scanned again, the index read again)
typedef struct { _Atomic uintptr_t base, end, maxend; _Atomic uint32_t slot; } ient_t;
typedef struct { _Atomic uint64_t seq; _Atomic uint32_t n; ient_t *e; } idx_t;
static idx_t g_idx[2];
static _Alignas(128) _Atomic int g_idx_cur;     // the buffer readers use
static _Atomic int g_idx_on;      // set (release) once both buffers exist and the index lists every live range; read by the hooks (acquire)
static int g_idx_mode = -1;       // DM_NVN_DIRTY_INDEX, read at the first registration (after env.txt is applied); g_slot_mu held
static _Atomic uint64_t g_idx_edits, g_idx_ticks;   // index rewrites and their time (mach ticks), for the benchmark
static inline uintptr_t ild(_Atomic uintptr_t *v) { return atomic_load_explicit(v, memory_order_relaxed); }
static inline void ist(_Atomic uintptr_t *v, uintptr_t x) { atomic_store_explicit(v, x, memory_order_relaxed); }
// Slots whose indexed range overlaps [a, e), at most IDX_HITS of them, in hit[]: how many; -1 when the index cannot answer (off, changing under every try, or too many). Usable in the signal handler
static int idx_find(uintptr_t a, uintptr_t e, uint32_t *hit) {
    if (!atomic_load_explicit(&g_idx_on, memory_order_acquire)) return -1;
    for (int tries = 0; tries < IDX_TRIES; tries++) {
        idx_t *x = &g_idx[atomic_load_explicit(&g_idx_cur, memory_order_acquire) & 1];
        uint64_t s = atomic_load_explicit(&x->seq, memory_order_acquire);
        if (s & 1) continue;
        uint32_t n = atomic_load_explicit(&x->n, memory_order_relaxed); if (n > MAX_RANGE) continue;
        uint32_t lo = 0, hi = n;   // the first entry starting at or past e
        while (lo < hi) { uint32_t m = lo + (hi - lo) / 2; if (ild(&x->e[m].base) < e) lo = m + 1; else hi = m; }
        int k = 0, over = 0;
        for (uint32_t j = lo; j-- > 0; ) {
            if (ild(&x->e[j].maxend) <= a) break;   // neither this entry nor any before it reaches a
            if (ild(&x->e[j].end) > a) { if (k == IDX_HITS) { over = 1; break; } hit[k++] = atomic_load_explicit(&x->e[j].slot, memory_order_relaxed); }
        }
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&x->seq, memory_order_relaxed) != s) continue;
        return over ? -1 : k;
    }
    return -1;
}
// Rewrite the index with range slot added (add = 1: [base, end)) or taken out (add = 0). g_slot_mu held, so the current buffer does not change under it
static void idx_edit(int add, uint32_t slot, uintptr_t base, uintptr_t end) {
    if (!atomic_load_explicit(&g_idx_on, memory_order_relaxed)) return;
    uint64_t t = mach_absolute_time();
    int c = atomic_load_explicit(&g_idx_cur, memory_order_relaxed) & 1;
    idx_t *src = &g_idx[c], *dst = &g_idx[!c];
    uint32_t n = atomic_load_explicit(&src->n, memory_order_relaxed), m = 0;
    uint64_t s = atomic_load_explicit(&dst->seq, memory_order_relaxed);
    atomic_store_explicit(&dst->seq, s + 1, memory_order_relaxed);   // odd: a reader still in it reads again
    atomic_thread_fence(memory_order_release);
    uintptr_t mx = 0; int put = !add;
    for (uint32_t i = 0; i <= n; i++) {
        uintptr_t b = i < n ? ild(&src->e[i].base) : UINTPTR_MAX; uint32_t sl = i < n ? atomic_load_explicit(&src->e[i].slot, memory_order_relaxed) : 0;
        if (!put && (b > base || (b == base && sl > slot) || i == n)) {   // the new entry, before the first that sorts after it
            put = 1; mx = end > mx ? end : mx;
            ist(&dst->e[m].base, base); ist(&dst->e[m].end, end); ist(&dst->e[m].maxend, mx); atomic_store_explicit(&dst->e[m].slot, slot, memory_order_relaxed); m++;
        }
        if (i == n) break;
        if (!add && sl == slot) continue;   // the entry taken out
        uintptr_t en = ild(&src->e[i].end); mx = en > mx ? en : mx;
        ist(&dst->e[m].base, b); ist(&dst->e[m].end, en); ist(&dst->e[m].maxend, mx); atomic_store_explicit(&dst->e[m].slot, sl, memory_order_relaxed); m++;
    }
    atomic_store_explicit(&dst->n, m, memory_order_relaxed);
    atomic_store_explicit(&dst->seq, s + 2, memory_order_release);
    atomic_store_explicit(&g_idx_cur, !c, memory_order_release);
    atomic_fetch_add_explicit(&g_idx_ticks, mach_absolute_time() - t, memory_order_relaxed); atomic_fetch_add_explicit(&g_idx_edits, 1, memory_order_relaxed);
}
// At the first registration (g_slot_mu held): read the switch and, on, reserve both buffers. The index then starts empty, as the table does
static void idx_init(void) {
    if (g_idx_mode >= 0) return;
    const char *v = getenv("DM_NVN_DIRTY_INDEX"); g_idx_mode = !(v && !strcmp(v, "0"));
    if (!g_idx_mode) return;
    size_t bytes = (size_t)MAX_RANGE * sizeof(ient_t);
    for (int k = 0; k < 2; k++) {
        void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p == MAP_FAILED) { LOG("[RED] dirty-page tracking: the address index could not be reserved (%zu bytes), scanning every range instead", bytes); g_idx_mode = 0; return; }
        g_idx[k].e = p;
    }
    atomic_store_explicit(&g_idx_on, 1, memory_order_release);
}
// The kernel's protection of the host page at a now: writable (and not executable). One vm_region call, made only for a fault no range claimed
static int page_writable(uintptr_t a) {
    vm_address_t pg = a & ~(g_pg - 1), va = pg; vm_size_t vs = 0; vm_region_basic_info_data_64_t bi; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &va, &vs, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&bi, &cnt, &obj) != KERN_SUCCESS || va > pg) return 0;
    return (bi.protection & (VM_PROT_WRITE | VM_PROT_EXECUTE)) == VM_PROT_WRITE;
}
// A write that faulted on a protected page may be handled only after a pool over it was retired: nvn_dirty_remove_range makes the pages writable, then drops the range, and the
// scan then found no range to claim the fault, so the crash handler stopped the host on a write that was the tracker's (t_dirty_reuse). So a fault no range claims is re-executed
// when the page is writable by now; and when it is not, but a protection change of this module ran during the scan (a pool registered over the page and protected it, say),
// the scan runs again. Only a scan and look with no change of this module during them hands the fault on as not ours (the next hook, or the crash path)
// Release slot i's page at a when its range is live and holds a (the scan's test, also for an index candidate: a stale entry fails it)
static int fault_slot(int i, uintptr_t a) {
    range_t *r = rg(i); int ours = 0;
    if (live_at(i) && a >= rb(r) && a < re(r) && pin(r)) { if (a >= rb(r) && a < re(r)) ours = release_page(r, (a - rb(r)) >> g_shift, &g_faults); unpin(r); }
    return ours;
}
static _Alignas(128) _Atomic uint64_t g_fault_calls, g_fault_ticks;   // write faults the hook was called for (claimed or not) and the time spent in it (mach ticks): nvn_dirty_fault_stats
static int on_fault_(uintptr_t a) {
    for (int tries = 0; tries < 1000; tries++) {
        uint64_t done = atomic_load(&g_mp_done); int ours = 0;
        uint32_t hit[IDX_HITS]; int k = idx_find(a, a + 1, hit), n = atomic_load(&g_nr);   // an indexed slot is below g_nr (counted before it is indexed)
        if (k >= 0) { for (int j = 0; j < k; j++) if ((int)hit[j] < n) ours |= fault_slot((int)hit[j], a); }
        else for (int i = 0; i < n; i++) ours |= fault_slot(i, a);   // Every range sharing the page must be released: releasing only one leaves the other range's state at "protected", and later writes no longer fault and are missed
        if (ours) return 1;
        if (page_writable(a)) return 1;
        if (atomic_load(&g_mp_begun) == done) return 0;   // none begun since the scan began, none in flight then: the page's protection is not this module's
    }
    return 0;
}
static int on_fault(void *addr, int is_write, void *uc) {
    (void)uc;
    if (!is_write) return 0;
    uint64_t t = mach_absolute_time();
    int ours = on_fault_((uintptr_t)addr);
    atomic_fetch_add_explicit(&g_fault_ticks, mach_absolute_time() - t, memory_order_relaxed); atomic_fetch_add_explicit(&g_fault_calls, 1, memory_order_relaxed);
    return ours;
}
// Unprotect pages p..q of a range with one mprotect per run of protected pages (a host write over a whole texture, e.g. WriteTexels, used to make one system call per 16 KB page:
// Link's Awakening, about 275 a frame). Pages another thread is changing are handled one by one after the run so far is finished, so no BUSY page is held while waiting
static void release_pages(range_t *r, uintptr_t p, uintptr_t q, _Atomic uint64_t *count) {
    uintptr_t run = 0; int open = 0;
    for (uintptr_t i = p; i <= q + 1; i++) {
        uint8_t st = PG_NONE; int took = i <= q && take_page(r, i, &st);
        if (took) { if (!open) { run = i; open = 1; } continue; }
        if (open) {
            mp(rb(r) + (run << g_shift), (i - run) << g_shift, PROT_READ | PROT_WRITE);
            for (uintptr_t k = run; k < i; k++) { stamp_page(r, k); sparse_note(r, k); atomic_store(&r->state[k], PG_NONE); }
            if (count) atomic_fetch_add(count, i - run);
            open = 0;
        }
        if (i <= q && st == PG_BUSY) release_page(r, i, count);   // another thread is changing it: wait, then unprotect it if it ended up protected
    }
}
static void prep_slot(int i, uintptr_t a, uintptr_t e) {
    range_t *r = rg(i);
    if (!live_at(i) || e <= rb(r) || a >= re(r) || !pin(r)) return;
    uintptr_t base = rb(r), end = re(r);   // pinned: these hold until the unpin
    if (e > base && a < end) {
        uintptr_t lo = a > base ? a : base, hi = e < end ? e : end;
        release_pages(r, (lo - base) >> g_shift, (hi - 1 - base) >> g_shift, &g_preps);
    }
    unpin(r);
}
static void prep_write(void *addr, size_t len) {
    uintptr_t a = (uintptr_t)addr, e = a + len;
    if (!len) return;
    uint32_t hit[IDX_HITS]; int k = idx_find(a, e, hit), n = atomic_load(&g_nr);   // the ranges overlapping the write, by the address index; else every slot
    if (k >= 0) { for (int j = 0; j < k; j++) if ((int)hit[j] < n) prep_slot((int)hit[j], a, e); }
    else for (int i = 0; i < n; i++) prep_slot(i, a, e);
}

// Page geometry, the timebase and both hooks are set when the host loads, on one thread before main: every pool registration, fault and host pre-write sees them complete.
// They were set by the first nvn_dirty_add_range behind a plain flag, published before the geometry and the hooks and with no lock: a pool registered on another thread
// at that moment could get zero geometry or return before the hooks existed, and a host write into guest memory (hle_fs.c reading a file on a game thread) read crash.c's
// hook table while it grew (PR #2225). With no pool registered the hooks scan an empty table, so a game that never makes one pays nothing for them.
// The fault hook is now registered before DM_PROBE_WATCH's (probe.c), so a watched page inside a tracked pool reaches the dirty hook first
__attribute__((constructor)) static void dirty_init(void) {
    g_pg = (uintptr_t)getpagesize(); g_shift = __builtin_ctzl(g_pg); mach_timebase_info(&g_tb);
    dm_fault_hook_register(on_fault); dm_guest_write_prep_register(prep_write);
}

void nvn_dirty_add_range(const void *mem, size_t size) {
    atomic_fetch_add(&g_adds_total, 1);
    pthread_mutex_lock(&g_slot_mu);
    idx_init();
    int n = atomic_load(&g_nr);
    int slot = -1;
    for (int i = 0; i < n; i++) if (!live_at(i)) { slot = i; break; }
    if (slot < 0) {
        if (n >= MAX_RANGE) {
            int expected = 0;
            if (atomic_compare_exchange_strong(&g_overflow_logged, &expected, 1)) LOG("[RED] dirty-page tracking ranges are full (%d), pool %p not tracked", MAX_RANGE, mem);
            pthread_mutex_unlock(&g_slot_mu); return;
        }
        slot = n;
        if (!atomic_load_explicit(&g_blk[n >> BLK_SHIFT], memory_order_acquire)) {   // published before g_nr counts the slot (the scans read g_nr first)
            range_t *b = calloc(BLK, sizeof *b); if (!b) die("dirty-page tracking range table allocation failed (block %d)", n >> BLK_SHIFT);
            atomic_store_explicit(&g_blk[n >> BLK_SHIFT], b, memory_order_release);
        }
    }
    atomic_fetch_add(&g_range_epoch, 1);
    { int lv = atomic_fetch_add(&g_live, 1) + 1, pk = atomic_load(&g_live_peak); while (lv > pk && !atomic_compare_exchange_weak(&g_live_peak, &pk, lv)) {} }
    range_t *r = rg(slot);
    while (atomic_load(&r->pins)) sched_yield();   // a reader that found the retired pool live still uses its fields (pin); one in the fault hook may wait out a BUSY page (BUSY_WAIT_MS at most)
    uintptr_t base = (uintptr_t)mem & ~(g_pg - 1), end = ((uintptr_t)mem + size + g_pg - 1) & ~(g_pg - 1);
    size_t np = (end - base) >> g_shift;
    _Atomic uint8_t *state = r->state;
    _Atomic uint64_t *gen = r->gen, *pgen = r->pgen;
    if (r->cap < np) {
        free((void *)state); free((void *)gen); free((void *)pgen); free((void *)atomic_load(&r->sparse));   // no reader holds them: none is pinned, and a reader pins before it reads the pointers
        state = calloc(np, 1); gen = calloc(np, sizeof *gen); pgen = calloc(np, sizeof *pgen);
        if (!state || !gen || !pgen) die("dirty-page table allocation failed (%zu pages)", np);
        atomic_store(&r->sparse, NULL);   // sized for the old cap
        r->cap = np;
    } else {
        memset((void *)state, 0, np); memset((void *)gen, 0, np * sizeof *gen); memset((void *)pgen, 0, np * sizeof *pgen);
        _Atomic uint8_t *sp = atomic_load(&r->sparse); if (sp) memset((void *)sp, 0, np);
    }
    atomic_store_explicit(&r->base, base, memory_order_relaxed); atomic_store_explicit(&r->end, end, memory_order_relaxed); r->mem = (uintptr_t)mem; r->state = state; r->gen = gen; r->pgen = pgen;
    atomic_store(&r->last, 0); atomic_store_explicit(&r->born, atomic_fetch_add(&g_now, 1) + 1, memory_order_relaxed); atomic_store(&r->wseq, atomic_fetch_add(&g_now, 1) + 1);   // published by the release store of live below; stamps taken from now on are past it
    if (slot == n) atomic_store(&g_nr, n + 1);
    atomic_store_explicit(&r->live, 1, memory_order_release);
    idx_edit(1, (uint32_t)slot, base, end);   // indexed before this returns, so before any page of it is protected
    atomic_fetch_add(&g_range_epoch, 1);
    pthread_mutex_unlock(&g_slot_mu);
}
// Pool destruction: first restore still-protected pages to writable (the pool memory may be reused for something else once returned to the game), then mark invalid
void nvn_dirty_remove_range(const void *mem) {
    pthread_mutex_lock(&g_slot_mu);
    range_t *r = NULL; int n = atomic_load(&g_nr), slot = -1;
    for (int i = 0; i < n && !r; i++) if (live_at(i) && rg(i)->mem == (uintptr_t)mem) { r = rg(i); slot = i; }   // Match by the pool's exact start: an adjacent pool sharing a page may have the same rounded base
    if (r) {
        atomic_fetch_add(&g_range_epoch, 1);
        prep_write((void *)rb(r), re(r) - rb(r));
        atomic_store(&r->live, 0);   // seq_cst: against pin (the reuse in add_range reads the pin count)
        atomic_store(&r->wseq, atomic_fetch_add(&g_now, 1) + 1);   // a reader's kept wseq no longer holds (nvn_dirty_since_seq)
        idx_edit(0, (uint32_t)slot, 0, 0);
        atomic_fetch_sub(&g_live, 1);
        atomic_fetch_add(&g_range_epoch, 1);
    }
    pthread_mutex_unlock(&g_slot_mu);
}
// A zero-copy Metal buffer made while any of its pages is read-only drops every GPU write through it, with no error, even to pages never protected and even once its pages are writable again;
// one made over writable pages keeps working when they are protected later (M4 Pro probe; LEGO Star Wars: The Skywalker Saga's font copies inside its 1.4 GB pool, issue #1591). So the protected
// pages of [addr, addr + len) are opened for the buffer: nvn_dirty_open makes them writable without counting them as written, the buffer is made, and nvn_dirty_close protects them again and
// counts as written only the pages whose bytes changed meanwhile (a write to an open page does not fault, so their hash before and after is what sees it). Counting every opened page as written
// (2d544e0d) read every packaged texture there again, though nothing wrote it: 34 on Ocarina of Time's village walk, 4,038 in its first load on a contributor's build that makes chunks there,
// and storage the GPU drew into lost its content (LEGO's 3D picture went black). A host write to an open page takes it as a protected one (stamped, left writable, not protected again). No protection starts between open and close:
// protection and pool retirement wait meanwhile (g_slot_mu, under which a page cannot become protected); the page-fault path takes no lock and is not held up
typedef struct { range_t *r; uintptr_t p; uint64_t h; } open_pg;
static open_pg *g_open; static size_t g_nopen, g_copen;   // the pages nvn_dirty_open opened, by range and then page; g_slot_mu held
static _Atomic uint64_t g_opened, g_open_changed;
static uint64_t page_hash(const void *page) {   // xxHash64's rounds over a page's four lanes: a change to any word changes it, and changes to several cancel only by chance (2^-64)
    const uint64_t P1 = 0x9E3779B185EBCA87ull, P2 = 0xC2B2AE3D27D4EB4Full, *w = page;
    uint64_t a = P1 + P2, b = P2, c = 0, d = -P1;
    for (size_t i = 0, n = g_pg / 8; i < n; i += 4) {
        a = __builtin_rotateleft64(a + w[i] * P2, 31) * P1; b = __builtin_rotateleft64(b + w[i + 1] * P2, 31) * P1;
        c = __builtin_rotateleft64(c + w[i + 2] * P2, 31) * P1; d = __builtin_rotateleft64(d + w[i + 3] * P2, 31) * P1;
    }
    uint64_t h = __builtin_rotateleft64(a, 1) + __builtin_rotateleft64(b, 7) + __builtin_rotateleft64(c, 12) + __builtin_rotateleft64(d, 18);
    h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P1; return h ^ (h >> 32);
}
static void open_add(range_t *r, uintptr_t p, uint64_t h) {
    if (g_nopen == g_copen) {
        size_t cap = g_copen ? 2 * g_copen : 1024; open_pg *grown = realloc(g_open, cap * sizeof *g_open);
        if (!grown) die("dirty-page tracking: out of memory for %zu open pages", cap);
        g_open = grown; g_copen = cap;
    }
    g_open[g_nopen++] = (open_pg){r, p, h};
}
void nvn_dirty_open(const void *addr, size_t len) {
    pthread_mutex_lock(&g_slot_mu);
    g_nopen = 0;
    uintptr_t a = (uintptr_t)addr, e = a + len; int n = atomic_load(&g_nr);
    // Every range's protected pages are hashed and taken before any page is opened, so each hash is of a read-only page: adjacent pools share their first / last host page, and opening one
    // range's pages before hashing the next let a write to the shared page into that range's first hash, which then matched at the close (the write missed; t_dirty_race open_shared_page).
    // The taken pages stay BUSY meanwhile: a fault or host write on one waits for the open below, and neither holds a BUSY page of its own while it waits
    for (int k = 0; len && k < n; k++) {
        range_t *r = rg(k);
        if (!live_at(k) || e <= rb(r) || a >= re(r)) continue;
        uintptr_t lo = a > rb(r) ? a : rb(r), hi = e < re(r) ? e : re(r), p = (lo - rb(r)) >> g_shift, q = (hi - 1 - rb(r)) >> g_shift;
        for (uintptr_t i = p; i <= q; i++) {
            uint8_t st = atomic_load(&r->state[i]);
            if (st == PG_PROT) {
                uint64_t h = page_hash((const void *)(rb(r) + (i << g_shift)));
                if (atomic_compare_exchange_strong(&r->state[i], &st, PG_BUSY)) open_add(r, i, h);
            }
            if (st == PG_BUSY) busy_wait(r, i);   // another thread's unprotect: it finishes without taking g_slot_mu or waiting for another page
        }
    }
    for (size_t j = 0; j < g_nopen; ) {
        range_t *r = g_open[j].r; size_t s = j++;
        while (j < g_nopen && g_open[j].r == r && g_open[j].p == g_open[s].p + (j - s)) j++;
        mp(rb(r) + (g_open[s].p << g_shift), (j - s) << g_shift, PROT_READ | PROT_WRITE);
        for (size_t k = s; k < j; k++) atomic_store(&r->state[g_open[k].p], PG_OPEN);
    }
    atomic_fetch_add(&g_opened, g_nopen);
}
void nvn_dirty_close(void) {
    size_t changed = 0;
    for (size_t j = 0; j < g_nopen; ) {
        // A run: one range's consecutive pages still open. A page a host write took meanwhile (stamped, left writable) ends the run and is left as it is
        range_t *r = g_open[j].r; size_t s = j;
        for (uint8_t st = PG_OPEN; j < g_nopen && g_open[j].r == r && g_open[j].p == g_open[s].p + (j - s) && atomic_compare_exchange_strong(&r->state[g_open[j].p], &st, PG_BUSY); st = PG_OPEN) j++;
        if (j == s) { j++; continue; }
        mp(rb(r) + (g_open[s].p << g_shift), (j - s) << g_shift, PROT_READ);   // protected again first: a write from here on faults as usual, and the bytes stay as hashed below
        for (size_t k = s; k < j; k++) atomic_store(&r->state[g_open[k].p], PG_PROT);
        for (size_t k = s; k < j; k++)
            if (page_hash((const void *)(rb(r) + (g_open[k].p << g_shift))) != g_open[k].h) { stamp_page(r, g_open[k].p); atomic_store(&r->pgen[g_open[k].p], atomic_load(&g_now)); sparse_note(r, g_open[k].p); changed++; }
    }
    atomic_fetch_add(&g_open_changed, changed);
    g_nopen = 0;
    pthread_mutex_unlock(&g_slot_mu);
}
void nvn_dirty_open_stats(uint64_t *opened, uint64_t *changed) { *opened = atomic_load(&g_opened); *changed = atomic_load(&g_open_changed); }
int nvn_dirty_tracked(const void *addr, size_t len) {
    return find_span((uintptr_t)addr, len) != NULL;
}
// The tracked range holding [addr, addr+len), as a handle a caller keeps (packaged textures: the scan over every range ran twice per texture lookup). NULL = untracked
const void *nvn_dirty_span(const void *addr, size_t len) { return len ? find_span((uintptr_t)addr, len) : NULL; }
// Set read-only: mark the pages BUSY first and mark them PROT only after mprotect has landed (for the order and the invariant see the state notes at the top of the file)
void nvn_dirty_protect(const void *addr, size_t len) {
    // Keep this descriptor live through the last mprotect. Retirement restores
    // RW under this same mutex; it must not finish between lookup and PG_BUSY.
    pthread_mutex_lock(&g_slot_mu);
    range_t *r = len ? find_span((uintptr_t)addr, len) : NULL;
    if (!r) { pthread_mutex_unlock(&g_slot_mu); return; }
    uintptr_t a = (uintptr_t)addr, p = (a - rb(r)) >> g_shift, q = (a + len - 1 - rb(r)) >> g_shift;
    // Consecutive pages are merged into one mprotect (per-page calls reach thousands per frame on the first upload of large textures; character select page startup frame 5: 4888 calls).
    // Pages already PROT / BUSY break the consecutive run: do not protect again, and do not touch pages another thread is changing.
    // A BUSY page is waited out (the run so far is protected first, so none of ours is BUSY meanwhile) and looked at again: an unprotect in progress leaves the page writable
    // with a generation the caller's stamp may cover, so skipped, its later writes never faulted and the texture stayed stale (MacNativeGames a166602)
    uintptr_t run = 0; int open = 0;
    for (uintptr_t i = p; i <= q + 1; i++) {
        uint8_t st = PG_NONE;
        int took = i <= q && atomic_compare_exchange_strong(&r->state[i], &st, PG_BUSY);
        if (took && !open) { run = i; open = 1; }
        if (!took && open) { mp(rb(r) + (run << g_shift), (i - run) << g_shift, PROT_READ); uint64_t now = atomic_load(&g_now);
            for (uintptr_t k = run; k < i; k++) { if (atomic_load(&r->gen[k])) atomic_store(&r->pgen[k], now); atomic_store(&r->state[k], PG_PROT); } open = 0; }   // pgen: a page written before (never-written pages hide nothing)
        if (!took && i <= q && st == PG_BUSY && busy_wait(r, i)) i--;   // this page again
    }
    pthread_mutex_unlock(&g_slot_mu);
}
// As nvn_dirty_protect, for the pages behind a placement sparse tile: a write to one of them moves nvn_dirty_sparse_writes, which nothing else moves, so its textures need no look at their tiles
// until one is written (the page table's walk per look is what this replaces; nvn_mtl.m sparse_look)
void nvn_dirty_protect_sparse(const void *addr, size_t len) {
    nvn_dirty_protect(addr, len);
    pthread_mutex_lock(&g_slot_mu);
    range_t *r = len ? find_span((uintptr_t)addr, len) : NULL;
    if (r) {
        _Atomic uint8_t *sp = atomic_load(&r->sparse);
        if (!sp) { sp = calloc(r->cap, 1); atomic_store(&r->sparse, sp); }
        if (sp) for (uintptr_t i = ((uintptr_t)addr - rb(r)) >> g_shift, q = ((uintptr_t)addr + len - 1 - rb(r)) >> g_shift; i <= q; i++) atomic_store(&sp[i], 1);
    }
    pthread_mutex_unlock(&g_slot_mu);
}
uint64_t nvn_dirty_sparse_writes(void) { return atomic_load(&g_sparse_writes); }
uint64_t nvn_dirty_now(void) { return atomic_load(&g_now); }
void nvn_dirty_tick(void) { atomic_fetch_add(&g_now, 1); }   // no page is stamped: what compares the clock with a kept value looks again
// As nvn_dirty_since, with the caller's last range kept in *span (rechecked, scanned again only if it no longer holds the span; a slot reused by another pool over the same memory
// holds it too, and a stamp older than that pool's registration then counts as written: born): a packaged texture keeps its handle (the scan over every range ran twice per texture lookup), and a sparse texture's page-table walk (hle_nvn.c vpt_walk) asks once per run of
// physical pages, which mostly lie in one pool, where find_span scans every registered range (about 4,300 in a Mario Kart World race)
int nvn_dirty_since_cached(const void **span, const void *addr, size_t len, uint64_t stamp) {
    if (!len) return 0;
    uintptr_t a = (uintptr_t)addr; range_t *r = pin_span((range_t *)*span, a, len); *span = r;
    if (!r) return 1;   // When untracked, conservatively treat as dirty: better to upload more than to show stale content
    int w = stamp < atomic_load_explicit(&r->born, memory_order_relaxed);   // checked before this pool was registered over the memory: what was written there in between left no generation (born)
    uintptr_t p = (a - rb(r)) >> g_shift, q = (a + len - 1 - rb(r)) >> g_shift;
    for (uintptr_t i = p; i <= q && !w; i++) w = atomic_load(&r->gen[i]) > stamp;   // The generation of the last write before upload is <= the stamp; any later write must be > the stamp
    unpin(r);
    return w;
}
int nvn_dirty_since_span(const void *span, const void *addr, size_t len, uint64_t stamp) { return nvn_dirty_since_cached(&span, addr, len, stamp); }
// nvn_dirty_since_span answered from the range's largest write generation when it is not past the stamp (as nvn_dirty_since_last), and, when clean, the range's write sequence as it was
// before the pages were read: *wp the sequence (NULL when written, untracked or not answered clean), *w its value. While *wp reads w, nothing was written to the range since this answer:
// every generation store moves it after the store (stamp_page), so a store this look did not see moves it past w for good (each value is a fresh one of the clock), and so do the
// range's removal and its registration over other memory. A texture ID keeps the pair to skip its next look (nvn_mtl.m tex_by_id, DM_NVN_TEX_SEQ)
int nvn_dirty_since_seq(const void *span, const void *addr, size_t len, uint64_t stamp, const void **wp, uint64_t *w) {
    *wp = NULL; *w = 0;
    if (!len) return 0;
    uintptr_t a = (uintptr_t)addr; range_t *r = pin_span((range_t *)span, a, len);
    if (!r) return 1;   // untracked: dirty, as nvn_dirty_since_cached
    uint64_t s = atomic_load(&r->wseq);   // before the pages are read: a store they miss moves it after
    int wr = stamp < atomic_load_explicit(&r->born, memory_order_relaxed);   // (born, as nvn_dirty_since_cached)
    if (!wr && atomic_load(&r->last) > stamp) {
        uintptr_t p = (a - rb(r)) >> g_shift, q = (a + len - 1 - rb(r)) >> g_shift;
        for (uintptr_t i = p; i <= q && !wr; i++) wr = atomic_load(&r->gen[i]) > stamp;
    }
    if (!wr) { *wp = (const void *)&r->wseq; *w = s; }   // the slot's memory stays for the run (range blocks are never freed)
    unpin(r);
    return wr;
}
// As nvn_dirty_since_cached, answered from the range's largest write generation (last) when nothing in the whole range was written after the stamp: a sparse texture's runs of physical
// memory (hle_nvn.c nvn_sparse_since_runs, nvn_mtl.m pkg_sparse_clean) mostly lie in pools the game does not write between two looks, and each run read every page's generation
int nvn_dirty_since_last(const void **span, const void *addr, size_t len, uint64_t stamp) {
    if (!len) return 0;
    uintptr_t a = (uintptr_t)addr; range_t *r = pin_span((range_t *)*span, a, len); *span = r;
    if (!r) return 1;   // untracked: dirty, as nvn_dirty_since_cached
    int w = stamp < atomic_load_explicit(&r->born, memory_order_relaxed);   // (born, as there)
    if (!w && atomic_load(&r->last) > stamp) {
        uintptr_t p = (a - rb(r)) >> g_shift, q = (a + len - 1 - rb(r)) >> g_shift;
        for (uintptr_t i = p; i <= q && !w; i++) w = atomic_load(&r->gen[i]) > stamp;
    }
    unpin(r);
    return w;
}
int nvn_dirty_since(const void *addr, size_t len, uint64_t stamp) { return nvn_dirty_since_span(NULL, addr, len, stamp); }
// Whether a reader that needs the writes made up to `limit` must read the span again, given content read at `stamp` with its pages protected by then (pnow: the clock after that protect).
// A page counts if its first write since the protect came at or before limit, or if a write to it may have been hidden since pnow (pgen: protected again after a write by another upload,
// or changed while open), or if the span is untracked or the range was registered after the stamp (born). A page whose first write since is past limit, with nothing hidden, had no write
// up to limit: the writes made later in it reach a later reader. The packaged textures' coalesced re-uploads (nvn_mtl.m reup_needed)
int nvn_dirty_needed(const void *span, const void *addr, size_t len, uint64_t stamp, uint64_t pnow, uint64_t limit) {
    if (!len) return 0;
    uintptr_t a = (uintptr_t)addr; range_t *r = pin_span((range_t *)span, a, len);
    if (!r) return 1;
    int w = stamp < atomic_load_explicit(&r->born, memory_order_relaxed) || !pnow;
    uintptr_t p = (a - rb(r)) >> g_shift, q = (a + len - 1 - rb(r)) >> g_shift;
    for (uintptr_t i = p; i <= q && !w; i++) { uint64_t g = atomic_load(&r->gen[i]); w = g > stamp && (g <= limit || atomic_load(&r->pgen[i]) > pnow); }
    unpin(r);
    return w;
}
// A page counts unless it holds a byte of an excepted range: a write the caller accounts for itself and judges any other write into those pages (none can be told from it by
// the page's generation). nvn_mtl.m's DM_NVN_REUPLOADS line counts with no exception
size_t nvn_dirty_since_except(const void *span, const void *addr, size_t len, uint64_t stamp, const uintptr_t (*ex)[2], int nex, uintptr_t *first) {
    if (!len) return 0;
    uintptr_t a = (uintptr_t)addr; range_t *r = pin_span((range_t *)span, a, len);
    if (!r) return SIZE_MAX;
    uintptr_t p = (a - rb(r)) >> g_shift, q = (a + len - 1 - rb(r)) >> g_shift; size_t n = 0; int before = stamp < atomic_load_explicit(&r->born, memory_order_relaxed);   // every page counts (born)
    for (uintptr_t i = p; i <= q; i++) {
        if (!before && atomic_load(&r->gen[i]) <= stamp) continue;
        uintptr_t lo = rb(r) + (i << g_shift), hi = lo + g_pg; int mine = 0;
        for (int k = 0; k < nex && !mine; k++) mine = ex[k][0] < hi && ex[k][1] > lo;
        if (mine) continue;
        if (!n++ && first) *first = lo < a ? a : lo;
    }
    unpin(r);
    return n;
}
void nvn_dirty_slot_stats(int *live, int *used_slots, uint64_t *adds_total) {
    int n = atomic_load(&g_nr), active = 0;
    for (int i = 0; i < n; i++) active += live_at(i) != 0;
    *live = active; *used_slots = n; *adds_total = atomic_load(&g_adds_total);
}
void nvn_dirty_fault_stats(uint64_t *calls, uint64_t *ns) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    *calls = atomic_load_explicit(&g_fault_calls, memory_order_relaxed); *ns = atomic_load_explicit(&g_fault_ticks, memory_order_relaxed) * tb.numer / tb.denom;
}
int nvn_dirty_index_on(void) { return atomic_load(&g_idx_on); }
void nvn_dirty_stats(uint64_t *faults, uint64_t *preps) { *faults = atomic_load(&g_faults); *preps = atomic_load(&g_preps); }
void nvn_dirty_mp_stats(uint64_t *calls, uint64_t *pages, uint64_t *ns) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    *calls = atomic_load(&g_mp_calls); *pages = atomic_load(&g_mp_pages); *ns = atomic_load(&g_mp_ticks) * tb.numer / tb.denom;
}
