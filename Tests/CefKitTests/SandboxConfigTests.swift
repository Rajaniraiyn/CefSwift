import Foundation
import Testing

@testable import CCef
@testable import CefKit

/// Pure-logic tests for the macOS sandbox seam: defaults and the bit that
/// crosses into `cef_settings_t.no_sandbox`, the inverse of
/// `isSandboxEnabled`. The helper's side (Sources/CefHelper) needs a
/// real bundle, but the settings mapping is where the toggle is easy to
/// break.
@Suite struct SandboxConfigTests {
    @Test func defaultIsSandboxed() {
        for configuration in [CefRuntime.Configuration(), .embedded, .browser] {
            #expect(configuration.isSandboxEnabled)
        }
        let mapped = MappedCefSettings(configuration: CefRuntime.Configuration(), frameworkDirectory: nil)
        #expect(mapped.raw.no_sandbox == 0)
    }

    @Test func disabledSandboxSetsNoSandbox() {
        var config = CefRuntime.Configuration()
        config.isSandboxEnabled = false
        let mapped = MappedCefSettings(configuration: config, frameworkDirectory: nil)
        #expect(mapped.raw.no_sandbox == 1)
    }

    @Test func messagePumpIsAlwaysExternal() {
        let mapped = MappedCefSettings(configuration: CefRuntime.Configuration(), frameworkDirectory: nil)
        #expect(mapped.raw.external_message_pump == 1)
    }
}
