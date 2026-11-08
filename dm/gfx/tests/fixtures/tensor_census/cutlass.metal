// LDSM.x4 from tid.x: (tid.x & 15) * 64 + (tid.x >> 4 & 1) * 16, local size 64x2x1, its words stored.
// The translator's output (spirv-cross, XLATE_DEBUG=1) since upstream's bd9f422d (each LDSM matrix lowered on its own, HMMA calls with TensorPass's flags) and 16776913 (each LDSM between subgroup barriers) for a synthetic Ampere program, local size 64x2x1: no game's code.
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
    simdgroup_barrier(mem_flags::mem_threadgroup);
    float _48 = as_type<float>(gl_SubgroupInvocationID);
    uint _50 = uint(int(uint(as_type<int>(_48)) >> uint(2)));
    int _52 = as_type<int>(_48) & 3;
    int _54 = int(_50) + 0;
    float _56 = spvSubgroupShuffle(as_type<float>(_46), uint(_54));
    int _58 = _52 << 2;
    int _60 = as_type<int>(_56) + _58;
    uint _62 = uint(int(uint(_60) >> uint(2)));
    float _64 = as_type<float>(_18[int(_62)]);
    int _66 = as_type<int>(_64);
    float _68 = as_type<float>(gl_SubgroupInvocationID);
    uint _70 = uint(int(uint(as_type<int>(_68)) >> uint(2)));
    int _72 = as_type<int>(_68) & 3;
    int _74 = int(_70) + 8;
    float _76 = spvSubgroupShuffle(as_type<float>(_46), uint(_74));
    int _78 = _72 << 2;
    int _80 = as_type<int>(_76) + _78;
    uint _82 = uint(int(uint(_80) >> uint(2)));
    float _84 = as_type<float>(_18[int(_82)]);
    int _86 = as_type<int>(_84);
    float _88 = as_type<float>(gl_SubgroupInvocationID);
    uint _90 = uint(int(uint(as_type<int>(_88)) >> uint(2)));
    int _92 = as_type<int>(_88) & 3;
    int _94 = int(_90) + 16;
    float _96 = spvSubgroupShuffle(as_type<float>(_46), uint(_94));
    int _98 = _92 << 2;
    int _100 = as_type<int>(_96) + _98;
    uint _102 = uint(int(uint(_100) >> uint(2)));
    float _104 = as_type<float>(_18[int(_102)]);
    int _106 = as_type<int>(_104);
    float _108 = as_type<float>(gl_SubgroupInvocationID);
    uint _110 = uint(int(uint(as_type<int>(_108)) >> uint(2)));
    int _112 = as_type<int>(_108) & 3;
    int _114 = int(_110) + 24;
    float _116 = spvSubgroupShuffle(as_type<float>(_46), uint(_114));
    int _118 = _112 << 2;
    int _120 = as_type<int>(_116) + _118;
    uint _122 = uint(int(uint(_120) >> uint(2)));
    float _124 = as_type<float>(_18[int(_122)]);
    int _126 = as_type<int>(_124);
    simdgroup_barrier(mem_flags::mem_threadgroup);
    _18[8] = uint(_66);
    _18[9] = uint(_86);
    _18[10] = uint(_106);
    _18[11] = uint(_126);
}
