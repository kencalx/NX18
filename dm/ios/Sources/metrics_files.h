// The files of Documents/metrics (DmMetrics.m): one JSON file per MetricKit report, named <UTC date>-<UTC time>-<sequence>-<kind>.json (20261105-143012-000-diagnostic-crash.json), so that
// the names sort by age whatever the kind, and only the newest DM_METRICS_KEEP of them are kept. Plain C, so the unit tests compile and run it on Linux (dm/ios/tests/test_metrics_bgprepare.py)
#pragma once
#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum { DM_METRICS_KEEP = 30 };

// The file name for a report written at time t; seq tells reports written in the same second apart (DmMetrics.m counts it per process and steps it past a name that is taken).
// Returns the length snprintf gives, or -1 when kind is empty or carries a character a file name should not (only letters, digits and - are taken)
static inline int dm_metrics_name(char *out, size_t n, time_t t, unsigned seq, const char *kind) {
    if (!kind || !*kind) return -1;
    for (const char *c = kind; *c; c++)
        if (!((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == '-')) return -1;
    struct tm tm;
    if (!gmtime_r(&t, &tm)) return -1;
    return snprintf(out, n, "%04d%02d%02d-%02d%02d%02d-%03u-%s.json", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, seq % 1000u, kind);
}

// Whether a name in the folder is one of the reports (it starts with a digit and ends in .json): anything else there, a player's own file or a write in progress, is never deleted
static inline int dm_metrics_is_report(const char *name) {
    size_t L = strlen(name);
    return L > 5 && name[0] >= '0' && name[0] <= '9' && !strcmp(name + L - 5, ".json");
}
static inline int dm_metrics_cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

// Deletes the oldest reports in dir past the newest keep. Returns how many it deleted, -1 when the folder cannot be read or memory runs out (then nothing is deleted)
static inline int dm_metrics_prune(const char *dir, int keep) {
    if (keep < 0) keep = 0;
    DIR *d = opendir(dir);
    if (!d) return -1;
    char **names = NULL; size_t n = 0, cap = 0; int bad = 0;
    for (struct dirent *e; (e = readdir(d)) != NULL;) {
        if (!dm_metrics_is_report(e->d_name)) continue;
        if (n == cap) {
            char **grown = realloc(names, (cap = cap ? cap * 2 : 64) * sizeof *names);
            if (!grown) { bad = 1; break; }
            names = grown;
        }
        if (!(names[n] = strdup(e->d_name))) { bad = 1; break; }
        n++;
    }
    closedir(d);
    int deleted = 0;
    if (!bad && n > (size_t)keep) {
        qsort(names, n, sizeof *names, dm_metrics_cmp);
        for (size_t i = 0; i < n - (size_t)keep; i++) {
            char p[PATH_MAX];
            if (snprintf(p, sizeof p, "%s/%s", dir, names[i]) < (int)sizeof p && !unlink(p)) deleted++;
        }
    }
    for (size_t i = 0; i < n; i++) free(names[i]);
    free(names);
    return bad ? -1 : deleted;
}
