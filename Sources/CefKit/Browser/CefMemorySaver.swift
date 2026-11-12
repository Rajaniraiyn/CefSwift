import AppKit
import Foundation

/// When CefKit discards hidden browsers on its own to free memory; set it
/// as ``CefRuntime/memorySaver``.
///
/// ```swift
/// CefRuntime.shared.memorySaver = .after(.seconds(30 * 60))     // and under memory pressure
/// CefRuntime.shared.memorySaver = .underMemoryPressure     // only when macOS runs low
/// CefRuntime.shared.memorySaver = .off                     // the default
/// ```
///
/// A browser counts as hidden while it is off screen: a window tab that is
/// not selected, a minimized or hidden window, or a `CefWebView` that is not
/// in a visible window. Each browser is discarded at most once per hidden
/// spell, and only when ``CefBrowser/discardBlockers()`` allows.
public struct CefMemorySaver: Sendable, Equatable {
    /// How long a browser has to stay hidden before it is discarded; `nil`
    /// discards none for that reason.
    public var hiddenDuration: Duration?
    /// Whether every hidden browser is discarded when macOS reports memory
    /// pressure.
    public var discardsUnderMemoryPressure: Bool

    public init(hiddenDuration: Duration? = nil, discardsUnderMemoryPressure: Bool = false) {
        self.hiddenDuration = hiddenDuration
        self.discardsUnderMemoryPressure = discardsUnderMemoryPressure
    }

    /// Discards nothing on its own.
    public static let off = CefMemorySaver()

    /// Discards browsers hidden for `duration`, and, unless told otherwise,
    /// every hidden browser under memory pressure.
    public static func after(_ duration: Duration, orUnderMemoryPressure: Bool = true) -> CefMemorySaver {
        CefMemorySaver(hiddenDuration: duration, discardsUnderMemoryPressure: orUnderMemoryPressure)
    }

    /// Discards every hidden browser when macOS reports memory pressure.
    public static let underMemoryPressure = CefMemorySaver(discardsUnderMemoryPressure: true)

    /// How often hidden browsers are checked.
    var checkInterval: Duration? {
        hiddenDuration.map { min(max($0 / 4, .milliseconds(250)), .seconds(30)) }
    }
}

// MARK: - Monitor

/// Tracks how long each browser has been hidden, applies
/// ``CefRuntime/memorySaver``, and brings back browsers discarded by closing
/// them when their view is shown again. The lifecycle coordinator reports
/// every change of what is on screen.
@MainActor
final class CefMemorySaverMonitor {
    var policy = CefMemorySaver.off {
        didSet {
            guard policy != oldValue else { return }
            schedule()
        }
    }

    private var hiddenSince: [ObjectIdentifier: ContinuousClock.Instant] = [:]
    private var timer: Task<Void, Never>?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var isDiscarding = false

    func browserDidDiscard(_ browser: CefBrowser) {
        hiddenSince[ObjectIdentifier(browser)] = nil
    }

    /// Records which browsers are hidden, and restores discarded ones that
    /// are on screen. Called by ``CefLifecycleCoordinator``.
    func visibilityDidChange() {
        updateHiddenBrowsers()
        for browser in CefRuntime.shared.browsers where browser.isDiscarded && browser.isOnScreen {
            switch browser.discardPhase {
            case .closed:
                browser.restore()
            case .discarded:
                // Chromium loads a discarded tab again when it is shown; make
                // sure, in case the tab was discarded while merely covered.
                Task { @MainActor [weak browser] in
                    try? await Task.sleep(for: .milliseconds(500))
                    if let browser, browser.isDiscarded, browser.discardPhase == .discarded, browser.isOnScreen {
                        browser.restore()
                    }
                }
            default:
                break
            }
        }
    }

    private func updateHiddenBrowsers() {
        let now = ContinuousClock.now
        var seen = Set<ObjectIdentifier>()
        for browser in CefRuntime.shared.browsers where browser.state == .live {
            let id = ObjectIdentifier(browser)
            seen.insert(id)
            if browser.isOnScreen || browser.isDiscarded {
                hiddenSince[id] = nil
            } else if hiddenSince[id] == nil {
                hiddenSince[id] = now
            }
        }
        hiddenSince = hiddenSince.filter { seen.contains($0.key) }
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        if let interval = policy.checkInterval {
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard let self, !Task.isCancelled else { return }
                    await self.discardHiddenBrowsers(hiddenFor: self.policy.hiddenDuration)
                }
            }
        }
        if policy.discardsUnderMemoryPressure, pressureSource == nil {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.policy.discardsUnderMemoryPressure else { return }
                    Task { await self.discardHiddenBrowsers(hiddenFor: .zero) }
                }
            }
            source.activate()
            pressureSource = source
        } else if !policy.discardsUnderMemoryPressure, let source = pressureSource {
            source.cancel()
            pressureSource = nil
        }
    }

    /// Discards, longest hidden first, every browser that has been hidden
    /// for at least `duration` and that nothing keeps loaded.
    func discardHiddenBrowsers(hiddenFor duration: Duration?) async {
        guard let duration, !isDiscarding, !CefRuntime.shared.isTerminating else { return }
        isDiscarding = true
        defer { isDiscarding = false }
        updateHiddenBrowsers()
        let now = ContinuousClock.now
        let candidates = CefRuntime.shared.browsers
            .compactMap { browser in hiddenSince[ObjectIdentifier(browser)].map { (browser, $0) } }
            .filter { now - $0.1 >= duration && $0.0.allowsDiscarding }
            .sorted { $0.1 < $1.1 }
        for (browser, _) in candidates where !browser.isDiscarded && !browser.isOnScreen {
            do {
                try await browser.discard()
            } catch {
                // Try again after another full spell.
                if hiddenSince[ObjectIdentifier(browser)] != nil {
                    hiddenSince[ObjectIdentifier(browser)] = ContinuousClock.now
                }
            }
        }
    }
}

