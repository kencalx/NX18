// The device's pipeline list filter as 64-bit row hashes (nvn_mtl.m pso_user_put, DM_PSO_USER_HASH): the same rows written as the string filter writes, on real lists.
// The seed is a profile's pso_manifest.tsv (argv[1]), the device's list a part of it with the oddities a real list gets (a comment, empty lines, a CR, a row twice, a cut last
// line); the rows recorded are every row of the seed, rows of another game's list (argv[2]), each twice, rows that differ from a seed row in one byte or by a trailing
// space, and an empty row. The file written must equal what a reference string filter (the old code's rules, an NSMutableSet of NSStrings) writes; the run under
// DM_PSO_USER_HASH=0 checks the reference against the old code itself. `bench` measures both filters' fill: time and heap bytes, best of 5.
#include "../nvn/nvn_mtl.m"
#include <malloc/malloc.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; int ok_ = !!(c); if (!ok_) failed++; printf("%s: %s\n", label, ok_ ? "PASS" : "FAIL"); } while (0)
static NSArray<NSString *> *rows_of(NSString *path) {
    NSString *t = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *r = [NSMutableArray array]; for (NSString *l in [t componentsSeparatedByString:@"\n"]) if (l.length && ![l hasPrefix:@"#"]) [r addObject:l];
    return r;
}
// The old filter's rules (pso_user_put before DM_PSO_USER_HASH): what it writes for these recorded lines, given the lists. drop_s (DM_PSO_DROP_S, the default): S rows are
// neither in the set nor written, and the rest as before
static NSString *reference(NSArray<NSString *> *lists, NSArray<NSString *> *recorded, int drop_s) {
    NSMutableSet<NSString *> *seen = [NSMutableSet set]; NSMutableString *out = [NSMutableString string];
    for (NSString *path in lists) { NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        for (NSString *old in [txt componentsSeparatedByString:@"\n"]) if (old.length && ![old hasPrefix:@"#"] && !(drop_s && [old hasPrefix:@"S\t"])) [seen addObject:old]; }
    for (NSString *line in recorded) { NSString *s = [line hasSuffix:@"\n"] ? [line substringToIndex:line.length - 1] : line;
        if (drop_s && [line hasPrefix:@"S\t"]) continue;
        if ([seen containsObject:s]) continue; [seen addObject:s]; [out appendString:line]; }
    return out;
}
static size_t heap_used(void) { malloc_statistics_t st; malloc_zone_statistics(NULL, &st); return st.size_in_use; }
static void bench(NSString *seed, NSString *user) {
    double best_old = 1e9, best_new = 1e9; size_t mem_old = 0, mem_new = 0, n_old = 0, n_new = 0;
    for (int r = 0; r < 5; r++) @autoreleasepool {
        size_t m0 = heap_used(); uint64_t t0 = now_ns();
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (NSString *path in @[seed, user]) { NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            for (NSString *old in [txt componentsSeparatedByString:@"\n"]) if (old.length && ![old hasPrefix:@"#"]) [seen addObject:old]; }
        double t = (now_ns() - t0) / 1e6; size_t m = heap_used() - m0;   // the split's array and the file's string are autoreleased: counted here as the old filter's peak
        if (t < best_old) best_old = t;
        mem_old = m; n_old = seen.count;
    }
    // what the old set keeps after its autorelease pool drains: the set and its strings
    size_t kept_old = 0; @autoreleasepool { size_t m0 = heap_used(); NSMutableSet<NSString *> *seen = [NSMutableSet set];
        @autoreleasepool { for (NSString *path in @[seed, user]) { NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            for (NSString *old in [txt componentsSeparatedByString:@"\n"]) if (old.length && ![old hasPrefix:@"#"]) [seen addObject:old]; } }
        kept_old = heap_used() - m0; n_old = seen.count; }
    for (int r = 0; r < 5; r++) @autoreleasepool {
        pso_hset s = {0}; size_t m0 = heap_used(); uint64_t t0 = now_ns();
        pso_hset_add_list(&s, seed); pso_hset_add_list(&s, user);
        double t = (now_ns() - t0) / 1e6; if (t < best_new) best_new = t;
        mem_new = heap_used() - m0; n_new = s.n; free(s.k);
    }
    printf("bench: string filter %zu rows: fill %.2f ms (best of 5), heap %.2f MB at the fill's peak, %.2f MB kept for the run\n", n_old, best_old, mem_old / 1048576.0, kept_old / 1048576.0);
    printf("bench: hash filter %zu rows: fill %.2f ms (best of 5), heap %.2f MB kept for the run\n", n_new, best_new, mem_new / 1048576.0);
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: t_pso_user_hash <seed pso_manifest.tsv> <another list> [bench]\n"); return 2; }
    NSString *seed_src = @(argv[1]), *other = @(argv[2]);
    NSArray<NSString *> *seed_rows = rows_of(seed_src), *other_rows = rows_of(other);
    if (seed_rows.count < 100 || other_rows.count < 100) { fprintf(stderr, "lists too short\n"); return 2; }
    char dir[] = "/tmp/t_pso_user_hash.XXXXXX"; if (!mkdtemp(dir)) return 2;
    NSString *d = @(dir), *seed = [d stringByAppendingPathComponent:@"pso_manifest.tsv"], *user = [d stringByAppendingPathComponent:@"pso_user.tsv"];
    [[NSFileManager defaultManager] copyItemAtPath:seed_src toPath:seed error:nil];
    if (argc > 3 && !strcmp(argv[3], "bench")) {   // the device's list as large as the seed (a device that played the game through): both lists in full
        [[NSFileManager defaultManager] copyItemAtPath:other toPath:user error:nil]; bench(seed, user);
        unlink(seed.fileSystemRepresentation); unlink(user.fileSystemRepresentation); rmdir(dir); return 0; }
    // The device's list: a comment, every 7th row of the other list, an empty line, a CR-ended row, a seed row again, and a cut last line (no newline)
    NSMutableString *u = [NSMutableString stringWithString:@"# device list\n"];
    for (NSUInteger i = 0; i < other_rows.count; i += 7) { [u appendString:other_rows[i]]; [u appendString:@"\n"]; }
    [u appendFormat:@"\n%@\r\n%@\n%@", other_rows[1], seed_rows[3], [other_rows[2] substringToIndex:other_rows[2].length / 2]];
    [u writeToFile:user atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray<NSString *> *rec = [NSMutableArray array];
    for (NSString *r in seed_rows) [rec addObject:[r stringByAppendingString:@"\n"]];   // all already in the seed
    for (int pass = 0; pass < 2; pass++) for (NSString *r in other_rows) [rec addObject:[r stringByAppendingString:@"\n"]];   // new once (but every 7th), then again
    for (NSUInteger i = 0; i < seed_rows.count; i += 97) { NSString *r = seed_rows[i]; unichar c = [r characterAtIndex:r.length - 1];
        [rec addObject:[NSString stringWithFormat:@"%@%C\n", [r substringToIndex:r.length - 1], (unichar)(c == '0' ? '1' : '0')]];   // one byte off
        [rec addObject:[r stringByAppendingString:@" \n"]]; }   // a trailing space
    [rec addObject:[other_rows[1] stringByAppendingString:@"\r\n"]];   // as the CR-ended row in the device's list: already there
    [rec addObject:[other_rows[2] substringToIndex:other_rows[2].length / 2]];   // the cut line, with no newline as recorded: already there
    [rec addObject:@"\n"]; [rec addObject:@"\n"];   // an empty row: written once
    int drop = drop_s_on(); printf("S rows: %s\n", drop ? "dropped (default)" : "kept (DM_PSO_DROP_S=0)");
    NSString *ref = reference(@[seed, user], rec, drop);   // read before anything is written
    NSUInteger nref = [ref componentsSeparatedByString:@"\n"].count - 1;
    setenv("DM_PSO_USER", user.fileSystemRepresentation, 1); unsetenv("DM_SAVE"); setenv("DM_PSO_USER_QUEUE", "0", 1);
    g_shmap_path = [d stringByAppendingPathComponent:@"shader_map.tsv"];   // the seed beside it
    int hash = pso_user_hash_on(); printf("filter: %s\n", hash ? "64-bit row hashes (default)" : "strings (DM_PSO_USER_HASH=0)");
    for (NSString *l in rec) pso_user_record("%s", l.UTF8String);
    pso_user_sync(); if (g_pso_user) { fclose(g_pso_user); g_pso_user = NULL; }
    // The device's list as it was, the newline pso_user_file puts after its cut last line, then the rows the old filter adds
    NSString *got = [NSString stringWithContentsOfFile:user encoding:NSUTF8StringEncoding error:nil], *want = [[u stringByAppendingString:@"\n"] stringByAppendingString:ref];
    printf("seed %lu rows, device list %lu bytes; recorded %lu rows: the reference writes %lu; the file grew by %ld bytes, the reference's %lu\n", (unsigned long)seed_rows.count, (unsigned long)u.length,
           (unsigned long)rec.count, (unsigned long)nref, (long)got.length - (long)u.length - 1, (unsigned long)ref.length);
    CHECK("the file equals the string filter's, row for row", [got isEqualToString:want]);
    NSUInteger other_n = 0; for (NSString *r in other_rows) other_n += !(drop && [r hasPrefix:@"S\t"]);   // the other list's rows the reference can write
    CHECK("the reference wrote new rows and filtered the rest (a test that can fail)", nref > other_n / 2 && nref < rec.count / 2);
    unsigned seed_s = 0; for (NSString *r in seed_rows) seed_s += [r hasPrefix:@"S\t"];
    if (drop) CHECK("the seed has S rows to leave out (a test that can fail)", seed_s > 0);
    if (drop && hash) CHECK("the hash filter holds no S row: fewer rows than the seed's others and the written ones", g_pso_user_hs.n <= seed_rows.count - seed_s + other_rows.count + nref);
    if (hash) CHECK("the hash filter holds every distinct row once, the strings none", g_pso_user_hs.n > (drop ? seed_rows.count - seed_s : seed_rows.count) && g_pso_user_seen == nil);
    else CHECK("=0: the string filter was used", g_pso_user_seen != nil && g_pso_user_hs.n == 0);
    unlink(seed.fileSystemRepresentation); unlink(user.fileSystemRepresentation); rmdir(dir);
    printf("t_pso_user_hash%s%s: %d checks, %d failed\n", hash ? "" : " (DM_PSO_USER_HASH=0)", drop ? "" : " (DM_PSO_DROP_S=0)", checks, failed); return failed != 0;
} }
