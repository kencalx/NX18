// LDSM.x4 from an address read from shared memory, its first word stored.
// The translator's output (spirv-cross, XLATE_DEBUG=1) since upstream's bd9f422d (each LDSM matrix lowered on its own, HMMA calls with TensorPass's flags) for a synthetic Ampere program, local size 32x1x1: no game's code.
// Cut down for dm/gfx/tests/test_tensor_census.py: the headers, and the helper's per-lane body (dmsh_build.py hmma_msl replaces it anyway).
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

kernel void main0(uint3 gl_LocalInvocationID [[thread_position_in_threadgroup]], uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]])
{
    threadgroup spvUnsafeArray<uint, 2048> _18;
    float _32 = as_type<float>(gl_LocalInvocationID.x);
    int _35 = as_type<int>(_32) & 15;
    int _37 = _35 + 16;
    uint _40 = uint(int(uint(_37) >> uint(2)));
    float _42 = as_type<float>(_18[int(_40)]);
    float _44 = as_type<float>(gl_SubgroupInvocationID);
    uint _46 = uint(int(uint(as_type<int>(_44)) >> uint(2)));
    int _48 = as_type<int>(_44) & 3;
    int _50 = int(_46) + 0;
    float _52 = spvSubgroupShuffle(_42, uint(_50));
    int _54 = _48 << 2;
    int _56 = as_type<int>(_52) + _54;
    uint _58 = uint(int(uint(_56) >> uint(2)));
    float _60 = as_type<float>(_18[int(_58)]);
    int _62 = as_type<int>(_60);
    _18[8] = uint(_62);
}
