// The address-space ceiling probe (../as_ceiling.h), on any machine: the binary search against devices that reserve up to a known size (none, less than a quarter GB, whole and
// odd sizes, everything up to the cap), how many reservations it asks for, the "which Mac-only games' blocks fit" text at the sizes that decide it, and with real mmap: the search
// leaves the address space as it found it, so the guest's block lands where it would have without it
#include "../as_ceiling.h"
#include <string.h>

static int checks, failed;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); checks++; if (w_ != g_) { fprintf(stderr, "%s: expected %lld, got %lld\n", name, w_, g_); failed++; } } while (0)
#define HAS(name, text, part) do { checks++; if (!strstr((text), (part))) { fprintf(stderr, "%s: \"%s\" not in \"%s\"\n", name, (part), (text)); failed++; } } while (0)

#define GB ((uint64_t)1 << 30)
typedef struct { uint64_t limit; int asked; uint64_t largest_asked; } fake;
static int fake_try(uint64_t bytes, void *ctx) { fake *f = ctx; f->asked++; if (bytes > f->largest_asked) f->largest_asked = bytes; return bytes <= f->limit; }
static void search(const char *name, uint64_t limit, uint64_t want) {
    fake f = {limit, 0, 0}; int tries = -1;
    uint64_t got = as_ceiling(fake_try, &f, AS_GRAN, AS_CAP, &tries);
    EXPECT(name, want, got);
    EXPECT("tries: what it says it asked", f.asked, tries);
    checks++; if (tries > 13) { fprintf(stderr, "%s: %d tries, more than 13\n", name, tries); failed++; }
    checks++; if (f.largest_asked > AS_CAP) { fprintf(stderr, "%s: asked for %llu bytes, past the cap\n", name, (unsigned long long)f.largest_asked); failed++; }
}

int main(void) {
    search("nothing fits", 0, 0);
    search("less than a quarter GB", AS_GRAN - 1, 0);
    search("a quarter GB", AS_GRAN, AS_GRAN);
    search("6 GB, an iPhone without Extended Virtual Addressing", 6 * GB, 6 * GB);
    search("7 GB less a page: 6.75 GB", 7 * GB - 16384, 6 * GB + 3 * AS_GRAN);
    search("21.25 GB", 0x550000000ull, 0x550000000ull);
    search("61.75 GB", 61 * GB + 3 * AS_GRAN, 61 * GB + 3 * AS_GRAN);
    search("everything up to the cap", UINT64_MAX, AS_CAP);
    { fake f = {UINT64_MAX, 0, 0}; int tries = 0; as_ceiling(fake_try, &f, AS_GRAN, AS_CAP, &tries); EXPECT("at the cap: one try", 1, tries); }
    { fake f = {UINT64_MAX, 0, 0}; EXPECT("a cap below one gran", 0, as_ceiling(fake_try, &f, AS_GRAN, AS_GRAN - 1, NULL)); EXPECT("a cap below one gran asks nothing", 0, f.asked); }
    { fake f = {9 * GB, 0, 0}; EXPECT("a failed reservation's search: up to what it asked", 9 * GB, as_ceiling(fake_try, &f, AS_GRAN, 21 * GB, NULL)); }

    char t[512];
    as_fit_text(6 * GB, t, sizeof t);
    HAS("6 GB: FC 27's 7 GB does not fit", t, "7.00 GB (EA SPORTS FC 27) does not fit");
    HAS("6 GB: one size, its three games", t, "21.25 GB (Splatoon Raiders, Fire Emblem Fortune's Weave, Star Fox) does not fit");
    HAS("6 GB: Mario Tennis Fever", t, "25.25 GB (Mario Tennis Fever) does not fit");
    as_fit_text(7 * GB, t, sizeof t);
    HAS("exactly 7 GB fits", t, "7.00 GB (EA SPORTS FC 27) fits; 21.25 GB");
    as_fit_text(0x550000000ull, t, sizeof t);
    HAS("exactly 21.25 GB fits", t, "Star Fox) fits; 25.25 GB (Mario Tennis Fever) does not fit");
    as_fit_text(AS_CAP, t, sizeof t);
    EXPECT("1 TB: all fit, each size once", 0, strcmp(t, "7.00 GB (EA SPORTS FC 27) fits; 21.25 GB (Splatoon Raiders, Fire Emblem Fortune's Weave, Star Fox) fits; 25.25 GB (Mario Tennis Fever) fits"));
    char small[20]; memset(small, 'x', sizeof small); as_fit_text(AS_CAP, small, 12);
    EXPECT("a short buffer is cut at its size", 11, strlen(small)); EXPECT("and not overrun", 'x', small[12]);

    // Real reservations: the guest's block (4 GB, as mem_init_once asks for it) lands at the same address after the search as before it
    size_t blk = (size_t)4 << 30;
    void *a = mmap(NULL, blk, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (a == MAP_FAILED) fprintf(stderr, "t_as_ceiling: this machine cannot reserve 4 GB; the real-mmap checks are skipped\n");
    else {
        munmap(a, blk);
        int tries = 0; uint64_t c = as_ceiling(as_try_mmap, NULL, AS_GRAN, AS_CAP, &tries);
        void *b = mmap(NULL, blk, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        EXPECT("the search leaves the guest's block where it was", (long long)(uintptr_t)a, (long long)(uintptr_t)b);
        if (b != MAP_FAILED) munmap(b, blk);
        checks++; if (c < blk) { fprintf(stderr, "real ceiling %llu below the 4 GB just reserved\n", (unsigned long long)c); failed++; }
        printf("t_as_ceiling: this machine reserves %s%.2f GB in one block (%d tries)\n", c >= AS_CAP ? "at least " : "", c / (double)GB, tries);
    }
    printf("t_as_ceiling: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
