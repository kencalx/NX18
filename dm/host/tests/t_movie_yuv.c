// The movie pictures' NEON loops (hle_movie_yuv.h; DM_MOVIE_NEON=0 turns them off) against the scalar code they replaced, byte for byte: md_rgba over every Y, U, V for both ranges
// and both matrices, then random pictures (odd sizes, padded strides, crops and padding, every colour space value, both ranges, heights about the 720-line rule), the NV12 chroma
// split of hle_codec_video.c and the red / blue swap of hle_movie.c. Planes and outputs end at an inaccessible page, so reading or writing past the old code's last byte stops the test.
// Without NEON (x86) the scalar loops alone are checked against the old code. Needs no game profile: make -C dm/host/tests build/t_movie_yuv && dm/host/tests/build/t_movie_yuv [seed]
#include "../hle_movie_yuv.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__aarch64__)
#define NEON_RUNS 1
#else
#define NEON_RUNS 0
#endif
#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "t_movie_yuv: FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); exit(1); } } while (0)

// md_rgba as it was before the NEON loop (hle_movie.c), unchanged
static void old_rgba(const vpx_image_t *im, uint8_t *dst, int w, int h) {
    int full = im->range == VPX_CR_FULL_RANGE, b709 = im->cs == VPX_CS_BT_709 || (im->cs == VPX_CS_UNKNOWN && h >= 720);
    double ky = full ? 1.0 : 255.0 / 219.0, kc = full ? 1.0 : 255.0 / 224.0;
    double rv = b709 ? 1.5748 : 1.402, gu = b709 ? 0.1873 : 0.3441, gv = b709 ? 0.4681 : 0.7141, bu = b709 ? 1.8556 : 1.772;
    int Y = (int)(ky * 65536), RV = (int)(rv * kc * 65536), GU = (int)(gu * kc * 65536), GV = (int)(gv * kc * 65536), BU = (int)(bu * kc * 65536), y0 = full ? 0 : 16;
    int cw = (int)im->d_w < w ? (int)im->d_w : w, ch = (int)im->d_h < h ? (int)im->d_h : h;
    if (cw < w || ch < h) for (size_t i = 0; i < (size_t)w * h; i++) ((uint32_t *)dst)[i] = 0xff000000u;
    #define CL(v) ((v) < 0 ? 0 : (v) > 255 ? 255 : (v))
    for (int y = 0; y < ch; y++) {
        const uint8_t *py = im->planes[0] + (size_t)y * im->stride[0], *pu = im->planes[1] + (size_t)(y >> 1) * im->stride[1], *pv = im->planes[2] + (size_t)(y >> 1) * im->stride[2];
        uint8_t *o = dst + (size_t)y * w * 4;
        for (int x = 0; x < cw; x++) {
            int l = (py[x] - y0) * Y, u = pu[x >> 1] - 128, v = pv[x >> 1] - 128;
            int r = (l + RV * v + 32768) >> 16, g = (l - GU * u - GV * v + 32768) >> 16, b = (l + BU * u + 32768) >> 16;
            o[4 * x] = (uint8_t)CL(r); o[4 * x + 1] = (uint8_t)CL(g); o[4 * x + 2] = (uint8_t)CL(b); o[4 * x + 3] = 255;
        }
    }
    #undef CL
}
// nv12_to_i420's and av1_to_i420's chroma loop (hle_codec_video.c) and md_out_tex's swap (hle_movie.c) as they were
static void old_uv_split(const uint8_t *uv, uint8_t *u, uint8_t *v, int n) { for (int x = 0; x < n; x++) { u[x] = uv[2 * x]; v[x] = uv[2 * x + 1]; } }
static void old_swap_rb(uint8_t *dst, const uint8_t *src, size_t n) { for (size_t k = 0; k < n; k += 4) { dst[k] = src[k + 2]; dst[k + 1] = src[k + 1]; dst[k + 2] = src[k]; dst[k + 3] = src[k + 3]; } }

