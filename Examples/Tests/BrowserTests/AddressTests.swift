import Foundation
import Testing

@testable import Browser

@Suite struct TypedAddressTests {
    @Test func addressesWithASchemeAreTakenAsTheyAre() {
        #expect(TypedAddress.destination(for: "https://swift.org/blog") == URL(string: "https://swift.org/blog"))
        #expect(TypedAddress.destination(for: "browser://playground/") == URL(string: "browser://playground/"))
        #expect(TypedAddress.destination(for: "about:blank") == URL(string: "about:blank"))
    }

    @Test func hostsGetHTTPS() {
        #expect(TypedAddress.destination(for: "swift.org") == URL(string: "https://swift.org"))
        #expect(TypedAddress.destination(for: "  swift.org/blog \n") == URL(string: "https://swift.org/blog"))
        #expect(TypedAddress.destination(for: "localhost:8080") == URL(string: "https://localhost:8080"))
    }

    @Test func everythingElseIsASearch() throws {
        let search = try #require(TypedAddress.destination(for: "swift concurrency"))
        #expect(search.host() == "duckduckgo.com")
        #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "swift concurrency")
        // A dot does not make an address when there are spaces.
        #expect(TypedAddress.destination(for: "what is swift.org")?.host() == "duckduckgo.com")
        #expect(TypedAddress.destination(for: "swift")?.host() == "duckduckgo.com")
    }

    @Test func blankTextGoesNowhere() {
        #expect(TypedAddress.destination(for: "") == nil)
        #expect(TypedAddress.destination(for: "   ") == nil)
    }

    @Test func searchesEscapeTheQuery() throws {
        let url = try #require(TypedAddress.searchURL(for: "a&b=c d"))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "q", value: "a&b=c d")])
    }

    @Test func commandLineArgumentsAreAddressesOrExistingFiles() throws {
        #expect(TypedAddress.url(fromArgument: "https://swift.org", relativeTo: nil) == URL(string: "https://swift.org"))
        #expect(TypedAddress.url(fromArgument: "-urls", relativeTo: nil) == nil)
        #expect(TypedAddress.url(fromArgument: "YES", relativeTo: nil) == nil)
        let directory = FileManager.default.temporaryDirectory
        let file = directory.appendingPathComponent("browser-tests-\(UUID().uuidString).html")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(TypedAddress.url(fromArgument: file.lastPathComponent, relativeTo: directory)?.standardizedFileURL == file.standardizedFileURL)
        #expect(TypedAddress.url(fromArgument: "missing-\(UUID().uuidString).html", relativeTo: directory) == nil)
    }
}

@Suite struct AddressFieldTextTests {
    @Test func theSummaryIsTheSite() {
        #expect(AddressBar.summary(of: URL(string: "https://www.swift.org/blog/"), title: "Blog") == "swift.org")
        #expect(AddressBar.summary(of: URL(string: "http://example.com/a"), title: "") == "example.com")
        #expect(AddressBar.summary(of: URL(string: "file:///tmp/page.html"), title: "Page") == "file:///tmp/page.html")
    }

    @Test func internalPagesShowTheirTitle() {
        #expect(AddressBar.summary(of: URL(string: "chrome://settings/"), title: "Settings") == "Settings")
        #expect(AddressBar.summary(of: URL(string: "browser://playground/"), title: "") == "browser://playground/")
    }

    @Test func blankTabsShowNothing() {
        // A data: page never shows its content: Chromium's security display, or the scheme.
        #expect(AddressBar.summary(of: URL(string: "data:text/html,<title>x</title>secret"), title: "x") == "data:")
        #expect(AddressBar.summary(of: URL(string: "data:text/html,x"), title: "", securityDisplay: "data:") == "data:")
        #expect(AddressBar.summary(of: nil, title: "") == "")
        #expect(AddressBar.summary(of: URL(string: "about:blank"), title: "") == "")
        #expect(AddressBar.editableText(for: URL(string: "about:blank")) == "")
        #expect(AddressBar.editableText(for: URL(string: "https://swift.org/")) == "https://swift.org/")
    }
}

@Suite struct LaunchOptionsTests {
    @MainActor @Test func optionsAreReadFromTheArgumentDomain() throws {
        let name = "browser-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("https://swift.org swift.org browser://playground/", forKey: "urls")
        defaults.set("swi", forKey: "addressBarText")
        defaults.set(true, forKey: "private")
        let options = LaunchOptions(defaults: defaults)
        #expect(options.urls.map(\.absoluteString) == ["https://swift.org", "https://swift.org", "browser://playground/"])
        #expect(options.addressBarText == "swi")
        // Typed text implies editing.
        #expect(options.focusesAddressBar)
        #expect(options.opensPrivateTabs)
        #expect(!options.benchmarks)
        #expect(options.script == nil)
    }
}
