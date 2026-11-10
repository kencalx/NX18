// Diagnostic DM_NVN_HILITE=<fragment shader key>,...: the solid colours that replace those shaders' fragment output (keys 1-6 in order magenta / green / cyan / yellow / blue /
// white), to see where their geometry lands (nvn_mtl.m pso_desc). Three colour outputs, as the targets a game's pass binds most often
#include <metal_stdlib>
using namespace metal;
struct O { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; float4 c2 [[color(2)]]; };
fragment O hl0() { return {float4(1,0,1,1),float4(1,0,1,1),float4(1,0,1,1)}; } fragment O hl1() { return {float4(0,1,0,1),float4(0,1,0,1),float4(0,1,0,1)}; }
fragment O hl2() { return {float4(0,1,1,1),float4(0,1,1,1),float4(0,1,1,1)}; } fragment O hl3() { return {float4(1,1,0,1),float4(1,1,0,1),float4(1,1,0,1)}; }
fragment O hl4() { return {float4(0,0,1,1),float4(0,0,1,1),float4(0,0,1,1)}; } fragment O hl5() { return {float4(1,1,1,1),float4(1,1,1,1),float4(1,1,1,1)}; }
