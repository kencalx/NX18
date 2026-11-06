// MetricKit, kept on the device (DM_METRICS): iOS collects crash, hang, CPU and disk-write exception reports, on iOS 27 also the memory-limit exits with the call stacks of that moment, and
// daily metrics (launch and resume times, hitches, peak memory, the game layer's frame rate: front_ios.m names the layer "game"). The app subscribes at launch and writes each report, as it
// arrives, into Documents/metrics (in the Files app beside log.txt; the newest 30 are kept), and log.txt gets a line naming it: an end for going over the memory limit otherwise leaves no line
// in any log; a crash report also gets a summary in log.txt (metrics_crash_summary). Nothing is sent anywhere. iOS 27 delivers through MetricManager (Metrics.swift; MXMetricManager is deprecated from iOS 27.3), a system without it or DM_METRICS=mx through the
// MXMetricManager subscriber below. A run's diagnostics arrive at a later start, its daily metrics at most once a day. All of it runs on MetricKit's queues, Swift's task pool and the metrics
// queue here, never on the game's threads; DM_METRICS=0 subscribes to nothing
#import <Foundation/Foundation.h>
#import <MetricKit/MetricKit.h>
#include <stdbool.h>
#include <string.h>
#include "dm.h"
#include "metrics_files.h"
#include "crash_summary.h"
#import "DmMetrics.h"

bool dm_metrics_modern_start(void);   // Metrics.swift: MetricManager's two report sequences, read until the app ends; false where it is missing (before iOS 27)

static dispatch_queue_t g_metrics_q;   // the folder's writes and deletions, one at a time, at utility QoS
static NSString *g_metrics_dir;   // Documents/metrics
static unsigned g_metrics_seq;   // tells apart reports written in the same second (metrics queue)

static void metrics_log(NSString *kind, const char *name, int gone) {
    char older[96] = "";
    if (gone > 0) snprintf(older, sizeof older, "; %d older report%s deleted (the newest %d are kept)", gone, gone == 1 ? "" : "s", DM_METRICS_KEEP);
    if ([kind hasSuffix:@"-unencoded"])   // Metrics.swift could not encode the report: the file holds only the error, so the lines below (call stacks, a crash report) would not be true of it
        LOG("[RED] front end: MetricKit: a %s report arrived but could not be encoded as JSON; Documents/metrics/%s holds the error%s", kind.UTF8String, name, older);
    else if ([kind hasPrefix:@"diagnostic-memoryException"])
        LOG("[RED] front end: MetricKit: iOS ended a run of the app for going over its memory limit; the report, with the call stacks of that moment, is Documents/metrics/%s%s", name, older);
    else if ([kind hasPrefix:@"diagnostic-crash"]) LOG("[RED] front end: MetricKit: a crash report of a run of the app: Documents/metrics/%s%s", name, older);
    else if ([kind hasPrefix:@"diagnostic-hang"]) LOG("[RED] front end: MetricKit: a hang report (the main thread stopped answering) of a run of the app: Documents/metrics/%s%s", name, older);
    else if ([kind hasPrefix:@"diagnostic-"]) LOG("front end: MetricKit: a %s report: Documents/metrics/%s%s", kind.UTF8String + 11, name, older);
    else LOG("front end: MetricKit: metrics (%s): Documents/metrics/%s%s", kind.UTF8String, name, older);
}

