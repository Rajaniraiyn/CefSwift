import Foundation
import JavaScriptCore
import Testing

@testable import CefKit

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
        #expect(CefBrowser.DiscardError.blocked([.visible, .playingAudio]).description == "not discardable: playingAudio, visible")
        #expect(CefBrowser.DiscardError.blocked([.unknown("why")]).description == "not discardable: unknown(why)")
    }

    private func isUnknown(_ blocker: CefBrowser.DiscardBlocker) -> Bool {
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

/// Reading an Alloy-style page's audio and form state from Chromium's
/// performance-manager graph (`CefPageGraph`).
@Suite struct DiscardPageGraphTests {
    private func reply(_ page: [String: CefJSON]) -> CefJSON {
        ["found": true, "page": ["PageNodeImpl": .object(page)]]
    }

    private let quiet: [String: CefJSON] = ["is_audible": false, "had_form_interaction": false, "had_user_edits": false]

    @MainActor @Test func frameTokensComeFromCEFFrameIdentifiers() {
        #expect(CefPageGraph.frameToken(fromFrameIdentifier: "6-7BDA0EC034A043A7C2AEFDA5571BB1B6") == "7BDA0EC034A043A7C2AEFDA5571BB1B6")
        #expect(CefPageGraph.frameToken(fromFrameIdentifier: "12-7bda0ec034a043a7c2aefda5571bb1b6") == "7BDA0EC034A043A7C2AEFDA5571BB1B6")
        // The process id is hexadecimal.
        #expect(CefPageGraph.frameToken(fromFrameIdentifier: "1A-7BDA0EC034A043A7C2AEFDA5571BB1B6") == "7BDA0EC034A043A7C2AEFDA5571BB1B6")
        for identifier in [nil, "", "7BDA0EC034A043A7C2AEFDA5571BB1B6", "x-7BDA0EC034A043A7C2AEFDA5571BB1B6", "-7BDA0EC034A043A7C2AEFDA5571BB1B6", "6-7BDA",
                           "6-7BDA0EC034A043A7C2AEFDA5571BB1BZ", "6-1-2"] {
            #expect(CefPageGraph.frameToken(fromFrameIdentifier: identifier) == nil)
        }
    }

    @MainActor @Test func aQuietPageHasNoBlockers() {
        #expect(CefPageGraph.blockers(fromDescription: reply(quiet)).isEmpty)
    }

    @MainActor @Test func audioAndFormStateBlock() {
        var audible = quiet
        audible["is_audible"] = true
        audible["audible_change_time"] = "0 hr, 0 min, 4 sec"
        #expect(CefPageGraph.blockers(fromDescription: reply(audible)) == [.playingAudio])
        var edited = quiet
        edited["had_user_edits"] = true
        #expect(CefPageGraph.blockers(fromDescription: reply(edited)) == [.formInteraction])
        var interacted = quiet
        interacted["had_form_interaction"] = true
        #expect(CefPageGraph.blockers(fromDescription: reply(interacted)) == [.formInteraction])
    }

    /// Chromium protects a page for a minute after it falls silent.
    @MainActor @Test func recentAudioBlocks() {
        var recent = quiet
        recent["audible_change_time"] = "0 hr, 0 min, 59 sec"
        #expect(CefPageGraph.blockers(fromDescription: reply(recent)) == [.playingAudio])
        var old = quiet
        old["audible_change_time"] = "0 hr, 1 min, 0 sec"
        #expect(CefPageGraph.blockers(fromDescription: reply(old)).isEmpty)
        old["audible_change_time"] = "2 hr, 0 min, 0 sec"
        #expect(CefPageGraph.blockers(fromDescription: reply(old)).isEmpty)
    }

    /// Anything CefKit cannot read keeps the page: no node, missing
    /// fields, a time in another format.
    @MainActor @Test func unreadableDescriptionsBlock() {
        var oddTime = quiet
        oddTime["audible_change_time"] = "4 seconds ago"
        let unreadable: [CefJSON] = [
            .null, ["found": false], ["found": true, "page": .null],
            reply(["is_audible": false, "had_form_interaction": false]),
            reply(["is_audible": "no", "had_form_interaction": false, "had_user_edits": false]),
            reply(oddTime),
        ]
        for description in unreadable {
            let blockers = CefPageGraph.blockers(fromDescription: description)
            #expect(blockers.count == 1 && blockers.allSatisfy(isUnknown), "\(description)")
        }
    }

    @MainActor @Test func describerTimes() {
        #expect(CefPageGraph.elapsed(fromDescriberTime: "0 hr, 0 min, 3 sec") == .seconds(3))
        #expect(CefPageGraph.elapsed(fromDescriberTime: "1 hr, 2 min, 3 sec") == .seconds(3723))
        #expect(CefPageGraph.elapsed(fromDescriberTime: "3 sec") == nil)
        #expect(CefPageGraph.elapsed(fromDescriberTime: "0 h, 0 m, 3 s") == nil)
    }

    /// The store the service host keeps of the graph's frames, run in
    /// JavaScriptCore on events shaped like `GraphChangeStream`'s.
    @MainActor @Test func theFrameStoreFollowsTheGraph() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var frames = new Map(), apply = \(CefPageGraph.frameStore);")
        func frame(_ id: Int, page: Int, token: String?) -> String {
            let description = token.map { #"{\"FrameNodeImpl\":{\"frame_token\":\"\#($0)\"}}"# } ?? "not json"
            return #"{ id: \#(id), pageId: \#(page), descriptionJson: "\#(description)" }"#
        }
        context.evaluateScript("apply(frames, 'created', \(frame(1, page: 3, token: "AA")))")
        context.evaluateScript("apply(frames, 'created', \(frame(2, page: 4, token: "BB")))")
        // A change whose description has no token keeps the one it had.
        context.evaluateScript("apply(frames, 'changed', \(frame(1, page: 3, token: nil)))")
        #expect(context.evaluateScript("JSON.stringify([...frames])")?.toString()
            == #"[[1,{"page":3,"token":"AA"}],[2,{"page":4,"token":"BB"}]]"#)
        context.evaluateScript("apply(frames, 'deleted', 2)")
        #expect(context.evaluateScript("JSON.stringify([...frames.keys()])")?.toString() == "[1]")
    }

    private func isUnknown(_ blocker: CefBrowser.DiscardBlocker) -> Bool {
        if case .unknown = blocker { return true }
        return false
    }
}

/// The DevTools Protocol replies the `beforeunload` check reads, as
/// CEF 156.0.28 sends them.
@Suite struct BeforeUnloadListenerTests {
    @MainActor @Test func onlyBeforeUnloadListenersCount() throws {
        let some: CefJSON = ["listeners": [
            ["type": "click", "useCapture": false], ["type": "beforeunload", "useCapture": false, "scriptId": "3"],
        ]]
        #expect(try CefBeforeUnloadListeners.hasBeforeUnload(listeners: some))
        #expect(try !CefBeforeUnloadListeners.hasBeforeUnload(listeners: ["listeners": [["type": "unload"]]]))
        #expect(try !CefBeforeUnloadListeners.hasBeforeUnload(listeners: ["listeners": []]))
        #expect(throws: (any Error).self) { try CefBeforeUnloadListeners.hasBeforeUnload(listeners: [:]) }
    }

    @MainActor @Test func subframesAreEveryFrameBelowTheMainOne() throws {
        let tree: CefJSON = ["frameTree": [
            "frame": ["id": "MAIN"],
            "childFrames": [
                ["frame": ["id": "A", "parentId": "MAIN"], "childFrames": [["frame": ["id": "A1", "parentId": "A"]]]],
                ["frame": ["id": "B", "parentId": "MAIN"]],
            ],
        ]]
        #expect(try CefBeforeUnloadListeners.subframes(inFrameTree: tree) == ["A", "A1", "B"])
        #expect(try CefBeforeUnloadListeners.subframes(inFrameTree: ["frameTree": ["frame": ["id": "MAIN"]]]).isEmpty)
        #expect(throws: (any Error).self) { try CefBeforeUnloadListeners.subframes(inFrameTree: [:]) }
        #expect(throws: (any Error).self) {
            try CefBeforeUnloadListeners.subframes(inFrameTree: ["frameTree": [
                "frame": ["id": "MAIN"], "childFrames": [["frame": ["url": "about:blank"]]],
            ]])
        }
    }

    /// `Target.getTargets` lists the page and its out-of-process frames,
    /// and may list other targets; only frames whose parents lead to the
    /// page are its own.
    @MainActor @Test func outOfProcessFramesAreThePagesOwn() throws {
        let targets: CefJSON = ["targetInfos": [
            ["targetId": "PAGE", "type": "page", "attached": true],
            ["targetId": "X", "type": "iframe", "parentId": "PAGE", "parentFrameId": "PAGE", "attached": false],
            ["targetId": "X1", "type": "iframe", "parentId": "X", "parentFrameId": "LOCAL-IN-X"],
            ["targetId": "OTHER", "type": "page"],
            ["targetId": "Y", "type": "iframe", "parentId": "OTHER"],
            ["targetId": "W", "type": "worker", "parentId": "PAGE"],
            ["targetId": "LOOP", "type": "iframe", "parentId": "LOOP"],
        ]]
        #expect(try CefBeforeUnloadListeners.outOfProcessFrames(of: "PAGE", in: targets) == ["X", "X1"])
        #expect(try CefBeforeUnloadListeners.outOfProcessFrames(of: "OTHER", in: targets) == ["Y"])
        #expect(throws: (any Error).self) { try CefBeforeUnloadListeners.outOfProcessFrames(of: "PAGE", in: [:]) }
    }

    /// Messages of an attached frame's session carry a top-level
    /// `sessionId`, which CEF's typed callbacks do not know: they are
    /// taken before them, and their events never reach this session's
    /// listeners.
    @MainActor @Test func childSessionMessagesAreTakenApart() {
        let browser = CefBrowser()
        var heard = 0
        _ = browser.devTools.addListener(for: "Runtime.consoleAPICalled") { _ in heard += 1 }
        let childEvent = Data(#"{"method":"Runtime.consoleAPICalled","params":{},"sessionId":"S"}"#.utf8)
        let childReply = Data(#"{"id":7,"result":{},"sessionId":"S"}"#.utf8)
        // This session's messages, one mentioning a session in its parameters.
        let attached = Data(#"{"method":"Target.attachedToTarget","params":{"sessionId":"S"}}"#.utf8)
        let reply = Data(#"{"id":8,"result":{"sessionId":"S"}}"#.utf8)
        #expect(browser.devTools.receivedChildSessionMessage(childEvent))
        #expect(browser.devTools.receivedChildSessionMessage(childReply))
        #expect(!browser.devTools.receivedChildSessionMessage(attached))
        #expect(!browser.devTools.receivedChildSessionMessage(reply))
        #expect(!browser.devTools.receivedChildSessionMessage(Data(#"{"id":9,"result":{}}"#.utf8)))
        #expect(heard == 0)
    }
}