// n bytes that end where an inaccessible page starts
typedef struct { uint8_t *p; void *map; size_t len; } gbuf;
static gbuf galloc(size_t n) {
    size_t pg = (size_t)sysconf(_SC_PAGESIZE), body = (n + pg - 1) / pg * pg; gbuf g;
    g.map = mmap(NULL, body + pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); CHECK(g.map != MAP_FAILED, "mmap");
    CHECK(!mprotect((uint8_t *)g.map + body, pg, PROT_NONE), "mprotect");
    g.len = body + pg; g.p = (uint8_t *)g.map + body - n; return g;
}
static void gfree(gbuf g) { munmap(g.map, g.len); }
static uint64_t rs = 0x9e3779b97f4a7c15ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)(rs >> 32); }
static int rin(int lo, int hi) { return lo + (int)(rnd() % (uint32_t)(hi - lo + 1)); }   // lo..hi
// random bytes, or now and then the values at the ranges' edges, where the clamps act
static void fill(uint8_t *p, size_t n) {
    static const uint8_t edge[] = {0, 1, 15, 16, 17, 127, 128, 129, 234, 235, 236, 239, 240, 241, 254, 255};
    int mode = rin(0, 3);
    for (size_t i = 0; i < n; i++) p[i] = mode == 0 ? edge[rnd() & 15] : mode == 1 && (rnd() & 1) ? (rnd() & 1 ? 0 : 255) : (uint8_t)rnd();
}

