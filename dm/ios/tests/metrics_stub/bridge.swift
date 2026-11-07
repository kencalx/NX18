// Stand-in for the Objective-C part of DmMetrics.h (void dm_metrics_store(NSData *_Nonnull json, NSString *_Nonnull kind)), for the typecheck of Metrics.swift off a Mac
// (test_metrics_bgprepare.py), where Swift reads no Objective-C; the header's C part (dm_metrics_modern_start, which Metrics.swift implements) comes from DmMetrics.h itself
import Foundation
func dm_metrics_store(_ json: Data, _ kind: String) { _ = (json, kind) }
