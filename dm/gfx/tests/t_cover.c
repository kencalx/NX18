// nvn_cover.h: whether a draw's triangles cover every pixel centre of its target (the geometric half of DM_NVN_COVERED_LOAD's proof). The full-screen triangle and quad in
// their usual shapes (both windings, either way up, as a list and a strip) are proven; a quad short of an edge by a fraction of a pixel, half a screen, w other than 1, z past
// the clip range with the clip on, a NaN, two triangles whose shared edge differs by one bit, a non-convex pair and unsupported vertex counts are not (negative controls).
// Then a soundness sweep: random triangles and pairs on small targets, each pixel centre tested exactly; nothing the proof accepts may leave a centre uncovered. Last, the cost
// of one proof (it runs once a pass a draw opens, when the cheaper checks pass).
#include "../nvn/nvn_cover.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

// Pixel centre (x, y) inside triangle a b c (closed: on an edge counts, the fill rule gives it to one side), in the same window mapping as nvn_cover_full
static int in_tri(const float a[4], const float b[4], const float c[4], double x, double y, uint32_t tw, uint32_t th) {
    double ax = (a[0] + 1.0) * 0.5 * tw, ay = (a[1] + 1.0) * 0.5 * th, bx = (b[0] + 1.0) * 0.5 * tw, by = (b[1] + 1.0) * 0.5 * th, cx = (c[0] + 1.0) * 0.5 * tw, cy = (c[1] + 1.0) * 0.5 * th;
    double d1 = (bx - ax) * (y - ay) - (by - ay) * (x - ax), d2 = (cx - bx) * (y - by) - (cy - by) * (x - bx), d3 = (ax - cx) * (y - cy) - (ay - cy) * (x - cx);
    int neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(neg && pos);
}
static int brute(const float p[][4], int n, int strip, uint32_t tw, uint32_t th) {
    int nt = strip ? n - 2 : n / 3;
    for (uint32_t y = 0; y < th; y++) for (uint32_t x = 0; x < tw; x++) { int hit = 0;
        for (int t = 0; t < nt && !hit; t++) { int i = strip ? t : 3 * t; hit = in_tri(p[i], p[i + 1], p[i + 2], x + 0.5, y + 0.5, tw, th); }
        if (!hit) return 0; }
    return 1;
}
static float rnd(float lo, float hi) { return lo + (hi - lo) * (float)rand() / (float)RAND_MAX; }

