// GPU diagnostics of the NVN layer (nvn_mtl.m), the parts that are plain C and run on any machine (dm/gfx/tests/t_gpu_diag.c, make gpu-diag: plain, TSan, ASan):
//   - GPU errors of the host's own command buffers (presents, snapshot copies, uploads, readbacks ...): a [RED] line at the 1st, 2nd, 4th, 8th ... error of a kind (gd_err_due).
//     The iPhone's GPU resets with Frame buffering on left only victims' lines (kIOGPUCommandBufferCallbackErrorInnocentVictim) in log.txt: the command buffer that faulted had
//     no handler (the present snapshot copy had none), or was another process's. Every command buffer the host commits now has one.
//   - The passes of each command buffer of the game's submissions (a submission, its segments, an indirect-count wait), in a fixed ring of compact records written with plain
//     stores on the submit thread and turned into text only when that command buffer fails (gd_pass_*): its passes, their kinds, sizes and formats, and the shader keys bound
//     in them, without DM_NVN_ENC_LABEL. No allocation and no string on the submit thread: a pass costs about 16 stores and one store barrier, a draw or dispatch a load, a
//     store and a compare (two more stores when its program differs from the last one of its pass).
//   - The GPU's busy time from command buffers' GPU start and end times, the intervals' union (gd_busy_*): the power line's GPU ms/s on iOS, where task_power_info's
//     gpu_energy.task_gpu_utilisation reads 0 (hle_nvn.c power_line).
#pragma once
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// ---------- Errors by kind ----------
// The n-th error of a kind (counted from 1, any thread) is logged when n is a power of two: returns n then, 0 for the errors between. A storm of errors (every command
// buffer in flight is discarded when the GPU resets) costs a few lines, and the count still shows how many there were
static inline uint32_t gd_err_due(_Atomic uint32_t *count) {
    uint32_t n = atomic_fetch_add_explicit(count, 1, memory_order_relaxed) + 1;
    return n && !(n & (n - 1)) ? n : 0;
}

// ---------- The passes of the game's command buffers ----------
// GD_RING passes are kept, whatever command buffer they belong to: about ten frames of a heavy game (Breath of the Wild: about 150 passes a frame), far more than the GPU is
// behind the submit thread when a command buffer's feedback comes (a few frames). A command buffer is the range [first, end) of record numbers it encoded (gd_cb_close);
// a record overwritten since, by a pass GD_RING later, reads as gone (gd_pass_text)
enum { GD_RING = 2048 };
enum { GD_RENDER = 'R', GD_HOST_RENDER = 'r', GD_COMPUTE = 'C', GD_COPY = 'B', GD_DLSS = 'D', GD_METALFX = 'M' };
// R a game render pass (rp_begin_ex), r one of the host's own (clears, copies drawn, geometry, transform feedback), C a compute encoder of the host's (built-in kernels,
// geometry, dispatches in an encoder of their own), B the copy encoder (copies, fills, uniform updates, and the dispatches that share it), D NVN2's DLSS on MetalFX,
// M the game's upscaler drawn by MetalFX
typedef struct {
    _Atomic uint64_t tag;          // the record's number + 1 once written; 0 while it is written again
    _Atomic uint64_t key[4];       // the first program's vertex and fragment shader keys (a kernel's in key[0]), the last other program's in key[2], key[3]
    _Atomic uint32_t frame, pass;  // the frame; a game render pass's number (g_stat_pass, as [gpuprof] and DM_NVN_PASSDUMP count them), 0 for the other kinds
    _Atomic uint16_t w, h, cfmt, dfmt, draws, nth;   // size; MTLPixelFormat of colour attachment 0 and of the depth (or stencil) attachment; draws or dispatches; the record's place in its frame
    _Atomic uint8_t kind, ncol, samples, progs;      // kind; colour attachments; samples; programs bound (each change counts, up to 255)
} gd_pass;
typedef struct {
    gd_pass r[GD_RING];
    uint64_t seq;          // records written so far (submit thread only, as every field below)
    uint64_t cb_first;     // the first record of the command buffer being encoded
    gd_pass *cur;          // the open record (NULL after gd_cb_close until the next pass)
    const void *prog;      // the program last noted in it
    uint32_t frame;        // the frame of the last record,
    uint64_t frame_first;  // and the number of its frame's first record
    int off;               // DM_NVN_PASS_RING=0 (nvn_mtl.m mtl_init, before any pass): nothing is recorded, a pass costs a load and a branch and a draw finds no open record
} gd_ring;

