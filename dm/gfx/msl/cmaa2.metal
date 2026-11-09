// Edge smoothing in the present (DM_POST_AA, nvn_mtl.m aa_encode): Intel's Conservative Morphological Anti-Aliasing 2.3, ported by hand from CMAA2.hlsl for the present's
// one case: one sample per pixel, the HIGH preset (edge threshold 0.07), luma edge detection computed in place (CMAA2_EDGE_DETECTION_LUMA_PATH 1), half-width packed edges,
// blend items collected in threadgroup memory, the threadgroup swap of the apply pass. The five dispatches run in one compute encoder: cmaa2_edges, cmaa2_args (2, 1, 1),
// cmaa2_process (indirect), cmaa2_args (1, 2, 1), cmaa2_apply (indirect). The picture is processed in place: aa->tex holds the game's crop at the origin, the first passes read it
// and the last writes only the pixels it smooths.
//
// What differs from upstream, and why:
// - The crop's size (Aa.size) bounds every read, where upstream asks the texture (GetDimensions) and relies on Direct3D returning 0 past it. aa->tex is the window texture's
//   size so a dynamic resolution's moving crop needs no new allocation, and what lies past the crop is an older, larger crop's: a colour read is clamped to the crop's edge, and
//   an edge read past it is "no edge" (LoadEdge), so a line stops there as upstream's stops at the screen's edge. Clamping instead of reading black also means the crop's border
//   is never taken for an edge against black, which upstream's out-of-bounds 0 would blend toward. Nothing is written outside the crop but the FX_PAD texels below.
// - The list heads and the edges are buffers, not R32Uint and R8Uint textures: device atomics on a buffer need no texture atomics (MTLTextureUsageShaderAtomic), which the
//   iPhone has not run in this project, and a buffer read past nothing is checked as easily.
// - Every append (shape candidates, deferred blend items, blend locations) is checked against its buffer's capacity (Aa.cap): Metal does not drop an out-of-bounds write as
//   Direct3D drops one. A dropped item leaves its pixel as it was. cmaa2_args records the raw counts and an overflow bit, which the host reads for its log and the tests.
// - The colour is written through a texture of its own (texture 1): an sRGB swapchain is read through its _sRGB format (decoded to linear by the hardware) and written through
//   a UNORM view with the encode done here (CONVERT, upstream's CMAA2_UAV_STORE_CONVERT_TO_SRGB). A plain RGBA8 swapchain (Super Mario Odyssey's) is read and written as it
//   is (CONVERT false). Alpha is kept: upstream writes 0.
// - EXTRA_SHARP is upstream's CMAA2_EXTRA_SHARPNESS as a function constant, so one library serves both of the setting's values.
// - The deferred apply also writes a smoothed pixel of the crop's last column or row into the PAD columns and rows past it (Aa.pad), where aa_encode copied the crop's
//   edge before: MetalFX's spatial scaler reads up to two texels past its content (nvn_mtl.m FX_PAD), and takes this texture as its input.
// - A Z shape whose blend items do not fit the threadgroup's store (CollectBlendZs) marks the slots it reserved below the store's end as empty, and the items' pass skips them.
//   Upstream leaves them as they were, which Direct3D's groupshared memory may tolerate in practice; Metal's threadgroup memory holds whatever an earlier threadgroup or kernel left
//   there, which decodes to a blend of some pixel in the crop with a colour far from it.
//
// Ported from CMAA2.hlsl (https://github.com/GameTechDev/CMAA2), whose notice follows:
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2018, Intel Corporation
//
// Licensed under the Apache License, Version 2.0 ( the "License" );
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//
// Conservative Morphological Anti-Aliasing, version: 2.3
//
// Author(s):       Filip Strugar (filip.strugar@intel.com)
//
// More info:       https://github.com/GameTechDev/CMAA2
//
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// This file is changed from the original: ported from HLSL to the Metal Shading Language, reduced to the configuration above, with the changes listed at its top.
// The full license text is dm/third_party/cmaa2/LICENSE.
#include <metal_stdlib>
using namespace metal;

constant bool CONVERT [[function_constant(0)]];       // cmaa2_apply: encode linear to sRGB before the write (an sRGB swapchain)
constant bool EXTRA_SHARP [[function_constant(1)]];   // CMAA2_EXTRA_SHARPNESS: keeps more text and shape clarity for less smoothing (DM_POST_AA=edge-sharp)

// The host's constants (nvn_mtl.m aa_encode: in the present's constants buffer, after the present pass's own)
struct Aa {
    uint2 size;      // the crop: the picture at the origin of aa->tex
    uint stride;     // entries per row of the edges and the list heads: (size.x + 1) / 2, one byte or word per 2 pixels across
    uint cap_cand;   // capacities of the shape candidates, the deferred blend items and the blend locations (one per 2x2 quad at most)
    uint cap_item;
    uint cap_loc;
    uint2 pad;       // texels past the crop's last column and row that copy it (FX_PAD, fewer where the texture ends)
    uint slm;        // the blend items' threadgroup store used, at most CMAA2_BLEND_ITEM_SLM_SIZE: the tests make it small to run the fallback (BlendZs) and its empty slots
    uint stray;      // the tests: 1 fills the store with a stray blend item before the Z shapes take it, so a slot read before anything wrote it shows in the item count
};
// The control buffer (aa->ctl), as uints. The counters are upstream's offsets (4*3, 4*4, 4*8, 4*12 bytes); the rest are this port's
enum {
    CTL_NUM = 3,        // the count the next pass processes (cmaa2_args)
    CTL_CAND = 4,       // shape candidates appended (cmaa2_edges)
    CTL_LOC = 8,        // blend locations appended
    CTL_ITEM = 12,      // deferred blend items appended
    CTL_RAW_CAND = 13, CTL_RAW_ITEM = 14, CTL_RAW_LOC = 15,   // the last run's appends before the clamp (the host's log, the tests)
    CTL_OVERFLOW = 16,  // bits 1, 2, 4: candidates, items, locations ran past their capacity in some run since the buffer was made (never cleared)
    CTL_INPLACE = 17,   // Z shapes whose blend items did not fit the threadgroup store and were blended in place (cmaa2_process, BlendZs)
    CTL_RAW_INPLACE = 18,   // the last run's (the host's tests)
    CTL_ARGS1 = 20,     // cmaa2_process's indirect dispatch arguments (MTLDispatchThreadgroupsIndirectArguments)
    CTL_ARGS2 = 24,     // cmaa2_apply's
    CTL_WORDS = 32
};

