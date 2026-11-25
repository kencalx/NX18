// iOS 27's MetricKit diagnostic reports, kept on the device: when iOS ended an earlier run for going over its memory limit, a later start gets the system's report
// (usually within a day). Each one becomes a [memory] line in log.txt (when, which NX 18 states it was in: state_report.h, Low Power Mode) and the full report,
// with its call stacks, as Documents/logs/memory-kill-<time>.json for the player to share. Hangs (the main thread unresponsive, with the system's call stacks of
// every thread: the iPhone freeze that needs the app closed) and crashes are kept the same way, as [hang] / [crash] lines and Documents/logs/hang-<time>.json /
// crash-<time>.json (2026-11-21). Nothing is sent anywhere. Started from main.m before UIApplicationMain
import Foundation
import MetricKit

nonisolated(unsafe) private var g_metrics: MetricManager?   // kept for the process's life: the report stream ends with it

@_cdecl("dm_memory_reports_start")
func dmMemoryReportsStart() {
    guard g_metrics == nil else { return }
    let m = MetricManager(enabledStateReportingDomains: ["com.nx18.screen", "com.nx18.hold"])
    g_metrics = m
    Task.detached(priority: .utility) {
        for await report in m.diagnosticReports {
            switch report.result {
            case .memoryException: diagnosticSave(report, kind: "memory", file: "memory-kill", what: "iOS ended a run for going over its memory limit")
            case .hang(let h): diagnosticSave(report, kind: "hang", file: "hang", what: "the app stopped responding for \(Int(h.hangDuration.converted(to: .milliseconds).value)) ms")
            case .crash: diagnosticSave(report, kind: "crash", file: "crash", what: "a run ended in a crash")
            default: continue
            }
        }
    }
}

private func diagnosticSave(_ report: DiagnosticReport, kind: String, file prefix: String, what: String) {
    let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
    let env = report.environment
    let states = env.states.map { "\($0.domain.split(separator: ".").last ?? "") \($0.label) \(Int($0.duration.converted(to: .seconds).value)) s" }
    var file = ""
    if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
        let dir = docs.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = iso.string(from: report.timeRange.end).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(prefix)-\(stamp).json")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(report), (try? data.write(to: url, options: .atomic)) != nil { file = ", full report Documents/logs/\(url.lastPathComponent)" }
    }
    let line = "[dm] [\(kind)] \(what) between \(iso.string(from: report.timeRange.start)) and \(iso.string(from: report.timeRange.end))"
        + " (app \(env.applicationVersion) build \(env.applicationBuildVersion), Low Power Mode \(env.lowPowerModeEnabled ? "on" : "off"))"
        + "; states: \(states.isEmpty ? "none reported" : states.joined(separator: ", "))\(file)\n"
    FileHandle.standardError.write(Data(line.utf8))   // log.txt (main.m's redirect)
}
