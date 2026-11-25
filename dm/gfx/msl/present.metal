// The present: the frame drawn into the drawable, cropped (nvn_mtl.m present_pipeline)
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
struct Crop { float4 rect; float4 edge; };
// Minification: texels per pixel the filter widens to at most (smaller pictures alias a little again). A radius-1 tent
// spans at most 2 * 3 = 6 texels an axis (3 bilinear fetches, 9 in 2D; at most 4 in 2D up to 2:1).
constant float MINIFY_SCALE_MAX = 3;
// Non-negative tent (radius 1, in pixels of the picture as shown): exact with hardware bilinear pairing (no negative lobes
// that cross zero within a pair), 4 fetches a pixel up to 2:1 and at most 9 up to 3:1.
static float tent(float x) { return max(1.0 - abs(x), 0.0); }
// One tap along an axis: texels a and a + 1 of the tent around centre p (texel units) for scale s, taken by one bilinear
// fetch at their weighted centroid, clamped to the crop's [lo, hi] texel centres and converted to normalized uv.
static float minify_pair(int a, int last, float p, float s, float lo, float hi, float inv_size, thread float &pos) {
    float wa = tent((float(a) + 0.5 - p) / s);
    float wb = a + 1 <= last ? tent((float(a) + 1.5 - p) / s) : 0.0;
    float w = wa + wb;
    pos = clamp(float(a) + 0.5 + (w > 1e-6 ? wb / w : 0.5), lo, hi) * inv_size;
    return w;
}
// Builds up to 3 bilinear taps (pos in normalized uv, normalized wgt) for one axis in registers (no dynamic array indexing,
// avoiding stack spills on Apple GPUs). A non-minified axis takes one bilinear tap.
static void minify_axis(float step, float p, float lo, float hi, float inv_size, thread float3 &pos, thread float3 &wgt) {
    if (step < 1.001) { pos = float3(clamp(p, lo, hi) * inv_size, 0.0, 0.0); wgt = float3(1.0, 0.0, 0.0); return; }
    float s = min(step, MINIFY_SCALE_MAX);
    int i0 = int(floor(p - 0.5 - s)) + 1, last = min(int(ceil(p - 0.5 + s)) - 1, i0 + 5);
    float p0 = 0.0, p1 = 0.0, p2 = 0.0;
    float w0 = minify_pair(i0, last, p, s, lo, hi, inv_size, p0);
    float w1 = i0 + 2 <= last ? minify_pair(i0 + 2, last, p, s, lo, hi, inv_size, p1) : 0.0;
    float w2 = i0 + 4 <= last ? minify_pair(i0 + 4, last, p, s, lo, hi, inv_size, p2) : 0.0;
    float wsum = w0 + w1 + w2;
    if (wsum <= 1e-6) { pos = float3(clamp(p, lo, hi) * inv_size, 0.0, 0.0); wgt = float3(1.0, 0.0, 0.0); return; }
    pos = float3(p0, p1, p2);
    wgt = float3(w0, w1, w2) / wsum;
}
static float4 sample_row(texture2d<float> t, sampler s, float3 px, float3 wx, float py) {
    float4 r = wx.x * t.sample(s, float2(px.x, py));
    if (wx.y > 0.0) r += wx.y * t.sample(s, float2(px.y, py));
    if (wx.z > 0.0) r += wx.z * t.sample(s, float2(px.z, py));
    return r;
}
// A picture shown at its size or larger takes one bilinear tap. One shown smaller (e.g. a 2560x1440 frame in a 1920x1080
// rectangle or a 1280x720 window) is filtered over each pixel's footprint with a separable tent kernel stretched by the
// scale, two texels an axis per bilinear fetch: one bilinear tap weighs texels unevenly by pixel-centre phase, so edges
// stair-step and crawl as they move (minification aliasing), and past 2:1 texels are skipped entirely. Fetches stay within
// the crop (edge: its first and last texel centres in uv).
fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    float2 uv = in.uv * c.rect.zw + c.rect.xy;
    float2 size = float2(t.get_width(), t.get_height());
    float2 step = abs(float2(dfdx(uv.x), dfdy(uv.y))) * size;   // texels per pixel: uv is linear over the triangle, so the derivatives are exact
    if (step.x < 1.001 && step.y < 1.001) return t.sample(s, clamp(uv, c.edge.xy, c.edge.zw));
    float2 inv_size = 1.0 / size, p = uv * size;
    float2 lo = min(c.edge.xy, c.edge.zw) * size, hi = max(c.edge.xy, c.edge.zw) * size;   // first and last texel centres of the crop, texel units
    float3 px, wx, py, wy;
    minify_axis(step.x, p.x, lo.x, hi.x, inv_size.x, px, wx);
    minify_axis(step.y, p.y, lo.y, hi.y, inv_size.y, py, wy);
    float4 sum = wy.x * sample_row(t, s, px, wx, py.x);
    if (wy.y > 0.0) sum += wy.y * sample_row(t, s, px, wx, py.y);
    if (wy.z > 0.0) sum += wy.z * sample_row(t, s, px, wx, py.z);
    return sum;
}

