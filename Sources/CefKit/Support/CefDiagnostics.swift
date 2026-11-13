import CefBase
import Darwin
import os

/// Counters for SelfTest's benchmarks: time spent in CefKit's own part of
/// hot callbacks. Off unless ``isEnabled`` is set; then each sample costs
/// one lock.
@_spi(Testing) public enum CefDiagnostics {
    /// One accumulated measurement.
    public struct Counter: Sendable, Equatable {
        public var count = 0
        public var nanoseconds: UInt64 = 0
        public var microsecondsEach: Double { count == 0 ? 0 : Double(nanoseconds) / Double(count) / 1000 }
    }

    /// What can be measured.
    public enum Metric: String, Sendable, CaseIterable {
        /// CefKit's part of `on_before_resource_load`, around the filter.
        case requestFilterOverhead
        /// The request filter itself.
        case requestFilter
        /// Main-thread time taking an accessibility update from CEF.
        case accessibilityIngestMain
        /// Background time turning an accessibility update into `CefJSON`.
        case accessibilityIngestBackground
        /// Main-thread time handling a DevTools event.
        case devToolsEvent
        /// A service-host call, from the engine's entry to its result.
        case serviceCall
        /// Encoding a service call: its script or its arguments.
        case serviceEncode
        /// Decoding a service call's result into the caller's type.
        case serviceDecode
        /// Bytes sent to service hosts (``Counter/nanoseconds`` holds bytes).
        case serviceRequestBytes
        /// Bytes received from service hosts (``Counter/nanoseconds`` holds bytes).
        case serviceReplyBytes
        /// Events delivered from service hosts.
        case serviceEvent
    }

    /// How offscreen accessibility updates are taken from CEF.
    public enum AccessibilityIngestion: Sendable {
        /// `cef_write_json` on the main thread, parsed on a queue.
        case json
        /// A deep copy on the main thread, read value by value on a queue
        /// (the default).
        case valueCopy
    }

    private static let ingestion = OSAllocatedUnfairLock(initialState: AccessibilityIngestion.valueCopy)

    /// For SelfTest's `axingest` benchmark.
    public static var accessibilityIngestion: AccessibilityIngestion {
        get { ingestion.withLock { $0 } }
        set { ingestion.withLock { $0 = newValue } }
    }

    private static let state = OSAllocatedUnfairLock(initialState: (enabled: false, counters: [Metric: Counter]()))

    public static var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set { state.withLock { $0.enabled = newValue } }
    }

    public static func counter(_ metric: Metric) -> Counter {
        state.withLock { $0.counters[metric] ?? Counter() }
    }

    public static func reset() {
        state.withLock { $0.counters = [:] }
    }

    /// A start time, or 0 when measuring is off.
    package static func start() -> UInt64 {
        isEnabled ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0
    }

    /// Adds `amount` (bytes, say) to `metric`, when measuring is on.
    package static func record(_ metric: Metric, amount: Int) {
        guard isEnabled else { return }
        state.withLock {
            $0.counters[metric, default: Counter()].count += 1
            $0.counters[metric, default: Counter()].nanoseconds += UInt64(max(0, amount))
        }
    }

    /// Adds the time since `start` to `metric`.
    package static func record(_ metric: Metric, since start: UInt64) {
        guard start != 0 else { return }
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start
        state.withLock {
            $0.counters[metric, default: Counter()].count += 1
            $0.counters[metric, default: Counter()].nanoseconds += elapsed
        }
    }
}

// MARK: - Census

extension CefDiagnostics {
    /// Turns on the live-object census: counts of `CefRef`s by CEF type,
    /// CEF structs CefSwift implements by owner type, received payloads and
    /// their shared memory mappings. Call it before
    /// ``CefRuntime/initialize(configuration:)``; objects made before are
    /// not counted.
    public static func enableCensus() {
        CefCensus.setEnabled(true)
    }

    /// The live counts that are not zero, by description.
    public static func census() -> [String: Int] {
        var result: [String: Int] = [:]
        for (kind, count) in CefCensus.snapshot() { result[kind.description] = count }
        return result
    }
}
