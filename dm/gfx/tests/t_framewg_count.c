// Counting stand-ins for the frame workgroup (the host's frame_wg.c), linked into t_nvn_framewg in place of hle_nvn.c's weak ones that do nothing: each call is counted with
// the name of the thread it came from, the joins with the name they were given and the starts with their deadline. No interval is made, so no thread joins anything and threads
// may end freely (t_framewg tests frame_wg.c itself on libdispatch)
#include "../../host/frame_wg.h"
#include <pthread.h>
#include <string.h>

int fwg_joins, fwg_ends, fwg_begins;
uint64_t fwg_last_period;
char fwg_last_who[64], fwg_end_on[64], fwg_begin_on[64];
int dm_frame_wg_join(const char *who) { fwg_joins++; strlcpy(fwg_last_who, who ? who : "", sizeof fwg_last_who); return 0; }
void dm_frame_wg_end(void) { fwg_ends++; pthread_getname_np(pthread_self(), fwg_end_on, sizeof fwg_end_on); }
void dm_frame_wg_begin(uint64_t period_ns) { fwg_begins++; fwg_last_period = period_ns; pthread_getname_np(pthread_self(), fwg_begin_on, sizeof fwg_begin_on); }
void dm_frame_wg_counts_read(dm_frame_wg_counts *c) { memset(c, 0, sizeof *c); }
