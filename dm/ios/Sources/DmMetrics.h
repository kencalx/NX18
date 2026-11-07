// MetricKit's reports kept on the device (DmMetrics.m, Metrics.swift): Documents/metrics, one JSON file per report, the newest 30. The app sends them nowhere.
// Its C part parses as plain C too (test_metrics_bgprepare.py typechecks Metrics.swift against it off a Mac, where nothing reads Objective-C)
#pragma once
#include <stdbool.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>   // outside the extern "C" block: a C++ reader may not import a module inside one
#endif

#ifdef __cplusplus
extern "C" {
#endif
/// At launch (main.m, application:didFinishLaunchingWithOptions:): subscribes to MetricKit's reports unless DM_METRICS=0. Returns at once; the work runs on a queue of its own.
void dm_metrics_start(void);

/// Metrics.swift implements it (@c @implementation: the compiler checks the Swift signature against this declaration): MetricManager's two report sequences, read until the app
/// ends; false where MetricManager is missing (before iOS 27), and DmMetrics.m subscribes the older MXMetricManager instead. Called once by DmMetrics.m, on its metrics queue
bool dm_metrics_modern_start(void);

#ifdef __OBJC__
/// Writes one report (its JSON) into Documents/metrics as <UTC time>-<sequence>-<kind>.json (metrics_files.h), drops the oldest past 30 and logs a line. kind: "metrics", or "diagnostic-" and what happened
/// (crash, hang, memoryException, cpuException, diskWriteException, appLaunch). A crash report's line is followed by its summary (crash_summary.h, by the layout record of the run
/// that crashed, Documents/run_layouts.txt). Any thread; the write and the summary go to the metrics queue, never a game thread.
void dm_metrics_store(NSData *_Nonnull json, NSString *_Nonnull kind);
#endif
#ifdef __cplusplus
}
#endif
