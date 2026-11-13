import AppKit
import Foundation

extension CefRuntime {
    /// When CefKit discards hidden browsers on its own to free memory; set it
    /// as ``CefRuntime/discardPolicy``.
    ///
    /// ```swift
    /// CefRuntime.shared.discardPolicy = .after(.seconds(30 * 60))     // and under memory pressure
    /// CefRuntime.shared.discardPolicy = .underMemoryPressure     // only when macOS runs low
    /// CefRuntime.shared.discardPolicy = .disabled                      // the default
    /// ```
    ///
    /// A browser counts as hidden while it is off screen: a window tab that is
    /// not selected, a minimized or hidden window, or a `CefWebView` that is not
    /// in a visible window. Each browser is discarded at most once per hidden
    /// spell, and only when ``CefBrowser/discardBlockers()`` allows.
    public struct DiscardPolicy: Sendable, Equatable {
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
        public static let disabled = CefRuntime.DiscardPolicy()

        /// Discards browsers hidden for `duration`, and, unless told otherwise,
        /// every hidden browser under memory pressure.
        public static func after(_ duration: Duration, orUnderMemoryPressure: Bool = true) -> CefRuntime.DiscardPolicy {
            CefRuntime.DiscardPolicy(hiddenDuration: duration, discardsUnderMemoryPressure: orUnderMemoryPressure)
        }

        /// Discards every hidden browser when macOS reports memory pressure.
        public static let underMemoryPressure = CefRuntime.DiscardPolicy(discardsUnderMemoryPressure: true)

        /// How often hidden browsers are checked.
        var checkInterval: Duration? {
            hiddenDuration.map { min(max($0 / 4, .milliseconds(250)), .seconds(30)) }
        }
    }
}

// MARK: - Monitor