#define CMAA2_CS_INPUT_KERNEL_SIZE_X        16
#define CMAA2_CS_INPUT_KERNEL_SIZE_Y        16
#define CMAA2_CS_OUTPUT_KERNEL_SIZE_X       (CMAA2_CS_INPUT_KERNEL_SIZE_X - 2)
#define CMAA2_CS_OUTPUT_KERNEL_SIZE_Y       (CMAA2_CS_INPUT_KERNEL_SIZE_Y - 2)
#define CMAA2_PROCESS_CANDIDATES_NUM_THREADS 128
#define CMAA2_DEFERRED_APPLY_NUM_THREADS    32
#define CMAA2_BLEND_ITEM_SLM_SIZE           768   // there's a fallback for extreme cases (observed with this value set to 256 or below) in which case image will remain correct but performance will suffer
#define CMAA2_BLEND_ITEM_EMPTY              0xFFFFFFFFu   // a reserved slot nothing was written to (CollectBlendZs); no item's header is this, since a pixel's x and y are under 16384

// Longest line search distance; must be even number; for high perf low quality start from ~32 - the bigger the number, the nicer the gradients but more costly. Max supported is 128!
constant float c_maxLineLength = 86;
// HIGH preset
constant float g_CMAA2_EdgeThreshold = 0.07f;
#define g_CMAA2_LocalContrastAdaptationAmount (EXTRA_SHARP ? 0.15f : 0.10f)
#define g_CMAA2_SimpleShapeBlurinessAmount    (EXTRA_SHARP ? 0.07f : 0.10f)
// these are blendZ settings, determined empirically :)
constant float c_symmetryCorrectionOffset = 0.22f;
#define c_dampeningEffect (EXTRA_SHARP ? 0.11f : 0.15f)

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// encoding/decoding of various data such as edges
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// how .rgba channels from the edge texture maps to pixel edges:
//
//                   A - 0x08               (A - there's an edge between us and a pixel above us)
//              |---------|                 (R - there's an edge between us and a pixel to the right)
//              |         |                 (G - there's an edge between us and a pixel at the bottom)
//     0x04 - B |  pixel  | R - 0x01        (B - there's an edge between us and a pixel to the left)
//              |         |
//              |_________|
//                   G - 0x02
static uint PackEdges(float4 edges) { return (uint)dot(edges, float4(1, 2, 4, 8)); }   // input edges are binary 0 or 1
static float4 UnpackEdgesFlt(uint value) { return float4((value & 0x01) != 0, (value & 0x02) != 0, (value & 0x04) != 0, (value & 0x08) != 0); }

static bool InCrop(int2 p, constant Aa &k) { return all(p >= 0) && all(uint2(p) < k.size); }
// The source colour at p, clamped to the crop's edge (see the top)
static float3 LoadSourceColor(texture2d<float, access::read> color, constant Aa &k, int2 p) {
    return color.read(uint2(clamp(p, int2(0), int2(k.size) - 1))).rgb;
}
// The packed edges of the pixel at p; none outside the crop
static uint LoadEdge(const device uchar *edges, constant Aa &k, int2 p) {
    if (!InCrop(p, k)) return 0;
    return (edges[uint(p.y) * k.stride + uint(p.x) / 2] >> ((uint(p.x) & 1) * 4)) & 0xF;
}

// (R11G11B10 conversion code below taken from Miniengine's PixelPacking_R11G11B10.hlsli,
// Copyright (c) Microsoft, MIT license, Developed by Minigraph, Author:  James Stanard; original file link:
// https://github.com/Microsoft/DirectX-Graphics-Samples/blob/master/MiniEngine/Core/Shaders/PixelPacking_R11G11B10.hlsli )
//
// This is like R11G11B10_FLOAT except that it moves one bit from each exponent to each mantissa.
// By knowing that our values are [0.0, 1.0] (or [0.0, 2.0), incidentally), we can reduce how many bits we need in the exponent.
static uint f32tof16(float v) { return as_type<ushort>(half(v)); }
static float f16tof32(uint v) { return float(as_type<half>(ushort(v))); }
static uint Pack_R11G11B10_E4_FLOAT(float3 rgb) {
    // Clamp to [0.0, 2.0).  The magic number is 1.FFFFF x 2^0.
    rgb = clamp(rgb, 0.0f, as_type<float>(0x3FFFFFFFu));
    uint r = ((f32tof16(rgb.r) + 4) >> 3) & 0x000007FF;
    uint g = ((f32tof16(rgb.g) + 4) << 8) & 0x003FF800;
    uint b = ((f32tof16(rgb.b) + 8) << 18) & 0xFFC00000;
    return r | g | b;
}
static float3 Unpack_R11G11B10_E4_FLOAT(uint rgb) {
    return float3(f16tof32((rgb << 3) & 0x3FF8), f16tof32((rgb >> 8) & 0x3FF8), f16tof32((rgb >> 18) & 0x3FF0));
}
// This is for temporary storage - R11G11B10_E4 covers 8bit per channel sRGB well enough
static float3 InternalUnpackColor(uint packedColor) { return Unpack_R11G11B10_E4_FLOAT(packedColor); }
static uint InternalPackColor(float3 color) { return Pack_R11G11B10_E4_FLOAT(color); }

