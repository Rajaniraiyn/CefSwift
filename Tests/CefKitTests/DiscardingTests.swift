import Foundation
import JavaScriptCore
import Testing

@testable import CefKit

@Suite struct MemorySaverTests {
    @Test func presets() {
        #expect(CefMemorySaver.off == CefMemorySaver(hiddenDuration: nil, discardsUnderMemoryPressure: false))
        #expect(CefMemorySaver.underMemoryPressure.hiddenDuration == nil)
        #expect(CefMemorySaver.underMemoryPressure.discardsUnderMemoryPressure)
        let after = CefMemorySaver.after(.seconds(1800))
        #expect(after.hiddenDuration == .seconds(1800) && after.discardsUnderMemoryPressure)
        #expect(!CefMemorySaver.after(.seconds(60), orUnderMemoryPressure: false).discardsUnderMemoryPressure)
    }

    @Test func checkIntervalFollowsTheDuration() {
        #expect(CefMemorySaver.off.checkInterval == nil)
        #expect(CefMemorySaver.underMemoryPressure.checkInterval == nil)
        #expect(CefMemorySaver.after(.seconds(2)).checkInterval == .milliseconds(500))
        #expect(CefMemorySaver.after(.milliseconds(100)).checkInterval == .milliseconds(250))
        #expect(CefMemorySaver.after(.seconds(3600)).checkInterval == .seconds(30))
    }
}

@Suite struct DiscardBlockerTests {
    @MainActor @Test func chromiumReasonsMapToBlockers() {
        #expect(CefTabDiscarder.blocker(forReason: "Tab is playing audio") == .playingAudio)
        #expect(CefTabDiscarder.blocker(forReason: "Tab has recently played audio") == .playingAudio)
        #expect(CefTabDiscarder.blocker(forReason: "Tab is capturing video") == .capturingMedia)
        #expect(CefTabDiscarder.blocker(forReason: "Tab is currently capturing a display") == .capturingMedia)
        #expect(CefTabDiscarder.blocker(forReason: "Tab has form interactions") == .formInteraction)
        #expect(CefTabDiscarder.blocker(forReason: "The user has edited the tab's content") == .formInteraction)
        #expect(CefTabDiscarder.blocker(forReason: "Tab is currently connected to a USB device") == .connectedToDevice)
        #expect(CefTabDiscarder.blocker(forReason: "Tab is protected by an extension") == .exempt)
    }

    /// CefKit tabs are always the active tab of their Chromium window and
    /// keep a DevTools session; those protections do not apply to them.
    @MainActor @Test func overriddenReasonsAreIgnored() {
        for reason in [
            "Tab is currently active", "Tab is currently using DevTools", "Tab is recently visible",
            "URL scheme is not http, https, chrome or data", "Notification permission is granted",
            "Tab discarding has already been attempted",
        ] {
            #expect(CefTabDiscarder.blocker(forReason: reason) == nil)
        }
    }

    /// A reason CefKit does not know keeps the tab, as do the ones that say
    /// Chromium sees it on screen or protects it.
    @MainActor @Test func unknownReasonsBlock() {
        #expect(CefTabDiscarder.blocker(forReason: "Tab is hosting a PDF") == .unknown("Tab is hosting a PDF"))
        #expect(CefTabDiscarder.blocker(forReason: "Some reason of a later Chromium") == .unknown("Some reason of a later Chromium"))
        #expect(CefTabDiscarder.blocker(forReason: "Tab is currently visible") == .visible)
        #expect(CefTabDiscarder.blocker(forReason: "Tab was pinned") == .exempt)
    }

    /// A look-up that failed or that matched no tab, or several, is a
    /// blocker, not an empty set.
    @MainActor @Test func unclearLookUpsBlock() {
        #expect(CefTabDiscarder.blockers(fromLookUp: .null).count == 1)
        #expect(CefTabDiscarder.blockers(fromLookUp: ["count": 0, "reasons": []]).first.map(isUnknown) == true)
        #expect(CefTabDiscarder.blockers(fromLookUp: ["count": 2, "reasons": []]).first.map(isUnknown) == true)
        #expect(CefTabDiscarder.blockers(fromLookUp: ["count": 1]).first.map(isUnknown) == true)
        #expect(CefTabDiscarder.blockers(fromLookUp: ["count": 1, "id": 3, "reasons": []]).isEmpty)
        #expect(CefTabDiscarder.blockers(fromLookUp: ["count": 1, "id": 3, "reasons": ["Tab is playing audio"]]) == [.playingAudio])
    }

