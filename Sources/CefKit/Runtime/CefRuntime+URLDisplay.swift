import CCef
import CefBase
import Foundation

extension CefRuntime {
    /// `url` as Chromium shows a site to people deciding whether to trust
    /// it, in a permission prompt or an address bar's security view:
    /// scheme and host, without the path for web schemes (`file:` keeps
    /// it), without a default port, and with an internationalized domain
    /// name in Unicode only where Chromium considers that safe from
    /// spoofing (otherwise in Punycode).
    ///
    /// ```swift
    /// CefRuntime.shared.securityDisplayString(for: URL(string: "https://xn--80ak6aa92e.com/login")!)
    /// // "https://xn--80ak6aa92e.com": the Cyrillic look-alike of apple.com stays Punycode
    /// ```
    ///
    /// For display only: never parse the result or hand it to another
    /// app. `nil` before Chromium runs.
    public func securityDisplayString(for url: URL) -> String? {
        guard isRunning else { return nil }
        return CefStringUtil.withCefString(url.absoluteString) {
            CefStringUtil.takingUserFree(cef_format_url_for_security_display($0))
        }
    }
}
