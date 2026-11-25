// When a pipeline the compiler service failed to build is built again (../nvn/nvn_pso_retry.h; ported from the S2Arm project's 2a7e0bf9). The expected frames are worked out by hand.
#include <stdio.h>
#include "../nvn/nvn_pso_retry.h"
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
int main(void) {
    CHECK("an interrupted connection is a service crash", pso_err_service_crash("Compiler encountered XPC_ERROR_CONNECTION_INTERRUPTED"));
    CHECK("an invalid connection is a service crash", pso_err_service_crash("Compiler encountered an internal error: XPC_ERROR_CONNECTION_INVALID"));
    CHECK("Metal's own wording of it", pso_err_service_crash("Compiler encountered an error: interrupted connection to the compiler service"));
    CHECK("a compile error is not", !pso_err_service_crash("Fragment input(s) `user(locn0)` mismatching vertex shader output type(s) or not written by vertex shader"));
    CHECK("a link error is not", !pso_err_service_crash("Link failed: function 'f' not found"));
    CHECK("no text is not", !pso_err_service_crash(NULL) && !pso_err_service_crash(""));
    CHECK("1st failure: 30 frames", pso_retry_at(1000, 1) == 1030);
    CHECK("2nd failure: 120 frames", pso_retry_at(1000, 2) == 1120);
    CHECK("3rd failure: 480 frames", pso_retry_at(1000, 3) == 1480);
    CHECK("4th failure: never again", pso_retry_at(1000, 4) == 0);
    CHECK("past the limit: never again", pso_retry_at(1000, 9) == 0 && pso_retry_at(1000, 255) == 0);
    CHECK("no failure: nothing to retry", pso_retry_at(1000, 0) == 0);
    uint64_t big = PSO_RETRY_FRAME_MASK, v = pso_retry_pack(big, 3);
    CHECK("packing keeps the frame and the count apart", pso_retry_frame(v) == big && pso_retry_fails(v) == 3);
    v = pso_retry_pack(1796, 1); CHECK("packing small values", pso_retry_frame(v) == 1796 && pso_retry_fails(v) == 1);
    // A pair the service crashes on every time, from frame 1766 for 10 minutes at 60 fps, with the caller's rule (build again at the frame or after; fails + 1 on each failure)
    uint64_t at = 1766; unsigned fails = 0, tries = 0; int given_up = 0;
    for (uint64_t f = 1766; f < 1766 + 36000; f++) { if (given_up || f < at) continue; tries++; fails++; at = pso_retry_at(f, fails); if (!at) given_up = 1; }
    CHECK("a pair that always crashes the service: built 4 times, then given up (1,200 times every 30 frames before)", given_up && tries == PSO_RETRY_MAX);
    CHECK("a one-off crash costs 30 frames", pso_retry_at(500, 1) - 500 == 30);
    printf("t_pso_retry: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
