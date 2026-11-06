// LDSM.x2 at 0x100 and LDSM.MT88.x2 at 0x400 (Ra = RZ), their words stored.
// The translator's output (spirv-cross, XLATE_DEBUG=1) before upstream's bd9f422d (chain 300c544190ae: HMMA calls of 12 arguments) for a synthetic Ampere program, local size 32x1x1: no game's code.
// Cut down for dm/gfx/tests/test_tensor_census.py: the headers, and the helper's per-lane body (dmsh_build.py hmma_msl replaces it anyway).
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

kernel void main0(uint gl_SubgroupInvocationID [[thread_index_in_simdgroup]])
{
    threadgroup spvUnsafeArray<uint, 2048> _18;
    float _28 = as_type<float>(gl_SubgroupInvocationID);
    uint _31 = uint(int(uint(as_type<int>(_28)) >> uint(2)));
    int _34 = as_type<int>(_28) & 3;
    float _36 = spvSubgroupShuffle(3.5873240686715317015647477332222e-43, _31);
    int _38 = _34 << 2;
    int _40 = as_type<int>(_36) + _38;
    uint _42 = uint(int(uint(_40) >> uint(2)));
    float _44 = as_type<float>(_18[int(_42)]);
    int _46 = int(_31) + 8;
    float _48 = spvSubgroupShuffle(3.5873240686715317015647477332222e-43, uint(_46));
    int _50 = _34 << 2;
    int _52 = as_type<int>(_48) + _50;
    uint _54 = uint(int(uint(_52) >> uint(2)));
    float _56 = as_type<float>(_18[int(_54)]);
    float _58 = as_type<float>(gl_SubgroupInvocationID);
    uint _60 = uint(int(uint(as_type<int>(_58)) >> uint(2)));
    int _62 = as_type<int>(_58) & 3;
    int _64 = _62 << 1;
    float _66 = spvSubgroupShuffle(1.4349296274686126806258990932889e-42, uint(_64));
    int _68 = int(_60) << 1;
    int _70 = as_type<int>(_66) + _68;
    uint _72 = uint(int(uint(_70) >> uint(2)));
    float _74 = as_type<float>(_18[int(_72)]);
    int _76 = _70 & 2;
    int _78 = _76 << 3;
    uint _80 = extract_bits(as_type<uint>(_74), uint(_78), 16u);
    int _82 = _62 << 1;
    int _84 = _82 + 1;
    float _86 = spvSubgroupShuffle(1.4349296274686126806258990932889e-42, uint(_84));
    int _88 = int(_60) << 1;
    int _90 = as_type<int>(_86) + _88;
    uint _92 = uint(int(uint(_90) >> uint(2)));
    float _94 = as_type<float>(_18[int(_92)]);
    int _96 = _90 & 2;
    int _98 = _96 << 3;
    uint _100 = extract_bits(as_type<uint>(_94), uint(_98), 16u);
    int _102 = int(_100) << 16;
    int _104 = int(_80) | _102;
    int _106 = _62 << 1;
    int _108 = _106 + 8;
    float _110 = spvSubgroupShuffle(1.4349296274686126806258990932889e-42, uint(_108));
    int _112 = int(_60) << 1;
    int _114 = as_type<int>(_110) + _112;
    uint _116 = uint(int(uint(_114) >> uint(2)));
    float _118 = as_type<float>(_18[int(_116)]);
    int _120 = _114 & 2;
    int _122 = _120 << 3;
    uint _124 = extract_bits(as_type<uint>(_118), uint(_122), 16u);
    int _126 = _62 << 1;
    int _128 = _126 + 1;
    int _130 = _128 + 8;
    float _132 = spvSubgroupShuffle(1.4349296274686126806258990932889e-42, uint(_130));
    int _134 = int(_60) << 1;
    int _136 = as_type<int>(_132) + _134;
    uint _138 = uint(int(uint(_136) >> uint(2)));
    float _140 = as_type<float>(_18[int(_138)]);
    int _142 = _136 & 2;
    int _144 = _142 << 3;
    uint _146 = extract_bits(as_type<uint>(_140), uint(_144), 16u);
    int _148 = int(_146) << 16;
    int _150 = int(_124) | _148;
    _18[8] = as_type<uint>(_44);
    _18[9] = as_type<uint>(_56);
    _18[10] = uint(_104);
    _18[11] = uint(_150);
}
