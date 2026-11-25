// When a render pipeline the system compiler service failed to build is built again (pso_get_, nvn_mtl.m; ported from the S2Arm project's 2a7e0bf9). Pure functions: the frame
// numbers come from the caller (t_pso_retry checks them).
// Only a crash of the compiler service counts: its XPC connection interrupted or invalid (Metal retries a few times itself before it reports one). It is not the pipeline's fault
// and may not happen again: S2Arm saw one such failure in 35 runs of The Witcher 3 that the next build compiled. An ordinary compile error says nothing of the kind and the pipeline
// stays on the failed list for the run (g_pso_fail), as before. The service may also crash on one pair every time: S2Arm's report from an M1 Max running Ocarina of Time had the
// same pair fail within 4 ms in each of three runs, and retrying every 30 frames crashed the service all run long, taking the builds running beside it down too. So the n-th failure
// in a row waits PSO_RETRY_FRAMES·4^(n-1) frames (30, 120, 480), and the PSO_RETRY_MAX-th puts the pair on the failed list.
#pragma once
#include <stdint.h>
#include <string.h>

enum { PSO_RETRY_FRAMES = 30, PSO_RETRY_MAX = 4 };
#define PSO_RETRY_FRAME_MASK ((1ull << 56) - 1)

// Whether a build's error text says the compiler service crashed, not that the pipeline failed to compile
static inline int pso_err_service_crash(const char *d) {
    return d && (strstr(d, "XPC_ERROR_CONNECTION_INTERRUPTED") || strstr(d, "XPC_ERROR_CONNECTION_INVALID") || strstr(d, "interrupted connection"));
}
// fails: the pair's failures in a row, this one included (1 or more). The frame to build it again at; 0: never again
static inline uint64_t pso_retry_at(uint64_t now, unsigned fails) {
    if (fails == 0 || fails >= PSO_RETRY_MAX) return 0;
    return now + ((uint64_t)PSO_RETRY_FRAMES << (2 * (fails - 1)));
}
// The retry table's value: the failures in the top 8 bits, the frame in the low 56 (one NSNumber, no second table)
static inline uint64_t pso_retry_pack(uint64_t at, unsigned fails) { return (uint64_t)(fails & 0xff) << 56 | (at & PSO_RETRY_FRAME_MASK); }
static inline uint64_t pso_retry_frame(uint64_t v) { return v & PSO_RETRY_FRAME_MASK; }
static inline unsigned pso_retry_fails(uint64_t v) { return (unsigned)(v >> 56); }
