// The render-pass savings' pure decisions (nvn_rpsave.h, and nvn_cover_draw_ok in nvn_cover.h): expected values by hand from the rules, without Metal
#include "../nvn/nvn_rpsave.h"
#include "../nvn/nvn_cover.h"
#include <stdio.h>

static int fail, total;
static void t(const char *name, long want, long got) {
    total++; fail += want != got;
    printf("%-72s expected %#lx got %#lx %s\n", name, (unsigned long)want, (unsigned long)got, want == got ? "ok" : "FAIL");
}
int main(void) {
    // DM_NVN_CLEAR_FMTMASK
    t("R16 cleared with mask 0x1 (LM3 p01-p03) is whole", 1, nvn_clear_whole(0x1, 0x1, 0, 1));
    t("R16 cleared with mask 0xf is whole", 1, nvn_clear_whole(0xf, 0x1, 0, 1));
    t("RG11B10F cleared with mask 0x7 is whole", 1, nvn_clear_whole(0x7, 0x7, 0, 1));
    t("neg: RGBA8 cleared with mask 0x7 keeps alpha: a triangle", 0, nvn_clear_whole(0x7, 0xf, 0, 1));
    t("neg: RG16 cleared with mask 0x1 keeps green", 0, nvn_clear_whole(0x1, 0x3, 0, 1));
    t("neg: mask 0x1 on R16 inside a pass", 0, nvn_clear_whole(0x1, 0x1, 1, 1));
    t("neg: mask 0x1 on R16 with a partial scissor", 0, nvn_clear_whole(0x1, 0x1, 0, 0));
    t("neg: mask 0 clears nothing", 0, nvn_clear_whole(0x0, 0x1, 0, 1));
    t("neg: unknown format", 0, nvn_clear_whole(0xf, 0x0, 0, 1));
    t("A8 cleared with mask 0x8 is whole", 1, nvn_clear_whole(0x8, 0x8, 0, 1));
    // the slots a draw writes
    t("p103: full masks, the fragment writes output 0 only", 0x1, nvn_rp_wmask(0xffffffffu, 1, 1, 0x1, 0));
    t("outputs 0 and 2, slot 2's channel mask 0", 0x1, nvn_rp_wmask(0xfffff0ffu, 1, 1, 0x5, 0));
    t("outputs not known: every slot with channels (slot 1 has none)", 0xfd, nvn_rp_wmask(0xffffff0fu, 1, 0, 0x1, 0));
    t("a logic operation or specialized fragment: every slot with channels", 0xff, nvn_rp_wmask(0xffffffffu, 1, 1, 0x1, 1));
    t("no fragment stage writes no colour", 0, nvn_rp_wmask(0xffffffffu, 0, 1, 0xff, 1));
    t("BotW's G-buffer: mask 0x00f0f0ff (c2 and c4 zero), outputs 0-4", 0xb, nvn_rp_wmask(0x00f0f0ffu, 1, 1, 0x1f, 0));
    // DM_NVN_OMIT_UNWRITTEN
    { unsigned long w[8] = {1920, 1920, 1920}, h[8] = {1080, 1080, 1080};
      t("p103: slots 1 and 2 left out, slot 0 stays", 0x6, nvn_rp_omit(0x6, 0x7, w, h, 0, 0, 0));
      t("neg: every slot unwritten and no depth: the last one stays", 0x3, nvn_rp_omit(0x7, 0x7, w, h, 0, 0, 0));
      t("every colour slot unwritten with depth: one colour stays", 0x3, nvn_rp_omit(0x7, 0x7, w, h, 1, 1920, 1080));
      t("a slot not present is not left out", 0x2, nvn_rp_omit(0xa, 0x7, w, h, 0, 0, 0)); }
    { unsigned long w[8] = {1920, 960}, h[8] = {1080, 540};
      t("neg: the smaller slot sets the pass size: it stays", 0, nvn_rp_omit(0x2, 0x3, w, h, 0, 0, 0));
      t("the larger slot may go: the pass keeps 960x540", 0x1, nvn_rp_omit(0x1, 0x3, w, h, 0, 0, 0)); }
    { unsigned long w[8] = {960, 960}, h[8] = {540, 540};
      t("two smallest of one size: either may go, one stays", 0x1, nvn_rp_omit(0x3, 0x3, w, h, 0, 0, 0));
      t("neg: depth 1920x1080, colour 960x540 both unwritten: one colour stays", 0x1, nvn_rp_omit(0x3, 0x3, w, h, 1, 1920, 1080)); }
    { unsigned long w[8] = {1920, 1000}, h[8] = {500, 1080};
      t("neg: each slot is the smallest in one direction: both stay", 0, nvn_rp_omit(0x3, 0x3, w, h, 1, 1920, 1080)); }
    // DM_NVN_LOAD_COVER's draw check
    t("a direct draw with vertex and fragment stages", 1, nvn_cover_draw_ok(0, 0, 0, 0));
    t("neg: indirect draw", 0, nvn_cover_draw_ok(1, 0, 0, 0));
    t("neg: an indirect-count multi-draw's entry", 0, nvn_cover_draw_ok(0, 1, 0, 0));
    t("neg: a tessellation, geometry or mesh stage", 0, nvn_cover_draw_ok(0, 0, 1, 0));
    t("neg: the vertex shader writes the layer or viewport", 0, nvn_cover_draw_ok(0, 0, 0, 1));
    printf("== %d checks, %d failed ==\n", total, fail);
    return fail != 0;
}
