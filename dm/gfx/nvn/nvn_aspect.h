// Ultrawide's camera: the HUD kept in shape over a wider camera (nvn_mtl.m aspect_canvas_learn, draw_). A build with camera stubs (CAMERA_ASPECT: Breath of the Wild 1.9.0,
// Tears of the Kingdom 1.4.3; loader.c dm_game_aspect) draws a wider view into its 16:9 picture, which the front end's Stretch widens over the screen. The HUD and menus are drawn
// into that same picture, so they would be widened too: their quads on the final picture are squeezed about the middle of its content by 16:9 / the ratio instead, and come
// out at their own shape in the middle 16:9 band. The final picture is the last depth-free, level-0, 16:9 colour target (packed RGB10A2 or floating point) drawn before a pass on a window
// texture; on a floating-point one (Tears of the Kingdom's) only the profile's HUD vertex shaders (game.tsv aspect_ui_prefixes) are squeezed. Six-index quads only: the
// scene's full-screen triangles and quads that sample a GPU-drawn 16:9 picture (the menus' blurred scene) keep the whole width. Plain C, tested by t_aspect.
//
// Adapted from ComicBit/nxnative eb9a42ba4 / 76f085084 / a2f038d3f (MIT), whose UI squeeze was adapted from MacNativeGames' totk_ui_squeeze.h / nvn_mtl.m:
// Copyright (c) 2026 MacNativeGames contributors, MIT license (https://github.com/ly05010419/MacNativeGames).
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software
// without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
// persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#pragma once
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

typedef struct { double x, y, w, h; } nvn_aspect_rect;

// A colour target that can be the final picture: 16:9 within 1 %, at least 640 wide, level 0, no depth attachment, a packed or floating-point format (format_ok)
static inline int nvn_aspect_canvas_candidate(double w, double h, unsigned level, int depth, int format_ok) {
    return format_ok && w >= 640 && h > 0 && fabs(w / h * 9 / 16 - 1) < 0.01 && level == 0 && !depth;
}

// Whether a vertex shader's key starts with one of the profile's 8-digit prefixes (space-separated; empty: none), decided once when the shader loads
static inline int nvn_aspect_ui_prefix(const char *key, const char *prefixes) {
    if (!key || !prefixes) return 0;
    for (const char *p = prefixes; *p; ) {
        while (*p == ' ') p++;
        size_t n = strcspn(p, " ");
        if (n == 8 && !strncmp(key, p, 8)) return 1;
        p += n;
    }
    return 0;
}

// A packed final picture's quads are all HUD; a floating-point one's only those of the profile's HUD shaders
static inline int nvn_aspect_ui_shader(int float_canvas, int layout_shader) { return !float_canvas || layout_shader; }

// A draw on the final picture that is squeezed: six indices (a quad), not a GPU-drawn scene picture
static inline int nvn_aspect_ui_draw(int canvas, unsigned count, int scene_picture) { return canvas && count == 6 && !scene_picture; }

// The horizontal squeeze for a camera ratio (dm_game_aspect): 16:9 / ratio, 1 for the game's own 16:9 or narrower
static inline double nvn_aspect_ui_scale(double ratio) {
    double f = ratio > 0 && isfinite(ratio) ? ratio / (16.0 / 9.0) : 1;
    return f > 1.001 ? 1 / f : 1;
}

// A viewport or scissor rectangle squeezed by sx about x = cx (the middle of the picture's content: nvn_aspect_canvas.cx)
static inline nvn_aspect_rect nvn_aspect_ui_rect(nvn_aspect_rect r, double cx, double sx) {
    return (nvn_aspect_rect){cx + (r.x - cx) * sx, r.y, r.w * sx, r.h};
}

// The window textures presented lately (present_enqueue, one presenting thread; read from any thread), with the part of each the present shows across (its crop's x and width;
// Breath of the Wild handheld shows 1280 of its 1920-wide window textures): a pass on one of them follows the final picture
enum { NVN_ASPECT_WINS = 8 };
typedef struct { _Atomic uint64_t ser[NVN_ASPECT_WINS]; _Atomic uint32_t span[NVN_ASPECT_WINS], tw[NVN_ASPECT_WINS]; unsigned next; } nvn_aspect_wins;
// A present of window texture ser (tw wide) showing x .. x + w across (w <= 0: the whole width)
static inline void nvn_aspect_win_note(nvn_aspect_wins *w, uint64_t ser, uint32_t tw, int x, int cw) {
    if (!ser) return;
    uint32_t span = cw > 0 && x >= 0 && (uint64_t)x + (uint64_t)cw <= tw && tw <= 0xffff ? (uint32_t)x << 16 | (uint32_t)cw : 0;
    int k = -1;
    for (int i = 0; i < NVN_ASPECT_WINS; i++) if (atomic_load_explicit(&w->ser[i], memory_order_relaxed) == ser) { k = i; break; }
    if (k < 0) { k = (int)(w->next++ % NVN_ASPECT_WINS); atomic_store_explicit(&w->ser[k], 0, memory_order_release); }
    atomic_store_explicit(&w->span[k], span, memory_order_relaxed); atomic_store_explicit(&w->tw[k], tw, memory_order_relaxed);
    atomic_store_explicit(&w->ser[k], ser, memory_order_release);
}
// Whether ser is a window texture presented lately; *span its crop across (x << 16 | w, 0: the whole width) and *tw its width
static inline int nvn_aspect_is_win(nvn_aspect_wins *w, uint64_t ser, uint32_t *span, uint32_t *tw) {
    if (!ser) return 0;
    for (int i = 0; i < NVN_ASPECT_WINS; i++) if (atomic_load_explicit(&w->ser[i], memory_order_acquire) == ser) {
        if (span) *span = atomic_load_explicit(&w->span[i], memory_order_relaxed);
        if (tw) *tw = atomic_load_explicit(&w->tw[i], memory_order_relaxed);
        return 1;
    }
    return 0;
}

// The final picture, learnt pass by pass (the renderer's thread): a candidate is remembered with its size; a pass on a window texture makes the last candidate the final
// picture, and a later candidate of the final picture's size takes its place at once (a target the game makes anew, which must be known before its HUD is drawn, not at the
// next window pass). cx: the middle of its content across, the HUD's centre: the window's crop when the picture is as wide as the window texture (the game copies it 1:1),
// else the picture's own middle. serial 0: none yet
typedef struct { uint64_t canvas, last; uint32_t w, h, last_w, last_h; double cx; } nvn_aspect_canvas;
static inline void nvn_aspect_canvas_pass(nvn_aspect_canvas *c, uint64_t ser, int window, uint32_t win_span, uint32_t win_w, int candidate, uint32_t w, uint32_t h) {
    if (window) {
        if (!c->last) return;
        c->canvas = c->last; c->w = c->last_w; c->h = c->last_h;
        c->cx = win_span && win_w == c->w ? (win_span >> 16) + (win_span & 0xffff) / 2.0 : c->w / 2.0;
        return;
    }
    if (!candidate) return;
    c->last = ser; c->last_w = w; c->last_h = h;
    if (c->canvas && w == c->w && h == c->h) c->canvas = ser;
}
