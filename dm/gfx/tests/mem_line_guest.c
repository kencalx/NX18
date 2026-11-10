// t_mem_line's guest block: the strong svc_guest_range that the host's hle_svc.c gives, in a file of its own, as nvn_mtl.m (which the test includes) has the weak one that names no block
#include <stddef.h>
#include <stdint.h>
uint8_t *g_t_guest_base; size_t g_t_guest_size;
void svc_guest_range(uint8_t **base, size_t *size) { *base = g_t_guest_base; *size = g_t_guest_size; }
