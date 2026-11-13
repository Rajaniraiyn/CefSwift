import CefSwiftUI
import Foundation
import Testing

@testable import Browser

/// The feature list passes each point to every feature, in order.
@MainActor @Suite struct FeatureCompositionTests {
    struct AddsScript: BrowserFeature {
        let name: String
        func configure(_ configuration: inout CefBrowser.Configuration) {
            configuration.userScripts.append(CefUserScript(source: name))
        }
    }

    struct Silent: BrowserFeature {}

    @Test func everyFeatureConfiguresTabsInOrder() {
        let features = BrowserFeatures {
            AddsScript(name: "first")
            Silent()
            AddsScript(name: "second")
            AddsScript(name: "third")
        }
        var configuration = CefBrowser.Configuration()
        features.configure(&configuration)
        #expect(configuration.userScripts.map(\.source) == ["first", "second", "third"])
    }

    @Test func oneFeatureIsAList() {
        let features = BrowserFeatures { AddsScript(name: "only") }
        var configuration = CefBrowser.Configuration()
        features.configure(&configuration)
        #expect(configuration.userScripts.map(\.source) == ["only"])
    }
}

@MainActor @Suite struct ChromiumPagesTests {
    @Test func chromiumsAboutPageIsReplaced() {
        #expect(ChromiumPages.replacement(for: URL(string: "chrome://help/")) == ChromiumPages.about)
        #expect(ChromiumPages.replacement(for: URL(string: "chrome://settings/help")) == ChromiumPages.about)
    }

    @Test func hiddenSettingsPagesOpenAppearance() {
        let appearance = URL(string: "chrome://settings/appearance")
        for page in ["chrome://settings", "chrome://settings/", "chrome://settings/people", "chrome://settings/syncSetup",
                     "chrome://settings/defaultBrowser"] {
            #expect(ChromiumPages.replacement(for: URL(string: page)) == appearance, "\(page)")
        }
    }

    @Test func otherPagesAreLeftAlone() {
        #expect(ChromiumPages.replacement(for: URL(string: "chrome://settings/appearance")) == nil)
        #expect(ChromiumPages.replacement(for: URL(string: "chrome://history/")) == nil)
        #expect(ChromiumPages.replacement(for: URL(string: "https://help.example/")) == nil)
        #expect(ChromiumPages.replacement(for: nil) == nil)
    }
}

@Suite struct LibraryTests {
    @Test func webPagesFilesAndInternalPagesCanBeBookmarked() {
        for page in ["https://swift.org", "http://example.com", "file:///tmp/a.html", "chrome://settings/", "browser://playground/"] {
            #expect(Bookmarks.canBookmark(URL(string: page)), "\(page)")
        }
        #expect(!Bookmarks.canBookmark(URL(string: "about:blank")))
        #expect(!Bookmarks.canBookmark(URL(string: "data:text/html,hi")))
        #expect(!Bookmarks.canBookmark(nil))
    }

    @Test func historyMenuListsEachPageOnceAndNoInternalPages() {
        let visits = ["https://a.example/", "chrome://settings/", "https://b.example/", "https://a.example/", "browser://start/"]
            .map { URL(string: $0)! }
        #expect(History.menuEntries(visits, url: { $0 }).map(\.absoluteString) == ["https://a.example/", "https://b.example/"])
        let many = (0..<40).map { URL(string: "https://\($0).example/")! }
        #expect(History.menuEntries(many, url: { $0 }) == Array(many.prefix(15)))
    }

    @Test func menuTitlesFallBackToTheAddressAndAreShortened() {
        #expect(String(menuTitle: "Swift", url: URL(string: "https://swift.org")) == "Swift")
        #expect(String(menuTitle: "", url: URL(string: "https://swift.org")) == "https://swift.org")
        #expect(String(menuTitle: "", url: nil) == "Untitled")
        let long = String(repeating: "a", count: 80)
        #expect(String(menuTitle: long, url: nil) == String(repeating: "a", count: 59) + "…")
    }
}

@MainActor @Suite struct PopupTests {
    @Test func popupsGetTheSizeTheyAskForWithinTheOpener() {
        let available = CGSize(width: 1000, height: 800)
        #expect(PopupPresenter.pageSize(requested: CGSize(width: 420, height: 360), available: available) == CGSize(width: 420, height: 360))
        #expect(PopupPresenter.pageSize(requested: .zero, available: available) == CGSize(width: 520, height: 640))
        #expect(PopupPresenter.pageSize(requested: CGSize(width: 2000, height: 2000), available: available) == CGSize(width: 952, height: 752))
    }
}
