// Run the ordinary-IR fixture and compare every data/guard word in both modes.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <string.h>
#include "../t_mtl4.h"   // a Metal 4 queue of its own (the standalone back end)

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2) return 1;   // 2 is t_mtl4.h's "no Metal 4 device" (a skip)
    if (!MTLCreateSystemDefaultDevice()) return 77;
    id<MTLDevice> device = t4_dev();
    enum { GUARD = 16, WORDS = 64 };
    uint32_t initial[WORDS], expected[WORDS];
    for (unsigned i = 0; i < WORDS; i++) initial[i] = 0xc1000000u + i * 0x103u;
    memcpy(expected, initial, sizeof expected);
    // Independent arithmetic/memory model of Program.cs, not generated-source matching.
    expected[GUARD] = 6 * (3 + 4);
    expected[GUARD + 1] = 6 + (3 + 4);
    expected[GUARD + 2] = 77;
    expected[GUARD + 3] = 99;
    expected[GUARD + 4] = initial[GUARD + 3] + 7;
    expected[GUARD + 5] = 13;
    expected[GUARD + 6] = 10 + 11;
    expected[GUARD + 7] = initial[GUARD + 7] + 5;

    unsigned failures = 0;
    for (NSString *mode in @[@"optimized", @"debug"]) {
        NSError *error = nil;
        NSString *path = [@(argv[1]) stringByAppendingPathComponent:[mode stringByAppendingString:@".metal"]];
        NSString *source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        MTLCompileOptions *options = [MTLCompileOptions new];
        options.languageVersion = MTLLanguageVersion2_4;
        id<MTLLibrary> library = t4_lib(source, options, &error);
        id<MTLFunction> function = library ? t4_fn(library, @"main0") : nil;
        id<MTLComputePipelineState> pipeline = function ? t4_cps(function, &error) : nil;
        if (!pipeline) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        id<MTLBuffer> data = [device newBufferWithBytes:initial length:sizeof initial options:MTLResourceStorageModeShared];
        T4 *command = t4_begin();
        id<MTL4ComputeCommandEncoder> encoder = t4_compute(command);
        [encoder setComputePipelineState:t4_keep(command, pipeline)];
        t4_buf(command, encoder, T4_CS, data, GUARD * sizeof(uint32_t), 1);
        [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        t4_end(command, encoder);
        if (t4_wait(command) != MTLCommandBufferStatusCompleted) { fprintf(stderr, "the GPU run failed\n"); return 1; }
        const uint32_t *got = data.contents;
        unsigned bad = 0;
        for (unsigned i = 0; i < WORDS; i++) if (got[i] != expected[i]) {
            fprintf(stderr, "%s word %u: got %#x, expected %#x\n", mode.UTF8String, i, got[i], expected[i]); bad++;
        }
        failures += bad;
        printf("%s: %u words, %u mismatches\n", mode.UTF8String, WORDS, bad);
    }
    printf("device: %s\n", device.name.UTF8String);
    return failures != 0;
} }