// The crash summary (crash_summary.h), after the line naming a crash report: the exception, the crashed thread's newest frames with the game's own named by the layout record of
// the run that crashed (Documents/run_layouts.txt, which loader.c writes at each start), and the switchable mods that run had in place. Both delivery paths come here (Metrics.swift's
// MetricManager and the MXMetricManager subscriber below); it runs on the metrics queue, as their writes do
static void metrics_crash_line(void *ctx, const char *line) { (void)ctx; LOG("[RED] front end: crash: %s", line); }
static void metrics_crash_summary(NSData *json) {
    NSData *lay = [NSData dataWithContentsOfFile:[[g_metrics_dir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"run_layouts.txt"]];   // nil when there is none: the summary says so
    int n = dm_crash_summary(json.bytes, json.length, lay ? (lay.bytes ?: "") : NULL, lay.length, metrics_crash_line, NULL);   // every crash report gets a line
    if (n == 0) LOG("[RED] front end: crash: the report holds no crash diagnostic the summary knows; Documents/metrics keeps it as it came");
    else if (n == -2) LOG("[RED] front end: crash: the report is larger or nested deeper than the summary reads; Documents/metrics keeps it as it came");
    else if (n < 0) LOG("[RED] front end: crash: the report is not JSON the summary can read; Documents/metrics keeps it as it came");
}

void dm_metrics_store(NSData *json, NSString *kind) {
    if (!g_metrics_q || !json.length || !kind.length) return;
    NSData *data = [json copy]; NSString *k = [kind copy];
    dispatch_async(g_metrics_q, ^{
        char name[192]; time_t now = time(NULL); NSString *path = nil;
        for (int tries = 0; tries < 1000 && !path; tries++) {   // a free name: the same second and kind again takes the next sequence number
            if (dm_metrics_name(name, sizeof name, now, g_metrics_seq++, k.UTF8String) < 0) { LOG("[RED] front end: MetricKit: a report of kind %s has no file name; not kept", k.UTF8String); return; }
            NSString *p = [g_metrics_dir stringByAppendingPathComponent:@(name)];
            if (![NSFileManager.defaultManager fileExistsAtPath:p]) path = p;
        }
        if (!path) return;
        NSError *e = nil;
        if (![data writeToFile:path options:NSDataWritingAtomic error:&e]) {
            LOG("[RED] front end: MetricKit: Documents/metrics/%s could not be written: %s", name, e.localizedDescription.UTF8String);
            if ([k isEqualToString:@"diagnostic-crash"]) metrics_crash_summary(data);   // then the summary is all that is left of it
            return;
        }
        metrics_log(k, name, dm_metrics_prune(g_metrics_dir.fileSystemRepresentation, DM_METRICS_KEEP));
        if ([k isEqualToString:@"diagnostic-crash"]) metrics_crash_summary(data);
    });
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // MXMetricManager and its payloads are deprecated from iOS 27.3 (MetricManager replaces them): this path serves DM_METRICS=mx and a system without MetricManager
@interface DmMetricsSubscriber : NSObject <MXMetricManagerSubscriber>
@end
@implementation DmMetricsSubscriber
- (void)didReceiveMetricPayloads:(NSArray<MXMetricPayload *> *)payloads {
    for (MXMetricPayload *p in payloads) dm_metrics_store([p JSONRepresentation], @"metrics");
}
- (void)didReceiveDiagnosticPayloads:(NSArray<MXDiagnosticPayload *> *)payloads {
    for (MXDiagnosticPayload *p in payloads) {   // a payload can hold several kinds of diagnostic: its file is named after the gravest
        NSString *k = p.crashDiagnostics.count ? @"crash" : p.hangDiagnostics.count ? @"hang" : p.cpuExceptionDiagnostics.count ? @"cpuException"
                    : p.diskWriteExceptionDiagnostics.count ? @"diskWriteException" : p.appLaunchDiagnostics.count ? @"appLaunch" : @"other";
        dm_metrics_store([p JSONRepresentation], [@"diagnostic-" stringByAppendingString:k]);
    }
}
@end
static DmMetricsSubscriber *g_metrics_sub;   // held for the app's lifetime
static void metrics_mx_subscribe(void) {
    g_metrics_sub = [DmMetricsSubscriber new];
    [[MXMetricManager sharedManager] addSubscriber:g_metrics_sub];
}
#pragma clang diagnostic pop

void dm_metrics_start(void) {
    static int started; if (started++) return;
    const char *e = getenv("DM_METRICS");
    if (e && !strcmp(e, "0")) { LOG("front end: MetricKit off (DM_METRICS=0): no reports in Documents/metrics"); return; }
    int mx = e && !strcmp(e, "mx");
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!doc) return;
    g_metrics_dir = [doc stringByAppendingPathComponent:@"metrics"];
    g_metrics_q = dispatch_queue_create("dm.metrics", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    dispatch_async(g_metrics_q, ^{   // off the main thread: launch does not wait for the folder or MetricKit
        NSError *err = nil;
        if (![NSFileManager.defaultManager createDirectoryAtPath:g_metrics_dir withIntermediateDirectories:YES attributes:nil error:&err]) {
            LOG("[RED] front end: MetricKit: Documents/metrics could not be made (%s); no reports kept", err.localizedDescription.UTF8String);
            return;
        }
        int modern = !mx && dm_metrics_modern_start();
        if (!modern) metrics_mx_subscribe();
        LOG("front end: MetricKit reports go to Documents/metrics through %s (the newest %d kept, nothing leaves the device; DM_METRICS=0 turns this off)",
            modern ? "MetricManager" : mx ? "MXMetricManager (DM_METRICS=mx)" : "MXMetricManager (no MetricManager on this system)", DM_METRICS_KEEP);
    });
}
