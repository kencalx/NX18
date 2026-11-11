// The front ends' log file onto the standard descriptors: the iPhone app's Documents/log.txt onto 2 (dm/ios/Sources/main.m log_open), the Mac launcher's
// ~/Library/Logs/nxnative/<title ID>.log onto 1 and 2 (dm/mac/launcher.c log_open, whose host inherits both). The host writes its log to stderr, and some writers use descriptor
// 2 directly, not the stream: crash.c's write(2, ...) of a crash report, Swift's launcher log, NSLog, the diagnostic threads a launch environment can start before main
// (DM_MEMSTAT, DM_THRCPU, DM_FD_LOG). So descriptor 2 must never be free: open() hands out the lowest free descriptor, and a free 2 goes to the next file the process opens,
// possibly a save, which then receives every later write to descriptor 2 (a crash report, NSLog, and the log lines while the stream stderr is on it). Two old forms freed it.
// freopen(log, "w", stderr) closes descriptor 2 before it opens the file and leaves it closed when the open fails (Documents full or not writable: main.m has just moved log.txt
// to log.prev.txt, so the file has to be created). And open, dup2 onto 1 and 2, close: when the launch left 2 closed (a shell's 2>&-, a parent that closed it) open returns 2
// itself, and the close then frees the descriptor just set up. dm_log_redirect first puts /dev/null on any of 0, 1 and 2 the launch left closed (in a normal start, from the Home
// Screen, Xcode, Finder, the Dock or a terminal, all three are open and nothing changes), so the log's own descriptor is above 2, then moves the log onto each descriptor from
// first to 2 with dup2, which replaces it in one step, so no other thread can be handed it in between, and closes its own descriptor. A log that cannot be opened leaves the
// descriptors where the launch put them (Xcode's console, a terminal, /dev/null) and the caller says so on stderr. Not O_CLOEXEC: dup2's copy is inheritable anyway, and the
// Mac's host must inherit 1 and 2 (posix_spawn). Plain POSIX, header only, so both front ends and dm/host/tests/t_log_redirect.c use this very code
#ifndef DM_LOG_REDIRECT_H
#define DM_LOG_REDIRECT_H
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

// path (created or truncated with mode, as fopen's "w" does with 0666) onto descriptors first..2: STDERR_FILENO for 2 alone, STDOUT_FILENO for 1 and 2. 0 when the log is
// there, else the errno of its open (the standard descriptors are then each open: as the launch left them, or on /dev/null)
static inline int dm_log_redirect(const char *path, mode_t mode, int first) {
    for (int to = STDIN_FILENO; to <= STDERR_FILENO; to++) {
        if (fcntl(to, F_GETFD) >= 0) continue;   // open: as the launch put it
        // The lowest free descriptor, so this one, as the ones below it are open. Above 2 only when another thread's open took this one between the two calls, and then
        // nothing of this is left open. That other thread's file is not kept when the descriptor is one the log goes onto (2 on the iPhone, 1 and 2 on the Mac): the dup2
        // below closes it and puts the log there, so that thread's later writes go into the log. Only in theory: the launch would have to leave the descriptor closed while
        // another thread opens a file at that very moment, and the old freopen form had the same window
        int null = open("/dev/null", O_RDWR);
        if (null > STDERR_FILENO) close(null);
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (fd < 0) return errno ? errno : EIO;
    for (int to = first; to <= STDERR_FILENO; to++) if (fd != to) dup2(fd, to);
    if (fd > STDERR_FILENO) close(fd);   // only its own: one that came on 0 to 2 (a /dev/null open failed) stays, so that descriptor is not free either
    return 0;
}
#endif
