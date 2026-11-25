// account::GetUserId copies the Uid of any handle, as the SDK's accessor does: the host's own handles and handles a game built itself, whatever their third word
// (upstream 84e63860acf).
#include "../hle_account.c"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

void hle_signal_system_event(void *g) { (void)g; }
void dm_applet_enter(const char *name) { (void)name; }
void dm_applet_leave(void) {}

int main(void) {
    UserHandle h; Uid out;
    assert(h_acc_TryOpenPre(&h));
    assert(h_acc_GetUserId(&out, &h) == RES_OK);
    assert(!memcmp(&out, &k_uid, sizeof out));
    assert(h_acc_EnsureNsa(&h) == 0x27c);   // ResultCancelledByUser for an open local account (upstream e7dc2d9af)
    // A handle the game built: EA SPORTS FC 27's second controller passes third word 0x2, the FC 26 patch reports 8
    const uint64_t third[] = {2, 8, 0, UINT64_MAX};
    for (unsigned i = 0; i < sizeof third / sizeof third[0]; i++) {
        h = (UserHandle){{0x7012222b20, 0x400000001, third[i]}};
        assert(h_acc_GetUserId(&out, &h) == RES_OK);
        assert(out.v[0] == 0x7012222b20 && out.v[1] == 0x400000001);
        assert(h.v[2] == third[i]);
        h.v[0] = h.v[1] = 0;
        assert(h_acc_GetUserId(&out, &h) == RES_OK);
        assert(out.v[0] == 0 && out.v[1] == 0);
    }
    // The name: at most 32 bytes, cut at the last whole UTF-8 character
    char nk[33];
    acc_nick_cut("Player", nk); assert(!strcmp(nk, "Player"));
    acc_nick_cut("0123456789012345678901234567890123456789", nk); assert(strlen(nk) == 32);
    acc_nick_cut("0123456789012345678901234567890\xc3\xa9", nk); assert(strlen(nk) == 31);                 // é would end at byte 33: left out whole
    acc_nick_cut("012345678901234567890123456789\xe3\x81\x82", nk); assert(strlen(nk) == 30);            // あ (3 bytes) at 31-33: left out
    acc_nick_cut("01234567890123456789012345678\xe3\x81\x82", nk); assert(strlen(nk) == 32);             // あ ends at byte 32: kept
    acc_nick_cut("0123456789012345678901234567890\xf0\x9f\x8e\xae", nk); assert(strlen(nk) == 31);       // a 4-byte emoji at 32-35
    // The picture: the built-in one passes; another size, another frame kind, a cut file and too big a file are refused
    const uint8_t *j = (const uint8_t *)k_profile_jpeg; size_t jn = sizeof k_profile_jpeg - 1;
    assert(acc_jpeg_ok(j, jn));
    uint8_t *w = malloc(PROFILE_JPEG_MAX + 16);
    memcpy(w, j, jn); size_t sof = 0; for (size_t i = 2; i + 1 < jn; i++) if (w[i] == 0xFF && w[i + 1] == 0xC0) { sof = i; break; }
    assert(sof);
    w[sof + 8] = 0x80; assert(!acc_jpeg_ok(w, jn)); w[sof + 8] = 0x00;    // 256 x 128
    w[sof + 1] = 0xC2; assert(!acc_jpeg_ok(w, jn)); w[sof + 1] = 0xC0;    // progressive
    assert(acc_jpeg_ok(w, jn)); assert(!acc_jpeg_ok(w, jn - 2));           // no end marker
    memset(w + jn - 2, 0, PROFILE_JPEG_MAX + 16 - jn); w[PROFILE_JPEG_MAX + 2] = 0xFF; w[PROFILE_JPEG_MAX + 3] = 0xD9;   // the same file, padded past 128 KiB
    assert(!acc_jpeg_ok(w, PROFILE_JPEG_MAX + 4));
    free(w);
    // DM_PROFILE_IMAGE: a good file is what LoadProfileImage hands out
    char path[256]; snprintf(path, sizeof path, "%s/t_account_pic.jpg", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    uint8_t mine[1024]; memcpy(mine, j, jn); mine[jn - 10] = 0x5A;           // another picture: one scan byte differs
    FILE *f = fopen(path, "wb"); assert(f); fwrite(mine, 1, jn, f); fclose(f);
    setenv("DM_PROFILE_IMAGE", path, 1);
    uint64_t got = 0; uint8_t img[1024]; Uid u = k_uid;
    assert(h_acc_LoadImage(&got, img, sizeof img, &u) == RES_OK);
    assert(got == jn && !memcmp(img, mine, jn));
    assert(h_acc_LoadImage(&got, img, 16, &u) == RES_OK && got == jn);       // a short buffer gets the start, the size is the file's
    unlink(path);
    // DM_NICK reaches GetNickname, cut whole
    setenv("DM_NICK", "Zelda", 1); char nick[33]; assert(h_acc_GetNick(nick, &u) == RES_OK && !strcmp(nick, "Zelda"));
    setenv("DM_NICK", "", 1); assert(h_acc_GetNick(nick, &u) == RES_OK && !strcmp(nick, "Player"));
    puts("t_account: OK");
    return 0;
}