#define GD_ST(f, v) atomic_store_explicit(&(f), (v), memory_order_relaxed)
#define GD_LD(f) atomic_load_explicit(&(f), memory_order_relaxed)
// A pass begins (submit thread). Its size, formats and samples are what its attachments have (0 for a compute or copy encoder)
static inline void gd_pass_begin(gd_ring *g, int kind, uint32_t frame, uint32_t pass, unsigned w, unsigned h, unsigned ncol, unsigned cfmt, unsigned dfmt, unsigned samples) {
    if (g->off) return;
    uint64_t s = g->seq++;
    gd_pass *p = &g->r[s % GD_RING];
    if (!s || frame != g->frame) { g->frame = frame; g->frame_first = s; }
    // A seqlock of one writer: a reader that sees any store below also sees the tag cleared (the fence orders it before them), and so knows the record changed under it
    GD_ST(p->tag, 0);
    atomic_thread_fence(memory_order_release);
    for (int i = 0; i < 4; i++) GD_ST(p->key[i], 0);
    GD_ST(p->frame, frame); GD_ST(p->pass, pass);
    GD_ST(p->w, (uint16_t)(w > 0xffff ? 0xffff : w)); GD_ST(p->h, (uint16_t)(h > 0xffff ? 0xffff : h));
    GD_ST(p->cfmt, (uint16_t)cfmt); GD_ST(p->dfmt, (uint16_t)dfmt); GD_ST(p->draws, 0); GD_ST(p->nth, (uint16_t)(s - g->frame_first));
    GD_ST(p->kind, (uint8_t)kind); GD_ST(p->ncol, (uint8_t)ncol); GD_ST(p->samples, (uint8_t)samples); GD_ST(p->progs, 0);
    atomic_store_explicit(&p->tag, s + 1, memory_order_release);
    g->cur = p; g->prog = NULL;
}
// A draw or dispatch in the open pass (submit thread): counted; returns 1 when its program is not the last one noted, and the caller then passes its keys to gd_prog
static inline int gd_count(gd_ring *g, const void *prog) {
    gd_pass *p = g->cur;
    if (!p) return 0;
    uint16_t d = GD_LD(p->draws); if (d != 0xffff) GD_ST(p->draws, (uint16_t)(d + 1));
    return prog != g->prog;
}
static inline void gd_prog(gd_ring *g, const void *prog, uint64_t k0, uint64_t k1) {
    gd_pass *p = g->cur;
    if (!p) return;
    uint8_t n = GD_LD(p->progs);
    GD_ST(p->key[n ? 2 : 0], k0); GD_ST(p->key[n ? 3 : 1], k1);
    if (n != 0xff) GD_ST(p->progs, (uint8_t)(n + 1));
    g->prog = prog;
}
// The command buffer being encoded is committed (submit thread): its records are [*first, *end); the next pass begins the next command buffer's
static inline void gd_cb_close(gd_ring *g, uint64_t *first, uint64_t *end) { *first = g->cb_first; *end = g->cb_first = g->seq; g->cur = NULL; g->prog = NULL; }

