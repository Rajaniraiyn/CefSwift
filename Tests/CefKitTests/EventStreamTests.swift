import Foundation
import Testing

@testable import CefKit

/// Event streams buffer according to what their events mean.
@MainActor
struct EventStreamTests {
    @Test func devToolsEventsKeepABoundedNumberByDefault() async {
        let browser = CefBrowser()
        let bounded = browser.devTools.events("Network.dataReceived")
        let everything = browser.devTools.events("Network.dataReceived", bufferingPolicy: .unbounded)
        for index in 0..<1_500 {
            browser.devTools.received(event: "Network.dataReceived", params: Data(#"{"index":\#(index)}"#.utf8))
        }
        browser.devTools.invalidate()
        var kept: [Int] = []
        for await event in bounded { kept.append(event["index"].intValue ?? -1) }
        var all = 0
        for await _ in everything { all += 1 }
        #expect(kept.count == 1_000)
        #expect(kept.first == 500 && kept.last == 1_499)
        #expect(all == 1_500)
    }

    @Test func serviceInvalidationsCoalesce() async {
        let services = CefInternalServices(profile: CefProfile.incognito())
        let module = CefServiceModule(name: "test", hosts: [], setup: "")
        let changed = services.events(module, "changed", bufferingPolicy: .bufferingNewest(1))
        for index in 0..<10 { services.deliver(module: "test", name: "changed", payload: .number(Double(index))) }
        var iterator = changed.makeAsyncIterator()
        #expect(await iterator.next() == .number(9))
    }

    @Test func bookmarkChangesCoalesce() async throws {
        let profile = CefProfile.persistent(id: "event-stream-tests")
        let changes = profile.bookmarks.changes
        // Subscribing hands the live events to a task; let it start.
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<10 { profile.services.deliver(module: CefBookmarks.module.name, name: "changed", payload: .null) }
        try await Task.sleep(for: .milliseconds(100))
        var count = 0
        let reader = Task { @MainActor in
            for await _ in changes { count += 1 }
        }
        try await Task.sleep(for: .milliseconds(100))
        reader.cancel()
        #expect(count == 1)
    }
}
