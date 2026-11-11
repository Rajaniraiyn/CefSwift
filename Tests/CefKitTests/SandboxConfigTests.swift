import Foundation
import Testing

@testable import CCef
@testable import CefKit

/// Pure-logic tests for the macOS sandbox seam: defaults and the bit that
/// crosses into `cef_settings_t.no_sandbox`, the inverse of
/// `isSandboxEnabled`. We can't exercise the helper
/// dlopen path in a unit test (it needs a real bundle layout), but the
/// settings mapping is where the toggle is easy to break.
@Suite struct SandboxConfigTests {
    @Test func defaultIsUnsandboxed() {
        #expect(CefConfiguration().isSandboxEnabled == false)
        #expect(CefConfiguration.default.isSandboxEnabled == false)
        let mapped = MappedCefSettings(configuration: CefConfiguration(), frameworkDirectory: nil)
        #expect(mapped.raw.no_sandbox == 1)
    }

    @Test func disabledSandboxSetsNoSandbox() {
        var config = CefConfiguration()
        config.isSandboxEnabled = false
        let mapped = MappedCefSettings(configuration: config, frameworkDirectory: nil)
        #expect(mapped.raw.no_sandbox == 1)
    }

    @Test func enabledSandboxClearsNoSandbox() {
        var config = CefConfiguration()
        config.isSandboxEnabled = true
        let mapped = MappedCefSettings(configuration: config, frameworkDirectory: nil)
        #expect(mapped.raw.no_sandbox == 0)
    }

    @Test func messagePumpIsAlwaysExternal() {
        let mapped = MappedCefSettings(configuration: CefConfiguration(), frameworkDirectory: nil)
        #expect(mapped.raw.external_message_pump == 1)
    }
}
