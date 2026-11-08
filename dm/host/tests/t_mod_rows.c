// The Mac's reader of a module's switchable mods (dm/host/mod_rows.h, loader.c mod_variants_one), on any machine: rows as dm/tools/game_mods.py write_variants writes them,
// a row far past 64 KB (a fixed buffer of that size skipped it before, so the Mac put a large role in place in part), comments, blank lines, CRLF and a last line with no newline,
// and the rows it cannot read: one takes out its own role whole, one whose role cannot be told takes out both, and the other role's rows still read. Under ASan and UBSan in
// make asan. Plain C: cc -std=gnu11 t_mod_rows.c
#include "../mod_rows.h"

static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

static void read_text(const char *text, unsigned want, dm_mod_rows *rows) {
    FILE *f = tmpfile();
    if (!f) { perror("tmpfile"); exit(2); }
    if (fputs(text, f) < 0 || fseek(f, 0, SEEK_SET)) { perror("tmpfile"); exit(2); }
    dm_mod_rows_read(f, want, rows);
    fclose(f);
}

static void rows_as_written(void) {
    dm_mod_rows rows;
    read_text("# switchable mods (dm/tools/game_mods.py): role\tkind\tfile offset\timage offset\tbytes\n"
              "fps\tc\t0x10\t0x10\t1f2003d5\n"
              "\n"
              "ultrawide\tw\t0x5000\t0x5000\t98E3\r\n"
              "fps\tw\t0x24000\t-0x8000\tAbCd\n"
              "ultrawide\tc\t0x0\t0x0\t00", 3, &rows);
    CHECK(rows.bad == 0 && rows.n == 4, "bad %u, %zu rows", rows.bad, rows.n);
    if (rows.n == 4) {
        const dm_mod_row *r = rows.row;
        CHECK(r[0].role == DM_MOD_ROLE_FPS && r[0].code && r[0].io == 0x10 && r[0].len == 4 && !memcmp(r[0].bytes, "\x1f\x20\x03\xd5", 4), "the first row");
        CHECK(r[1].role == DM_MOD_ROLE_ULTRAWIDE && !r[1].code && r[1].io == 0x5000 && r[1].len == 2 && !memcmp(r[1].bytes, "\x98\xe3", 2), "CRLF");
        CHECK(r[2].io == -0x8000 && r[2].len == 2 && !memcmp(r[2].bytes, "\xab\xcd", 2), "before the base, either case of hex");
        CHECK(r[3].code && r[3].io == 0 && r[3].len == 1 && r[3].bytes[0] == 0, "a last line with no newline");
    }
    dm_mod_rows_free(&rows);
    read_text("fps\tc\t0x10\t0x10\t1f2003d5\nultrawide\tw\t0x5000\t0x5000\t3f80\n", DM_MOD_ROLE_ULTRAWIDE, &rows);
    CHECK(rows.n == 1 && rows.row[0].role == DM_MOD_ROLE_ULTRAWIDE && rows.bad == 0, "only the roles asked for are kept");
    dm_mod_rows_free(&rows);
}

static void a_long_row(void) {   // 100 KB of bytes in one row: 200,000 hex digits
    enum { N = 100000 };
    char *text = malloc(64 + 2 * N);
    if (!text) exit(2);
    int at = snprintf(text, 64, "ultrawide\tc\t0x100000\t0x100000\t");
    for (int i = 0; i < N; i++) { static const char hx[] = "0123456789abcdef"; text[at++] = hx[(i * 7) >> 4 & 15]; text[at++] = hx[(i * 7) & 15]; }
    memcpy(text + at, "\nfps\tw\t0x5000\t0x5000\t01\n", 25);
    dm_mod_rows rows; read_text(text, 3, &rows); free(text);
    CHECK(rows.bad == 0 && rows.n == 2, "bad %u, %zu rows", rows.bad, rows.n);
    if (rows.n == 2) {
        int same = rows.row[0].len == N;
        for (int i = 0; same && i < N; i++) same = rows.row[0].bytes[i] == (uint8_t)(i * 7);
        CHECK(same, "the long row's bytes (%zu of them)", rows.row[0].len);
        CHECK(rows.row[1].role == DM_MOD_ROLE_FPS && rows.row[1].bytes[0] == 1, "the row after it");
    }
    dm_mod_rows_free(&rows);
}

static void rows_it_cannot_read(void) {
    static const struct { const char *row; unsigned bad; } cases[] = {
        {"fps\tc\t0x10\t0x10\t1f2003d", DM_MOD_ROLE_FPS},             // an odd count of hex digits: a row cut short
        {"fps\tc\t0x10\t0x10\t1f2003dx", DM_MOD_ROLE_FPS},            // not hex
        {"fps\tc\t0x10\t0x10\t", DM_MOD_ROLE_FPS},                    // no bytes
        {"ultrawide\tx\t0x10\t0x10\t00", DM_MOD_ROLE_ULTRAWIDE},      // another kind
        {"ultrawide\tc\t0x10\t16\t00", DM_MOD_ROLE_ULTRAWIDE},        // an image offset without 0x (decimal, which the writer never writes)
        {"ultrawide\tc\t-0x10\t0x10\t00", DM_MOD_ROLE_ULTRAWIDE},     // a negative file offset
        {"ultrawide\tc\t0x10\t0x1000000000000000\t00", DM_MOD_ROLE_ULTRAWIDE},   // more digits than an offset has
        {"ultrawide\tc\t0x10\t0x10\t00\textra", DM_MOD_ROLE_ULTRAWIDE},          // a sixth field
        {"ultrawide\tc\t0x10", DM_MOD_ROLE_ULTRAWIDE},               // fields missing
        {"ultrawid\tc\t0x10\t0x10\t00", DM_MOD_ROLES},               // a role it cannot tell: both
        {"cheats\tc\t0x10\t0x10\t00", DM_MOD_ROLES},
        {"\tc\t0x10\t0x10\t00", DM_MOD_ROLES},
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        char text[256];
        snprintf(text, sizeof text, "fps\tc\t0x10\t0x10\t1f2003d5\n# a comment\n%s\nultrawide\tw\t0x5000\t0x5000\t3f80\n", cases[i].row);
        dm_mod_rows rows; read_text(text, 3, &rows);
        long want_line = 3;
        CHECK(rows.bad == cases[i].bad, "%s: bad %u, not %u", cases[i].row, rows.bad, cases[i].bad);
        CHECK(!(cases[i].bad & 1) || rows.bad_line[0] == want_line, "%s: the fps line %ld", cases[i].row, rows.bad_line[0]);
        CHECK(!(cases[i].bad & 2) || rows.bad_line[1] == want_line, "%s: the ultrawide line %ld", cases[i].row, rows.bad_line[1]);
        CHECK(rows.n == 2, "%s: the good rows are still read (%zu)", cases[i].row, rows.n);
        dm_mod_rows_free(&rows);
    }
    dm_mod_rows rows; read_text("ultrawide\tc\t0x10\t0x10\t0\nfps\tw\t0x10\t0x10\tzz\nultrawide\tc\t0x10\t0x10\t00\n", 3, &rows);
    CHECK(rows.bad == 3 && rows.bad_line[0] == 2 && rows.bad_line[1] == 1 && rows.n == 1, "each role's first line it cannot read: bad %u, %ld, %ld", rows.bad, rows.bad_line[0], rows.bad_line[1]);
    dm_mod_rows_free(&rows);
}

int main(void) {
    rows_as_written();
    a_long_row();
    rows_it_cannot_read();
    printf("t_mod_rows: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
