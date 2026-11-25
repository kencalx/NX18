// Passes drawn every other frame (profile key pass_alternate, DM_NVN_PASS_ALT and DM_NVN_CUBE_ALT; nvn_mtl.m rp_begin_ex_ and the draw path). Donkey Kong Bananza draws a 128x128 view
// (RG11B10Float colour + Depth32Float) with 700 to 1,700 draws in some areas: 1.35 ms a frame at the phone's lower GPU clock (NX18-X2.0 gpu-clock-collapse.md). On every other frame its pass
// keeps the previous frame's picture: its clears become loads and its draws are dropped, except draws that count an occlusion query or may write memory. Only when the same target ran the
// frame before, so a view that comes and goes, or a texture that changes, always draws; a pass reopened within a frame keeps that frame's decision. The profile names passes by shape:
// <W>x<H>:<colour>/<depth> (a pass of that size and those Metal formats; its target is the texture) or cube:<colour> (a pass into any level and face of a cube or cube-array texture in that
// colour format, with no depth attachment: an environment cube's mip chain and filters; its target is the texture's level and first layer, so a game that updates one face or level a frame,
// never the same one two frames running, always draws it). Header only, for t_pass_alt
#pragma once
#include <stdint.h>
enum { PA_DRAW = 1, PA_KEEP = 2 };
typedef struct { uint64_t ser, frame; uint32_t sub; int dec; } pa_state;
// The decision for a pass on texture ser in frame: PA_DRAW or PA_KEEP (one target). gap: how many frames back its last drawing may be for this visit to keep it (1: only the frame
// before). A cube target takes PA_CUBE_GAP: a game that spreads its cube over a few frames comes back to each target every few frames (The Legend of Zelda: Ocarina of Time redraws
// faces 0-1, 2-3 and 4-5 of its environment cube, each with mip levels 1-7, on three frames in turn, and prefilters the second cube every third frame); each target then draws on every
// other visit, so the update runs at half its rate however the game spreads it, and a face is at most 2 x gap frames old. A target that comes back later than that draws
static inline int pa_decide_gap(pa_state *s, uint64_t ser, uint64_t frame, uint64_t gap) {
    if (s->dec && s->ser == ser && s->frame == frame) return s->dec;   // the same pass reopened (a split, or its clears landed in a pass of their own first)
    int keep = s->dec == PA_DRAW && s->ser == ser && frame > s->frame && frame - s->frame <= gap;   // drawn on its last visit, no more than gap frames before, on this texture
    s->ser = ser; s->frame = frame; s->dec = keep ? PA_KEEP : PA_DRAW; return s->dec;
}
static inline int pa_decide(pa_state *s, uint64_t ser, uint64_t frame) { return pa_decide_gap(s, ser, frame, 1); }
enum { PA_CUBE_GAP = 3 };
// Several targets at once (the cube passes of a frame: each level of each cube): one state per target (texture ser, sub: 0, or a cube pass's level << 16 | first layer), the oldest
// replaced when the table is full. A replaced target draws when it comes back, as a new one does
enum { PA_SLOTS = 128 };   // Ocarina of Time: 8 levels x 6 faces of its environment cube and its prefiltered cube's
typedef struct { pa_state s[PA_SLOTS]; unsigned next; } pa_table;
static inline int pa_decide_in(pa_table *t, uint64_t ser, uint32_t sub, uint64_t frame, uint64_t gap) {
    pa_state *e = 0;
    for (int i = 0; i < PA_SLOTS && !e; i++) if (t->s[i].dec && t->s[i].ser == ser && t->s[i].sub == sub) e = &t->s[i];
    if (!e) { e = &t->s[t->next++ % PA_SLOTS]; *e = (pa_state){.ser = ser, .sub = sub}; }
    return pa_decide_gap(e, ser, frame, gap);
}
// A profile's pass shapes (game.py: DM_GAME_PASS_ALT_SHAPES): w x h with colour format cfmt and depth format dfmt, or cube (w, h, dfmt 0): any cube or cube-array target in cfmt, no depth
typedef struct { int w, h, cfmt, dfmt, cube; } pa_shape;
// The shape a pass matches, or -1: its colour attachment 0's texture w x h in format cfmt, its depth attachment's format dfmt (0: none), is_cube: the texture is a cube or a cube array
static inline int pa_match(const pa_shape *sh, int n, int w, int h, int cfmt, int dfmt, int is_cube) {
    for (int i = 0; i < n; i++) {
        const pa_shape *s = &sh[i];
        if (s->cube ? is_cube && cfmt == s->cfmt && !dfmt : w == s->w && h == s->h && cfmt == s->cfmt && dfmt && dfmt == s->dfmt) return i;
    }
    return -1;
}