// MARK: - Chromium's tab discarding

/// Discards Chrome-style tabs through the Mojo interface behind
/// `chrome://discards`, from a hidden service host on that page.
///
/// Chromium's own discard policies never pick a CefKit tab: each is the
/// active tab of its own Chromium window, and the active tab is protected.
/// A discard with the `EXTERNAL` reason — the one `chrome.tabs.discard()`
/// uses — skips those rules, so CefKit applies its own
/// (``CefBrowser/discardBlockers()``) and reads Chromium's protections from
/// the same page. Chromium identifies tabs by address and title only.
///
/// Lifecycle units belong to the browser process, so the default profile's
/// service host answers for tabs of every profile.
@MainActor
final class CefTabDiscarder {
    /// Chromium's reasons, mapped to blockers, for keeping the tab of
    /// `browser`. Reasons that CefKit overrides (the tab being active, its
    /// DevTools session, its address scheme) are left out.
    func blockers(for browser: CefBrowser) async -> Set<CefDiscardBlocker> {
        guard let reasons = try? await call("(s, a) => s.find(a).then(c => c[0]?.cannotDiscardReasons ?? [])", target(browser))
            .arrayValue?.compactMap(\.stringValue)
        else { return [] }
        return Set(reasons.compactMap(Self.blocker(forReason:)))
    }

    /// Discards a hidden tab showing the page of `browser`, the
    /// `candidate`-th of those that match. Returns how many match.
    func discard(_ browser: CefBrowser, candidate: Int) async throws(CefDiscardError) -> Int {
        let arguments: CefJSON = [
            "url": .string(browser.url?.absoluteString ?? ""), "title": .string(browser.title),
            "candidate": .number(Double(candidate)),
        ]
        let reply: CefJSON
        do {
            reply = try await call(
                """
                async (s, a) => {
                  const tabs = await s.find(a);
                  const tab = tabs[a.candidate];
                  if (tab) await s.provider.discardById(tab.id, 0);
                  return { count: tabs.length, discarded: !!tab };
                }
                """, arguments)
        } catch {
            throw .failed("chrome://discards: \(error)")
        }
        guard reply["discarded"].boolValue == true else {
            throw .failed("Chromium does not list a hidden tab for \(browser.url?.absoluteString ?? "this browser").")
        }
        return reply["count"].intValue ?? 1
    }

    private func target(_ browser: CefBrowser) -> CefJSON {
        ["url": .string(browser.url?.absoluteString ?? ""), "title": .string(browser.title)]
    }

    private func call(_ function: String, _ arguments: CefJSON) async throws -> CefJSON {
        try await CefProfile.default.services.call(Self.module, function, arguments, timeout: .seconds(10))
    }

    static func blocker(forReason reason: String) -> CefDiscardBlocker? {
        switch reason {
        case "Tab is playing audio", "Tab has recently played audio": .playingAudio
        case "Tab is capturing video", "Tab is capturing audio", "Tab is currently being mirrored (casting, etc)",
             "Tab is currently capturing a window", "Tab is currently capturing a display":
            .capturingMedia
        case "Tab is displaying content in picture-in-picture": .pictureInPicture
        case "Tab is currently connected to a bluetooth device", "Tab is currently connected to a USB device":
            .connectedToDevice
        case "Tab has form interactions", "The user has edited the tab's content": .formInteraction
        case "Tab is protected by an extension": .exempt
        default: nil
        }
    }

    /// Binds a `DetailsProvider` of its own. Tab IDs are numbered afresh on
    /// every `getTabDiscardsInfo`, so each call looks its tab up again.
    static let module = CefServiceModule(
        name: "discards", hosts: [.discards],
        setup: """
        async () => {
          const m = await import('chrome://discards/discards.mojom-webui.js');
          const provider = m.DetailsProvider.getRemote();
          const VISIBLE = 2, DISCARDED = 5;
          const find = async a => {
            const { infos } = await provider.getTabDiscardsInfo();
            const tabs = infos.filter(i => i.tabUrl === a.url && i.visibility !== VISIBLE && i.state !== DISCARDED);
            const titled = tabs.filter(i => i.title === a.title);
            return titled.length ? titled : tabs;
          };
          return { provider, find };
        }
        """)
}
