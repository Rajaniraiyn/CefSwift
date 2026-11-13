import CefSwiftUI
import Dispatch

/// Memory Saver: puts tabs to sleep with `CefBrowser.discard()` once they
/// have been hidden for a while, and every hidden tab when macOS reports
/// memory pressure.
///
/// CefKit discards a browser only when asked; this is the browser's policy
/// for when to ask. A tab counts as hidden while its `lifecycle` is
/// `.hidden`, and `lifecycleChangedAt` says since when. Each tab is tried
/// at most once per hidden spell: one that `discard()` refuses (it plays
/// audio, has a `beforeunload` handler, …) waits another full spell.
@MainActor
final class TabDiscarding {
    struct Policy: Equatable {
        /// How long a tab has to stay hidden before it is discarded; `nil`
        /// discards none for that reason.
        var hiddenDuration: Duration?
        /// Whether every hidden tab is discarded under memory pressure.
        var discardsUnderMemoryPressure = false

        static let disabled = Policy()

        /// How often hidden tabs are checked.
        var checkInterval: Duration? {
            hiddenDuration.map { min(max($0 / 4, .milliseconds(250)), .seconds(30)) }
        }
    }

    /// What the policy needs to know of one browser.
    struct Tab<ID: Hashable> {
        var id: ID
        var isLive: Bool
        var lifecycle: CefBrowser.Lifecycle
        var lifecycleChangedAt: ContinuousClock.Instant
    }

    static let shared = TabDiscarding()

    var policy = Policy.disabled {
        didSet { if policy != oldValue { schedule() } }
    }

    private var lastAttempts: [CefBrowser.ID: ContinuousClock.Instant] = [:]
    private var timer: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var isDiscarding = false

    /// The tabs hidden for at least `duration`, longest hidden first. A tab
    /// tried at `lastAttempts[id]` waits `duration` from then.
    static func tabsToDiscard<ID: Hashable>(
        _ tabs: [Tab<ID>], hiddenFor duration: Duration, now: ContinuousClock.Instant,
        lastAttempts: [ID: ContinuousClock.Instant] = [:]
    ) -> [ID] {
        tabs.compactMap { tab -> (ID, ContinuousClock.Instant)? in
            guard tab.isLive, tab.lifecycle == .hidden else { return nil }
            let since = max(tab.lifecycleChangedAt, lastAttempts[tab.id] ?? tab.lifecycleChangedAt)
            return now - since >= duration ? (tab.id, tab.lifecycleChangedAt) : nil
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        if let interval = policy.checkInterval {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self, !Task.isCancelled, let duration = self.policy.hiddenDuration else { return }
                    await self.discardHiddenTabs(hiddenFor: duration)
                }
            }
        }
        if policy.discardsUnderMemoryPressure, pressureSource == nil {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.policy.discardsUnderMemoryPressure else { return }
                    Task { await self.discardHiddenTabs(hiddenFor: .zero) }
                }
            }
            source.activate()
            pressureSource = source
        } else if !policy.discardsUnderMemoryPressure, let source = pressureSource {
            source.cancel()
            pressureSource = nil
        }
    }

    private func discardHiddenTabs(hiddenFor duration: Duration) async {
        guard !isDiscarding else { return }
        isDiscarding = true
        defer { isDiscarding = false }
        let browsers = CefRuntime.shared.browsers
        let tabs = browsers.map {
            Tab(id: $0.id, isLive: $0.state == .live, lifecycle: $0.lifecycle, lifecycleChangedAt: $0.lifecycleChangedAt)
        }
        let live = Set(tabs.map(\.id))
        lastAttempts = lastAttempts.filter { live.contains($0.key) }
        for id in Self.tabsToDiscard(tabs, hiddenFor: duration, now: .now, lastAttempts: lastAttempts) {
            guard let browser = browsers.first(where: { $0.id == id }), browser.lifecycle == .hidden else { continue }
            do {
                try await browser.discard()
                lastAttempts[id] = nil
            } catch {
                lastAttempts[id] = .now
            }
        }
    }
}