// Every (Y, U, V): pixel x of a 65,536-pixel row has Y = x & 255 and V = x >> 8 (chroma sample k = x / 2 holds k >> 7), one row for each U
static long rgba_every_value(void) {
    enum { W = 65536 };
    uint8_t *py = malloc(W), *pu = malloc(W / 2), *pv = malloc(W / 2), *a = malloc(4 * W), *b = malloc(4 * W), *c = malloc(4 * W);
    CHECK(py && pu && pv && a && b && c, "malloc");
    for (int x = 0; x < W; x++) py[x] = (uint8_t)x;
    for (int k = 0; k < W / 2; k++) pv[k] = (uint8_t)(k >> 7);
    vpx_image_t im; memset(&im, 0, sizeof im);
    im.fmt = VPX_IMG_FMT_I420; im.d_w = W; im.d_h = 1; im.planes[0] = py; im.planes[1] = pu; im.planes[2] = pv; im.stride[0] = W; im.stride[1] = im.stride[2] = W / 2;
    long n = 0;
    for (int full = 0; full < 2; full++) for (int m = 0; m < 2; m++) {
        im.range = full ? VPX_CR_FULL_RANGE : VPX_CR_STUDIO_RANGE; im.cs = m ? VPX_CS_BT_709 : VPX_CS_BT_601;
        for (int u = 0; u < 256; u++) {
            memset(pu, u, W / 2);
            old_rgba(&im, a, W, 1); md_rgba_to(&im, b, W, 1, 0);
            CHECK(!memcmp(a, b, 4 * W), "scalar md_rgba_to differs from md_rgba (full range %d, BT.709 %d, U %d)", full, m, u);
            if (NEON_RUNS && (md_rgba_to(&im, c, W, 1, 1), memcmp(a, c, 4 * W))) for (int x = 0; x < W; x++) CHECK(!memcmp(a + 4 * x, c + 4 * x, 4), "NEON md_rgba_to differs: full range %d, BT.709 %d, Y %d U %d V %d: %d %d %d, not %d %d %d",
                                                                                                                         full, m, x & 255, u, x >> 8, c[4 * x], c[4 * x + 1], c[4 * x + 2], a[4 * x], a[4 * x + 1], a[4 * x + 2]);
            n += W;
        }
    }
    free(py); free(pu); free(pv); free(a); free(b); free(c);
    return n;
}
// A random picture into a random output size: equal, smaller (cropped) or larger (padded with black), each dimension on its own
static void rgba_random(int i) {
    int tall = i % 23 == 0, big = !tall && i % 16 == 0;   // tall: output heights about 720, where an undeclared colour space turns BT.709
    int dw = big ? rin(1, 2100) : tall ? rin(1, 40) : rin(1, 140), dh = tall ? rin(700, 740) : rin(1, 40);
    int w = rin(0, 2) == 0 ? dw : rin(0, 1) ? (dw > 1 ? rin(1, dw - 1) : 1) : dw + rin(1, 37);
    int h = tall ? rin(715, 725) : rin(0, 2) == 0 ? dh : rin(0, 1) ? (dh > 1 ? rin(1, dh - 1) : 1) : dh + rin(1, 9);
    int s0 = dw + (rin(0, 1) ? 0 : rin(1, 40)), cw2 = (dw + 1) / 2, s1 = cw2 + (rin(0, 1) ? 0 : rin(1, 24)), s2 = rin(0, 1) ? s1 : cw2 + rin(0, 24), ch2 = (dh + 1) / 2;
    size_t n0 = (size_t)(dh - 1) * s0 + dw, n1 = (size_t)(ch2 - 1) * s1 + cw2, n2 = (size_t)(ch2 - 1) * s2 + cw2, no = (size_t)w * h * 4;
    gbuf p0 = galloc(n0), p1 = galloc(n1), p2 = galloc(n2), a = galloc(no), b = galloc(no), c = galloc(no);
    fill(p0.p, n0); fill(p1.p, n1); fill(p2.p, n2);
    uint8_t junk = (uint8_t)rnd(); memset(a.p, junk, no); memset(b.p, junk, no); memset(c.p, junk, no);
    vpx_image_t im; memset(&im, 0, sizeof im);
    im.fmt = VPX_IMG_FMT_I420; im.d_w = (unsigned)dw; im.d_h = (unsigned)dh; im.planes[0] = p0.p; im.planes[1] = p1.p; im.planes[2] = p2.p; im.stride[0] = s0; im.stride[1] = s1; im.stride[2] = s2;
    im.cs = (vpx_color_space_t)(tall && rin(0, 1) ? VPX_CS_UNKNOWN : rin(0, 7)); im.range = rin(0, 1) ? VPX_CR_FULL_RANGE : VPX_CR_STUDIO_RANGE;
    old_rgba(&im, a.p, w, h); md_rgba_to(&im, b.p, w, h, 0);
    CHECK(!memcmp(a.p, b.p, no), "picture %d: scalar md_rgba_to differs (%dx%d strides %d %d %d into %dx%d, colour space %d range %d)", i, dw, dh, s0, s1, s2, w, h, im.cs, im.range);
    if (NEON_RUNS) { md_rgba_to(&im, c.p, w, h, 1); CHECK(!memcmp(a.p, c.p, no), "picture %d: NEON md_rgba_to differs (%dx%d strides %d %d %d into %dx%d, colour space %d range %d)", i, dw, dh, s0, s1, s2, w, h, im.cs, im.range); }
    gfree(p0); gfree(p1); gfree(p2); gfree(a); gfree(b); gfree(c);
}
static void uv_random(int i) {
    int n = i % 8 == 0 ? rin(0, 2000) : rin(0, 70);
    gbuf uv = galloc((size_t)2 * n), u = galloc((size_t)n), v = galloc((size_t)n), u2 = galloc((size_t)n), v2 = galloc((size_t)n);
    fill(uv.p, (size_t)2 * n);
    old_uv_split(uv.p, u.p, v.p, n); md_uv_split(uv.p, u2.p, v2.p, n, 0);
    CHECK(!memcmp(u.p, u2.p, n) && !memcmp(v.p, v2.p, n), "scalar md_uv_split differs (%d samples)", n);
    if (NEON_RUNS) { memset(u2.p, 0x5a, n); memset(v2.p, 0xa5, n); md_uv_split(uv.p, u2.p, v2.p, n, 1); CHECK(!memcmp(u.p, u2.p, n) && !memcmp(v.p, v2.p, n), "NEON md_uv_split differs (%d samples)", n); }
    gfree(uv); gfree(u); gfree(v); gfree(u2); gfree(v2);
}
static void swap_random(int i) {
    size_t n = (size_t)4 * (i % 8 == 0 ? rin(0, 3000) : rin(0, 80));
    gbuf s = galloc(n), a = galloc(n), b = galloc(n);
    fill(s.p, n);
    old_swap_rb(a.p, s.p, n); md_swap_rb(b.p, s.p, n, 0);
    CHECK(!memcmp(a.p, b.p, n), "scalar md_swap_rb differs (%zu bytes)", n);
    if (NEON_RUNS) { memset(b.p, 0x33, n); md_swap_rb(b.p, s.p, n, 1); CHECK(!memcmp(a.p, b.p, n), "NEON md_swap_rb differs (%zu bytes)", n); }
    gfree(s); gfree(a); gfree(b);
}
int main(int argc, char **argv) {
    if (argc > 1) rs = strtoull(argv[1], NULL, 0) | 1;
    long every = rgba_every_value();
    int pictures = 4000; for (int i = 0; i < pictures; i++) rgba_random(i);
    for (int i = 0; i < 4000; i++) uv_random(i);
    for (int i = 0; i < 4000; i++) swap_random(i);
    printf("t_movie_yuv: md_rgba equals the old code for all %ld (Y, U, V, range, matrix) and %d random pictures, the chroma split and the red / blue swap for 4000 rows each (%s)\n",
           every, pictures, NEON_RUNS ? "scalar and NEON loops" : "scalar loops only: no NEON on this machine");
    return 0;
}