// The touch controls drawn into the frame (nvn_mtl.m touch_draw, dm/host/touch_draw.h): one instance per control, a quad from its place on the canvas (dst: x, y, w, h normalized,
// y down) textured with its look in the atlas (src, normalized), premultiplied alpha over the picture (the pipeline's blending, host_msl_rps_over), as Core Animation laid the layer over it
struct TouchQuad { float4 dst; float4 src; };
struct TouchV { float4 p [[position]]; float2 uv; };
vertex TouchV vs_touch(uint id [[vertex_id]], uint q [[instance_id]], const device TouchQuad *quads [[buffer(0)]]) {
    float2 c = float2(id & 1, id >> 1); TouchQuad k = quads[q];   // a strip of four: (0, 0) (1, 0) (0, 1) (1, 1)
    float2 d = k.dst.xy + c * k.dst.zw;
    TouchV o; o.p = float4(d.x * 2 - 1, 1 - d.y * 2, 0, 1); o.uv = k.src.xy + c * k.src.zw; return o;
}
fragment float4 fs_touch(TouchV in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, in.uv); }
fragment float4 fs_touch_grey(TouchV in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { float2 v = t.sample(s, in.uv).rg; return float4(v.xxx, v.y); }   // a grey and alpha atlas (RG8)

// Sharpening (DM_PRESENT_SHARPEN, nvn_mtl.m present_sharpen): the same draw as fs with FidelityFX FSR1's Robust Contrast Adaptive Sharpening (RCAS, ffx_fsr1.h FsrRcasF) fused in.
// Its four neighbours are one source texel away (k.yz), clamped to the crop like the centre, so a 1:1 present is RCAS on the picture's own grid and a scaled crop is RCAS of the
// bilinear field (five bilinear taps). k.x is RCAS's linear sharpness, exp2(-stops) (FsrRcasCon). Alpha passes through as fs passes it (FSR_RCAS_PASSTHROUGH_ALPHA), so the
// screenshots and offscreen presents keep it. Without FSR_RCAS_DENOISE, as FSR's default. The limiter's reciprocals take a small epsilon that ffx_fsr1.h does not: its
// reciprocal of 0 (a black ring, or a white one) gives 0 * inf there, which its max() swallows on AMD's hardware, and Metal's max() of a NaN is not specified to do the same.
// Ported from ffx_fsr1.h of the FidelityFX FSR 1.0 SDK, whose notice follows:
//
// Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and / or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
struct Sharp { float4 rect; float4 edge; float4 k; };
#define FSR_RCAS_LIMIT (0.25f - (1.0f / 16.0f))
fragment float4 fs_rcas(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Sharp& c [[buffer(0)]]) {
    // The minimal 3x3 neighbourhood:  b
    //                               d e f
    //                                 h
    float2 u = clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw), dx = float2(c.k.y, 0), dy = float2(0, c.k.z);
    float4 ee = t.sample(s, u);
    float3 e = ee.rgb;
    float3 b = t.sample(s, clamp(u - dy, c.edge.xy, c.edge.zw)).rgb, h = t.sample(s, clamp(u + dy, c.edge.xy, c.edge.zw)).rgb;
    float3 d = t.sample(s, clamp(u - dx, c.edge.xy, c.edge.zw)).rgb, f = t.sample(s, clamp(u + dx, c.edge.xy, c.edge.zw)).rgb;
    // Min and max of the ring
    float3 mn4 = min(min(b, d), min(f, h)), mx4 = max(max(b, d), max(f, h));
    // The limiters: the largest negative lobe that keeps the result inside the 0..1 range the ring and the centre allow
    float3 hitMin = min(mn4, e) / (4.0f * mx4 + 1e-5f);
    float3 hitMax = (1.0f - max(mx4, e)) / (4.0f * mn4 - 4.0f - 1e-5f);
    float3 lobe3 = max(-hitMin, hitMax);
    float lobe = max(-FSR_RCAS_LIMIT, min(max(lobe3.r, max(lobe3.g, lobe3.b)), 0.0f)) * c.k.x;
    // Resolve
    return float4((lobe * (b + d + f + h) + e) / (4.0f * lobe + 1.0f), ee.a);
}
