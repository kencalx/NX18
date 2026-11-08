// LDSM.x2 at 0x100 and LDSM.MT88.x2 at 0x400 (Ra = RZ), their words stored.
// The translator's output (spirv-cross, XLATE_DEBUG=1) since upstream's bd9f422d (each LDSM matrix lowered on its own, HMMA calls with TensorPass's flags) and 16776913 (each LDSM between subgroup barriers) for a synthetic Ampere program, local size 32x1x1: no game's code.
// Cut down for dm/gfx/tests/test_tensor_census.py: the headers, and the helper's per-lane body (dmsh_build.py hmma_msl replaces it anyway).
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

kernel void main0(uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]])
{
    threadgroup spvUnsafeArray<uint, 2048> _18;
    simdgroup_barrier(mem_flags::mem_threadgroup);
    float _28 = as_type<float>(gl_SubgroupInvocationID);
    uint _31 = uint(int(uint(as_type<int>(_28)) >> uint(2)));
    int _34 = as_type<int>(_28) & 3;
    int _36 = int(_31) + 0;
    float _38 = spvSubgroupShuffle(3.5873240686715317015647477332222e-43, uint(_36));
    int _40 = _34 << 2;
    int _42 = as_type<int>(_38) + _40;
    uint _44 = uint(int(uint(_42) >> uint(2)));
    float _46 = as_type<float>(_18[int(_44)]);
    int _48 = as_type<int>(_46);
    float _50 = as_type<float>(gl_SubgroupInvocationID);
    uint _52 = uint(int(uint(as_type<int>(_50)) >> uint(2)));
    int _54 = as_type<int>(_50) & 3;
    int _56 = int(_52) + 8;
    float _58 = spvSubgroupShuffle(3.5873240686715317015647477332222e-43, uint(_56));
    int _60 = _54 << 2;
    int _62 = as_type<int>(_58) + _60;
    uint _64 = uint(int(uint(_62) >> uint(2)));
    float _66 = as_type<float>(_18[int(_64)]);
    int _68 = as_type<int>(_66);
    simdgroup_barrier(mem_flags::mem_threadgroup);
    simdgroup_barrier(mem_flags::mem_threadgroup);
    float _70 = as_type<float>(gl_SubgroupInvocationID);
    uint _72 = uint(int(uint(as_type<int>(_70)) >> uint(2)));
    int _74 = as_type<int>(_70) & 3;
    int _76 = _74 << 1;
    int _78 = _76 + 0;
    int _80 = _78 + 0;
    float _82 = spvSubgroupShuffle(1.4349296274686126806258990932889e-42, uint(_80));
    int _84 = int(_72) << 1;
    int _86 = as_type<int>(_82) + _84;
    uint _88 = uint(int(uint(_86) >> uint(2)));
    float _90 = as_type<float>(_18[int(_88)]);
    int _92 = _86 & 2;
    int _94 = _92 << 3;
    uint _96 = extract_bits(as_type<uint>(_90), uint(_94), 16u);
    int _98 = _74 << 1;
    int _100 = _98 + 1;
    int _102 = _100 + 0;
    float _104 = spvSubgroupShuffle(1.4349296274686126806258990932889e-42, uint(_102));
    int _106 = int(_72) << 1;
    int _108 = as_type<int>(_104) + _106;
    uint _110 = uint(int(uint(_108) >> uint(2)));
    float _112 = as_type<float>(_18[int(_110)]);
    int _114 = _108 & 2;
    int _116 = _114 << 3;
    uint _118 = extract_bits(as_type<uint>(_112), uint(_116), 16u);
    int _120 = int(_118) << 16;
    int _122 = int(_96) | _120;
    int _124 = _122;
    float _126 = as_type<float>(gl_SubgroupInvocationID);
    uint _128 = uint(int(uint(as_type<int>(_126)) >> uint(2)));
    int _130 = as_type<int>(_126) & 3;
    int _132 = _130 << 1;
    int _134 = _132 + 0;
    int _136 = _134 + 8;
    float _138 = spvSubgroupShuffle(1.4349296274686126806258990932889e-42, uint(_136));
    int _140 = int(_128) << 1;
    int _142 = as_type<int>(_138) + _140;
    uint _144 = uint(int(uint(_142) >> uint(2)));
    float _146 = as_type<float>(_18[int(_144)]);
    int _148 = _142 & 2;
    int _150 = _148 << 3;
    uint _152 = extract_bits(as_type<uint>(_146), uint(_150), 16u);
    int _154 = _130 << 1;
    int _156 = _154 + 1;
    int _158 = _156 + 8;
    float _160 = spvSubgroupShuffle(1.4349296274686126806258990932889e-42, uint(_158));
    int _162 = int(_128) << 1;
    int _164 = as_type<int>(_160) + _162;
    uint _166 = uint(int(uint(_164) >> uint(2)));
    float _168 = as_type<float>(_18[int(_166)]);
    int _170 = _164 & 2;
    int _172 = _170 << 3;
    uint _174 = extract_bits(as_type<uint>(_168), uint(_172), 16u);
    int _176 = int(_174) << 16;
    int _178 = int(_152) | _176;
    int _180 = _178;
    simdgroup_barrier(mem_flags::mem_threadgroup);
    _18[8] = uint(_48);
    _18[9] = uint(_68);
    _18[10] = uint(_124);
    _18[11] = uint(_180);
}
