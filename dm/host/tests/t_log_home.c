// Log privacy (hle_bigstack.c log_emit, dm_log_tilde): the home folder in a log line becomes ~, so a shared log names neither the Mac's account (/Users/<name>) nor the iOS
// app's data container (its UUID); a longer folder that starts with the same letters, and a path that only holds the home folder inside it, stay as they are
#include "../hle.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int dm_guest_as_contains(uintptr_t a) { (void)a; return 0; }   // hle_svc.c: no guest address space here, log lines are written on the calling stack
size_t dm_log_tilde(char *s, size_t n, const char *home, size_t hn);

static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  FAIL "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static void tilde(const char *in, const char *home, const char *want) {
    char b[512]; snprintf(b, sizeof b, "%s", in);
    size_t n = dm_log_tilde(b, strlen(b), home, strlen(home)); b[n] = 0;
    CHECK(!strcmp(b, want), "'%s' (HOME %s) -> '%s', want '%s'", in, home, b, want);
}

int main(void) {
    printf("1 the home folder becomes ~\n");
    tilde("fs mount save: → /Users/pat/Library/Application Support/x", "/Users/pat", "fs mount save: → ~/Library/Application Support/x");
    tilde("/Users/pat", "/Users/pat", "~");
    tilde("a /Users/pat/a and (/Users/pat/b)", "/Users/pat", "a ~/a and (~/b)");
    tilde("home '/Users/pat'.", "/Users/pat/", "home '~'.");
    printf("2 a longer folder name or a path holding it inside stays\n");
    tilde("/Users/patrick/x", "/Users/pat", "/Users/patrick/x");
    tilde("/Users/pat.old/x", "/Users/pat", "/Users/pat.old/x");
    tilde("/Volumes/Disk/Users/pat/x", "/Users/pat", "/Volumes/Disk/Users/pat/x");
    tilde("no paths here", "/Users/pat", "no paths here");
    printf("3 iOS: the data container in either spelling\n");
    const char *ios = "/var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0";
    tilde("save /private/var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/Documents/s", ios, "save ~/Documents/s");
    tilde("save /var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/Library/c", ios, "save ~/Library/c");
    tilde("save /private/var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0/tmp",
          "/private/var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", "save ~/tmp");
    printf("4 a home of / or none changes nothing\n");
    tilde("/Users/pat/x", "/", "/Users/pat/x");
    tilde("/Users/pat/x", "", "/Users/pat/x");

    printf("5 dm_log writes the line with ~ (a short line and one longer than the formatting buffer)\n");
    setenv("HOME", "/Users/pat", 1);
    char path[] = "/tmp/t_log_home_XXXXXX"; int fd = mkstemp(path); if (fd < 0) return 2;
    fflush(stderr); int saved = dup(2); dup2(fd, 2);
    LOG("fs mount save: → %s/Library/x (%d)", "/Users/pat", 7);
    static char big[9000]; memset(big, 'a', sizeof big - 1);
    LOG("long %s /Users/pat/end", big);
    fflush(stderr); dup2(saved, 2); close(saved);
    static char got[20000]; lseek(fd, 0, SEEK_SET); ssize_t n = read(fd, got, sizeof got - 1); close(fd); unlink(path);
    got[n > 0 ? n : 0] = 0;
    CHECK(strstr(got, "[dm] fs mount save: → ~/Library/x (7)\n") != NULL, "short line: %.200s", got);
    CHECK(strstr(got, "a ~/end\n") != NULL && strlen(got) > sizeof big, "long line not whole or not scrubbed (%zu bytes)", strlen(got));
    CHECK(!strstr(got, "/Users/pat"), "the home folder is still in the log");

    printf("%s: %d/%d\n", fails ? "FAILED" : "all passed", checks - fails, checks);
    return fails != 0;
}
