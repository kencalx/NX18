// Stand-in for what the bridging header gives Metrics.swift (DmMetrics.h: void dm_metrics_store(NSData *_Nonnull json, NSString *_Nonnull kind)), for its typecheck (test_metrics_bgprepare.py)
import Foundation
func dm_metrics_store(_ json: Data, _ kind: String) { _ = (json, kind) }