// A shader key as shader_map.tsv writes it, or "-" for none (a built-in kernel, a stage the program does not have)
static inline const char *gd_key(char b[17], uint64_t k) { if (!k) return "-"; snprintf(b, 17, "%016llx", (unsigned long long)k); return b; }
// Record s as text (any thread; for a command buffer that failed): 0 when it is gone, overwritten by a pass GD_RING later
static inline int gd_pass_text(gd_ring *g, uint64_t s, char *out, size_t n) {
    gd_pass *p = &g->r[s % GD_RING];
    if (atomic_load_explicit(&p->tag, memory_order_acquire) != s + 1) return 0;
    uint64_t k[4]; for (int i = 0; i < 4; i++) k[i] = GD_LD(p->key[i]);
    unsigned frame = GD_LD(p->frame), pass = GD_LD(p->pass), w = GD_LD(p->w), h = GD_LD(p->h), cfmt = GD_LD(p->cfmt), dfmt = GD_LD(p->dfmt), draws = GD_LD(p->draws), nth = GD_LD(p->nth);
    int kind = GD_LD(p->kind); unsigned ncol = GD_LD(p->ncol), samples = GD_LD(p->samples), progs = GD_LD(p->progs);
    atomic_thread_fence(memory_order_acquire);
    if (atomic_load_explicit(&p->tag, memory_order_relaxed) != s + 1) return 0;
    int o = snprintf(out, n, "frame %u #%u %c", frame, nth, kind ? kind : '?');
    if (o < 0 || (size_t)o >= n) return 1;
    if (kind == GD_RENDER) o += snprintf(out + o, n - (size_t)o, " pass %u", pass);
    if (w && (size_t)o < n) o += snprintf(out + o, n - (size_t)o, " %ux%u", w, h);
    if ((ncol || dfmt) && (size_t)o < n) o += snprintf(out + o, n - (size_t)o, " colours %u (format %u) depth/stencil format %u samples %u", ncol, cfmt, dfmt, samples ? samples : 1);
    int compute = kind == GD_COMPUTE || kind == GD_COPY || kind == GD_METALFX;
    if ((size_t)o < n) o += snprintf(out + o, n - (size_t)o, ", %u %s%s", draws, compute ? "dispatches" : "draws", draws == 0xffff ? " or more" : "");
    char b0[17], b1[17];
    if (progs && (size_t)o < n) {
        if (compute) o += snprintf(out + o, n - (size_t)o, ", kernel %s", gd_key(b0, k[0]));
        else o += snprintf(out + o, n - (size_t)o, ", vertex %s fragment %s", gd_key(b0, k[0]), gd_key(b1, k[1]));
        if (progs > 1 && (size_t)o < n) {
            if (compute) o += snprintf(out + o, n - (size_t)o, " ... last kernel %s", gd_key(b0, k[2]));
            else o += snprintf(out + o, n - (size_t)o, " ... last vertex %s fragment %s", gd_key(b0, k[2]), gd_key(b1, k[3]));
            if ((size_t)o < n) o += snprintf(out + o, n - (size_t)o, " (%u%s programs bound)", progs, progs == 0xff ? " or more" : "");
        }
    }
    return 1;
}
// Which records of [first, end) to show, at most max: all of them, or the first max / 2 and the last max - max / 2. Returns how many; *gap is the index (from first) where
// the left-out ones begin, *skip how many are left out
static inline unsigned gd_pick(uint64_t first, uint64_t end, unsigned max, uint64_t *gap, uint64_t *skip) {
    uint64_t n = end > first ? end - first : 0;
    if (n <= max) { *gap = n; *skip = 0; return (unsigned)n; }
    *gap = max / 2; *skip = n - max; return max;
}
#undef GD_ST
#undef GD_LD

// ---------- GPU busy time ----------
// The union of command buffers' GPU intervals (ns): the part of an interval before the latest end seen so far is taken as covered, so command buffers that overlap on the GPU
// count once. One writer: every feedback handler of the Metal 4 queue runs on one serial queue (nvn_mtl.m g_feedback_q). They come in about the order the GPU ran the work
// (each encoder starts with a queue barrier); one reported after a later one it did not overlap would count only past that one's end, an undercount. Readers on any thread
typedef struct { uint64_t end; _Atomic uint64_t busy; } gd_busy;
static inline void gd_busy_add(gd_busy *b, uint64_t s0, uint64_t s1) {
    if (!s0 || s1 <= s0) return;   // a command buffer can complete with no start time (nvn_mtl.m gpu_tag_done), and a failed one with none at all
    uint64_t from = s0 > b->end ? s0 : b->end;
    if (s1 > from) atomic_store_explicit(&b->busy, atomic_load_explicit(&b->busy, memory_order_relaxed) + (s1 - from), memory_order_relaxed);
    if (s1 > b->end) b->end = s1;
}
static inline uint64_t gd_busy_ns(gd_busy *b) { return atomic_load_explicit(&b->busy, memory_order_relaxed); }
