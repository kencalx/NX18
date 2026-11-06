// The host's own Metal shaders (dm/gfx/msl/<name>.metal), compiled into the host when it is built (dm/gfx/tools/host_msl.py). host_msl_lib loads one by name from the
// metallib the build made: no compile at run time, so the Metal performance HUD counts none and no thread waits for the compiler. A library the build could not compile
// (no Metal toolchain) is compiled from its source, through comp when there is one, else the device, with a [RED] line. Libraries are made once per device and name
#pragma once
#import <Metal/Metal.h>

id<MTLLibrary> host_msl_lib(id<MTLDevice> dev, id<MTL4Compiler> comp, const char *name, NSError **e);
// A start-up self-test's kernel (selftest.m), compiled when the host was built as the game chain compiles this platform's game shaders (host_msl.py, hmma_selftest.py): its
// metallib, or NULL when the build has none; *record says which commands compiled it, or why there is none. Nothing is compiled at run time
const unsigned char *host_msl_chain_lib(const char *name, unsigned long *len, const char **record);
