// The empty fragment function of a host render pipeline that draws no colour (host_msl_rps with no fragment function: a depth / stencil only clear or copy). Metal 4 needs
// a fragment function whenever rasterization is on (MTL4RenderPipeline.h)
fragment void dm_nop() {}
