import CCef
import Foundation
import Testing

@testable import CefKit
import CefBase

/// The declarative part of a request filter, tested in C on CEF's UTF-16
/// addresses, and what a filter reads about a request.
@Suite struct RequestFilterTests {
    private func wants(_ filter: CefRequestFilter, _ url: String, _ type: cef_resource_type_t = RT_SUB_RESOURCE) -> Bool {
        let compiled = CefCompiledRequestFilter(filter)
        var string = cef_string_utf16_t()
        CefStringUtil.set(url, into: &string)
        defer { ccef_string_clear(&string) }
        return withUnsafePointer(to: &string) { compiled.wants($0, type: type) }
    }

    private func filter(
        hosts: Set<String> = [], urlPatterns: [String] = [], types: Set<CefResourceRequest.ResourceType> = []
    ) -> CefRequestFilter {
        CefRequestFilter(hosts: hosts, urlPatterns: urlPatterns, resourceTypes: types) { _ in .allow }
    }

    @Test func aFilterWithoutMatchingWantsEverything() {
        #expect(wants(filter(), "https://example.com/"))
        #expect(wants(filter(), ""))
    }

    @Test func hostsMatchThemselvesAndTheirSubdomains() {
        let ads = filter(hosts: ["Ads.Example", ".tracker.example."])
        #expect(wants(ads, "https://ads.example/x"))
        #expect(wants(ads, "https://cdn.ADS.example:8443/x?y#z"))
        #expect(wants(ads, "https://user:pass@ads.example/"))
        #expect(wants(ads, "wss://tracker.example"))
        #expect(!wants(ads, "https://badads.example/"))
        #expect(!wants(ads, "https://ads.example.com/"))
        #expect(!wants(ads, "https://example.com/?u=https://ads.example/"))
        #expect(!wants(ads, "data:text/plain,ads.example"))
    }

    @Test func patternsMatchWholeAddresses() {
        let scripts = filter(urlPatterns: ["https://*.example.com/ads/*", "*/pixel.gif"])
        #expect(wants(scripts, "https://cdn.example.com/ads/banner.js"))
        #expect(wants(scripts, "http://any.where/pixel.gif"))
        #expect(!wants(scripts, "https://cdn.example.com/content/ads.js"))
        #expect(!wants(scripts, "http://any.where/pixel.gif?x"))
        // Patterns compare exactly, case included; non-ASCII survives.
        #expect(!wants(filter(urlPatterns: ["HTTPS://*"]), "https://a/"))
        #expect(wants(filter(urlPatterns: ["https://a/é*"]), "https://a/éclair"))
        #expect(wants(filter(urlPatterns: ["*😀"]), "https://a/😀"))
    }

    @Test func resourceTypesComeFirst() {
        let images = filter(hosts: ["ads.example"], types: [.image, .mainFrame])
        #expect(wants(images, "https://ads.example/a.png", RT_IMAGE))
        #expect(wants(images, "https://ads.example/", RT_NAVIGATION_PRELOAD_MAIN_FRAME))
        #expect(!wants(images, "https://ads.example/a.js", RT_SCRIPT))
        let compiled = CefCompiledRequestFilter(images)
        #expect(compiled.excludes(RT_SCRIPT))
        #expect(!compiled.excludes(RT_IMAGE))
        // Only types: every address of those types.
        #expect(wants(filter(types: [.script]), "https://anything/", RT_SCRIPT))
        #expect(!wants(filter(types: [.script]), "https://anything/", RT_IMAGE))
    }

    @Test func hostRangesFollowTheAuthority() {
        func host(_ url: String) -> String? {
            let units = Array(url.utf16)
            var start = 0, end = 0
            guard ccef_request_match_host_range(units, units.count, &start, &end) != 0 else { return nil }
            return String(decoding: units[start..<end], as: UTF16.self)
        }
        #expect(host("https://a.example:443/p") == "a.example")
        #expect(host("http://u@b.example?x") == "b.example")
        #expect(host("http://[::1]:8080/") == "[::1]")
        #expect(host("file:///tmp/x") == "")
        #expect(host("about:blank") == nil)
        #expect(host("/relative://x") == nil)
    }

    @Test func resourceTypesMapFromChromium() {
        #expect(CefResourceRequest.ResourceType(RT_XHR) == .fetch)
        #expect(CefResourceRequest.ResourceType(RT_SUB_FRAME) == .subframe)
        #expect(CefResourceRequest.ResourceType(RT_PLUGIN_RESOURCE) == .object)
        #expect(CefResourceRequest.ResourceType(RT_SUB_RESOURCE) == .other)
        for type in CefResourceRequest.ResourceType.allCases {
            #expect(type.cefMask != 0)
        }
    }

    @Test func thirdPartyComparesSites() {
        func request(_ url: String, firstParty: String?) -> CefResourceRequest {
            CefResourceRequest(url: URL(string: url), firstPartyURL: firstParty.flatMap(URL.init(string:)))
        }
        #expect(!request("https://cdn.example.com/a.js", firstParty: "https://www.example.com/").isThirdParty)
        #expect(request("https://tracker.example/a.js", firstParty: "https://www.example.com/").isThirdParty)
        #expect(!request("https://a.example.co.uk/", firstParty: "https://b.example.co.uk/").isThirdParty)
        #expect(request("https://other.co.uk/", firstParty: "https://b.example.co.uk/").isThirdParty)
        #expect(request("http://10.0.0.2/", firstParty: "http://10.0.0.1/").isThirdParty)
        #expect(!request("https://a.example/", firstParty: nil).isThirdParty)
    }
}
