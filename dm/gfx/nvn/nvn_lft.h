// The long-frame line's split of the replay's time (the "; replay split:" part of hle_nvn.c's [longframe] line; nvn_mtl.m keeps the timers, mtl_lft_take hands them over).
// Mario Kart World's title load had a frame of 474 ms, 416 ms of it submit and present, whose line named 83 ms of texture uploads and nothing else (the round of 2026-11-15,
// scan/071972d7-Archive/log.txt:370): the rest had no cause in the log. The timers run on the replay thread only, from where its work begins to where it ends:
//   LFT_TEX   textures and their memory made: tex_mtl_'s texture (a render target's, with its fill), an upload's new texture and CPU staging buffer
//   LFT_SWZ   the CPU's deswizzle of an upload (a sparse texture's gather with it); the GPU's deswizzle is the upload batch's, not timed here
//   LFT_MD    textures left without their top levels (DM_NVN_MIP_DROP) made whole again for a host use (md_whole: an upload each)
//   LFT_RES   residency adds (res_add); LFT_RESC the residency set's commits on the replay thread (the kernel's part, res_commit)
//   LFT_LOCK  the replay's waits for the host's locks (g_mu, g_smu, g_rmu, g_res_mu, g_res_commit_mu), read only when a lock is held by another thread (a try first)
// A part may hold another (a lock wait inside a texture's making counts in both); up[k] is the part of k inside a texture upload (pkg_upload), whose time the line already
// gives. drain_ns: the replay's waits for the encode thread (rec_drain). Logging only
#pragma once
#include <stdint.h>
#include <stdio.h>
enum { LFT_TEX, LFT_SWZ, LFT_MD, LFT_RES, LFT_RESC, LFT_LOCK, LFT_N };
typedef struct { uint64_t ns[LFT_N], n[LFT_N], up[LFT_N], drain_ns; } nvn_lft;
void mtl_lft_take(nvn_lft *out);
// The replay's page-ins by the part of its work that was running (nvn_mtl.m pf_*): the process's page-in count (task_info TASK_EVENTS_INFO) read at each change of part while a
// replayed node's scope runs (mtl_pf_scope), the difference given to the part that ran. Process-wide counts: another thread's page-ins at the same time go to whatever part the
// replay was in. PF_OTHER is the replay's work outside the named parts. Logging only (the long-frame line)
enum { PF_OTHER, PF_TEX, PF_SCAN, PF_POOL, PF_UBD, PF_UPLOAD, PF_RES, PF_IDX, PF_UBP, PF_PBUF, PF_VBUF, PF_ARGS, PF_PSO, PF_IMG, PF_TBA, PF_A_MISC, PF_A_TEX, PF_A_POOL, PF_A_CBUF, PF_A_DRV, PF_A_PUSH, PF_A_STORE, PF_TEXLOOK, PF_EDGE, PF_N };
void mtl_pf_scope(int on);              // a replayed node's scope begins (1) or ends (0), on the replay thread
void mtl_pf_take(uint64_t out[PF_N]);   // the counts since the last call, which starts the next
int mtl_sop_text(char *out, size_t n);   // the replay's slow commands since the last call (DM_NVN_PF_PARTS), as the long-frame line's part; resets them
static inline int nvn_pf_text(char *out, size_t n, const uint64_t pf[PF_N]) {
    static const char *const name[PF_N] = {"other", "textures made", "storage scans", "pool tables", "uniform reads", "uploads", "residency", "index scans", "uniform shadows", "pool buffers made", "vertex buffers", "arguments", "pipelines", "images", "buffer-texture copies", "arguments: other bindings", "arguments: textures and samplers", "arguments: pool and handle tables", "arguments: uniforms and sizes", "arguments: driver banks", "arguments: push constants", "arguments: storage, images, raw memory", "texture lookups", "edge checks"};
    uint64_t sum = 0; for (int k = 0; k < PF_N; k++) sum += pf[k];
    if (!n || !sum) { if (n) out[0] = 0; return 0; }
    int o = snprintf(out, n, "; replay page-ins by part:");
    for (int k = 0; k < PF_N && o > 0 && (size_t)o < n; k++) if (pf[k]) o += snprintf(out + o, n - (size_t)o, " %s %llu,", name[k], (unsigned long long)pf[k]);
    if (o > 0 && (size_t)o < n && out[o - 1] == ',') out[--o] = 0;
    return o < 0 ? 0 : (size_t)o < n ? o : (int)n - 1;
}   // nvn_mtl.m: the split since the last call, which starts the next
// The line's part, into out (n bytes): every part with a count, in the order above, when they come to 0.5 ms or more together (with the encode-thread waits); "" otherwise.
// Returns the characters written
static inline int nvn_lft_text(char *out, size_t n, const nvn_lft *l) {
    static const char *const name[LFT_N] = {"textures made", "CPU deswizzle", "mip-dropped textures made whole", "residency adds", "residency commits", "lock waits"};
    if (!n) return 0;
    out[0] = 0;
    uint64_t sum = l->drain_ns; for (int k = 0; k < LFT_N; k++) sum += l->ns[k];
    if (sum < 500000) return 0;
    int o = snprintf(out, n, "; replay split:");
    for (int k = 0; k < LFT_N && o > 0 && (size_t)o < n; k++) {
        if (!l->n[k]) continue;
        o += snprintf(out + o, n - (size_t)o, " %s %llu, %.1f ms", name[k], (unsigned long long)l->n[k], l->ns[k] / 1e6);
        if (l->up[k] >= 50000 && (size_t)o < n) o += snprintf(out + o, n - (size_t)o, " (%.1f in uploads)", l->up[k] / 1e6);
        if ((size_t)o < n) o += snprintf(out + o, n - (size_t)o, ";");
    }
    if (l->drain_ns >= 50000 && o > 0 && (size_t)o < n) o += snprintf(out + o, n - (size_t)o, " encode-thread waits %.1f ms;", l->drain_ns / 1e6);
    if (o > 0 && (size_t)o < n && out[o - 1] == ';') out[--o] = 0;
    return o < 0 ? 0 : (size_t)o < n ? o : (int)n - 1;
}
