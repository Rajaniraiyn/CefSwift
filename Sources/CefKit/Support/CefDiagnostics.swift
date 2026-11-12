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
        /// Main-thread time handling a DevTools method result.
        case devToolsResult
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
    static func start() -> UInt64 {
        isEnabled ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0
    }

    /// Adds the time since `start` to `metric`.
    static func record(_ metric: Metric, since start: UInt64) {
        guard start != 0 else { return }
        let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start
        state.withLock {
            $0.counters[metric, default: Counter()].count += 1
            $0.counters[metric, default: Counter()].nanoseconds += elapsed
        }
    }
}