// The working buffers of one run, as the passes see them
struct Work {
    device atomic_uint *ctl;
    device uint *cand;
    device uint *loc;
    device uint2 *item;
    device atomic_uint *heads;
};
static void StoreColorSample(Work w, constant Aa &k, int2 pixelPos, float3 color, bool isComplexShape) {
    if (!InCrop(pixelPos, k)) return;   // a line stops at the crop's edge (LoadEdge), so none is stored there; kept as a guard for the writes below
    uint counterIndex = atomic_fetch_add_explicit(&w.ctl[CTL_ITEM], 1, memory_order_relaxed);
    if (counterIndex >= k.cap_item) return;   // full: the pixel keeps the other items of its list, or its colour
    // quad coordinates
    uint2 quadPos = uint2(pixelPos) / 2;
    // 2x2 inter-quad coordinates
    uint offsetXY = (uint(pixelPos.y) % 2) * 2 + (uint(pixelPos.x) % 2);
    // encode item-specific info: {2 bits for 2x2 quad location}, {3 bits for MSAA sample index}, {1 bit for isComplexShape flag}, {26 bits left for address (index)}
    uint header = (offsetXY << 30) | (uint(isComplexShape) << 26);
    uint originalIndex = atomic_exchange_explicit(&w.heads[quadPos.y * k.stride + quadPos.x], counterIndex | header, memory_order_relaxed);
    w.item[counterIndex] = uint2(originalIndex, InternalPackColor(color));
    // First one added?
    if (originalIndex == 0xFFFFFFFF) {
        // Make a list of all edge pixels - these cover all potential pixels where AA is applied.
        uint edgeListCounter = atomic_fetch_add_explicit(&w.ctl[CTL_LOC], 1, memory_order_relaxed);
        if (edgeListCounter < k.cap_loc) w.loc[edgeListCounter] = (quadPos.x << 16) | quadPos.y;
    }
}

static float LINEAR_to_SRGB(float val) { return val < 0.0031308f ? val * 12.92f : 1.055f * pow(abs(val), 1.0f / 2.4f) - 0.055f; }

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Edge detection and local contrast adaptation helpers
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// color -> log luma-for-edges conversion: what original FXAA (and consequently CMAA2) use by default - these coefficients correspond to Rec. 601 and those should be used on
// gamma-compressed components; using sqrt luma for now but log luma like in miniengine provides a nicer curve on the low-end
static float RGBToLumaForEdges(float3 linearRGB) { return dot(sqrt(linearRGB), float3(0.299f, 0.587f, 0.114f)); }
static float2 ComputeEdgeLuma(int x, int y, thread const float *pixelLumas) {
    return float2(abs(pixelLumas[x + y * 3] - pixelLumas[x + 1 + y * 3]), abs(pixelLumas[x + y * 3] - pixelLumas[x + (y + 1) * 3]));
}
// new, small kernel 4-connecting-edges-only local contrast adaptation
static float ComputeLocalContrastV(int x, int y, thread const float2 (&n)[4][4]) {
    return max(max(n[x + 1][y + 0].y, n[x + 1][y + 1].y), max(n[x + 2][y + 0].y, n[x + 2][y + 1].y)) * g_CMAA2_LocalContrastAdaptationAmount;
}
static float ComputeLocalContrastH(int x, int y, thread const float2 (&n)[4][4]) {
    return max(max(n[x + 0][y + 1].x, n[x + 1][y + 1].x), max(n[x + 0][y + 2].x, n[x + 1][y + 2].x)) * g_CMAA2_LocalContrastAdaptationAmount;
}

