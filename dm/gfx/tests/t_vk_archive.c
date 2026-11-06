// The Vulkan layer's pipeline archive (../vk/vk_archive.h, hle_vk.m DM_VK_ARCHIVE), its plain-C parts on any machine: the keys and their set, the stamp that keeps an archive of
// another system, host, GPU, game build or shader library from being read, a file's keys (all or none, only for a file of the size they name), whole-or-nothing writes, a file's
// identity and a Metal library's (its function list), the folder a start finds (another stamp or none: every file goes, thousands of them too, and the stamp waits until none is
// left; a write cut short: its files go; the files kept, oldest first, at most VKA_FILES), the gate that keeps the archive's writes apart from the compiles (several threads, also
// under ThreadSanitizer: make vk-archive; the compiles begun during a write counted), and the crash guard (../nvn/nvn_pso_guard.h) as hle_vk.m uses it: one early end leaves the
// archive out, a new archive or app build is a new identity, the start the guard runs without it is watched too, an app away before the guard begins is taken into account,
// and its record names this archive. hle_vk.m's Metal calls are not run here
#define _DEFAULT_SOURCE   // mkdtemp under -std=c11 on Linux (macOS declares it anyway)
#include "../vk/vk_archive.h"
#include "../nvn/nvn_pso_guard.h"
#include <stdatomic.h>

static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

static char dir[256];
static void put(const char *name, const char *txt) { char p[512]; snprintf(p, sizeof p, "%s/%s", dir, name); FILE *f = fopen(p, "w"); if (!f) abort(); fputs(txt, f); fclose(f); }
static void put_bytes(const char *name, size_t n, int fill) { char p[512]; snprintf(p, sizeof p, "%s/%s", dir, name); FILE *f = fopen(p, "w"); if (!f) abort(); for (size_t i = 0; i < n; i++) fputc(fill, f); fclose(f); }
static int exists(const char *name) { char p[512]; struct stat st; snprintf(p, sizeof p, "%s/%s", dir, name); return !stat(p, &st); }
static void rm(const char *name) { char p[512]; snprintf(p, sizeof p, "%s/%s", dir, name); unlink(p); }
// A file of the archive as the writer leaves it: n bytes of p<seq>.bin and the keys that name that size
static void archive_file(int seq, size_t n, const uint64_t *k, size_t nk) {
    char b[32], kn[32]; snprintf(b, sizeof b, "p%05d.bin", seq); snprintf(kn, sizeof kn, "p%05d.keys", seq);
    put_bytes(b, n, 'a' + seq % 26);
    size_t len; char *txt = vka_keys_format(n, k, nk, &len); if (!txt) abort();
    char p[512]; snprintf(p, sizeof p, "%s/%s", dir, kn); CHECK(!vka_write(p, txt, len), "write %s", kn); free(txt);
}

static vka_gate g_gate = VKA_GATE_INIT;
static _Atomic int g_readers, g_writing, g_overlap, g_reads, g_writes;
static void *reader(void *arg) {
    (void)arg;
    for (int i = 0; i < 20000; i++) {
        if (!vka_read_begin(&g_gate)) continue;   // a write runs: this pipeline compiles without the archive
        atomic_fetch_add(&g_readers, 1);
        if (atomic_load(&g_writing)) atomic_fetch_add(&g_overlap, 1);
        atomic_fetch_add(&g_reads, 1);
        atomic_fetch_sub(&g_readers, 1);
        vka_read_end(&g_gate);
    }
    return NULL;
}
static void *writer(void *arg) {
    (void)arg;
    for (int i = 0; i < 20000; i++) {
        if (!vka_write_begin(&g_gate)) continue;   // a compile that names the archive is under way: later
        atomic_store(&g_writing, 1);
        if (atomic_load(&g_readers)) atomic_fetch_add(&g_overlap, 1);
        atomic_fetch_add(&g_writes, 1);
        atomic_store(&g_writing, 0);
        vka_write_end(&g_gate);
    }
    return NULL;
}

