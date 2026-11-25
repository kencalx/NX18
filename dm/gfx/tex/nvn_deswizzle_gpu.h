#pragma once
#include <stddef.h>
#include <stdint.h>
#import <Metal/Metal.h>
#include "nvn_deswizzle.h"

int nvn_deswz_gpu_init(id<MTLDevice> dev, id<MTL4Compiler> comp);   // the kernels' pipelines, built through comp (the host's MTL4Compiler)
// Small RGBA16F arrays: write raw component bits through an integer texture
// view, across all layers in one dispatch per mip (no per-face staging/copies).
int nvn_deswz_gpu_direct_supported(const nvn_texdesc *d);
int nvn_deswz_gpu_direct_m4(id<MTL4ComputeCommandEncoder> enc, id<MTL4ArgumentTable> table,
                            id<MTLBuffer> params, size_t params_off, id<MTLBuffer> src, uint64_t src_off,
                            const nvn_texdesc *d, unsigned level, id<MTLTexture> uint_view);
int nvn_deswz_gpu_encode_m4(id<MTL4ComputeCommandEncoder> enc, id<MTL4ArgumentTable> table,
                            id<MTLBuffer> params, size_t params_off, id<MTLBuffer> src, uint64_t src_off,
                            const nvn_texdesc *d, unsigned level, unsigned layer,
                            id<MTLBuffer> dst, uint64_t dst_off, size_t dst_pitch);
// Block rows [row0, row0 + nrows) only (row0 a multiple of the level's GOB block rows, 8 << its block height; not 3D): a band of a level re-uploaded where its storage was written (nvn_mtl.m
// pkg_upload_), into dst as rows of dst_pitch from dst_off
int nvn_deswz_gpu_encode_rows_m4(id<MTL4ComputeCommandEncoder> enc, id<MTL4ArgumentTable> table,
                                 id<MTLBuffer> params, size_t params_off, id<MTLBuffer> src, uint64_t src_off,
                                 const nvn_texdesc *d, unsigned level, unsigned layer, uint32_t row0, uint32_t nrows,
                                 id<MTLBuffer> dst, uint64_t dst_off, size_t dst_pitch);