// a 3x3 kernel for higher quality handling of L-based shapes (still rather basic and conservative). The callers have tested the shape's validity (dontTestShapeValidity)
static float4 ComputeSimpleShapeBlendValues(float4 edges, float4 edgesLeft, float4 edgesRight, float4 edgesTop, float4 edgesBottom) {
    float fromRight = edges.r, fromBelow = edges.g, fromLeft = edges.b, fromAbove = edges.a;
    float blurCoeff = g_CMAA2_SimpleShapeBlurinessAmount;
    float numberOfEdges = dot(edges, float4(1, 1, 1, 1));
    float numberOfEdgesAllAround = dot(edgesLeft.bga + edgesRight.rga + edgesTop.rba + edgesBottom.rgb, float3(1, 1, 1));
    // L-like step shape
    if (numberOfEdges == 2) {
        blurCoeff *= 0.75f;
        float k = 0.9f;
        fromRight += k * (edges.g * edgesTop.r     * (1.0f - edgesLeft.g)   + edges.a * edgesBottom.r * (1.0f - edgesLeft.a));
        fromBelow += k * (edges.b * edgesRight.g   * (1.0f - edgesTop.b)    + edges.r * edgesLeft.g   * (1.0f - edgesTop.r));
        fromLeft  += k * (edges.a * edgesBottom.b  * (1.0f - edgesRight.a)  + edges.g * edgesTop.b    * (1.0f - edgesRight.g));
        fromAbove += k * (edges.r * edgesLeft.a    * (1.0f - edgesBottom.r) + edges.b * edgesRight.a  * (1.0f - edgesBottom.b));
    }
    // Dampen the blurring effect when lots of neighbouring edges - additionally preserves text and texture detail
    blurCoeff *= EXTRA_SHARP ? saturate(1.15f - numberOfEdgesAllAround / 8.0f) : saturate(1.30f - numberOfEdgesAllAround / 10.0f);
    return float4(fromLeft, fromAbove, fromRight, fromBelow) * blurCoeff;
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Edge detection compute shader
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Dispatched over ceil(size / 28) threadgroups of 16x16: each thread takes a 2x2 quad, the outer ring of threads only feeds the inner ones' local contrast adaptation
kernel void cmaa2_edges(texture2d<float, access::read> color [[texture(0)]], constant Aa &k [[buffer(0)]], device atomic_uint *ctl [[buffer(1)]],
                        device uint *cand [[buffer(2)]], device atomic_uint *heads [[buffer(5)]], device uchar *edgesOut [[buffer(6)]],
                        uint2 groupID [[threadgroup_position_in_grid]], uint2 groupThreadID [[thread_position_in_threadgroup]]) {
    threadgroup float4 g_groupShared2x2FracEdgesH[CMAA2_CS_INPUT_KERNEL_SIZE_X * CMAA2_CS_INPUT_KERNEL_SIZE_Y];
    threadgroup float4 g_groupShared2x2FracEdgesV[CMAA2_CS_INPUT_KERNEL_SIZE_X * CMAA2_CS_INPUT_KERNEL_SIZE_Y];
    // screen position in the input (expanded) kernel (shifted one 2x2 block up/left)
    int2 pixelPos = (int2(groupID) * int2(CMAA2_CS_OUTPUT_KERNEL_SIZE_X, CMAA2_CS_OUTPUT_KERNEL_SIZE_Y) + int2(groupThreadID) - int2(1, 1)) * 2;
    const int2 qeOffsets[4] = {int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1)};
    const uint rowStride2x2 = CMAA2_CS_INPUT_KERNEL_SIZE_X;
    const uint centerAddr2x2 = groupThreadID.x + groupThreadID.y * rowStride2x2;
    const bool inOutputKernel = !(groupThreadID.x == CMAA2_CS_INPUT_KERNEL_SIZE_X - 1 || groupThreadID.x == 0 || groupThreadID.y == CMAA2_CS_INPUT_KERNEL_SIZE_Y - 1 || groupThreadID.y == 0);
    uint4 outEdges = uint4(0);

    // edge detection
    float pixelLumas[3 * 3 - 1];
    for (int i = 0; i < 3 * 3 - 1; i++) pixelLumas[i] = RGBToLumaForEdges(LoadSourceColor(color, k, pixelPos + int2(i % 3, i / 3)));
    float2 qe0 = ComputeEdgeLuma(0, 0, pixelLumas), qe1 = ComputeEdgeLuma(1, 0, pixelLumas), qe2 = ComputeEdgeLuma(0, 1, pixelLumas), qe3 = ComputeEdgeLuma(1, 1, pixelLumas);
    g_groupShared2x2FracEdgesV[centerAddr2x2] = float4(qe0.x, qe1.x, qe2.x, qe3.x);
    g_groupShared2x2FracEdgesH[centerAddr2x2] = float4(qe0.y, qe1.y, qe2.y, qe3.y);

    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (inOutputKernel) {
        float2 topRow = g_groupShared2x2FracEdgesH[centerAddr2x2 - rowStride2x2].zw;   // top row's bottom edge
        float2 leftColumn = g_groupShared2x2FracEdgesV[centerAddr2x2 - 1].yw;          // left column's right edge
        bool someNonZeroEdges = any((float4(qe0, qe1) + float4(qe2, qe3) + float4(topRow[0], topRow[1], leftColumn[0], leftColumn[1])) != 0);
        if (someNonZeroEdges) {
            // Clear deferred color list heads to empty (if potentially needed - even though some edges might get culled by local contrast adaptation step below, it's still
            // cheaper to just clear it without additional logic)
            if (InCrop(pixelPos, k)) atomic_store_explicit(&heads[uint(pixelPos.y) / 2 * k.stride + uint(pixelPos.x) / 2], 0xFFFFFFFFu, memory_order_relaxed);

            // local contrast adaptation: load & unpack kernel data from SLM (upstream's GroupsharedLoadQuadHV calls, each quad's .x from V and .y from H)
            float2 n[4][4];
            float4 h, v;
            h = g_groupShared2x2FracEdgesH[centerAddr2x2 - rowStride2x2 - 1]; v = g_groupShared2x2FracEdgesV[centerAddr2x2 - rowStride2x2 - 1];
            n[0][0] = float2(v.w, h.w);
            h = g_groupShared2x2FracEdgesH[centerAddr2x2 - rowStride2x2]; v = g_groupShared2x2FracEdgesV[centerAddr2x2 - rowStride2x2];
            n[1][0] = float2(v.z, h.z); n[2][0] = float2(v.w, h.w);
            h = g_groupShared2x2FracEdgesH[centerAddr2x2 - rowStride2x2 + 1]; v = g_groupShared2x2FracEdgesV[centerAddr2x2 - rowStride2x2 + 1];
            n[3][0] = float2(v.z, h.z);
            h = g_groupShared2x2FracEdgesH[centerAddr2x2 - 1]; v = g_groupShared2x2FracEdgesV[centerAddr2x2 - 1];
            n[0][1] = float2(v.y, h.y); n[0][2] = float2(v.w, h.w);
            h = g_groupShared2x2FracEdgesH[centerAddr2x2 + 1]; v = g_groupShared2x2FracEdgesV[centerAddr2x2 + 1];
            n[3][1] = float2(v.x, h.x); n[3][2] = float2(v.z, h.z);
            h = g_groupShared2x2FracEdgesH[centerAddr2x2 - 1 + rowStride2x2]; v = g_groupShared2x2FracEdgesV[centerAddr2x2 - 1 + rowStride2x2];
            n[0][3] = float2(v.y, h.y);
            h = g_groupShared2x2FracEdgesH[centerAddr2x2 + rowStride2x2]; v = g_groupShared2x2FracEdgesV[centerAddr2x2 + rowStride2x2];
            n[1][3] = float2(v.x, h.x); n[2][3] = float2(v.y, h.y);
            n[1][0].y = topRow[0];        // already in registers
            n[2][0].y = topRow[1];
            n[0][1].x = leftColumn[0];
            n[0][2].x = leftColumn[1];
            n[1][1] = qe0; n[2][1] = qe1; n[1][2] = qe2; n[2][2] = qe3;

            topRow[0]     = (topRow[0]     - ComputeLocalContrastH(0, -1, n)) > g_CMAA2_EdgeThreshold;
            topRow[1]     = (topRow[1]     - ComputeLocalContrastH(1, -1, n)) > g_CMAA2_EdgeThreshold;
            leftColumn[0] = (leftColumn[0] - ComputeLocalContrastV(-1, 0, n)) > g_CMAA2_EdgeThreshold;
            leftColumn[1] = (leftColumn[1] - ComputeLocalContrastV(-1, 1, n)) > g_CMAA2_EdgeThreshold;
            float4 ce[4];
            ce[0].x = (qe0.x - ComputeLocalContrastV(0, 0, n)) > g_CMAA2_EdgeThreshold;
            ce[0].y = (qe0.y - ComputeLocalContrastH(0, 0, n)) > g_CMAA2_EdgeThreshold;
            ce[1].x = (qe1.x - ComputeLocalContrastV(1, 0, n)) > g_CMAA2_EdgeThreshold;
            ce[1].y = (qe1.y - ComputeLocalContrastH(1, 0, n)) > g_CMAA2_EdgeThreshold;
            ce[2].x = (qe2.x - ComputeLocalContrastV(0, 1, n)) > g_CMAA2_EdgeThreshold;
            ce[2].y = (qe2.y - ComputeLocalContrastH(0, 1, n)) > g_CMAA2_EdgeThreshold;
            ce[3].x = (qe3.x - ComputeLocalContrastV(1, 1, n)) > g_CMAA2_EdgeThreshold;
            ce[3].y = (qe3.y - ComputeLocalContrastH(1, 1, n)) > g_CMAA2_EdgeThreshold;
            // left
            ce[0].z = leftColumn[0]; ce[1].z = ce[0].x; ce[2].z = leftColumn[1]; ce[3].z = ce[2].x;
            // top
            ce[0].w = topRow[0]; ce[1].w = topRow[1]; ce[2].w = ce[0].y; ce[3].w = ce[1].y;

            for (int i = 0; i < 4; i++) {
                const int2 localPixelPos = pixelPos + qeOffsets[i];
                const float4 edges = ce[i];
                // if there's at least one two edge corner, this is a candidate for simple or complex shape processing...
                bool isCandidate = (edges.x * edges.y + edges.y * edges.z + edges.z * edges.w + edges.w * edges.x) != 0;
                if (isCandidate && InCrop(localPixelPos, k)) {
                    uint counterIndex = atomic_fetch_add_explicit(&ctl[CTL_CAND], 1, memory_order_relaxed);
                    if (counterIndex < k.cap_cand) cand[counterIndex] = (uint(localPixelPos.x) << 18) | uint(localPixelPos.y);
                }
                // Write out edges - we write out all, including empty pixels, to make sure shape detection edge tracing doesn't continue on previous frame's edges that no longer exist.
                outEdges[i] = PackEdges(edges);
            }
        }
    }

    // finally, write the edges! (the quad's two rows inside the crop)
    if (inOutputKernel && InCrop(pixelPos, k)) {
        edgesOut[uint(pixelPos.y) * k.stride + uint(pixelPos.x) / 2] = uchar((outEdges[1] << 4) | outEdges[0]);
        if (uint(pixelPos.y) + 1 < k.size.y) edgesOut[(uint(pixelPos.y) + 1) * k.stride + uint(pixelPos.x) / 2] = uchar((outEdges[3] << 4) | outEdges[2]);
    }
}

