import CCef

/// How a CefSwift app names itself to the sites it loads
/// (``CefConfiguration/userAgent``).
///
/// Sites read two things. The `User-Agent` header and
/// `navigator.userAgent`, which this sets, and the user-agent client hints
/// (`Sec-CH-UA` headers and `navigator.userAgentData`). CEF is built as
/// Chromium, so its client hints name the brand `Chromium` and a GREASE
/// brand, never `Google Chrome`, whatever this says; only the DevTools
/// protocol's `Emulation.setUserAgentOverride` changes them, per browser.
///
/// Many sites, bot protection among them, compare the two and check that
/// the `User-Agent` names a browser engine they know. Every choice here
/// is honest about what the app is; which to use is your product's
/// decision.
public enum CefUserAgent: Sendable, Equatable {
    /// Chromium's own, as Chrome sends it: `Mozilla/5.0 (Macintosh; Intel
    /// Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)
    /// Chrome/156.0.0.0 Safari/537.36`. The default.
    case chromium
    /// Chromium's own with your product's token after Chromium's, as Edge
    /// and Opera do: `… Chrome/156.0.0.0 MyApp/1.0 Safari/537.36`. Client
    /// hints are unchanged.
    case appendingProduct(String)
    /// Your product's token in place of `Chrome/<version>`: `…
    /// (KHTML, like Gecko) MyApp/1.0 Safari/537.36` (CEF's
    /// `user_agent_product`). Sites that look for a `Chrome/` token treat
    /// such a browser as an unknown one.
    case replacingProduct(String)
    /// This exact string. Chromium then sends only the low-entropy client
    /// hints (brands, mobile, platform), and `getHighEntropyValues()` has
    /// no versions or architecture, which differs from any stock browser.
    case custom(String)

    /// `cef_settings_t.user_agent_product`.
    var product: String? {
        switch self {
        case .chromium, .custom: return nil
        case .appendingProduct(let product):
            // Chrome reports only its major version.
            return "Chrome/\(cef_version_info(4)).0.0.0 \(product)"
        case .replacingProduct(let product): return product
        }
    }

    /// `cef_settings_t.user_agent`.
    var fullString: String? {
        if case .custom(let string) = self { return string }
        return nil
    }
}
