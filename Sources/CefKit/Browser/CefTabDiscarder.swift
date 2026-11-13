import Foundation

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
    /// the app decides how long a tab stays hidden first, and may discard
    /// pages of any scheme, with notification permission, or discarded
    /// before.
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

