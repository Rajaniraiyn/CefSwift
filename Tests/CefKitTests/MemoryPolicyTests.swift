import Testing

@testable import CefKit

@Suite struct MemoryPolicyTests {
    @Test func presetsChooseTheirPolicy() {
        #expect(CefConfiguration.default.memoryPolicy == .standard)
        #expect(CefConfiguration.browser.memoryPolicy == .standard)
        #expect(CefConfiguration.embedded.memoryPolicy == .reduced)
    }

    @Test func standardAddsNothing() {
        var configuration = CefConfiguration()
        configuration.enabledFeatures = ["A"]
        configuration.disabledFeatures = ["B"]
        #expect(configuration.chromiumFeatures.enabled == ["A"])
        #expect(configuration.chromiumFeatures.disabled == ["B"])
    }

    @Test func policiesAddTheirFeatures() {
        var configuration = CefConfiguration()
        configuration.memoryPolicy = .reduced
        #expect(configuration.chromiumFeatures.enabled.isEmpty)
        #expect(configuration.chromiumFeatures.disabled == ["SpareRendererForSitePerProcess"])
        configuration.memoryPolicy = .minimal
        #expect(configuration.chromiumFeatures.enabled == ["NetworkServiceInProcess2"])
        #expect(configuration.chromiumFeatures.disabled == ["SpareRendererForSitePerProcess"])
    }

    @Test func appFeaturesWinOverThePolicy() {
        var configuration = CefConfiguration()
        configuration.memoryPolicy = .minimal
        configuration.enabledFeatures = ["SpareRendererForSitePerProcess"]
        configuration.disabledFeatures = ["NetworkServiceInProcess2"]
        #expect(configuration.chromiumFeatures.enabled == ["SpareRendererForSitePerProcess"])
        #expect(configuration.chromiumFeatures.disabled == ["NetworkServiceInProcess2"])
    }
}