///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Compute shaders used to generate DispatchIndirec() control buffer
///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Compute dispatch arguments for the DispatchIndirect() that calls ProcessCandidatesCS and DeferredColorApply2x2CS. One thread per threadgroup
kernel void cmaa2_args(constant Aa &k [[buffer(0)]], device uint *ctl [[buffer(1)]], uint2 groupID [[threadgroup_position_in_grid]]) {
    // activated once on Dispatch( 2, 1, 1 )
    if (groupID.x == 1) {
        // get current count; check for overflow!
        uint raw = ctl[CTL_CAND], shapeCandidateCount = min(raw, k.cap_cand);
        ctl[CTL_RAW_CAND] = raw;
        if (raw > k.cap_cand) ctl[CTL_OVERFLOW] |= 1;
        // write dispatch indirect arguments for ProcessCandidatesCS
        ctl[CTL_ARGS1 + 0] = (shapeCandidateCount + CMAA2_PROCESS_CANDIDATES_NUM_THREADS - 1) / CMAA2_PROCESS_CANDIDATES_NUM_THREADS;
        ctl[CTL_ARGS1 + 1] = 1;
        ctl[CTL_ARGS1 + 2] = 1;
        // write actual number of items to process in ProcessCandidatesCS
        ctl[CTL_NUM] = shapeCandidateCount;
    }
    // activated once on Dispatch( 1, 2, 1 )
    else if (groupID.y == 1) {
        // get current count; check for overflow!
        uint raw = ctl[CTL_LOC], blendLocationCount = min(raw, k.cap_loc), items = ctl[CTL_ITEM];
        ctl[CTL_RAW_LOC] = raw; ctl[CTL_RAW_ITEM] = items; ctl[CTL_RAW_INPLACE] = ctl[CTL_INPLACE];
        if (items > k.cap_item) ctl[CTL_OVERFLOW] |= 2;
        if (raw > k.cap_loc) ctl[CTL_OVERFLOW] |= 4;
        // write dispatch indirect arguments for DeferredColorApply2x2CS (the threadgroup swap: the candidates go down y)
        ctl[CTL_ARGS2 + 0] = 1;
        ctl[CTL_ARGS2 + 1] = (blendLocationCount + CMAA2_DEFERRED_APPLY_NUM_THREADS - 1) / CMAA2_DEFERRED_APPLY_NUM_THREADS;
        ctl[CTL_ARGS2 + 2] = 1;
        // write actual number of items to process in DeferredColorApply2x2CS
        ctl[CTL_NUM] = blendLocationCount;
        // clear counters for next frame
        ctl[CTL_CAND] = 0;
        ctl[CTL_LOC] = 0;
        ctl[CTL_ITEM] = 0;
        ctl[CTL_INPLACE] = 0;
    }
}

