import Testing

@testable import CefKit

@Suite struct ProcessPolicyTests {
    @Test func presetsChooseTheirPolicy() {
        #expect(CefRuntime.Configuration().processPolicy == .automatic)
        #expect(CefRuntime.Configuration.browser.processPolicy == .automatic)
        #expect(CefRuntime.Configuration.embedded.processPolicy == .onDemand)
    }

    @Test func standardAddsNothing() {
        var configuration = CefRuntime.Configuration()
        configuration.enabledFeatures = ["A"]
        configuration.disabledFeatures = ["B"]
        #expect(configuration.chromiumFeatures.enabled == ["A"])
        #expect(configuration.chromiumFeatures.disabled == ["B"])
    }

    @Test func policiesAddTheirFeatures() {
        var configuration = CefRuntime.Configuration()
        configuration.processPolicy = .onDemand
        #expect(configuration.chromiumFeatures.enabled.isEmpty)
        #expect(configuration.chromiumFeatures.disabled == ["SpareRendererForSitePerProcess"])
        configuration.processPolicy = .minimal
        #expect(configuration.chromiumFeatures.enabled == ["NetworkServiceInProcess2"])
        #expect(configuration.chromiumFeatures.disabled == ["SpareRendererForSitePerProcess"])
    }

    @Test func appFeaturesWinOverThePolicy() {
        var configuration = CefRuntime.Configuration()
        configuration.processPolicy = .minimal
        configuration.enabledFeatures = ["SpareRendererForSitePerProcess"]
        configuration.disabledFeatures = ["NetworkServiceInProcess2"]
        #expect(configuration.chromiumFeatures.enabled == ["SpareRendererForSitePerProcess"])
        #expect(configuration.chromiumFeatures.disabled == ["NetworkServiceInProcess2"])
    }
}
