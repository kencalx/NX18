// The present: the frame drawn into the drawable, cropped (nvn_mtl.m present_pipeline)
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
struct Crop { float4 rect; float4 edge; };
fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)); }

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