static void FindZLineLengths(thread float &lineLengthLeft, thread float &lineLengthRight, int2 screenPos, bool horizontal, bool invertedZShape, int2 stepRight,
                             const device uchar *edges, constant Aa &k) {
    // Horizontal (vertical is the same, just rotated 90- counter-clockwise)
    // Inverted Z case:              // Normal Z case:
    //   __                          // __
    //  X|                           //  X|
    // --                            //   --
    uint maskTraceLeft = horizontal ? 0x08 : 0x04;    // tracing top edge, or left edge
    uint maskTraceRight = horizontal ? 0x02 : 0x01;   // tracing bottom edge, or right edge
    if (invertedZShape) { uint temp = maskTraceLeft; maskTraceLeft = maskTraceRight; maskTraceRight = temp; }
    uint maskLeft = maskTraceLeft, bitsContinueLeft = maskTraceLeft, maskRight = maskTraceRight, bitsContinueRight = maskTraceRight;

    bool continueLeft = true, continueRight = true;
    lineLengthLeft = 1;
    lineLengthRight = 1;
    for (;;) {
        uint edgeLeft = LoadEdge(edges, k, screenPos - stepRight * int(lineLengthLeft));
        uint edgeRight = LoadEdge(edges, k, screenPos + stepRight * (int(lineLengthRight) + 1));
        // stop on encountering 'stopping' edge (as defined by masks)
        continueLeft = continueLeft && ((edgeLeft & maskLeft) == bitsContinueLeft);
        continueRight = continueRight && ((edgeRight & maskRight) == bitsContinueRight);
        lineLengthLeft += continueLeft;
        lineLengthRight += continueRight;
        float maxLR = max(lineLengthRight, lineLengthLeft);
        // both stopped? cause the search end by setting maxLR to max length.
        if (!continueLeft && !continueRight) maxLR = c_maxLineLength;
        // either the longer one is ahead of the smaller (already stopped) one by more than a factor of x, or both are stopped - end the search.
        if (EXTRA_SHARP ? maxLR >= min(c_maxLineLength, 1.20f * min(lineLengthRight, lineLengthLeft) - 0.20f)
                        : maxLR >= min(c_maxLineLength, 1.25f * min(lineLengthRight, lineLengthLeft) - 0.25f)) break;
    }
}

static bool CollectBlendZs(threadgroup atomic_uint *count, threadgroup uint2 *items, uint slmSize, int2 screenPos, bool horizontal, bool invertedZShape, float shapeQualityScore,
                           float lineLengthLeft, float lineLengthRight) {
    float leftOdd = c_symmetryCorrectionOffset * fmod(lineLengthLeft, 2.0f);
    float rightOdd = c_symmetryCorrectionOffset * fmod(lineLengthRight, 2.0f);
    float dampenEffect = saturate((lineLengthLeft + lineLengthRight - shapeQualityScore) * c_dampeningEffect);
    float loopFrom = -floor((lineLengthLeft + 1) / 2) + 1.0f;
    float loopTo = floor((lineLengthRight + 1) / 2);

    const uint blendItemCount = uint(loopTo - loopFrom + 1);
    uint itemIndex = atomic_fetch_add_explicit(count, blendItemCount, memory_order_relaxed);
    // safety
    if ((itemIndex + blendItemCount) > slmSize) {
        // The count stays raised, so the items' pass reads up to the store's end: the slots this reservation took there are marked empty, as nothing else will write them. Only
        // one reservation can start below the end and not fit, since every later one starts past it
        for (uint i = itemIndex; i < slmSize; i++) items[i] = uint2(CMAA2_BLEND_ITEM_EMPTY, 0);
        return false;
    }

    float totalLength = (loopTo - loopFrom) + 1 - leftOdd - rightOdd;
    float lerpStep = 1.0f / totalLength;
    float lerpFromK = (0.5f - leftOdd - loopFrom) * lerpStep;
    uint itemHeader = (uint(screenPos.x) << 18) | uint(screenPos.y);
    uint itemValStatic = (uint(horizontal) << 31) | (uint(invertedZShape) << 30);
    for (float i = loopFrom; i <= loopTo; i++) {
        float secondPart = i > 0;
        float srcOffset = 1.0f - secondPart * 2.0f;
        float lerpK = (lerpStep * i + lerpFromK) * srcOffset + secondPart;
        lerpK *= dampenEffect;
        items[itemIndex++] = uint2(itemHeader, itemValStatic | (uint(i + 256) << 20) | (uint(srcOffset + 256) << 10) | uint(saturate(lerpK) * 1023 + 0.5f));
    }
    return true;
}

static void BlendZs(Work w, texture2d<float, access::read> color, constant Aa &k, int2 screenPos, bool horizontal, bool invertedZShape, float shapeQualityScore,
                    float lineLengthLeft, float lineLengthRight, int2 stepRight) {
    int2 blendDir = horizontal ? int2(0, -1) : int2(-1, 0);
    if (invertedZShape) blendDir = -blendDir;
    float leftOdd = c_symmetryCorrectionOffset * fmod(lineLengthLeft, 2.0f);
    float rightOdd = c_symmetryCorrectionOffset * fmod(lineLengthRight, 2.0f);
    float dampenEffect = saturate((lineLengthLeft + lineLengthRight - shapeQualityScore) * c_dampeningEffect);
    float loopFrom = -floor((lineLengthLeft + 1) / 2) + 1.0f;
    float loopTo = floor((lineLengthRight + 1) / 2);
    float totalLength = (loopTo - loopFrom) + 1 - leftOdd - rightOdd;
    float lerpStep = 1.0f / totalLength;
    float lerpFromK = (0.5f - leftOdd - loopFrom) * lerpStep;
    for (float i = loopFrom; i <= loopTo; i++) {
        float secondPart = i > 0;
        float srcOffset = 1.0f - secondPart * 2.0f;
        float lerpK = (lerpStep * i + lerpFromK) * srcOffset + secondPart;
        lerpK *= dampenEffect;
        int2 pixelPos = screenPos + stepRight * int(i);
        float3 colorCenter = LoadSourceColor(color, k, pixelPos);
        float3 colorFrom = LoadSourceColor(color, k, pixelPos + blendDir * int(srcOffset));
        StoreColorSample(w, k, pixelPos, mix(colorCenter, colorFrom, lerpK), true);
    }
}

// There were issues with moving this (including the calling code) to half-float on some hardware (broke in certain cases on RX 480).
static void DetectZsHorizontal(float4 edges, float4 edgesM1P0, float4 edgesP1P0, float4 edgesP2P0, thread float &invertedZScore, thread float &normalZScore) {
    // Inverted Z case:
    //   __
    //  X|
    // --
    invertedZScore = edges.r * edges.g * edgesP1P0.a;
    invertedZScore *= 2.0f + ((edgesM1P0.g + edgesP2P0.a)) - (edges.a + edgesP1P0.g) - 0.7f * (edgesP2P0.g + edgesM1P0.a + edges.b + edgesP1P0.r);
    // Normal Z case:
    // __
    //  X|
    //   --
    normalZScore = edges.r * edges.a * edgesP1P0.g;
    normalZScore *= 2.0f + ((edgesM1P0.a + edgesP2P0.g)) - (edges.g + edgesP1P0.a) - 0.7f * (edgesP2P0.a + edgesM1P0.g + edges.b + edgesP1P0.r);
}

