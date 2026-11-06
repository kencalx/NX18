// LDSM.x4 from tid.x: (tid.x & 15) * 64 + (tid.x >> 4 & 1) * 16, local size 64x2x1, its words stored.
// The translator's output (spirv-cross, XLATE_DEBUG=1) before upstream's bd9f422d (chain 300c544190ae: HMMA calls of 12 arguments) for a synthetic Ampere program, local size 64x2x1: no game's code.
// Cut down for dm/gfx/tests/test_tensor_census.py: the headers, and the helper's per-lane body (dmsh_build.py hmma_msl replaces it anyway).
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

kernel void main0(uint3 gl_LocalInvocationID [[thread_position_in_threadgroup]], uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]])
{
    threadgroup spvUnsafeArray<uint, 2048> _18;
    float _32 = as_type<float>(gl_LocalInvocationID.x);
    int _35 = as_type<int>(_32) & 15;
    uint _38 = uint(int(uint(as_type<int>(_32)) >> uint(4)));
    int _40 = int(_38) & 1;
    int _42 = _35 * 64;
    int _44 = _40 * 16;
    int _46 = _44 + _42;
    float _48 = as_type<float>(gl_SubgroupInvocationID);
    uint _50 = uint(int(uint(as_type<int>(_48)) >> uint(2)));
    int _52 = as_type<int>(_48) & 3;
    float _54 = spvSubgroupShuffle(as_type<float>(_46), _50);
    int _56 = _52 << 2;
    int _58 = as_type<int>(_54) + _56;
    uint _60 = uint(int(uint(_58) >> uint(2)));
    float _62 = as_type<float>(_18[int(_60)]);
    int _64 = int(_50) + 8;
    float _66 = spvSubgroupShuffle(as_type<float>(_46), uint(_64));
    int _68 = _52 << 2;
    int _70 = as_type<int>(_66) + _68;
    uint _72 = uint(int(uint(_70) >> uint(2)));
    float _74 = as_type<float>(_18[int(_72)]);
    int _76 = int(_50) + 16;
    float _78 = spvSubgroupShuffle(as_type<float>(_46), uint(_76));
    int _80 = _52 << 2;
    int _82 = as_type<int>(_78) + _80;
    uint _84 = uint(int(uint(_82) >> uint(2)));
    float _86 = as_type<float>(_18[int(_84)]);
    int _88 = int(_50) + 24;
    float _90 = spvSubgroupShuffle(as_type<float>(_46), uint(_88));
    int _92 = _52 << 2;
    int _94 = as_type<int>(_90) + _92;
    uint _96 = uint(int(uint(_94) >> uint(2)));
    float _98 = as_type<float>(_18[int(_96)]);
    _18[8] = as_type<uint>(_62);
    _18[9] = as_type<uint>(_74);
    _18[10] = as_type<uint>(_86);
    _18[11] = as_type<uint>(_98);
}
