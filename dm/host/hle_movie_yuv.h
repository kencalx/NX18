// libvpx pictures to the layouts games read (hle_movie.c), shared with the Switch 2 decoder API (hle_codec_video.c)
#pragma once
#include <stddef.h>
#include <stdint.h>
#include "vpx/vpx_image.h"
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

// I420 → NV12 at dst: the Y plane (stride w, h rows), then the interleaved UV plane (stride w, h / 2 rows); a smaller picture is padded with black, a larger one cropped
void md_nv12(const vpx_image_t *im, uint8_t *dst, int w, int h);
// I420 → RGBA (stride 4 w) by the colour space and range the picture declares; a smaller picture is padded with black, a larger one cropped
void md_rgba(const vpx_image_t *im, uint8_t *dst, int w, int h);
// DM_MOVIE_NEON=0: md_rgba, the NV12 → I420 chroma split and the red / blue swap below run their scalar loops alone, as before (hle_movie.c; read once)
int md_neon(void);

// The loops themselves, here so that dm/host/tests/t_movie_yuv.c runs them both ways against a copy of the code they replaced. neon = 0 runs the scalar loops alone; with neon
// the NEON loops take whole 16-pixel steps and the scalar loop the rest of a row, and they write the same bytes (that test: every Y, U, V for both ranges and both matrices,
// random pictures of odd sizes with padded strides, crops and padding). The NEON loops read no byte the scalar loop does not
#if defined(__aarch64__)
// One channel of 16 pixels from its four 32-bit sums: a sum's high half is its arithmetic >> 16 (uzp2), and sqxtun saturates that to 0..255 as CL() does
static inline uint8x16_t md_q16_u8(int32x4_t a, int32x4_t b, int32x4_t c, int32x4_t d) {
    return vqmovun_high_s16(vqmovun_s16(vuzp2q_s16(vreinterpretq_s16_s32(a), vreinterpretq_s16_s32(b))), vuzp2q_s16(vreinterpretq_s16_s32(c), vreinterpretq_s16_s32(d)));
}
// md_rgba's pixels [0, n & ~15) of one row: the scalar loop's 32-bit sums (32768 added first, then the products: the same values, none leaves 32 bits) for 16 pixels a step, each
// chroma sample zipped to its two pixels. Written out with no arrays or loops over channels: an array-based form took 152 instructions for 16 pixels at the Mac host's -O1, this one 76. → the first pixel left
static inline int md_rgba_row_neon(const uint8_t *py, const uint8_t *pu, const uint8_t *pv, uint8_t *o, int n, int y0, int Y, int RV, int GU, int GV, int BU) {
    const int32x4_t rnd = vdupq_n_s32(32768); const uint8x16_t ky = vdupq_n_u8((uint8_t)y0), alpha = vdupq_n_u8(255); const uint8x8_t kc = vdup_n_u8(128);
    int x = 0;
    for (; x + 16 <= n; x += 16) {
        uint8x16_t l8 = vld1q_u8(py + x);
        int16x8_t ya = vreinterpretq_s16_u16(vsubl_u8(vget_low_u8(l8), vget_low_u8(ky))), yb = vreinterpretq_s16_u16(vsubl_high_u8(l8, ky));
        int16x8_t u = vreinterpretq_s16_u16(vsubl_u8(vld1_u8(pu + x / 2), kc)), v = vreinterpretq_s16_u16(vsubl_u8(vld1_u8(pv + x / 2), kc));   // Y - y0, U - 128, V - 128 in 16 bits (usubl), as the scalar loop's ints
        int16x8_t ua = vzip1q_s16(u, u), ub = vzip2q_s16(u, u), va = vzip1q_s16(v, v), vb = vzip2q_s16(v, v);
        int32x4_t l0 = vmlaq_n_s32(rnd, vmovl_s16(vget_low_s16(ya)), Y), l1 = vmlaq_n_s32(rnd, vmovl_high_s16(ya), Y), l2 = vmlaq_n_s32(rnd, vmovl_s16(vget_low_s16(yb)), Y), l3 = vmlaq_n_s32(rnd, vmovl_high_s16(yb), Y);
        int32x4_t u0 = vmovl_s16(vget_low_s16(ua)), u1 = vmovl_high_s16(ua), u2 = vmovl_s16(vget_low_s16(ub)), u3 = vmovl_high_s16(ub);
        int32x4_t v0 = vmovl_s16(vget_low_s16(va)), v1 = vmovl_high_s16(va), v2 = vmovl_s16(vget_low_s16(vb)), v3 = vmovl_high_s16(vb);
        uint8x16x4_t px;
        px.val[0] = md_q16_u8(vmlaq_n_s32(l0, v0, RV), vmlaq_n_s32(l1, v1, RV), vmlaq_n_s32(l2, v2, RV), vmlaq_n_s32(l3, v3, RV));
        px.val[1] = md_q16_u8(vmlsq_n_s32(vmlsq_n_s32(l0, u0, GU), v0, GV), vmlsq_n_s32(vmlsq_n_s32(l1, u1, GU), v1, GV), vmlsq_n_s32(vmlsq_n_s32(l2, u2, GU), v2, GV), vmlsq_n_s32(vmlsq_n_s32(l3, u3, GU), v3, GV));
        px.val[2] = md_q16_u8(vmlaq_n_s32(l0, u0, BU), vmlaq_n_s32(l1, u1, BU), vmlaq_n_s32(l2, u2, BU), vmlaq_n_s32(l3, u3, BU));
        px.val[3] = alpha;
        vst4q_u8(o + 4 * x, px);
    }
    return x;
}
#endif
// md_rgba: by the colour space and range the picture declares (VP9 colour config; when undeclared BT.709 from 720 lines up, else BT.601), 16-bit fixed point; a smaller picture is padded with black, a larger one cropped
static inline void md_rgba_to(const vpx_image_t *im, uint8_t *dst, int w, int h, int neon) {
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
        int x = 0;
#if defined(__aarch64__)
        if (neon) x = md_rgba_row_neon(py, pu, pv, o, cw, y0, Y, RV, GU, GV, BU);
#endif
        for (; x < cw; x++) {
            int l = (py[x] - y0) * Y, u = pu[x >> 1] - 128, v = pv[x >> 1] - 128;
            int r = (l + RV * v + 32768) >> 16, g = (l - GU * u - GV * v + 32768) >> 16, b = (l + BU * u + 32768) >> 16;
            o[4 * x] = (uint8_t)CL(r); o[4 * x + 1] = (uint8_t)CL(g); o[4 * x + 2] = (uint8_t)CL(b); o[4 * x + 3] = 255;
        }
    }
    #undef CL
    (void)neon;
}
// NV12's interleaved chroma row (U V U V …) → I420's U and V rows, n samples (hle_codec_video.c: VideoToolbox's and the AV1 decoder's pictures, kept as I420)
static inline void md_uv_split(const uint8_t *uv, uint8_t *u, uint8_t *v, int n, int neon) {
    int x = 0;
#if defined(__aarch64__)
    if (neon) for (; x + 16 <= n; x += 16) { uint8x16x2_t t = vld2q_u8(uv + 2 * x); vst1q_u8(u + x, t.val[0]); vst1q_u8(v + x, t.val[1]); }
#endif
    for (; x < n; x++) { u[x] = uv[2 * x]; v[x] = uv[2 * x + 1]; }
    (void)neon;
}
// RGBA ↔ BGRA, n bytes (whole pixels): red and blue swapped (hle_movie.c md_out_tex: a BGRA8 / BGRX8 client texture)
static inline void md_swap_rb(uint8_t *dst, const uint8_t *src, size_t n, int neon) {
    size_t k = 0;
#if defined(__aarch64__)
    if (neon) for (; k + 64 <= n; k += 64) { uint8x16x4_t p = vld4q_u8(src + k); uint8x16_t t = p.val[0]; p.val[0] = p.val[2]; p.val[2] = t; vst4q_u8(dst + k, p); }
#endif
    for (; k < n; k += 4) { dst[k] = src[k + 2]; dst[k + 1] = src[k + 1]; dst[k + 2] = src[k]; dst[k + 3] = src[k + 3]; }
    (void)neon;
}
