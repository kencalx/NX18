// A later start's prepare step (warm_later_ready, warm_later_bg, warm_later_mark; idea from S2Arm e899d98a1). Each start is a process of its own (this binary again, "start"), as the step runs once a process: the archive folder and prepared.tsv carry over between them.
//   1 a first start waits for the step, and writes prepared.tsv (its stamp) once the archive has its lines
//   2 the next start with the same list hands it to the background: warm_start returns while the background's first library load is held at the device (the first frame does not
//     wait), the lines finish after it as archive hits (no base compiled) and the next submission claims the pipeline
//   3 a changed list waits again (negative control), and rewrites prepared.tsv; 4 the start after it hands it on again
//   5 DM_PSO_LATER_START=0 waits (negative control) with prepared.tsv the same
//   6 an archive file Metal refuses, removed at the open, removes prepared.tsv: that start waits (negative control); 7 the one after it hands it on
//   8 the archive's open alone (no prepare step after it: no window, DM_PSO_LATER_START=0, a quit) removes prepared.tsv with a refused file, and keeps it without one (negative control)
// In this process: the stamp follows the depth mode and the lists' bytes
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#include <spawn.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
extern char **environ;

static int checks, failed;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); checks++; \
    printf("%s %s: expected %lld, got %lld\n", w_ == g_ ? "ok  " : "FAIL", name, w_, g_); failed += w_ != g_; } while (0)

static int fixtures(NSString *dir, int compile) {
    if (compile) {
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); return float4(uv * 2 - 1, 0, 1); }\n"
            "fragment float4 fs() { return float4(0.5, 0.25, 1, 0.5); }\n";
        NSString *metal = [dir stringByAppendingPathComponent:@"fixture.metal"], *library = [dir stringByAppendingPathComponent:@"warm-vs.metallib"];
        if (![source writeToFile:metal atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 0;
        NSTask *compiler = [NSTask new]; compiler.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
        compiler.arguments = @[@"-sdk", @"macosx", @"metal", metal, @"-o", library];
        if (![compiler launchAndReturnError:nil]) return 0;
        [compiler waitUntilExit]; if (compiler.terminationStatus) return 0;
        if (![NSFileManager.defaultManager copyItemAtPath:library toPath:[dir stringByAppendingPathComponent:@"warm-fs.metallib"] error:nil]) return 0;
        for (NSString *stage in @[@"vs", @"fs"]) {
            NSDictionary *reflection = @{@"chain": @DMSH_CHAIN, @"route": @"B", @"entry": stage, @"entry_z": stage, @"bindings": @[], @"vertex_inputs": @[]};
            NSData *json = [NSJSONSerialization dataWithJSONObject:reflection options:0 error:nil];
            if (![json writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"warm-%@.json", stage]] atomically:YES]) return 0;
        }
    }
    g_msl_dir = dir; g_shmap = @{@"warm-vs": @"vertex", @"warm-fs": @"pixel"}.mutableCopy;
    return 1;
}
static NSString *row(MTLPixelFormat f) {
    pso_key key = {0}; key.cfmt[0] = (uint32_t)f; key.samples = 1; key.chmask = 15;
    NvShader *vs = [NvShader new], *fs = [NvShader new];
    strcpy(vs->key, "warm-vs"); strcpy(fs->key, "warm-fs"); fs->stage = 1;
    pso_skey sk; char hex[sizeof sk * 2 + 1];
    pso_skey_from(&key, vs, fs, 0, NULL, &sk); pso_skey_hex(&sk, hex);
    return [NSString stringWithFormat:@"R\t%s\n", hex];
}

// The start's first library load held at the device until the test lets it go, or for GATE_S: a start that waits for its lines is held there that long (timed_out) and goes on
enum { GATE_S = 2 };
@interface GateDevice : NSObject { @public id<MTLDevice> device; dispatch_semaphore_t release; _Atomic unsigned calls; _Atomic int timed_out; } @end
@implementation GateDevice
- (id)forwardingTargetForSelector:(SEL)selector { return device; }
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    if (!atomic_fetch_add(&calls, 1) && dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, GATE_S * NSEC_PER_SEC))) atomic_store(&timed_out, 1);
    return [device newLibraryWithData:data error:error];
}
@end

