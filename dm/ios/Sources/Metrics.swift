// MetricKit on iOS 27 (DmMetrics.m starts it, unless DM_METRICS=0 or =mx): one MetricManager for the app's lifetime, its diagnostic and metric report sequences each read by a task of
// its own, and every report encoded as JSON (reports are Codable) and handed to dm_metrics_store, which writes it into Documents/metrics and logs a line. The diagnostics include iOS 27's
// MemoryExceptionDiagnostic, the end of a run for going over the memory limit, with its call stacks, which no log otherwise records; the metrics include MetalFrameRateMetric per CAMetalLayer,
// whose layerName is the game layer's name (front_ios.m: "game"). The tasks run on Swift's task pool at utility priority, never on a game thread, and send nothing anywhere
import Foundation
import MetricKit

/// Starts the two report loops. Called once by DmMetrics.m, on its metrics queue. Returns false where MetricManager is missing (before iOS 27), and DmMetrics.m subscribes the older
/// MXMetricManager instead. The C declaration is DmMetrics.h's (through the bridging header), which @c @implementation checks this signature against.
@c @implementation
public func dm_metrics_modern_start() -> Bool {
    guard #available(iOS 27.0, *) else { return false }
    DmMetricReports.start()
    return true
}

@available(iOS 27.0, *)
private enum DmMetricReports {
    static func start() {
        // One instance, shared by both loops (MetricManager's documentation: two managers reading the same sequence each get part of the reports); the loops never end, so it lives as long as the app
        let manager = MetricManager()
        Task.detached(priority: .utility) {
            for await report in manager.diagnosticReports { DmMetricReports.store(report, kind: "diagnostic-" + DmMetricReports.kind(of: report.result)) }
        }
        Task.detached(priority: .utility) {
            for await report in manager.metricReports { DmMetricReports.store(report, kind: "metrics") }
        }
    }

    /// The kind in the file name; a case a later system adds is "other" (its JSON still says what it is)
    static func kind(of result: DiagnosticResult) -> String {
        if case .memoryException = result { return "memoryException" }
        if case .crash = result { return "crash" }
        if case .hang = result { return "hang" }
        if case .cpuException = result { return "cpuException" }
        if case .diskWriteException = result { return "diskWriteException" }
        if case .appLaunch = result { return "appLaunch" }
        return "other"
    }

    /// A report that does not encode is kept as a note of the error, under its kind with -unencoded, so the file and the log line still say that one arrived
    static func store<Report: Encodable>(_ report: Report, kind: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            dm_metrics_store(try encoder.encode(report), kind)
        } catch {
            if let note = try? JSONSerialization.data(withJSONObject: ["encodingError": String(describing: error)]) { dm_metrics_store(note, kind + "-unencoded") }
        }
    }
}
