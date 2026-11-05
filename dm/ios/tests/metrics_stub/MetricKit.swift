// Stand-in for MetricKit's iOS 27 Swift API, written from the declarations on developer.apple.com (MetricManager, MetricReport, DiagnosticReport, DiagnosticResult and its cases, Sendable and Codable as documented), so that Metrics.swift typechecks off a Mac (test_metrics_bgprepare.py); a Mac checks it against the iPhone SDK instead
import Foundation
@available(iOS 27.0, *) public struct StateReportingDomain: Hashable, Sendable {}
@available(iOS 27.0, *) public struct CrashDiagnostic: Codable, Hashable, Sendable {}
@available(iOS 27.0, *) public struct HangDiagnostic: Codable, Hashable, Sendable {}
@available(iOS 27.0, *) public struct CPUExceptionDiagnostic: Codable, Hashable, Sendable {}
@available(iOS 27.0, *) public struct DiskWriteExceptionDiagnostic: Codable, Hashable, Sendable {}
@available(iOS 27.0, *) public struct AppLaunchDiagnostic: Codable, Hashable, Sendable {}
@available(iOS 27.0, *) public struct MemoryExceptionDiagnostic: Codable, Hashable, Sendable {}
@available(iOS 27.0, *) public enum DiagnosticResult: Codable, Hashable, Sendable {
    case appLaunch(AppLaunchDiagnostic)
    case cpuException(CPUExceptionDiagnostic)
    case crash(CrashDiagnostic)
    case diskWriteException(DiskWriteExceptionDiagnostic)
    case hang(HangDiagnostic)
    case memoryException(MemoryExceptionDiagnostic)
}
@available(iOS 27.0, *) public struct MetricReport: Codable, Hashable, Sendable { public let timeRange: DateInterval }
@available(iOS 27.0, *) public struct DiagnosticReport: Codable, Hashable, Sendable { public let timeRange: DateInterval; public let result: DiagnosticResult }
@available(iOS 27.0, *) public final class MetricManager: Sendable {
    public init(enabledStateReportingDomains: Set<StateReportingDomain>) {}
    public convenience init() { self.init(enabledStateReportingDomains: []) }
    public final var metricReports: some AsyncSequence<MetricReport, Never> { AsyncStream<MetricReport> { $0.finish() } }
    public final var diagnosticReports: some AsyncSequence<DiagnosticReport, Never> { AsyncStream<DiagnosticReport> { $0.finish() } }
}
