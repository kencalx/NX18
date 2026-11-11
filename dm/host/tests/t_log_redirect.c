// dm_log_redirect (log_redirect.h), the front ends' log onto the standard descriptors: the iPhone app's log.txt onto 2 (main.m), the Mac launcher's log onto 1 and 2
// (launcher.c). Each case runs in a child started as a launch would start the front end: descriptors 0 to 2 on an "outside" file (where a terminal or Xcode's console would be),
// some of them closed, then the redirect, to a log that opens or to one that cannot be created. The child then opens a stand-in save file, as the host's first file, writes
// through descriptor 2 (crash.c's write(2, ...)), the stream stderr and, for the Mac form, descriptor 1, and starts a program that writes to both (the Mac launcher's host
// inherits them). The save must hold only its own bytes, every line must be in the log when it opened, or where the launch put that descriptor when it did not (nowhere when
// that was closed), and no standard descriptor may be free or closed on exec afterwards. The old forms fail it: freopen(log, "w", stderr) with a log that cannot be created,
// and open, dup2, close with 2 (or 1) closed at launch, put the log lines into the save.
// Build and run: make -C dm/host/tests GAME=<title ID> log-redirect (no game profile is used; plain POSIX, so it runs on the Mac and on Linux)
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include "log_redirect.h"

extern char **environ;
static int checks, fails;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d %s: ", __FILE__, __LINE__, #c); printf(__VA_ARGS__); printf("\n"); } } while (0)

static char dir[512], log_path[600], bad_log[600], save_path[600], outside_path[600];

static size_t slurp(const char *path, char *buf, size_t n) {
    buf[0] = 0; FILE *f = fopen(path, "rb"); if (!f) return 0;
    size_t k = fread(buf, 1, n - 1, f); buf[k] = 0; fclose(f); return k;
}
static void put(const char *path, const char *text) { FILE *f = fopen(path, "wb"); if (f) { fputs(text, f); fclose(f); } }

// Child failures, one bit each, as its exit status
enum { C_RESULT = 1, C_OPEN = 2, C_CLOEXEC = 4, C_SAVE_FD = 8, C_SPAWN = 16, C_WRITE = 32 };

static int child(int closed, int log_ok, int first, mode_t mode) {
    int outside = open(outside_path, O_WRONLY | O_CREAT | O_APPEND, 0644);   // where the launch put 0 to 2
    if (outside < 0) return 64;
    for (int d = 0; d <= 2; d++) dup2(outside, d);
    close(outside);
    for (int d = 0; d <= 2; d++) if (closed & 1 << d) close(d);
    umask(0);
    int bad = 0;
    int err = dm_log_redirect(log_ok ? log_path : bad_log, mode, first);
    if (log_ok ? err != 0 : err != ENOENT) bad |= C_RESULT;
    if (!err) setvbuf(stderr, NULL, _IOLBF, 0);
    for (int d = 0; d <= 2; d++) {
        int f = fcntl(d, F_GETFD);
        if (f < 0) bad |= C_OPEN;
        else if (d >= first && (f & FD_CLOEXEC)) bad |= C_CLOEXEC;
    }
    int save = open(save_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);   // the host's first file, a save
    if (save <= STDERR_FILENO) bad |= C_SAVE_FD;
    static const char l2[] = "line through descriptor 2\n", l1[] = "line through descriptor 1\n";
    if (write(STDERR_FILENO, l2, sizeof l2 - 1) != (ssize_t)(sizeof l2 - 1) && !(closed & 4 && err)) bad |= C_WRITE;
    fprintf(stderr, "line through the stream stderr\n"); fflush(stderr);
    if (first == STDOUT_FILENO && write(STDOUT_FILENO, l1, sizeof l1 - 1) < 0 && !(closed & 2 && err)) bad |= C_WRITE;
    char *argv[] = {"sh", "-c", "echo spawned program output; echo spawned program error output >&2", NULL};
    pid_t pid; int st;
    if (posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, environ) || waitpid(pid, &st, 0) != pid || !WIFEXITED(st) || WEXITSTATUS(st)) bad |= C_SPAWN;
    if (save >= 0) { static const char s[] = "the save's own bytes"; if (write(save, s, sizeof s - 1) != (ssize_t)(sizeof s - 1)) bad |= C_WRITE; close(save); }
    return bad;
}