int main(void) {
    const float tri[3][4] = {{-1, -1, .5f, 1}, {3, -1, .5f, 1}, {-1, 3, .5f, 1}}, tri_cw[3][4] = {{-1, -1, .5f, 1}, {-1, 3, .5f, 1}, {3, -1, .5f, 1}};
    const float tri_up[3][4] = {{-1, 1, 0, 1}, {3, 1, 0, 1}, {-1, -3, 0, 1}};
    const float quad[6][4] = {{-1, -1, 0, 1}, {1, -1, 0, 1}, {1, 1, 0, 1}, {-1, -1, 0, 1}, {1, 1, 0, 1}, {-1, 1, 0, 1}};
    const float strip[4][4] = {{-1, -1, 0, 1}, {1, -1, 0, 1}, {-1, 1, 0, 1}, {1, 1, 0, 1}};
    CHECK(nvn_cover_full(tri, 3, 0, 1920, 1080, 1), "the full-screen triangle");
    CHECK(nvn_cover_full(tri_cw, 3, 0, 1920, 1080, 1), "the full-screen triangle, other winding");
    CHECK(nvn_cover_full(tri_up, 3, 0, 2880, 1620, 1), "the full-screen triangle, other way up");
    CHECK(nvn_cover_full(tri, 3, 1, 1, 1, 1), "a one-pixel target");
    CHECK(nvn_cover_full(quad, 6, 0, 1920, 1080, 1), "the full-screen quad, two listed triangles");
    CHECK(nvn_cover_full(strip, 4, 1, 1280, 720, 1), "the full-screen quad as a strip");
    CHECK(nvn_cover_full(tri, 3, 0, 4096, 16, 1), "a long thin target");
    {   float t[6][4]; memcpy(t, tri, sizeof tri); memcpy(t[3], quad[0], 3 * sizeof t[0]);
        CHECK(nvn_cover_full((const float (*)[4])t, 6, 0, 640, 360, 1), "a list whose first triangle covers alone"); }
    // negative controls
    {   float q[6][4]; memcpy(q, quad, sizeof q); q[1][0] = q[2][0] = q[4][0] = .999f;
        CHECK(!nvn_cover_full((const float (*)[4])q, 6, 0, 1920, 1080, 1), "a quad 0.96 px short of the right edge"); }
    {   const float half[3][4] = {{-1, -1, 0, 1}, {1, -1, 0, 1}, {-1, 1, 0, 1}}; CHECK(!nvn_cover_full(half, 3, 0, 64, 64, 1), "half the screen"); }
    {   float t[3][4]; memcpy(t, tri, sizeof t); t[1][3] = 2; CHECK(!nvn_cover_full((const float (*)[4])t, 3, 0, 64, 64, 1), "w other than 1"); }
    {   float t[3][4]; memcpy(t, tri, sizeof t); t[0][2] = 1.5f; CHECK(!nvn_cover_full((const float (*)[4])t, 3, 0, 64, 64, 1), "z past the far plane with the depth clip on");
        CHECK(nvn_cover_full((const float (*)[4])t, 3, 0, 64, 64, 0), "z past the far plane with the depth clip off"); t[0][2] = -0.25f;
        CHECK(!nvn_cover_full((const float (*)[4])t, 3, 0, 64, 64, 1), "z before the near plane with the depth clip on"); }
    {   float t[3][4]; memcpy(t, tri, sizeof t); t[2][1] = NAN; CHECK(!nvn_cover_full((const float (*)[4])t, 3, 0, 64, 64, 1), "a NaN position"); }
    {   float q[6][4]; memcpy(q, quad, sizeof q); q[4][0] = nextafterf(1.0f, 2.0f);   // the shared edge's end, one bit apart: the pair is not proven to be watertight
        CHECK(!nvn_cover_full((const float (*)[4])q, 6, 0, 64, 64, 1), "a shared edge one bit apart"); }
    {   const float dart[6][4] = {{-1, -1, 0, 1}, {1, -1, 0, 1}, {0, 0, 0, 1}, {-1, -1, 0, 1}, {0, 0, 0, 1}, {-1, 1, 0, 1}};
        CHECK(!nvn_cover_full(dart, 6, 0, 64, 64, 1), "a non-convex pair"); }
    {   const float bow[4][4] = {{-1, -1, 0, 1}, {1, -1, 0, 1}, {1, 1, 0, 1}, {-1, 1, 0, 1}};   // as a strip: the lower right and upper right halves, the wedge on the left left open
        CHECK(!nvn_cover_full(bow, 4, 1, 64, 64, 1), "a strip in quad order (half the screen)"); }
    CHECK(!nvn_cover_full(strip, 4, 0, 64, 64, 1) && !nvn_cover_full(quad, 5, 1, 64, 64, 1) && !nvn_cover_full(tri, 2, 0, 64, 64, 1), "vertex counts other than 3 / 6 (list), 3 / 4 (strip)");
    CHECK(!nvn_cover_full(tri, 3, 0, 0, 64, 1), "an empty target");
    {   const float huge[3][4] = {{-1, -1, .5f, 1}, {1e6f, -1, .5f, 1}, {-1, 1e6f, .5f, 1}}, big[3][4] = {{-1, -1, .5f, 1}, {15, -1, .5f, 1}, {-1, 15, .5f, 1}};
        CHECK(!nvn_cover_full(huge, 3, 0, 2880, 1620, 1), "a triangle far past the guard band (clipping's float error not bounded)");
        CHECK(nvn_cover_full(big, 3, 0, 2880, 1620, 1), "a large triangle inside the bound"); }
    // soundness: shapes near the screen's edges, the proof never accepts one that leaves a pixel centre uncovered
    srand(12345); int accepted = 0, sweeps = 0, unsound = 0;
    for (int it = 0; it < 200000; it++) {
        uint32_t tw = 1 + (uint32_t)(rand() % 24), th = 1 + (uint32_t)(rand() % 24); int kind = rand() % 3, strip_ = kind == 2, n = kind == 0 ? 3 : kind == 1 ? 6 : 4;
        float p[6][4];
        for (int i = 0; i < n; i++) { float e = rnd(-0.08f, 0.08f); int big = rand() % 4 == 0;
            p[i][0] = (rand() & 1 ? 1 : -1) * (big ? 3 : 1) + e; p[i][1] = (rand() & 1 ? 1 : -1) * (big ? 3 : 1) + rnd(-0.08f, 0.08f); p[i][2] = .5f; p[i][3] = 1; }
        if (kind == 1 && rand() % 2) { memcpy(p[3], p[0], sizeof p[0]); memcpy(p[4], p[2], sizeof p[0]); }   // a shared edge, as quads are drawn
        int ok = nvn_cover_full((const float (*)[4])p, n, strip_, tw, th, 1); sweeps++;
        if (ok) { accepted++; if (!brute((const float (*)[4])p, n, strip_, tw, th)) unsound++; }
    }
    CHECK(unsound == 0, "no accepted shape leaves a pixel centre uncovered");
    CHECK(accepted > 1000, "the sweep accepts enough shapes to mean something");
    printf("soundness sweep: %d shapes, %d proven, %d proven but not covering\n", sweeps, accepted, unsound);
    // cost of one proof (the quad, two triangles, the slowest path)
    {   struct timespec a, b; volatile int sink = 0; const int N = 2000000;
        clock_gettime(CLOCK_MONOTONIC, &a); for (int i = 0; i < N; i++) sink += nvn_cover_full(quad, 6, 0, 1920 + (uint32_t)(i & 1), 1080, 1); clock_gettime(CLOCK_MONOTONIC, &b);
        double ns = ((b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec)) / N;
        clock_gettime(CLOCK_MONOTONIC, &a); for (int i = 0; i < N; i++) sink += nvn_cover_full(tri, 3, 0, 1920 + (uint32_t)(i & 1), 1080, 1); clock_gettime(CLOCK_MONOTONIC, &b);
        double ns3 = ((b.tv_sec - a.tv_sec) * 1e9 + (b.tv_nsec - a.tv_nsec)) / N;
        printf("cost: %.1f ns a quad proof, %.1f ns a triangle proof (%d)\n", ns, ns3, sink != 0); }
    printf("cover: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
