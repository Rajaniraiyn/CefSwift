import CefChromium
import Foundation
import Testing

/// An app's tests and previews can make CefChromium's plain values
/// without `@testable`.
struct PublicChromiumValueTests {
    @Test func historyValues() {
        let url = URL(string: "https://example.com/")!
        let visit = Date(timeIntervalSince1970: 1_000)
        let entry = CefHistory.Entry(url: url, title: "Example", lastVisitDate: visit, visitDates: [visit])
        #expect(entry.id == CefHistory.Entry.ID(url: url, lastVisitDate: visit))
        #expect(!entry.isBookmarked)
        let site = CefHistory.TopSite(url: url, title: "Example")
        #expect(site.id == url)
    }

    @Test func suggestion() {
        let suggestion = CefAutocomplete.Suggestion(
            kind: .history, text: "example.com", url: URL(string: "https://example.com/"),
            replacementText: "example.com", relevance: 1_200, canBeDefault: true)
        #expect(suggestion.detail.isEmpty && suggestion.inlineCompletion.isEmpty)
        #expect(!suggestion.isSearch && !suggestion.isBookmarked)
    }
}