kernel void cmaa2_process(texture2d<float, access::read> color [[texture(0)]], constant Aa &k [[buffer(0)]], device atomic_uint *ctl [[buffer(1)]],
                          device uint *cand [[buffer(2)]], device uint *loc [[buffer(3)]], device uint2 *item [[buffer(4)]], device atomic_uint *heads [[buffer(5)]],
                          const device uchar *edges [[buffer(6)]], uint dispatchThreadID [[thread_position_in_grid]], uint groupThreadID [[thread_position_in_threadgroup]]) {
    threadgroup atomic_uint g_groupSharedBlendItemCount;
    threadgroup uint2 g_groupSharedBlendItems[CMAA2_BLEND_ITEM_SLM_SIZE];
    const uint slmSize = min(k.slm, uint(CMAA2_BLEND_ITEM_SLM_SIZE));
    Work w = {ctl, cand, loc, item, heads};
    if (groupThreadID == 0) atomic_store_explicit(&g_groupSharedBlendItemCount, 0, memory_order_relaxed);
    // The stray item blends pixel (1, 1) with the colour 100 pixels above it: what an unwritten slot could hold, since Metal does not clear threadgroup memory
    for (uint i = groupThreadID; k.stray && i < slmSize; i += CMAA2_PROCESS_CANDIDATES_NUM_THREADS) g_groupSharedBlendItems[i] = uint2((1u << 18) | 1u, (1u << 31) | (256u << 20) | (356u << 10) | 1023u);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const uint numCandidates = atomic_load_explicit(&ctl[CTL_NUM], memory_order_relaxed);
    if (dispatchThreadID < numCandidates) {
        uint pixelID = cand[dispatchThreadID];
        int2 pixelPos = int2(pixelID >> 18, pixelID & 0x3FFF);

        uint edgesCenterPacked = LoadEdge(edges, k, pixelPos);
        float4 edgesC      = UnpackEdgesFlt(edgesCenterPacked);
        float4 edgesLeft   = UnpackEdgesFlt(LoadEdge(edges, k, pixelPos + int2(-1, 0)));
        float4 edgesRight  = UnpackEdgesFlt(LoadEdge(edges, k, pixelPos + int2(1, 0)));
        float4 edgesBottom = UnpackEdgesFlt(LoadEdge(edges, k, pixelPos + int2(0, 1)));
        float4 edgesTop    = UnpackEdgesFlt(LoadEdge(edges, k, pixelPos + int2(0, -1)));

        // simple shapes
        {
            float4 blendVal = ComputeSimpleShapeBlendValues(edgesC, edgesLeft, edgesRight, edgesTop, edgesBottom);
            const float fourWeightSum = dot(blendVal, float4(1, 1, 1, 1));
            const float centerWeight = 1.0f - fourWeightSum;
            float3 outColor = LoadSourceColor(color, k, pixelPos) * centerWeight;
            if (blendVal.x > 0.0f) outColor += blendVal.x * LoadSourceColor(color, k, pixelPos + int2(-1, 0));   // from left
            if (blendVal.y > 0.0f) outColor += blendVal.y * LoadSourceColor(color, k, pixelPos + int2(0, -1));   // from above
            if (blendVal.z > 0.0f) outColor += blendVal.z * LoadSourceColor(color, k, pixelPos + int2(1, 0));    // from right
            if (blendVal.w > 0.0f) outColor += blendVal.w * LoadSourceColor(color, k, pixelPos + int2(0, 1));    // from below
            StoreColorSample(w, k, pixelPos, outColor, false);
        }

        // complex shapes - detect
        {
            float invertedZScore, normalZScore, maxScore;
            bool horizontal = true, invertedZ = false;
            // horizontal
            {
                float4 edgesM1P0 = edgesLeft, edgesP1P0 = edgesRight, edgesP2P0 = UnpackEdgesFlt(LoadEdge(edges, k, pixelPos + int2(2, 0)));
                DetectZsHorizontal(edgesC, edgesM1P0, edgesP1P0, edgesP2P0, invertedZScore, normalZScore);
                maxScore = max(invertedZScore, normalZScore);
                if (maxScore > 0) invertedZ = invertedZScore > normalZScore;
            }
            // vertical
            {
                // Reuse the same code for vertical (used for horizontal above), but rotate input data 90 degrees counter-clockwise, so that:
                // left becomes bottom, top becomes left, right becomes top, bottom becomes right; we also have to rotate edges, thus .argb
                float4 edgesM1P0 = edgesBottom, edgesP1P0 = edgesTop, edgesP2P0 = UnpackEdgesFlt(LoadEdge(edges, k, pixelPos + int2(0, -2)));
                DetectZsHorizontal(edgesC.argb, edgesM1P0.argb, edgesP1P0.argb, edgesP2P0.argb, invertedZScore, normalZScore);
                float vertScore = max(invertedZScore, normalZScore);
                if (vertScore > maxScore) { maxScore = vertScore; horizontal = false; invertedZ = invertedZScore > normalZScore; }
            }

            if (maxScore > 0) {
                // 0 - best quality, 1 - some edges missing but ok, 2 & 3 - dubious but better than nothing
                float shapeQualityScore = EXTRA_SHARP ? round(clamp(4.0f - maxScore, 0.0f, 3.0f)) : floor(clamp(4.0f - maxScore, 0.0f, 3.0f));
                const int2 stepRight = horizontal ? int2(1, 0) : int2(0, -1);
                float lineLengthLeft, lineLengthRight;
                FindZLineLengths(lineLengthLeft, lineLengthRight, pixelPos, horizontal, invertedZ, stepRight, edges, k);
                lineLengthLeft -= shapeQualityScore;
                lineLengthRight -= shapeQualityScore;
                if ((lineLengthLeft + lineLengthRight) >= 5.0f) {
                    // try adding to SLM but fall back to in-place processing if full (which only really happens in synthetic test cases)
                    if (!CollectBlendZs(&g_groupSharedBlendItemCount, g_groupSharedBlendItems, slmSize, pixelPos, horizontal, invertedZ, shapeQualityScore, lineLengthLeft, lineLengthRight)) {
                        BlendZs(w, color, k, pixelPos, horizontal, invertedZ, shapeQualityScore, lineLengthLeft, lineLengthRight, stepRight);
                        atomic_fetch_add_explicit(&ctl[CTL_INPLACE], 1, memory_order_relaxed);
                    }
                }
            }
        }
    }

    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint totalItemCount = min(slmSize, atomic_load_explicit(&g_groupSharedBlendItemCount, memory_order_relaxed));
    // spread items into waves
    uint loops = (totalItemCount + (CMAA2_PROCESS_CANDIDATES_NUM_THREADS - 1) - groupThreadID) / CMAA2_PROCESS_CANDIDATES_NUM_THREADS;
    for (uint loop = 0; loop < loops; loop++) {
        uint index = loop * CMAA2_PROCESS_CANDIDATES_NUM_THREADS + groupThreadID;
        uint2 itemVal = g_groupSharedBlendItems[index];
        if (itemVal.x == CMAA2_BLEND_ITEM_EMPTY) continue;   // reserved by a Z shape that did not fit, and blended in place instead (CollectBlendZs)
        int2 startingPos = int2(itemVal.x >> 18, itemVal.x & 0x3FFF);
        bool itemHorizontal = (itemVal.y >> 31) & 1;
        bool itemInvertedZ = (itemVal.y >> 30) & 1;
        int itemStepIndex = int((itemVal.y >> 20) & 0x3FF) - 256;
        int itemSrcOffset = int((itemVal.y >> 10) & 0x3FF) - 256;
        float itemLerpK = (itemVal.y & 0x3FF) / 1023.0f;
        int2 itemStepRight = itemHorizontal ? int2(1, 0) : int2(0, -1);
        int2 itemBlendDir = itemHorizontal ? int2(0, -1) : int2(-1, 0);
        if (itemInvertedZ) itemBlendDir = -itemBlendDir;
        int2 itemPixelPos = startingPos + itemStepRight * itemStepIndex;
        float3 colorCenter = LoadSourceColor(color, k, itemPixelPos);
        float3 colorFrom = LoadSourceColor(color, k, itemPixelPos + itemBlendDir * itemSrcOffset);
        StoreColorSample(w, k, itemPixelPos, mix(colorCenter, colorFrom, itemLerpK), true);
    }
}

