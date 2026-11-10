// Diagnostic DM_NVN_MAGSCAN (nvn_mtl.m ms_after, ms_fs_override).
// ms: per 16x16 block of a colour attachment (one threadgroup of 16x16 threads), the magenta pixel count (R and B both >= 0.8 of the largest channel, G <= 0.1 of it), the
// non-finite pixel count, each channel's largest value and whether the block holds one value throughout. o[0], o[1]: the attachment's size; o[2]: blocks per row; the blocks'
// four words each from o + 4.
// msg / msm: the constant fragment output of phases 2 / 3 (grey 0.5 / bright magenta 1500,2,1500)
#include <metal_stdlib>
using namespace metal;
kernel void ms(texture2d<float, access::read> t [[texture(0)]], device uint *o [[buffer(0)]], uint2 g [[thread_position_in_grid]], uint2 tg [[threadgroup_position_in_grid]],
               uint li [[thread_index_in_threadgroup]], uint si [[simdgroup_index_in_threadgroup]], uint sl [[thread_index_in_simdgroup]]) {
  threadgroup uint sh[8][8]; bool in = g.x < o[0] && g.y < o[1]; float4 c = in ? t.read(g) : float4(0); float m = max(c.r, max(c.g, c.b));
  bool bad = in && (isnan(c.r) || isnan(c.g) || isnan(c.b) || isinf(c.r) || isinf(c.g) || isinf(c.b));
  bool mag = in && !bad && m > 0.0 && c.r >= 0.8 * m && c.b >= 0.8 * m && c.g <= 0.1 * m;
  uint r = as_type<uint>(max(c.r, 0.0)), gg = as_type<uint>(max(c.g, 0.0)), b = as_type<uint>(max(c.b, 0.0));
  uint v[8] = {simd_sum(mag ? 1u : 0u), simd_sum(bad ? 1u : 0u), simd_min(in ? r : ~0u), simd_max(in ? r : 0u), simd_min(in ? gg : ~0u), simd_max(in ? gg : 0u), simd_min(in ? b : ~0u), simd_max(in ? b : 0u)};
  if (sl == 0) for (int k = 0; k < 8; k++) sh[si][k] = v[k];
  threadgroup_barrier(mem_flags::mem_threadgroup); if (li) return;
  for (int s = 1; s < 8; s++) { v[0] += sh[s][0]; v[1] += sh[s][1]; for (int k = 2; k < 8; k += 2) { v[k] = min(v[k], sh[s][k]); v[k + 1] = max(v[k + 1], sh[s][k + 1]); } }
  device uint *q = o + 4 + 4 * (tg.y * o[2] + tg.x); q[0] = v[0] | v[1] << 16 | (v[2] == v[3] && v[4] == v[5] && v[6] == v[7] ? 1u << 31 : 0u); q[1] = v[3]; q[2] = v[5]; q[3] = v[7]; }
fragment float4 msg() { return float4(0.5, 0.5, 0.5, 1.0); }
fragment float4 msm() { return float4(1500.0, 2.0, 1500.0, 0.6); }