// One start (a process of its own). Exit bits: 1 handed to the background, 2 warm_start returned while the background's first load was held, 4 the lines finished,
// 8 every base of the start from the archive (none compiled), 16 the next submission claimed the pipeline, 32 prepared.tsv there at the end
enum { R_LATER = 1, R_HELD = 2, R_DONE = 4, R_HITS = 8, R_CLAIMED = 16, R_MARK = 32 };
static int start(NSString *dir) {
    mtl_init(); fixtures(dir, 0);
    GateDevice *gate = [GateDevice new]; gate->device = g_dev; gate->release = dispatch_semaphore_create(0); g_dev = (id<MTLDevice>)gate;
    warm_start();
    int r = 0;
    if (atomic_load(&g_warm_later)) r |= R_LATER;
    // warm_start returned with the first load not let go yet (the first frame would go on now), and the background reaches it: then it is let go
    int early = !atomic_load(&gate->timed_out);
    for (int i = 0; i < 300 && !atomic_load(&gate->calls); i++) usleep(10000);
    if (early && atomic_load(&gate->calls) && !atomic_load(&gate->timed_out)) r |= R_HELD;
    dispatch_semaphore_signal(gate->release);
    for (int i = 0; i < 2000 && atomic_load(&g_warm_running); i++) usleep(10000);
    if (!atomic_load(&g_warm_running)) r |= R_DONE;
    if (atomic_load(&g_pb_archived) > 0 && atomic_load(&g_pb_built) == 0) r |= R_HITS;
    warm_claim(); if (g_warm_claim_rps > 0) r |= R_CLAIMED;
    NSString *mark = [[dir stringByAppendingPathComponent:@"arch"] stringByAppendingPathComponent:@"prepared.tsv"];
    // prepared.tsv holds this start's stamp: it is written on the archive's queue once the writes are done (warm_later_mark)
    CC_SHA256_CTX h; CC_SHA256_Init(&h); long n = 0; warm_parse_h(@[@(getenv("DM_PSO_MANIFEST"))], &n, &h); NSString *want = warm_later_stamp(&h, n);
    if (g_arch_pending) dispatch_group_wait(g_arch_pending, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    for (int i = 0; i < 500 && ![[NSString stringWithContentsOfFile:mark encoding:NSUTF8StringEncoding error:nil] isEqualToString:want]; i++) { dispatch_sync(g_arch_q, ^{}); usleep(10000); }
    if ([[NSString stringWithContentsOfFile:mark encoding:NSUTF8StringEncoding error:nil] isEqualToString:want]) r |= R_MARK;
    g_dev = gate->device;
    return r;
}
// The archive's open alone ("open"): exit 1 when prepared.tsv is there after it
static int open_only(NSString *dir) {
    mtl_init(); fixtures(dir, 0); pso4_init();
    return [NSFileManager.defaultManager fileExistsAtPath:[[dir stringByAppendingPathComponent:@"arch"] stringByAppendingPathComponent:@"prepared.tsv"]];
}
static int run_mode(const char *self, const char *mode, NSString *dir) {
    fflush(stdout);
    pid_t pid; char *argv[] = {(char *)self, (char *)mode, (char *)dir.UTF8String, NULL};
    if (posix_spawn(&pid, self, NULL, NULL, argv, environ)) return -1;
    int st = 0; waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}
static int run_start(const char *self, NSString *dir, const char *later_env) {
    if (later_env) setenv("DM_PSO_LATER_START", later_env, 1); else unsetenv("DM_PSO_LATER_START");
    fflush(stdout);
    pid_t pid; char *argv[] = {(char *)self, "start", (char *)dir.UTF8String, NULL};
    if (posix_spawn(&pid, self, NULL, NULL, argv, environ)) return -1;
    int st = 0; waitpid(pid, &st, 0);
    unsetenv("DM_PSO_LATER_START");
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

int main(int argc, char **argv) { @autoreleasepool {
    alarm(120);
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc == 3 && !strcmp(argv[1], "start")) return start(@(argv[2]));
    if (argc == 3 && !strcmp(argv[1], "open")) return open_only(@(argv[2]));
    char tmpl[] = "/tmp/t_pso_later.XXXXXX"; if (!mkdtemp(tmpl)) return 2;
    NSString *dir = @(tmpl), *list = [dir stringByAppendingPathComponent:@"list.tsv"];
    char self[4096]; uint32_t sz = sizeof self; if (_NSGetExecutablePath(self, &sz)) return 2;
    setenv("DM_PSO_MANIFEST", list.UTF8String, 1); setenv("DM_PSO_ARCHIVE", [dir stringByAppendingPathComponent:@"arch"].UTF8String, 1);
    setenv("DM_PSO_PREPARE", "1", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_NVN_PREDICT", "0", 1);
    unsetenv("DM_PSO_USER"); unsetenv("DM_SAVE"); unsetenv("DM_PSO_BUNDLE"); unsetenv("DM_NVN_HILITE"); unsetenv("DM_NVN_MAGSCAN"); unsetenv("DM_PSO_RECORD");
    mtl_init();
    if (!fixtures(dir, 1)) { fprintf(stderr, "failed to compile the shader fixtures\n"); return 1; }
    NSString *text = [@"S\twarm-vs\t0\nS\twarm-fs\t1\n" stringByAppendingString:row(MTLPixelFormatRGBA8Unorm)];
    [text writeToFile:list atomically:YES encoding:NSUTF8StringEncoding error:nil];

    int r = run_start(self, dir, NULL);
    EXPECT("1 first start: waits for the step", 0, r & R_LATER);
    EXPECT("1 first start: its lines done before the first frame", R_DONE, r & R_DONE);
    EXPECT("1 first start: prepared.tsv written", R_MARK, r & R_MARK);
    r = run_start(self, dir, NULL);
    EXPECT("2 later start: handed to the background", R_LATER, r & R_LATER);
    EXPECT("2 later start: the first frame does not wait for the lines", R_HELD, r & R_HELD);
    EXPECT("2 later start: the lines finish in the background", R_DONE, r & R_DONE);
    EXPECT("2 later start: every base from the archive", R_HITS, r & R_HITS);
    EXPECT("2 later start: the next submission claims the pipeline", R_CLAIMED, r & R_CLAIMED);
    EXPECT("2 later start: prepared.tsv kept", R_MARK, r & R_MARK);
    [[text stringByAppendingString:row(MTLPixelFormatBGRA8Unorm)] writeToFile:list atomically:YES encoding:NSUTF8StringEncoding error:nil];
    r = run_start(self, dir, NULL);
    EXPECT("3 changed list: waits", 0, r & (R_LATER | R_HELD));
    EXPECT("3 changed list: prepared.tsv for the new list", R_MARK, r & R_MARK);
    r = run_start(self, dir, NULL);
    EXPECT("4 the start after it: handed to the background", R_LATER | R_HELD | R_DONE, r & (R_LATER | R_HELD | R_DONE));
    r = run_start(self, dir, "0");
    EXPECT("5 DM_PSO_LATER_START=0: waits", 0, r & (R_LATER | R_HELD));
    EXPECT("5 DM_PSO_LATER_START=0: its lines done before the first frame", R_DONE, r & R_DONE);
    NSString *bad = [[dir stringByAppendingPathComponent:@"arch"] stringByAppendingPathComponent:@"99990-1.mtl4a"];
    [[NSData dataWithBytes:"not an archive, not an archive, not an archive" length:46] writeToFile:bad atomically:YES];
    r = run_start(self, dir, NULL);
    EXPECT("6 a refused archive file removed at the open: waits", 0, r & (R_LATER | R_HELD));
    EXPECT("6 the refused file is gone", 0, [NSFileManager.defaultManager fileExistsAtPath:bad]);
    EXPECT("6 prepared.tsv written again by that start", R_MARK, r & R_MARK);
    r = run_start(self, dir, NULL);
    EXPECT("7 the start after it: handed to the background", R_LATER | R_HELD | R_DONE, r & (R_LATER | R_HELD | R_DONE));
    EXPECT("8 the archive's open with every file usable keeps prepared.tsv (negative control)", 1, run_mode(self, "open", dir));
    [[NSData dataWithBytes:"not an archive, not an archive, not an archive" length:46] writeToFile:bad atomically:YES];
    EXPECT("8 the archive's open alone removes prepared.tsv with a refused file", 0, run_mode(self, "open", dir));

    // The stamp: the depth mode and the lists' bytes are in it; the same inputs give the same stamp
    {
        CC_SHA256_CTX a, b, c, d; long n = 0;
        CC_SHA256_Init(&a); warm_parse_h(@[list], &n, &a); NSString *s1 = warm_later_stamp(&a, n);
        CC_SHA256_Init(&b); warm_parse_h(@[list], &n, &b); NSString *s2 = warm_later_stamp(&b, n);
        EXPECT("stamp: the same lists give the same stamp", 1, s1 && [s1 isEqualToString:s2]);
        EXPECT("stamp: names the chain, the app, the system", 1, [s1 containsString:@"chain\t" DMSH_CHAIN "\n"] && [s1 containsString:@"\napp\t"] && [s1 containsString:@"\nos\t"]);
        atomic_store(&g_depth_zero, 1); CC_SHA256_Init(&c); warm_parse_h(@[list], &n, &c); NSString *s3 = warm_later_stamp(&c, n); atomic_store(&g_depth_zero, 0);
        EXPECT("stamp: the depth mode changes it", 0, [s1 isEqualToString:s3]);
        [text writeToFile:list atomically:YES encoding:NSUTF8StringEncoding error:nil];
        CC_SHA256_Init(&d); warm_parse_h(@[list], &n, &d); NSString *s4 = warm_later_stamp(&d, n);
        EXPECT("stamp: another list changes it", 0, [s1 isEqualToString:s4]);
    }
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    printf("t_pso_later: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