// Threads (4, 32): x is the pixel in its 2x2 quad, y the blend location (CMAA2_DEFERRED_APPLY_THREADGROUP_SWAP)
kernel void cmaa2_apply(texture2d<float, access::read> color [[texture(0)]], texture2d<float, access::write> out [[texture(1)]], constant Aa &k [[buffer(0)]],
                        device atomic_uint *ctl [[buffer(1)]], device uint *loc [[buffer(3)]], device uint2 *item [[buffer(4)]], device atomic_uint *heads [[buffer(5)]],
                        uint2 dispatchThreadID [[thread_position_in_grid]], uint2 groupThreadID [[thread_position_in_threadgroup]]) {
    const uint numCandidates = atomic_load_explicit(&ctl[CTL_NUM], memory_order_relaxed);
    const uint currentCandidate = dispatchThreadID.y;
    const uint currentQuadOffsetXY = groupThreadID.x;
    if (currentCandidate >= numCandidates) return;

    uint pixelID = loc[currentCandidate];
    uint2 quadPos = uint2(pixelID >> 16, pixelID & 0xFFFF);
    const uint2 qeOffsets[4] = {uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 1)};
    uint2 pixelPos = quadPos * 2 + qeOffsets[currentQuadOffsetXY];
    uint counterIndexWithHeader = atomic_load_explicit(&heads[quadPos.y * k.stride + quadPos.x], memory_order_relaxed);

    float4 outColors = float4(0);
    const uint maxLoops = 32;   // do the loop to prevent bad data hanging the GPU <- probably not needed
    for (uint i = 0; (counterIndexWithHeader != 0xFFFFFFFF) && (i < maxLoops); i++) {
        // decode item-specific info: {2 bits for 2x2 quad location}, {3 bits for MSAA sample index}, {1 bit for isComplexShape flag}, {26 bits for address}
        uint offsetXY = (counterIndexWithHeader >> 30) & 0x03;
        bool isComplexShape = (counterIndexWithHeader >> 26) & 0x01;
        uint index = counterIndexWithHeader & ((1 << 26) - 1);
        if (index >= k.cap_item) break;   // only a list head left over from an earlier run could point here: StoreColorSample links no item past the capacity
        uint2 val = item[index];
        counterIndexWithHeader = val.x;
        if (offsetXY == currentQuadOffsetXY) {
            float3 c = InternalUnpackColor(val.y);
            float weight = 0.8f + 1.0f * float(isComplexShape);
            outColors += float4(c * weight, weight);
        }
    }
    if (outColors.a == 0 || any(pixelPos >= k.size)) return;

    float3 rgb = outColors.rgb / outColors.a;
    if (CONVERT) rgb = float3(LINEAR_to_SRGB(rgb.x), LINEAR_to_SRGB(rgb.y), LINEAR_to_SRGB(rgb.z));
    float4 o = float4(rgb, color.read(pixelPos).a);
    out.write(o, pixelPos);
    // the crop's last column and row into the padding past them (MetalFX's input; see the top)
    bool right = pixelPos.x == k.size.x - 1, bottom = pixelPos.y == k.size.y - 1;
    for (uint j = 0; right && j < k.pad.x; j++) out.write(o, uint2(k.size.x + j, pixelPos.y));
    for (uint j = 0; bottom && j < k.pad.y; j++) out.write(o, uint2(pixelPos.x, k.size.y + j));
    for (uint j = 0; right && bottom && j < k.pad.x; j++) for (uint i = 0; i < k.pad.y; i++) out.write(o, uint2(k.size.x + j, k.size.y + i));
}
