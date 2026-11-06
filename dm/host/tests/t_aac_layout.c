// The console's channel order for a movie's AAC sound (../hle_movie_aac_order.h): plain C, no Apple framework, no game data. Each of CoreAudioTypes' AAC layout tags, as its
// header comment spells its labels, goes into MediaCodec's order (Android's channel-mask order, the WAVE order) with the same labels; layouts already in that order are
// left alone; a label with no place, a repeated one or a count past 8 keeps AudioToolbox's order; and any set of known labels in any order comes out as a permutation of
// itself in increasing place
#include "../hle_movie_aac_order.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

enum { L = AACL_LEFT, R = AACL_RIGHT, C = AACL_CENTER, LFE = AACL_LFE, Ls = AACL_LS, Rs = AACL_RS, Lc = AACL_LC, Rc = AACL_RC, Cs = AACL_CS, Lsd = AACL_LSD, Rsd = AACL_RSD,
       Ts = AACL_TS, Vhl = AACL_VHL, Vhc = AACL_VHC, Vhr = AACL_VHR, Tbl = AACL_TBL, Tbc = AACL_TBC, Tbr = AACL_TBR, Rls = AACL_RLS, Rrs = AACL_RRS };
typedef struct { const char *tag; uint32_t in[8], want[8]; int n, moved; } layout_case;
static const layout_case k_cases[] = {
    // CoreAudioBaseTypes.h: the AAC tags (kAudioChannelLayoutTag_AAC_*) as AudioToolbox may report them, and the console's order of the same labels
    {"AAC_3_0", {C, L, R}, {L, R, C}, 3, 1},
    {"AAC_Quadraphonic", {L, R, Ls, Rs}, {L, R, Ls, Rs}, 4, 0},
    {"AAC_4_0", {C, L, R, Cs}, {L, R, C, Cs}, 4, 1},
    {"AAC_5_0", {C, L, R, Ls, Rs}, {L, R, C, Ls, Rs}, 5, 1},
    {"AAC_5_1", {C, L, R, Ls, Rs, LFE}, {L, R, C, LFE, Ls, Rs}, 6, 1},              // = MPEG_5_1_A / WAVE_5_1_A: Android's 5.1, FL FR FC LFE BL BR
    {"AAC_6_0", {C, L, R, Ls, Rs, Cs}, {L, R, C, Cs, Ls, Rs}, 6, 1},
    {"AAC_6_1", {C, L, R, Ls, Rs, Cs, LFE}, {L, R, C, LFE, Cs, Ls, Rs}, 7, 1},       // = WAVE_6_1: L R C LFE Cs Ls Rs
    {"AAC_7_0", {C, L, R, Ls, Rs, Rls, Rrs}, {L, R, C, Rls, Rrs, Ls, Rs}, 7, 1},
    {"AAC_7_1", {C, Lc, Rc, L, R, Ls, Rs, LFE}, {L, R, C, LFE, Ls, Rs, Lc, Rc}, 8, 1},   // = MPEG_7_1_A: FL FR FC LFE BL BR FLC FRC
    {"AAC_7_1_B", {C, L, R, Ls, Rs, Rls, Rrs, LFE}, {L, R, C, LFE, Rls, Rrs, Ls, Rs}, 8, 1},   // = WAVE_7_1: Android's 7.1, FL FR FC LFE BL BR SL SR
    {"AAC_7_1_C", {C, L, R, Ls, Rs, LFE, Vhl, Vhr}, {L, R, C, LFE, Ls, Rs, Vhl, Vhr}, 8, 1},
    {"AAC_Octagonal", {C, L, R, Ls, Rs, Rls, Rrs, Cs}, {L, R, C, Rls, Rrs, Cs, Ls, Rs}, 8, 1},
    // already in the console's order: nothing to set
    {"MPEG_3_0_A", {L, R, C}, {L, R, C}, 3, 0},
    {"MPEG_5_1_A", {L, R, C, LFE, Ls, Rs}, {L, R, C, LFE, Ls, Rs}, 6, 0},
    {"WAVE_5_1_B", {L, R, C, LFE, Rls, Rrs}, {L, R, C, LFE, Rls, Rrs}, 6, 0},
    {"WAVE_7_1", {L, R, C, LFE, Rls, Rrs, Ls, Rs}, {L, R, C, LFE, Rls, Rrs, Ls, Rs}, 8, 0},
    {"MPEG_7_1_C", {L, R, C, LFE, Ls, Rs, Rls, Rrs}, {L, R, C, LFE, Rls, Rrs, Ls, Rs}, 8, 1},   // the rear pair is WAVE's back: Ls / Rs go to the side
    {"Stereo", {L, R}, {L, R}, 2, 0},
    {"Mono", {AACL_MONO}, {AACL_MONO}, 1, 0},
    {"direct surrounds", {C, L, R, Lsd, Rsd, LFE}, {L, R, C, LFE, Lsd, Rsd}, 6, 1},
    {"heights and top backs", {Tbr, Tbc, Tbl, Vhr, Vhc, Vhl, Ts, C}, {C, Ts, Vhl, Vhc, Vhr, Tbl, Tbc, Tbr}, 8, 1},
};
static void tags(void) {
    for (size_t i = 0; i < sizeof k_cases / sizeof *k_cases; i++) {
        const layout_case *c = &k_cases[i]; uint32_t out[8] = {0}; char a[64], b[64];
        int r = aac_wave_order(c->in, c->n, out);
        aac_labels_text(c->in, c->n, a, sizeof a); aac_labels_text(out, c->n, b, sizeof b);
        if (r != c->moved || memcmp(out, c->want, (size_t)c->n * sizeof *out)) { printf("%s: %s → %s (%d)\n", c->tag, a, b, r); assert(0); }
        printf("%-22s %-28s → %s%s\n", c->tag, a, b, r ? "" : " (as it is)");
    }
}
static void kept(void) {   // AudioToolbox's order stays: a label with no WAVE place, two in one place, no channels or more than 8
    uint32_t out[16] = {0}, before[16];
    const uint32_t wide[] = {C, 35, 36, L, R, Ls, Rs, LFE}, lfe2[] = {L, R, C, LFE, 37, Ls, Rs}, dup[] = {L, R, C, L}, same_place[] = {Ls, Rs, Lsd, Rsd, Cs, L, R},
                   unknown[] = {L, R, C, 0xffffffffu}, unused[] = {L, R, C, 0}, nine[] = {C, L, R, Ls, Rs, Rls, Rrs, LFE, Cs}, both_centres[] = {C, AACL_MONO, L, R};
    memcpy(before, out, sizeof out);
    assert(aac_wave_order(wide, 8, out) == -1);   // the wide pair (Lw Rw): Android's old masks have no place for it
    assert(aac_wave_order(lfe2, 7, out) == -1);
    assert(aac_wave_order(dup, 4, out) == -1);
    assert(aac_wave_order(same_place, 7, out) == -1);   // with a back centre Ls / Rs take the side places, which Lsd / Rsd hold
    assert(aac_wave_order(unknown, 4, out) == -1 && aac_wave_order(unused, 4, out) == -1);
    assert(aac_wave_order(nine, 9, out) == -1 && aac_wave_order(nine, 0, out) == -1);
    assert(aac_wave_order(both_centres, 4, out) == -1);
    assert(!memcmp(out, before, sizeof out));   // nothing written
    char t[64]; aac_labels_text(wide, 8, t, sizeof t); assert(!strcmp(t, "C Lw Rw L R Ls Rs LFE"));
    aac_labels_text(unknown, 4, t, sizeof t); assert(!strcmp(t, "L R C #4294967295"));
    aac_labels_text(unknown, 4, t, 6); assert(!strcmp(t, "L R C"));   // cut at the buffer's end, terminated
    aac_labels_text(unknown, 4, t, 1); assert(!t[0]);
    puts("kept as AudioToolbox gives it: wide pair, second LFE, repeats, unknown and unused labels, more than 8 channels");
}
static uint64_t g_rng = 0x9e3779b97f4a7c15ull;
static uint32_t rnd(uint32_t n) { g_rng ^= g_rng << 13; g_rng ^= g_rng >> 7; g_rng ^= g_rng << 17; return (uint32_t)(g_rng % n); }
static void any_order(void) {   // 200,000 random sets of known labels in random orders: a permutation of the input, in increasing place, 0 only when the input was
    static const uint32_t known[] = {L, R, C, LFE, Ls, Rs, Lc, Rc, Cs, Lsd, Rsd, Ts, Vhl, Vhc, Vhr, Tbl, Tbc, Tbr, Rls, Rrs, AACL_MONO};
    int counts[3] = {0};
    for (int t = 0; t < 200000; t++) {
        int n = 1 + (int)rnd(AAC_LAYOUT_MAX); uint32_t in[8], out[8];
        for (int i = 0; i < n; i++) { for (;;) { uint32_t l = known[rnd(sizeof known / sizeof *known)]; int seen = 0; for (int k = 0; k < i; k++) seen |= in[k] == l; if (!seen) { in[i] = l; break; } } }
        int r = aac_wave_order(in, n, out); counts[r + 1]++;
        if (r < 0) continue;
        int back = 0; for (int i = 0; i < n; i++) back |= in[i] == Rls || in[i] == Rrs || in[i] == Cs;
        int sorted = 1;
        for (int i = 0; i < n; i++) {
            int found = 0; for (int k = 0; k < n; k++) found += out[k] == in[i];
            assert(found == 1);
            if (i) { assert(aac_wave_place(out[i - 1], back) < aac_wave_place(out[i], back)); sorted &= aac_wave_place(in[i - 1], back) < aac_wave_place(in[i], back); }
        }
        assert(r == !sorted);
    }
    assert(counts[0] && counts[1] && counts[2]);
    printf("random layouts: %d reordered, %d already in order, %d kept (two labels in one place)\n", counts[2], counts[1], counts[0]);
}
int main(void) {
    tags();
    kept();
    any_order();
    puts("t_aac_layout: ok");
    return 0;
}