static psg_guard g = PSG_GUARD_INIT_FOR("the Vulkan layer's pipeline archive in this folder (hle_vk.m, DM_VK_ARCHIVE)");
static char rec[512];
static const char *OS = "24A335";
// One start as hle_vk.m runs it (va_init, va_frame): the guard's verdict for this identity; then, unless it crashes in its window, the first burst ends (the mark) and the frames
// that end the window. 1: it used the archive
static int start(const char *ident, int crash) {
    psg_start s = psg_begin(&g, rec, OS, ident, 1);
    if (crash) return s.use;
    if (atomic_load(&g.watching)) { psg_mark(&g); int n = 0; while (!psg_frame(&g)) n++; CHECK(n + 1 == PSG_FRAMES, "the window ends PSG_FRAMES frames after the first burst's writes (%d)", n + 1); int err; psg_pass(&g, &err); CHECK(!err, "record written"); }
    return s.use;
}

int main(void) {
    snprintf(dir, sizeof dir, "%s/t_vk_archive.XXXXXX", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    if (!mkdtemp(dir)) abort();

    // Keys
    CHECK(vka_fnv(VKA_FNV0, "a", 1) == 0xaf63dc4c8601ec8cull, "FNV-1a 64 of \"a\"");
    CHECK(vka_fnv(VKA_FNV0, "", 0) == VKA_FNV0 && vka_end(0) == 1 && vka_end(5) == 5, "the empty input, and no key is 0");
    CHECK(vka_u32(VKA_FNV0, 1) != vka_u32(VKA_FNV0, 2) && vka_u32(vka_u32(VKA_FNV0, 1), 2) != vka_u32(vka_u32(VKA_FNV0, 2), 1), "order and value count");
    vka_set s = {0};
    uint64_t x = 88172645463325252ull;
    for (int i = 0; i < 5000; i++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; CHECK(vka_add(&s, x | 1) == 1, "a new key is added"); }
    CHECK(s.n == 5000, "5,000 keys");
    int sorted = 1; for (size_t i = 1; i < s.n; i++) sorted &= s.k[i - 1] < s.k[i];
    CHECK(sorted, "kept sorted, without duplicates");
    CHECK(vka_add(&s, s.k[1234]) == 0 && s.n == 5000 && vka_has(&s, s.k[4321]) && !vka_has(&s, 2), "a key there already; found; not found");
    vka_set_free(&s); CHECK(!s.n && !s.k && !vka_has(&s, 3), "freed");

    // The stamp
    vka_stamp st = {0}, other;
    snprintf(st.v[VKA_OS], 256, "%s", OS); snprintf(st.v[VKA_HOST], 256, "00112233445566778899aabbccddeeff"); snprintf(st.v[VKA_GPU], 256, "applegpu_g19p");
    snprintf(st.v[VKA_GAME], 256, "0123456789abcdef0123456789abcdef00000000"); snprintf(st.v[VKA_SHADERS], 256, "vk_shaders.metallib 7340032 0123456789abcdef");
    char buf[4096]; int k = vka_stamp_format(buf, sizeof buf, &st);
    CHECK(k > 0 && (size_t)k < sizeof buf && vka_stamp_diff(buf, &st) == VKA_FIELDS, "the same stamp");
    CHECK(vka_stamp_diff(NULL, &st) == -1, "no stamp");
    for (int i = 0; i < VKA_FIELDS; i++) {
        other = st; strcat(other.v[i], "x");
        CHECK(vka_stamp_diff(buf, &other) == i, "another %s", vka_field[i]);
        other = st; other.v[i][strlen(other.v[i]) - 1] = 0;   // a prefix of the value is another value
        CHECK(vka_stamp_diff(buf, &other) == i, "a shorter %s", vka_field[i]);
    }
    CHECK(vka_stamp_diff("# a comment\nos\t24A335\nhost\t00112233445566778899aabbccddeeff\ngpu\tapplegpu_g19p\n", &st) == VKA_GAME, "a field missing counts as different");
    char extra[4200]; snprintf(extra, sizeof extra, "# x\nextra\tfield\n%s", buf);
    CHECK(vka_stamp_diff(extra, &st) == VKA_FIELDS, "lines it does not know are left alone");

    // One file's keys
    uint64_t ks[3] = {0x1111222233334444ull, 0xffffffffffffffffull, 0x0000000000000005ull};
    size_t len; char *kt = vka_keys_format(123456, ks, 3, &len);
    CHECK(kt && strlen(kt) == len, "formatted");
    CHECK(vka_keys_parse(kt, 123456, &s) == 1 && s.n == 3 && vka_has(&s, ks[0]) && vka_has(&s, ks[1]) && vka_has(&s, ks[2]), "parsed for its size");
    vka_set_free(&s);
    CHECK(vka_keys_parse(kt, 123457, &s) == 0 && s.n == 0, "another size: none of them");
    free(kt);
    vka_add(&s, 9);
    static const char *bad[] = {"1111222233334444\nsize\t10\n", "size\t10\nsize\t10\n", "size\t10\n111122223333444\n", "size\t10\n11112222333344445\n", "size\t10\nzz11222233334444\n",
                                "size\t10\n0000000000000000\n", "size\t\n", "size\t10x\n", "", "# only a comment\n", "size\t10\n1111222233334444\nfoo\n"};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) CHECK(vka_keys_parse(bad[i], 10, &s) == 0 && s.n == 1, "malformed keys %zu: none of them, the set as it was", i);
    CHECK(vka_keys_parse("# c\nsize\t10\n\n1111222233334444", 10, &s) == 1 && s.n == 2, "comments, blank lines and no newline at the end");
    CHECK(vka_keys_parse(NULL, 10, &s) == 0, "no file");
    char *empty = vka_keys_format(0, NULL, 0, &len);
    CHECK(empty && vka_keys_parse(empty, 0, &s) == 1 && s.n == 2, "a file of no keys"); free(empty);
    vka_set_free(&s);

    // Files
    char p[512], q[512]; snprintf(p, sizeof p, "%s/w.txt", dir); snprintf(q, sizeof q, "%s/w.txt.tmp", dir);
    CHECK(!vka_write(p, "hello", 5) && exists("w.txt") && !exists("w.txt.tmp"), "written whole, no temporary left");
    char *r = vka_read(p, 100); CHECK(r && !strcmp(r, "hello"), "read back"); free(r);
    CHECK(!vka_read(p, 4), "a file over the limit is not read");
    snprintf(q, sizeof q, "%s/none/w.txt", dir); CHECK(vka_write(q, "x", 1) == ENOENT, "a folder that is not there");
    char id1[256], id2[256], id3[256];
    put_bytes("big.bin", 300000, 'q');
    snprintf(p, sizeof p, "%s/big.bin", dir); CHECK(!vka_file_id(p, id1, sizeof id1) && !strncmp(id1, "big.bin 300000 ", 15), "identity: name and size (%s)", id1);
    { FILE *f = fopen(p, "r+"); fseek(f, 150000, SEEK_SET); fputc('Q', f); fclose(f); }
    CHECK(!vka_file_id(p, id2, sizeof id2) && !strcmp(id1, id2), "a change between the first and last 64 KiB is not seen (the identity reads only those)");
    { FILE *f = fopen(p, "r+"); fseek(f, 299999, SEEK_SET); fputc('Q', f); fclose(f); }
    CHECK(!vka_file_id(p, id3, sizeof id3) && strcmp(id1, id3), "a change in the last 64 KiB is");
    snprintf(q, sizeof q, "%s/nothing.bin", dir); CHECK(vka_file_id(q, id3, sizeof id3) == ENOENT, "no file, no identity");
    {   // a Metal library: its MTLB header names the function list (offset at byte 24, size at 32), which holds every function's hash, and the module code after it
        enum { HDR = 88, LIST = 200000, CODE = 300000 }; static uint8_t lib[HDR + LIST + CODE];
        for (size_t i = 0; i < sizeof lib; i++) lib[i] = (uint8_t)(i * 7 + 3);
        lib[0] = 'M'; lib[1] = 'T'; lib[2] = 'L'; lib[3] = 'B'; for (int i = 0; i < 8; i++) { lib[24 + i] = (uint8_t)((uint64_t)HDR >> (8 * i)); lib[32 + i] = (uint8_t)((uint64_t)LIST >> (8 * i)); }
        snprintf(p, sizeof p, "%s/vk_shaders.metallib", dir); char l1[512], l2[512], l3[512];
        FILE *f = fopen(p, "w"); if (!f) abort(); fwrite(lib, 1, sizeof lib, f); fclose(f);
        CHECK(!vka_lib_id(p, l1, sizeof l1) && !vka_file_id(p, id1, sizeof id1) && !strncmp(l1, id1, strlen(id1)) && strstr(l1, " fl 200000 "), "a library's identity: the file's, then its function list (%s)", l1);
        f = fopen(p, "r+"); fseek(f, HDR + 150000, SEEK_SET); fputc(lib[HDR + 150000] ^ 1, f); fclose(f);   // one function's hash, past the first 64 KiB and before the last
        CHECK(!vka_file_id(p, id2, sizeof id2) && !strcmp(id1, id2) && !vka_lib_id(p, l2, sizeof l2) && strcmp(l1, l2), "a function changed in the middle: the file's identity misses it, the library's does not");
        f = fopen(p, "r+"); fseek(f, HDR + LIST + 100000, SEEK_SET); fputc(0, f); fclose(f);   // code whose function's hash has not changed: not a rebuilt library
        CHECK(!vka_lib_id(p, l3, sizeof l3) && !strcmp(l2, l3), "the code alone is not read (the function list's hashes cover it)");
        lib[32 + 3] = 0x10;   // a list that would run past the end of the file
        f = fopen(p, "w"); fwrite(lib, 1, sizeof lib, f); fclose(f);
        CHECK(!vka_lib_id(p, l3, sizeof l3) && strstr(l3, " fl -") && !strncmp(l3, "vk_shaders.metallib ", 20), "a header that names no list in the file: the file's identity alone (%s)", l3);
        put_bytes("plain.metallib", 1000, 'z'); snprintf(q, sizeof q, "%s/plain.metallib", dir);
        CHECK(!vka_lib_id(q, l3, sizeof l3) && strstr(l3, " fl -"), "not a Metal library: the file's identity alone");
        CHECK(vka_lib_id(q, l3, 20) == ENAMETOOLONG, "too long for the field"); snprintf(q, sizeof q, "%s/missing.metallib", dir); CHECK(vka_lib_id(q, l3, sizeof l3) == ENOENT, "no file");
        rm("vk_shaders.metallib"); rm("plain.metallib");
    }
    rm("big.bin"); rm("w.txt");
    CHECK(vka_seq("p00012.bin", "bin") == 12 && vka_seq("p00012.keys", "keys") == 12 && vka_seq("p99999.bin", "bin") == 99999, "the files' numbers");
    CHECK(vka_seq("p0012.bin", "bin") < 0 && vka_seq("p00012.bin", "keys") < 0 && vka_seq("q00012.bin", "bin") < 0 && vka_seq("p000a2.bin", "bin") < 0 &&
          vka_seq("p00012.bin.tmp", "bin") < 0 && vka_seq("stamp.tsv", "bin") < 0, "other names are not the archive's");

    // The folder a start finds
    vka_folder fo; uint64_t k1[2] = {11, 12}, k2[1] = {21}, k3[1] = {31};
    archive_file(0, 100, k1, 2); put("p00007.keys", "size\t1\n");   // files from before any stamp
    CHECK(!vka_scan(dir, &st, &fo) && fo.diff == -1 && fo.n == 0 && fo.removed == 3 && fo.next == 8 && exists("stamp.tsv") && !exists("p00000.bin"), "no stamp: its files go, the stamp is written");
    CHECK(!vka_scan(dir, &st, &fo) && fo.diff == VKA_FIELDS && fo.n == 0 && fo.next == 0 && !fo.removed, "the same stamp, no files");
    archive_file(0, 100, k1, 2); archive_file(1, 2000, k2, 1); archive_file(3, 50, k3, 1);
    CHECK(!vka_scan(dir, &st, &fo) && fo.n == 3 && fo.seq[0] == 0 && fo.seq[1] == 1 && fo.seq[2] == 3 && fo.next == 4 && !fo.removed, "three files, oldest first, the next after the last");
    put_bytes("p00001.bin", 2001, 'x');   // a write cut short between the two renames: the .bin is not the one its keys name
    put("p00004.bin.tmp", "partial"); put("p00005.keys", "size\t9\n"); put("p00006.keys.tmp", "x");
    CHECK(!vka_scan(dir, &st, &fo) && fo.n == 2 && fo.seq[0] == 0 && fo.seq[1] == 3 && fo.next == 6 && fo.removed == 5, "a .bin of another size goes with its keys, a lone .keys and the .tmp files go (%d removed)", fo.removed);
    CHECK(!exists("p00001.bin") && !exists("p00001.keys") && !exists("p00005.keys") && !exists("p00004.bin.tmp") && exists("p00000.bin") && exists("p00003.keys"), "on disk");
    put_bytes("p00008.bin", 10, 'y');   // a .bin with no keys at all
    CHECK(!vka_scan(dir, &st, &fo) && fo.n == 2 && !exists("p00008.bin") && fo.next == 9, "a .bin without keys goes");
    other = st; snprintf(other.v[VKA_HOST], 256, "ffeeddccbbaa99887766554433221100");   // an app update
    CHECK(!vka_scan(dir, &other, &fo) && fo.diff == VKA_HOST && fo.n == 0 && !exists("p00000.bin") && !exists("p00003.bin") && !exists("p00003.keys"), "another host: every file goes");
    CHECK(!vka_scan(dir, &other, &fo) && fo.diff == VKA_FIELDS, "and the new stamp is written");
    for (int i = 0; i < VKA_FILES + 3; i++) { uint64_t kk = 100 + (uint64_t)i; archive_file(i, 10 + (size_t)i, &kk, 1); }
    CHECK(!vka_scan(dir, &other, &fo) && fo.n == VKA_FILES && fo.seq[VKA_FILES - 1] == VKA_FILES - 1 && !exists("p00033.bin") && fo.next == VKA_FILES + 3, "at most VKA_FILES files are kept");
    snprintf(q, sizeof q, "%s/none", dir); CHECK(vka_scan(q, &st, &fo) == ENOENT, "a folder that cannot take its stamp: the archive is not used");
    for (int i = 0; i < 2500; i++) { char b[32]; snprintf(b, sizeof b, "p%05d.bin", i); put(b, "x"); snprintf(b, sizeof b, "p%05d.keys", i); put(b, "size\t1\n"); }   // more than one readdir buffer
    CHECK(!vka_scan(dir, &st, &fo) && fo.diff == VKA_HOST && fo.removed == 5000 && fo.next == 2500, "another host with 5,000 files: all of them go (%d)", fo.removed);
    int left = 0; for (int i = 0; i < 2500; i++) { char b[32]; snprintf(b, sizeof b, "p%05d.bin", i); left += exists(b); snprintf(b, sizeof b, "p%05d.keys", i); left += exists(b); }
    CHECK(!left && vka_scan(dir, &st, &fo) == 0 && fo.diff == VKA_FIELDS, "none is left, and the stamp is written");
    snprintf(p, sizeof p, "%s/p00002.bin", dir); CHECK(!mkdir(p, 0755), "a p<seq> name that cannot be removed (a folder)");
    CHECK(vka_scan(dir, &other, &fo) == ENOTEMPTY && vka_scan(dir, &other, &fo) == ENOTEMPTY && fo.diff == VKA_HOST, "an old archive's file stays: the new stamp is not written, and the archive is not used");
    rmdir(p); CHECK(!vka_scan(dir, &other, &fo) && fo.diff == VKA_HOST && !vka_scan(dir, &other, &fo) && fo.diff == VKA_FIELDS, "once it can go, the next start starts the archive again");

    // Reads and writes apart: one thread
    CHECK(vka_read_begin(&g_gate) && !vka_write_begin(&g_gate), "no write while a compile names the archive");
    vka_read_end(&g_gate);
    CHECK(vka_write_begin(&g_gate) && !vka_read_begin(&g_gate) && !vka_write_begin(&g_gate), "a pipeline created during a write compiles without the archive; one write at a time");
    CHECK(!vka_read_begin(&g_gate) && vka_write_end(&g_gate) == 2, "the compiles begun during the write are counted (the one above and this one)");
    CHECK(vka_write_begin(&g_gate) && vka_write_end(&g_gate) == 0, "from each write's beginning");
    CHECK(vka_read_begin(&g_gate) && vka_read_begin(&g_gate) && g_gate.users == 2, "readers together"); vka_read_end(&g_gate); vka_read_end(&g_gate);
    // and several
    pthread_t th[6];
    for (int i = 0; i < 6; i++) pthread_create(&th[i], NULL, i < 4 ? reader : writer, NULL);
    for (int i = 0; i < 6; i++) pthread_join(th[i], NULL);
    CHECK(!atomic_load(&g_overlap) && atomic_load(&g_reads) > 0 && !g_gate.users && !g_gate.writing, "never a read and a write at once (%d reads, %d writes)", atomic_load(&g_reads), atomic_load(&g_writes));

    // The crash guard as hle_vk.m uses it: need 1, its own record, the archive's identity ("none yet host <uuid>" before its first file)
    snprintf(rec, sizeof rec, "%s/guard.tsv", dir);
    const char *none = "none yet host 00112233445566778899aabbccddeeff", *a1 = "3 files 7000 bytes 0123456789abcdef host 00112233445566778899aabbccddeeff";
    CHECK(start(none, 0) && !exists("guard.tsv"), "a first start writes its first files, watched, and gets past its window: no record");
    CHECK(start(a1, 1) && psg_load(&g) == PSG_WITH, "a start with the archive that crashes in its window");
    CHECK(!start(a1, 0) && psg_load(&g) == PSG_SKIP, "the next runs without it (reading and writing nothing), watched, and gets past: it stays out");
    CHECK(!start(a1, 0) && !atomic_load(&g.watching), "start after start, unwatched");
    CHECK(start("3 files 7000 bytes 0123456789abcdef host ffeeddccbbaa99887766554433221100", 0), "an app update is another identity: tried again");
    unlink(rec);
    CHECK(start(a1, 1) && !start(a1, 1) && psg_load(&g) == PSG_WITHOUT, "with it, then without it, both crash");
    CHECK(start(a1, 0) && !exists("guard.tsv"), "the archive is not shown to be the cause: used again, and past its window the record goes");
    CHECK(start(none, 1) && !start(none, 0) && psg_load(&g) == PSG_SKIP, "a crash in the start that writes the first files leaves the archive out as well");
    unlink(rec);
    psg_start s0 = psg_begin(&g, rec, OS, a1, 1); int err = 0;
    CHECK(s0.use && psg_away(&g, PSG_AWAY_BACKGROUND, 1, &err) == PSG_WITH && !exists("guard.tsv"), "in the background the record is as the start's end leaves it");
    CHECK(psg_away(&g, PSG_AWAY_BACKGROUND, 0, &err) == PSG_WITH && psg_load(&g) == PSG_WITH, "and back in the foreground it is written again");
    psg_unused(&g); CHECK(!exists("guard.tsv") && !atomic_load(&g.watching), "Metal took none of its files: the record goes back to what the start found");
    // The app away before the device is made, or while va_init opens the files (dm_vk_archive_away notes it whatever the guard's state): psg_begin reads it
    CHECK(psg_away(&g, PSG_AWAY_INACTIVE, 1, &err) == PSG_NONE && !err && !exists("guard.tsv"), "inactive before the guard begins: noted, no record written");
    psg_start s1 = psg_begin(&g, rec, OS, a1, 1);
    CHECK(s1.use && s1.armed == PSG_WITH && !exists("guard.tsv"), "the guard begins while the app is away: the record is as the start's end would leave it (none)");
    CHECK(psg_away(&g, PSG_AWAY_INACTIVE, 0, &err) == PSG_WITH && psg_load(&g) == PSG_WITH, "back in the foreground: written");
    psg_unused(&g);
    CHECK(psg_away(&g, PSG_AWAY_BACKGROUND, 1, &err) == PSG_NONE && psg_begin(&g, rec, OS, a1, 1).armed == PSG_WITH && !exists("guard.tsv"), "the same for the background");
    CHECK(psg_away(&g, PSG_AWAY_BACKGROUND, 0, &err) == PSG_WITH, "and back");
    char *txt = vka_read(rec, 4096);
    CHECK(txt && !strncmp(txt, "# the crash guard of the Vulkan layer's pipeline archive in this folder (hle_vk.m, DM_VK_ARCHIVE): ", 99) && psg_parse(txt, OS, a1) == PSG_WITH,
          "its record names this archive, not the bundled one (%.60s)", txt ? txt : "none");
    free(txt); psg_unused(&g);

    char cmd[300]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir); if (system(cmd)) {}   // NOLINT(bugprone-command-processor): removes the test's own mkdtemp folder
    printf("vk_archive: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
