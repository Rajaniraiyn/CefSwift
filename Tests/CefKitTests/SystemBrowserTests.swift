import Foundation
import Observation
import os
import Testing

@testable import CefKit
@testable import CefSystemEngine

@MainActor
@Suite struct SystemBrowserTests {
    @Test func streamingHostsAndTheirSubdomainsPreferTheSystemEngine() {
        #expect(CefSystemBrowser.prefersSystemEngine(for: URL(string: "https://www.netflix.com/watch/1")!))
        #expect(CefSystemBrowser.prefersSystemEngine(for: URL(string: "https://disneyplus.com/")!))
        #expect(!CefSystemBrowser.prefersSystemEngine(for: URL(string: "https://netflix.com.example.org/")!))
        #expect(!CefSystemBrowser.prefersSystemEngine(for: URL(string: "https://mynetflix.com/")!))
        #expect(!CefSystemBrowser.prefersSystemEngine(for: URL(string: "file:///netflix.com")!))
    }

    @Test func hostOnlyCookiesStayHostOnly() throws {
        let hostOnly = try #require(HTTPCookie(properties: [
            .name: "a", .value: "1", .domain: "www.example.com", .path: "/", .secure: "TRUE",
        ]))
        let converted = CefSystemBrowser.webKitCookie(hostOnly)
        #expect(converted.domain == "www.example.com")
        #expect(converted.isSecure)
        let domain = try #require(HTTPCookie(properties: [
            .name: "b", .value: "2", .domain: ".example.com", .path: "/",
        ]))
        #expect(CefSystemBrowser.webKitCookie(domain).domain == ".example.com")
    }

    @Test func profileDataStoreIdentifiersAreStable() {
        #expect(CefProfile.dataStoreIdentifier("Work") == CefProfile.dataStoreIdentifier("Work"))
        #expect(CefProfile.dataStoreIdentifier("Work") != CefProfile.dataStoreIdentifier("Home"))
    }

    @Test func scopedUserScriptsCheckTheURL() {
        let script = CefSystemBrowser.webKitScript(for: CefUserScript(source: "x()", matching: "https://*.example.com/*"))
        #expect(script.source.hasPrefix("if (new RegExp("))
        #expect(script.source.contains(".*") && script.source.contains("x()"))
    }

    @Test func pageZoomIsObservable() {
        let browser = CefSystemBrowser()
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = browser.pageZoom } onChange: { changed.withLock { $0 = true } }
        browser.pageZoom = 1.5
        #expect(changed.withLock { $0 })
        #expect(browser.pageZoom == 1.5 && browser.nativeView.pageZoom == 1.5)
    }

    @Test func safariApplicationNameNamesSafari() {
        #expect(CefSystemBrowser.safariApplicationName.hasPrefix("Version/"))
        #expect(CefSystemBrowser.safariApplicationName.hasSuffix(" Safari/605.1.15"))
    }
}
