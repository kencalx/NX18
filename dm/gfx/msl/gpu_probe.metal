// The GPU probe (nvn_mtl.m mtl_gpu_probe): a fixed job whose GPU time follows the GPU's clock. One SIMD group runs a dependent chain of fused multiply-adds, so its time is
// the chain's latency (cycles / clock), not the number of GPU cores or the memory. The seed comes from the buffer, so the compiler cannot fold the chain; the buffer holds 32 floats.
#include <metal_stdlib>
using namespace metal;
constant uint GPU_PROBE_STEPS = 2048;   // nvn_mtl.m says the same in its comment: about 120 µs on an idle Apple M4 Max (t_gpu_probe)
kernel void dm_gpu_probe(device float *v [[buffer(0)]], uint t [[thread_position_in_grid]]) {
  float x = v[t];
  for (uint k = 0; k < GPU_PROBE_STEPS; k++) x = fma(x, 0.9990234375f, 1.0f);   // converges to 1024: no overflow, no denormals
  v[t] = x; }
