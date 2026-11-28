// Whether a draw's triangles cover every pixel of its target (nvn_mtl.m lcv_check, DM_NVN_COVERED_LOAD): the geometric half of the proof that the pass's first draw overwrites a
// colour attachment whole, so the attachment can load as DontCare. The positions are clip-space positions as the vertex shader outputs them (read from the vertex stream on
// the CPU: nvn_mtl.m lcv_positions); the caller has checked that the viewport is the whole target (either way up) and the scissor covers it. Plain C, tested by t_cover.
//
// A pixel is drawn when its centre lies inside a triangle (shared edges of two triangles with the same vertices are filled once, never left open: the rasterizer's fill rule).
// One triangle or the union of two that share an edge and make a convex quadrilateral is convex, and the smallest signed distance of a point to its edges is a concave
// function, so it is smallest at a corner of the rectangle of pixel centres: when the four corner centres lie inside by NVN_COVER_MARGIN, every centre does. The margin
// is far more than the rasterizer's fixed-point snapping of the vertices moves an edge. Anything else (more triangles, a non-convex pair, w other than exactly 1, z outside
// the clip range while the depth clip is on, a value not finite) is "not proven": the attachment keeps its load.
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>

#define NVN_COVER_MARGIN (1.0 / 16)   // pixels
#define NVN_COVER_XY_MAX 16.0f   // clip-space |x|, |y| bound (w = 1): full-screen shapes use 1 or 3; far past it the GPU's clipping and float viewport transform could move an edge by more than the margin

typedef struct { double x, y; } nvn_cover_pt;

// Twice the signed area of polygon v[0..n)
static inline double nvn_cover_area2(const nvn_cover_pt *v, int n) {
    double a = 0;
    for (int i = 0; i < n; i++) { const nvn_cover_pt *p = &v[i], *q = &v[(i + 1) % n]; a += p->x * q->y - q->x * p->y; }
    return a;
}
// Whether polygon v[0..n) is strictly convex and holds the four points q inside by at least m (either winding)
static inline int nvn_cover_holds(const nvn_cover_pt *v, int n, const nvn_cover_pt q[4], double m) {
    double a2 = nvn_cover_area2(v, n);
    if (!(fabs(a2) > 0) || !isfinite(a2)) return 0;
    double s = a2 > 0 ? 1 : -1;
    for (int i = 0; i < n; i++) {
        nvn_cover_pt a = v[i], b = v[(i + 1) % n], c = v[(i + 2) % n];
        double ex = b.x - a.x, ey = b.y - a.y, l = sqrt(ex * ex + ey * ey);
        if (!(l > 0) || !isfinite(l)) return 0;
        if (!(s * (ex * (c.y - a.y) - ey * (c.x - a.x)) > 0)) return 0;   // a turn the other way (or none) at b: not strictly convex
        for (int k = 0; k < 4; k++) if (!(s * (ex * (q[k].y - a.y) - ey * (q[k].x - a.x)) / l >= m)) return 0;
    }
    return 1;
}
// pos: n positions (x, y, z, w); strip: a triangle strip (n 3 or 4), else a triangle list (n 3 or 6); tw x th: the target and viewport; zclip: the depth clip is on (z must
// lie in [0, w]). 1 when every pixel centre of the target lies inside the triangles by NVN_COVER_MARGIN
static inline int nvn_cover_full(const float pos[][4], int n, int strip, uint32_t tw, uint32_t th, int zclip) {
    if (!tw || !th || (strip ? n != 3 && n != 4 : n != 3 && n != 6)) return 0;
    nvn_cover_pt p[6];
    for (int i = 0; i < n; i++) {
        const float *v = pos[i];
        if (!isfinite(v[0]) || !isfinite(v[1]) || !isfinite(v[2]) || v[3] != 1.0f) return 0;   // w exactly 1: no perspective, no clipping at w
        if (zclip && !(v[2] >= 0.0f && v[2] <= 1.0f)) return 0;   // inside the near and far planes, or the depth clip would cut it
        if (!(fabsf(v[0]) <= NVN_COVER_XY_MAX && fabsf(v[1]) <= NVN_COVER_XY_MAX)) return 0;   // a huge shape: not proven (NVN_COVER_XY_MAX)
        p[i].x = ((double)v[0] + 1) * 0.5 * tw; p[i].y = ((double)v[1] + 1) * 0.5 * th;   // the pixel centres are symmetric about the middle: either way up maps them onto themselves
    }
    const nvn_cover_pt q[4] = {{0.5, 0.5}, {tw - 0.5, 0.5}, {tw - 0.5, th - 0.5}, {0.5, th - 0.5}};
    if (n == 3) return nvn_cover_holds(p, 3, q, NVN_COVER_MARGIN);
    int A[3] = {0, 1, 2}, B[3] = {3, 4, 5};
    if (strip) { B[0] = 1; B[1] = 2; B[2] = 3; }
    nvn_cover_pt ta[3] = {p[A[0]], p[A[1]], p[A[2]]}, tb[3] = {p[B[0]], p[B[1]], p[B[2]]};
    if (nvn_cover_holds(ta, 3, q, NVN_COVER_MARGIN) || nvn_cover_holds(tb, 3, q, NVN_COVER_MARGIN)) return 1;
    // Two triangles sharing an edge: the same two positions, bit for bit (then the rasterizer fills the edge once), and one more each
    int sa[2], sb[2], ns = 0;
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) if (!memcmp(pos[A[i]], pos[B[j]], 4 * sizeof(float))) { if (ns == 2) return 0; sa[ns] = i; sb[ns] = j; ns++; }
    if (ns != 2 || sa[0] == sa[1] || sb[0] == sb[1]) return 0;
    int oa = 3 - sa[0] - sa[1], ob = 3 - sb[0] - sb[1];
    nvn_cover_pt quad[4] = {p[A[oa]], p[A[sa[0]]], p[B[ob]], p[A[sa[1]]]};   // a, shared 0, b, shared 1: strictly convex means a and b lie on opposite sides of the shared edge
    return nvn_cover_holds(quad, 4, q, NVN_COVER_MARGIN);
}