    @Test func errorDescription() {
        #expect(CefDiscardError.blocked([.visible, .playingAudio]).description == "not discardable: playingAudio, visible")
        #expect(CefDiscardError.blocked([.unknown("why")]).description == "not discardable: unknown(why)")
    }

    private func isUnknown(_ blocker: CefDiscardBlocker) -> Bool {
        if case .unknown = blocker { return true }
        return false
    }
}

/// The JavaScript that picks a browser's tab from `chrome://discards`,
/// run in JavaScriptCore on lists shaped like `getTabDiscardsInfo`'s.
@Suite struct DiscardTabMatchingTests {
    private func tab(_ id: Int, _ url: String, _ title: String, visibility: Int = 0, state: Int = 0, reasons: [String] = []) -> [String: Any] {
        ["id": id, "tabUrl": url, "title": title, "visibility": visibility, "state": state, "cannotDiscardReasons": reasons]
    }

    @MainActor private func pick(_ infos: [[String: Any]], url: String, title: String) throws -> CefJSON {
        let context = try #require(JSContext())
        let arguments: [String: Any] = ["url": url, "title": title, "ignored": CefTabDiscarder.overriddenReasons.sorted()]
        let infosJSON = String(decoding: try JSONSerialization.data(withJSONObject: infos), as: UTF8.self)
        let argumentsJSON = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let result = try #require(context.evaluateScript(
            "JSON.stringify((\(CefTabDiscarder.matcher))(\(infosJSON), \(argumentsJSON)))")?.toString())
        return try JSONDecoder().decode(CefJSON.self, from: Data(result.utf8))
    }

    @MainActor @Test func theOneTabWithTheAddressIsPicked() throws {
        let reply = try pick([tab(1, "https://a.test/", "A"), tab(2, "https://b.test/", "B")], url: "https://a.test/", title: "a.test")
        #expect(reply["count"].intValue == 1 && reply["id"].intValue == 1)
        #expect(CefTabDiscarder.blockers(fromLookUp: reply).isEmpty)
    }

    @MainActor @Test func theTitleTellsTabsWithOneAddressApart() throws {
        let reply = try pick([tab(1, "https://a.test/", "Inbox"), tab(2, "https://a.test/", "Drafts")], url: "https://a.test/", title: "Drafts")
        #expect(reply["count"].intValue == 1 && reply["id"].intValue == 2)
    }

    /// Two tabs with the same address and title: discarding either could
    /// unload the other, so neither is picked. Before, the first match was.
    @MainActor @Test func indistinguishableTabsAreNotPicked() throws {
        let reply = try pick([tab(1, "https://a.test/", "A"), tab(2, "https://a.test/", "A", visibility: 2)], url: "https://a.test/", title: "A")
        #expect(reply["count"].intValue == 2 && reply["id"] == .null)
        #expect(CefTabDiscarder.blockers(fromLookUp: reply) == [.unknown("Chromium lists 2 tabs with this browser's address and title.")])
        // A title that matches neither does not fall back to the address alone.
        let untitled = try pick([tab(1, "https://a.test/", "A"), tab(2, "https://a.test/", "B")], url: "https://a.test/", title: "C")
        #expect(untitled["count"].intValue == 0)
    }

    @MainActor @Test func aVisibleOrDiscardedTabIsKept() throws {
        let visible = try pick([tab(1, "https://a.test/", "A", visibility: 2, reasons: ["Tab is currently active"])], url: "https://a.test/", title: "A")
        #expect(CefTabDiscarder.blockers(fromLookUp: visible) == [.visible])
        let discarded = try pick([tab(1, "https://a.test/", "A", state: 5)], url: "https://a.test/", title: "A")
        #expect(CefTabDiscarder.blockers(fromLookUp: discarded) == [.unknown("Tab is already discarded")])
        let unknown = try pick([tab(1, "https://a.test/", "A", reasons: ["Tab is hosting a PDF", "Tab is recently visible"])], url: "https://a.test/", title: "A")
        #expect(CefTabDiscarder.blockers(fromLookUp: unknown) == [.unknown("Tab is hosting a PDF")])
    }
}
