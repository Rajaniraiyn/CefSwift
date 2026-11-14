import Foundation
import Testing

@testable import CefChromium
@testable import CefKit

@MainActor
struct StoreTests {
    @Test func aServiceKeepsItsProfileAliveWithoutACycle() {
        weak var weakProfile: CefProfile?
        var autocomplete: CefAutocomplete?
        var history: CefHistory?
        do {
            let profile = CefProfile.incognito()
            weakProfile = profile
            autocomplete = profile.autocomplete
            history = profile.history
            #expect(profile.autocomplete === autocomplete)
        }
        #expect(weakProfile != nil)
        autocomplete = nil
        #expect(weakProfile != nil)
        history = nil
        #expect(weakProfile == nil)
        _ = (autocomplete, history)
    }

    @Test func bookmarkChangesCoalesce() async throws {
        let profile = CefProfile.persistent(id: "event-stream-tests")
        let changes = profile.bookmarks.changes
        // Subscribing hands the live events to a task; let it start.
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<10 { profile.serviceHosts.deliver(module: CefBookmarks.module.name, name: "changed", payload: .null) }
        try await Task.sleep(for: .milliseconds(100))
        var count = 0
        let reader = Task { @MainActor in
            for await _ in changes { count += 1 }
        }
        try await Task.sleep(for: .milliseconds(100))
        reader.cancel()
        // One when nothing is read between deliveries; a loaded machine can let
        // the forwarding task run mid-burst, which splits it into a few.
        #expect((1...3).contains(count))
    }

    /// An entry an app makes removes the visits it lists: Chromium's visit
    /// times are milliseconds since 1970.
    @Test func anAppMadeHistoryEntryCarriesItsVisitTimes() {
        let visits = [Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 1.5)]
        let entry = CefHistory.Entry(
            url: URL(string: "https://example.com/")!, title: "", lastVisitDate: visits[0], visitDates: visits)
        #expect(entry.visitTimes == [2_000, 1_500])
    }
}
