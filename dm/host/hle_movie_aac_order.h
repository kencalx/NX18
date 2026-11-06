// The channel order of a movie's AAC sound (hle_movie.c md_aac_layout). The console's movie::Decoder wraps Android's MediaCodec (hle_movie.c, docs/reference/movies.md), and
// MediaCodec's AAC decoder hands out multichannel PCM in its output's channel-mask order, lowest bit first (android.media.AudioFormat: "The order of the bits (from lsb to
// msb) corresponds to the order of that position's sample in the audio frame"): FL FR FC LFE BL BR FLC FRC BC SL SR TC TFL TFC TFR TBL TBC TBR, the WAVE order. 5.1 is
// FL FR FC LFE BL BR (Android's C2SoftAacDec maskFromCount; FDK AAC's WAV channel mapping: front left, front right, center, LFE, surround left, surround right).
// AudioToolbox's converter hands out the order its output channel layout names, and AAC's own order puts the centre first (CoreAudioTypes: kAudioChannelLayoutTag_AAC_5_1 is
// C L R Ls Rs LFE). md_aac_layout reads that layout and, when its order is not the console's, sets kAudioConverterOutputChannelLayout to the same labels in the console's order:
// the labels stay the stream's, so the converter moves whole channels between slots and mixes nothing. Apple's labels take their WAVE places as Apple's own WAVE layout tags
// give them (CoreAudioBaseTypes.h: kAudioChannelLayoutTag_WAVE_5_1_A L R C LFE Ls Rs, WAVE_6_1 L R C LFE Cs Ls Rs, WAVE_7_1 L R C LFE Rls Rrs Ls Rs): Ls / Rs are the back
// pair while the stream has no other back channel, else the side pair. A stream with a label that has no WAVE place (the wide pair, a second LFE, a discrete or unknown
// channel) or two labels in one place keeps AudioToolbox's order. Plain C, so dm/host/tests/t_aac_layout.c runs it on any machine
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

// Apple's AudioChannelLabel values (CoreAudioTypes, CoreAudioBaseTypes.h) that have a WAVE place; hle_movie.c checks each against the SDK's
enum {
    AACL_LEFT = 1, AACL_RIGHT = 2, AACL_CENTER = 3, AACL_LFE = 4, AACL_LS = 5, AACL_RS = 6, AACL_LC = 7, AACL_RC = 8, AACL_CS = 9, AACL_LSD = 10, AACL_RSD = 11,
    AACL_TS = 12, AACL_VHL = 13, AACL_VHC = 14, AACL_VHR = 15, AACL_TBL = 16, AACL_TBC = 17, AACL_TBR = 18, AACL_RLS = 33, AACL_RRS = 34, AACL_MONO = 42,
};
enum { AAC_LAYOUT_MAX = 8 };   // AAC's channel configurations 1 to 7, 11, 12 and 14 have at most 8 channels; a converter reporting more keeps its order

// The WAVE place (Android's channel-mask bit, from 0 = front left) of a label in a stream that has (back) or has not another back channel than Ls / Rs; -1 for none
static inline int aac_wave_place(uint32_t label, int back) {
    switch (label) {
    case AACL_LEFT: return 0;
    case AACL_RIGHT: return 1;
    case AACL_CENTER: case AACL_MONO: return 2;
    case AACL_LFE: return 3;
    case AACL_LS: return back ? 9 : 4;   // 5.1's Ls / Rs are WAVE's back pair; beside rear surrounds or a back centre they are its side pair
    case AACL_RS: return back ? 10 : 5;
    case AACL_RLS: return 4;
    case AACL_RRS: return 5;
    case AACL_LC: return 6;
    case AACL_RC: return 7;
    case AACL_CS: return 8;
    case AACL_LSD: return 9;
    case AACL_RSD: return 10;
    case AACL_TS: return 11;
    case AACL_VHL: return 12;
    case AACL_VHC: return 13;
    case AACL_VHR: return 14;
    case AACL_TBL: return 15;
    case AACL_TBC: return 16;
    case AACL_TBR: return 17;
    default: return -1;
    }
}
// The stream's labels in (in[i]: the channel AudioToolbox puts in slot i) → the console's order out. 1: out differs from in (the layout to set), 0: the same order already
// (nothing to set), -1: a label has no WAVE place, two share one, or n is 0 or above AAC_LAYOUT_MAX (AudioToolbox's order is kept). out is written only for 1 and 0
static inline int aac_wave_order(const uint32_t *in, int n, uint32_t *out) {
    if (n <= 0 || n > AAC_LAYOUT_MAX) return -1;
    int back = 0;
    for (int i = 0; i < n; i++) back |= in[i] == AACL_RLS || in[i] == AACL_RRS || in[i] == AACL_CS;
    uint32_t at[18] = {0};   // the label at each WAVE place, 0 for none
    for (int i = 0; i < n; i++) {
        int p = aac_wave_place(in[i], back);
        if (p < 0 || at[p]) return -1;
        at[p] = in[i];
    }
    int k = 0, moved = 0;
    for (int p = 0; p < 18; p++) if (at[p]) { moved |= in[k] != at[p]; out[k++] = at[p]; }
    return moved;
}
// A label's name in the log (CoreAudioBaseTypes.h's short names, its TopBack ones as Tbl / Tbc / Tbr); "#<value>" for any other
static inline const char *aac_label_name(uint32_t label, char *tmp, size_t cap) {
    static const char *const k[] = {[AACL_LEFT] = "L", [AACL_RIGHT] = "R", [AACL_CENTER] = "C", [AACL_LFE] = "LFE", [AACL_LS] = "Ls", [AACL_RS] = "Rs", [AACL_LC] = "Lc",
        [AACL_RC] = "Rc", [AACL_CS] = "Cs", [AACL_LSD] = "Lsd", [AACL_RSD] = "Rsd", [AACL_TS] = "Ts", [AACL_VHL] = "Vhl", [AACL_VHC] = "Vhc", [AACL_VHR] = "Vhr",
        [AACL_TBL] = "Tbl", [AACL_TBC] = "Tbc", [AACL_TBR] = "Tbr", [AACL_RLS] = "Rls", [AACL_RRS] = "Rrs", [35] = "Lw", [36] = "Rw", [37] = "LFE2", [AACL_MONO] = "M"};
    if (label < sizeof k / sizeof *k && k[label]) return k[label];
    snprintf(tmp, cap, "#%u", (unsigned)label);
    return tmp;
}
// The labels as the log names them, space-separated ("C L R Ls Rs LFE")
static inline void aac_labels_text(const uint32_t *l, int n, char *buf, size_t cap) {
    size_t at = 0; char tmp[16];
    if (cap) buf[0] = 0;
    for (int i = 0; i < n && at + 1 < cap; i++) {
        int w = snprintf(buf + at, cap - at, "%s%s", i ? " " : "", aac_label_name(l[i], tmp, sizeof tmp));
        if (w < 0) break;
        at += (size_t)w < cap - at ? (size_t)w : cap - at - 1;
    }
}