/// Tracks how long each browser has been hidden, applies
/// ``CefRuntime/discardPolicy``, and brings back browsers discarded by closing
/// them when their view is shown again. The lifecycle coordinator reports
/// every change of what is on screen.
@MainActor
final class CefDiscardMonitor {
    var policy = CefRuntime.DiscardPolicy.disabled {
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
    private func discardHiddenBrowsers(hiddenFor duration: Duration?) async {
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
/// the same page.
///
/// `TabDiscardsInfo` names a tab only by its address, its title and an
/// `id` that `getTabDiscardsInfo` numbers afresh on every call; nothing in
/// it maps to a CEF browser. A browser's tab is therefore the one tab with
/// its address or, when several share it, the one that also has its title.
/// Any other outcome is a blocker, never a guess. The look-up and the
/// discard run in one call, so the tab discarded is the one just checked.
///
/// Lifecycle units belong to the browser process, so the default profile's
/// service host answers for tabs of every profile.
@MainActor
final class CefTabDiscarder {
    /// Chromium's reasons, mapped to blockers, for keeping the tab of
    /// `browser`. A failed look-up is a blocker too.
    func blockers(for browser: CefBrowser) async -> Set<CefBrowser.DiscardBlocker> {
        do {
            return Self.blockers(fromLookUp: try await call("(s, a) => s.lookUp(a)", arguments(for: browser)))
        } catch {
            return [.unknown("chrome://discards: \(error)")]
        }
    }

    /// Discards the tab of `browser` if Chromium lists exactly one that can
    /// be its tab, and that tab is hidden and has no reason to stay.
    func discard(_ browser: CefBrowser) async throws(CefBrowser.DiscardError) {
        let reply: CefJSON
        do {
            reply = try await call(
                """
                async (s, a) => {
                  const found = await s.lookUp(a);
                  if (found.count === 1 && found.reasons.length === 0) {
                    await s.provider.discardById(found.id, 0);
                    found.discarded = true;
                  }
                  return found;
                }
                """, arguments(for: browser))
        } catch {
            throw .failed("chrome://discards: \(error)")
        }
        guard reply["discarded"].boolValue != true else { return }
        let blockers = Self.blockers(fromLookUp: reply)
        throw blockers.isEmpty ? .failed("Chromium did not discard the tab.") : .blocked(blockers)
    }

    private func arguments(for browser: CefBrowser) -> CefJSON {
        [
            "url": .string(browser.url?.absoluteString ?? ""), "title": .string(browser.title),
            "ignored": .array(Self.overriddenReasons.sorted().map { .string($0) }),
        ]
    }

    private func call(_ function: String, _ arguments: CefJSON) async throws -> CefJSON {
        try await CefProfile.default.services.call(Self.module, function, arguments, timeout: .seconds(10))
    }

    /// The blockers a look-up's reply (``matcher``) reports.
    static func blockers(fromLookUp reply: CefJSON) -> Set<CefBrowser.DiscardBlocker> {
        guard let count = reply["count"].intValue else { return [.unknown("chrome://discards gave no answer.")] }
        guard count == 1 else {
            return [.unknown(count == 0
                ? "Chromium lists no tab with this browser's address."
                : "Chromium lists \(count) tabs with this browser's address and title.")]
        }
        guard let reasons = reply["reasons"].arrayValue?.compactMap(\.stringValue) else {
            return [.unknown("chrome://discards gave no reasons.")]
        }
        return Set(reasons.compactMap(blocker(forReason:)))
    }

    /// Chromium's reasons that CefKit overrides: each of its tabs is the
    /// active tab of its own window and keeps CefKit's DevTools session, and
    /// CefKit decides by itself how long a tab stays hidden first, and
    /// discards pages of any scheme, with notification permission, or
    /// discarded before.
    static let overriddenReasons: Set<String> = [
        "Tab is currently active", "Tab is currently using DevTools", "Tab is recently visible",
        "URL scheme is not http, https, chrome or data", "Notification permission is granted",
        "Tab discarding has already been attempted",
    ]

    /// The blocker for one of Chromium's reasons (`CannotDiscardReasonToString`,
    /// `cannot_discard_reason.cc`): `nil` for an overridden reason, and
    /// ``CefBrowser/DiscardBlocker/unknown(_:)`` for one CefKit does not know.
    static func blocker(forReason reason: String) -> CefBrowser.DiscardBlocker? {
        if overriddenReasons.contains(reason) { return nil }
        switch reason {
        case "Tab is currently visible": return .visible
        case "Tab is playing audio", "Tab has recently played audio": return .playingAudio
        case "Tab is capturing video", "Tab is capturing audio", "Tab is currently being mirrored (casting, etc)",
             "Tab is currently capturing a window", "Tab is currently capturing a display":
            return .capturingMedia
        case "Tab is displaying content in picture-in-picture": return .pictureInPicture
        case "Tab is currently connected to a bluetooth device", "Tab is currently connected to a USB device":
            return .connectedToDevice
        case "Tab has form interactions", "The user has edited the tab's content": return .formInteraction
        case "Tab is protected by an extension", "Tab was pinned", "Tab was opted out via a setting or enterprise policy":
            return .exempt
        default: return .unknown(reason)
        }
    }

    /// Picks a browser's tab from `getTabDiscardsInfo`'s list:
    /// `(infos, {url, title, ignored}) => {count, id, reasons}`. `count` is
    /// how many tabs can be the browser's; only when it is 1 are `id` and
    /// `reasons` (Chromium's, less the `ignored` ones, plus the tab being
    /// visible or discarded) about that tab.
    static let matcher = """
        (infos, a) => {
          const VISIBLE = 2, DISCARDED = 5;
          let tabs = infos.filter(i => i.tabUrl === a.url);
          if (tabs.length > 1) tabs = tabs.filter(i => i.title === a.title);
          if (tabs.length !== 1) return { count: tabs.length, reasons: [] };
          const tab = tabs[0];
          const reasons = tab.cannotDiscardReasons.filter(r => !a.ignored.includes(r));
          const add = r => { if (!reasons.includes(r)) reasons.push(r); };
          if (tab.visibility === VISIBLE) add('Tab is currently visible');
          if (tab.state === DISCARDED) add('Tab is already discarded');
          return { count: 1, id: tab.id, reasons };
        }
        """

    /// Binds a `DetailsProvider` of its own.
    static let module = CefServiceModule(
        name: "discards", hosts: [.discards],
        setup: """
        async () => {
          const m = await import('chrome://discards/discards.mojom-webui.js');
          const provider = m.DetailsProvider.getRemote();
          const pick = \(matcher);
          const lookUp = async a => pick((await provider.getTabDiscardsInfo()).infos, a);
          return { provider, lookUp };
        }
        """)
}

