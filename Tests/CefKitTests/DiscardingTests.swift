import Foundation
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
        ] {
            #expect(CefTabDiscarder.blocker(forReason: reason) == nil)
        }
    }

    @Test func errorDescription() {
        #expect(CefDiscardError.blocked([.visible, .playingAudio]).description == "not discardable: playingAudio, visible")
    }
}
