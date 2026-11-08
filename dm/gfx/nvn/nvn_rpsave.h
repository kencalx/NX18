// Render-pass savings outside the TBDR mode (nvn_mtl.m; each behind its own switch, all off by default): the pure decisions, unit-tested in tests/t_rpsave.c without Metal.
//   DM_NVN_CLEAR_FMTMASK: a colour clear whose channel mask covers every channel the attached format has is a whole clear (a load action), not a triangle over a loaded target
//   DM_NVN_LOAD_COVER:    a colour load skipped when the draw that opens the pass provably writes every pixel of the attachment (nvn_cover.h), only when the attachment's level is the pass's size
//   DM_NVN_OMIT_UNWRITTEN: a colour attachment no draw of the pass writes is left out of the pass (not loaded, not stored, memory untouched), only when the pass keeps its size
#pragma once
#include <stdint.h>

// A colour clear outside a pass with the whole scissor: whole when its mask holds every channel the format has (channels a format lacks cannot be written either way, and the value
// is converted as for the 0xf mask, so the target ends up the same bit for bit). fmask: the format's channels (mtl_pf_chmask), 0 when unknown
static inline int nvn_clear_whole(unsigned mask, unsigned fmask, int in_pass, int scissor_full) {
    mask &= 0xf; fmask &= 0xf;
    return !in_pass && scissor_full && fmask && (mask & fmask) == fmask;
}
// The colour slots a draw writes, as the pipeline's write masks make them (pso_build: a slot is written when its channel mask nibble is not 0 and the fragment writes that output):
// no fragment stage, none; outputs not known, or anything that changes them (a specialized fragment, a merged pass's map, a logic operation, a geometry, tessellation or mesh stage), every
// slot whose nibble is not 0
static inline uint32_t nvn_rp_wmask(uint32_t chmask, int has_fs, int color_known, uint32_t color_mask, int unknown) {
    if (!has_fs) return 0;
    uint32_t out = unknown || !color_known ? 0xffu : color_mask, m = 0;
    for (int i = 0; i < 8; i++) if ((chmask >> (4 * i) & 0xf) && (out >> i & 1)) m |= 1u << i;
    return m;
}
// The slots of cand left out of a pass whose colour slots present have level sizes w[i] x h[i] (the depth plane dw x dh when has_d): a slot whose leaving out would make the pass larger
// (it is the only smallest attachment in either direction) stays, and at least one colour attachment stays. The pass covers the smallest of its attachments; a larger pass would let the
// draws reach pixels they did not reach before
static inline uint32_t nvn_rp_omit(uint32_t cand, uint32_t present, const unsigned long w[8], const unsigned long h[8], int has_d, unsigned long dw, unsigned long dh) {
    cand &= present;
    unsigned long fw = has_d ? dw : 0, fh = has_d ? dh : 0;
    for (int i = 0; i < 8; i++) if (present >> i & 1) { if (!fw || w[i] < fw) fw = w[i]; if (!fh || h[i] < fh) fh = h[i]; }
    uint32_t omit = 0;
    for (int i = 0; i < 8; i++) {
        if (!(cand >> i & 1)) continue;
        uint32_t keep = present & ~(omit | 1u << i);
        if (!keep) break;   // one colour attachment stays, depth or not: a pass whose depth then fails to attach would have none
        unsigned long rw = has_d ? dw : 0, rh = has_d ? dh : 0;
        for (int k = 0; k < 8; k++) if (keep >> k & 1) { if (!rw || w[k] < rw) rw = w[k]; if (!rh || h[k] < rh) rh = h[k]; }
        if (rw == fw && rh == fh) omit |= 1u << i;
    }
    return omit;
}
