import Testing

@testable import CefKit

@Suite struct ProcessPolicyTests {
    @Test func presetsChooseTheirPolicy() {
        #expect(CefRuntime.Configuration().processPolicy == .automatic)
        #expect(CefRuntime.Configuration.chrome.processPolicy == .automatic)
        #expect(CefRuntime.Configuration.embedded.processPolicy == .onDemand)
    }

    @Test func standardAddsNothing() {
        var configuration = CefRuntime.Configuration()
        configuration.services.systemNotifications = .automatic
        configuration.enabledFeatures = ["A"]
        configuration.disabledFeatures = ["B"]
        #expect(configuration.chromiumFeatures.enabled == ["A"])
        #expect(configuration.chromiumFeatures.disabled == ["B"])
    }

    @Test func policiesAddTheirFeatures() {
        var configuration = CefRuntime.Configuration()
        configuration.services.systemNotifications = .automatic
        configuration.processPolicy = .onDemand
        #expect(configuration.chromiumFeatures.enabled.isEmpty)
        #expect(configuration.chromiumFeatures.disabled == ["SpareRendererForSitePerProcess"])
        configuration.processPolicy = .minimal
        #expect(configuration.chromiumFeatures.enabled == ["NetworkServiceInProcess2"])
        #expect(configuration.chromiumFeatures.disabled == ["SpareRendererForSitePerProcess"])
    }

    /// Chromium asks macOS for notification authorization at launch when
    /// it uses system notifications, so no preset does.
    @Test func systemNotificationsAreOffInEveryPreset() {
        for configuration in [CefRuntime.Configuration(), .embedded, .chrome] {
            #expect(configuration.services.systemNotifications == .disabled)
            #expect(configuration.chromiumFeatures.disabled.contains("SystemNotifications"))
            #expect(!configuration.chromiumFeatures.enabled.contains("SystemNotifications"))
        }
        var optedIn = CefRuntime.Configuration.chrome
        optedIn.services.systemNotifications = .automatic
        #expect(!optedIn.chromiumFeatures.disabled.contains("SystemNotifications"))
        // An app that enables the feature itself wins, as with any feature.
        var enabled = CefRuntime.Configuration()
        enabled.enabledFeatures = ["SystemNotifications"]
        #expect(!enabled.chromiumFeatures.disabled.contains("SystemNotifications"))
        #expect(enabled.chromiumFeatures.enabled.contains("SystemNotifications"))
    }

    @Test func appFeaturesWinOverThePolicy() {
        var configuration = CefRuntime.Configuration()
        configuration.processPolicy = .minimal
        configuration.enabledFeatures = ["SpareRendererForSitePerProcess"]
        configuration.disabledFeatures = ["NetworkServiceInProcess2"]
        #expect(configuration.chromiumFeatures.enabled == ["SpareRendererForSitePerProcess"])
        #expect(configuration.chromiumFeatures.disabled == ["NetworkServiceInProcess2", "SystemNotifications"])
    }
}