static void run_case(int closed, int log_ok, int first, int stale_log) {
    unlink(log_path); unlink(save_path); unlink(outside_path);
    if (stale_log) put(log_path, "the previous run's lines\n");   // a log the open must truncate
    mode_t mode = first == STDERR_FILENO ? 0666 : 0644;   // main.m: freopen's mode; launcher.c: 0644
    fflush(stdout);
    pid_t pid = fork();
    if (!pid) _exit(child(closed, log_ok, first, mode));
    int st = 0; waitpid(pid, &st, 0);
    char what[160]; snprintf(what, sizeof what, "closed at launch {%s%s%s}, log %s, onto %s", closed & 1 ? " 0" : "", closed & 2 ? " 1" : "", closed & 4 ? " 2" : "",
                             log_ok ? (stale_log ? "opens (an old one there)" : "opens") : "cannot be created", first == STDOUT_FILENO ? "1 and 2" : "2");
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "%s: child status 0x%x", what, st);
    char save[4096], logt[4096], out[4096];
    slurp(save_path, save, sizeof save); slurp(log_path, logt, sizeof logt); slurp(outside_path, out, sizeof out);
    CHECK(!strcmp(save, "the save's own bytes"), "%s: the save holds [%s]", what, save);
    // Where each descriptor's lines must be: the log when it opened, else where the launch put that descriptor (nowhere when it was closed)
    int d2_out = !log_ok && !(closed & 4), d1_out = !(closed & 2) && (first == STDERR_FILENO || !log_ok);
    const char *err_lines[] = {"line through descriptor 2", "line through the stream stderr", "spawned program error output"};
    for (int i = 0; i < 3; i++) {
        CHECK(!!strstr(logt, err_lines[i]) == log_ok, "%s: [%s] in the log: [%s]", what, err_lines[i], logt);
        CHECK(!!strstr(out, err_lines[i]) == d2_out, "%s: [%s] outside: [%s]", what, err_lines[i], out);
    }
    CHECK(!!strstr(logt, "spawned program output") == (log_ok && first == STDOUT_FILENO), "%s: the program's output in the log: [%s]", what, logt);
    CHECK(!!strstr(out, "spawned program output") == d1_out, "%s: the program's output outside: [%s]", what, out);
    if (first == STDOUT_FILENO) CHECK(!!strstr(logt, "line through descriptor 1") == log_ok, "%s: descriptor 1's line in the log: [%s]", what, logt);
    if (log_ok) {
        CHECK(!strstr(logt, "previous run"), "%s: the old log was not truncated: [%s]", what, logt);
        struct stat sb;
        if (!stale_log) CHECK(!stat(log_path, &sb) && (sb.st_mode & 0777) == mode, "%s: log mode %o, not %o", what, (unsigned)(sb.st_mode & 0777), (unsigned)mode);
    } else {
        CHECK(access(log_path, F_OK), "%s: a log was made", what);
    }
}

int main(void) {
    const char *tmp = getenv("TMPDIR");
    snprintf(dir, sizeof dir, "%s/t_log_redirect.XXXXXX", tmp && *tmp ? tmp : "/tmp");
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    snprintf(log_path, sizeof log_path, "%s/log.txt", dir); snprintf(bad_log, sizeof bad_log, "%s/no such folder/log.txt", dir);
    snprintf(save_path, sizeof save_path, "%s/save.bin", dir); snprintf(outside_path, sizeof outside_path, "%s/outside.txt", dir);
    for (int first = STDOUT_FILENO; first <= STDERR_FILENO; first++)
        for (int closed = 0; closed < 8; closed++)
            for (int log_ok = 0; log_ok < 2; log_ok++) run_case(closed, log_ok, first, log_ok && closed & 1);
    unlink(log_path); unlink(save_path); unlink(outside_path); rmdir(dir);
    printf("t_log_redirect: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
