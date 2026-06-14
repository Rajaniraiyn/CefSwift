import Foundation
import Testing

@testable import CCef
@testable import CefKit

/// Pure-logic tests for the macOS sandbox seam: defaults and the bit that
/// crosses into `cef_settings_t.no_sandbox`. We can't exercise the helper
/// dlopen path in a unit test (it needs a real bundle layout), but the
/// settings mapping is where the toggle is easy to break.
@Suite struct SandboxConfigTests {
    @Test func defaultIsUnsandboxed() {
        #expect(CefConfiguration().noSandbox == true)
        #expect(CefConfiguration.default.noSandbox == true)
    }

    @Test func mappingPropagatesNoSandboxTrue() {
        var config = CefConfiguration()
        config.noSandbox = true
        let mapped = MappedCefSettings(configuration: config, frameworkDirectory: nil)
        #expect(mapped.raw.no_sandbox == 1)
    }

    @Test func mappingPropagatesNoSandboxFalse() {
        var config = CefConfiguration()
        config.noSandbox = false
        let mapped = MappedCefSettings(configuration: config, frameworkDirectory: nil)
        #expect(mapped.raw.no_sandbox == 0)
    }
}
