// t_signpost's stand-in for Apple's <os/signpost.h>: each call is counted by t_signpost.c, which defines the functions. Found first on the include path (-Isignpost_stub),
// so the same checks run on the Mac and on Linux. Name and format must be string literals, as with the real macros
#pragma once
#include <stdint.h>
typedef struct os_log_s *os_log_t;
typedef uint64_t os_signpost_id_t;
#define OS_SIGNPOST_ID_NULL ((os_signpost_id_t)0)
#define OS_SIGNPOST_ID_EXCLUSIVE ((os_signpost_id_t)0xEEEEB0B5B2B2EEEE)
#define OS_LOG_CATEGORY_POINTS_OF_INTEREST "PointsOfInterest"
os_log_t os_log_create(const char *subsystem, const char *category);
os_signpost_id_t os_signpost_id_generate(os_log_t log);
void stub_sp(int kind, os_log_t log, os_signpost_id_t id, const char *name, const char *fmt, ...);
#define os_signpost_interval_begin(log, id, name, fmt, ...) stub_sp('b', log, id, "" name "", "" fmt "", ##__VA_ARGS__)
#define os_signpost_interval_end(log, id, name, fmt, ...) stub_sp('e', log, id, "" name "", "" fmt "", ##__VA_ARGS__)
#define os_signpost_event_emit(log, id, name, fmt, ...) stub_sp('v', log, id, "" name "", "" fmt "", ##__VA_ARGS__)
