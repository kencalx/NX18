// MetricKit's reports kept on the device (DmMetrics.m, Metrics.swift): Documents/metrics, one JSON file per report, the newest 30. The app sends them nowhere.
#import <Foundation/Foundation.h>

/// At launch (main.m, application:didFinishLaunchingWithOptions:): subscribes to MetricKit's reports unless DM_METRICS=0. Returns at once; the work runs on a queue of its own.
void dm_metrics_start(void);

/// Writes one report (its JSON) into Documents/metrics as <UTC time>-<sequence>-<kind>.json (metrics_files.h), drops the oldest past 30 and logs a line. kind: "metrics", or "diagnostic-" and what happened
/// (crash, hang, memoryException, cpuException, diskWriteException, appLaunch). Any thread; the write goes to the metrics queue, never a game thread.
void dm_metrics_store(NSData *_Nonnull json, NSString *_Nonnull kind);
