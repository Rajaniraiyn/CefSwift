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
        let services = CefServiceHosts(profile: CefProfile.incognito())
        let module = CefServiceHost.Module(name: "test", hosts: [], setup: "")
        let changed = services.events(module, "changed", bufferingPolicy: .bufferingNewest(1))
        for index in 0..<10 { services.deliver(module: "test", name: "changed", payload: .number(Double(index))) }
        var iterator = changed.makeAsyncIterator()
        #expect(await iterator.next() == .number(9))
    }
}
