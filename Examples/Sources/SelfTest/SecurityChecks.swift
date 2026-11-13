import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import Security

/// Connection security, certificates and the profile's network
/// maintenance. The public-site checks need the network; offline they are
/// skipped as environment.
extension SelfTest {
    static func securityChecks() async {
        CefRuntime.shared.registerSchemeHandler(scheme: "https", domain: "cefswift.test", handler: CapabilityPages())
        let recorder = SecurityRecorder()
        var configuration = CefBrowser.Configuration()
        configuration.clientCertificates = .delegate
        let browser = CefBrowser(url: URL(string: "selftest://app/second.html")!, configuration: configuration)
        browser.delegate = recorder
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        view.browser = browser

        func load(_ url: URL, title: String? = nil) async -> Bool {
            browser.load(url)
            return await waitUntil(timeout: .seconds(20)) {
                browser.url?.host() == url.host() && !browser.isLoading && (title == nil || browser.title == title)
            }
        }

        _ = await waitUntil { browser.title == "second" && !browser.isLoading }
        check("security: the app's own scheme is local", browser.connectionSecurity?.level == .local,
              detail: "\(String(describing: browser.connectionSecurity))")
        _ = await load(capabilityOrigin.appending(path: "plain.html"), title: "plain")
        let handled = browser.connectionSecurity
        check("security: an https page served by the app has no TLS or certificate",
              handled?.isSecureConnection == false && handled?.certificate == nil && handled?.level == .notSecure,
              detail: "\(String(describing: handled))")

        // An error page also finishes loading, so the public site's own
        // title is what tells a working network from none.
        let online = await load(URL(string: "https://example.com/")!) && browser.title.lowercased().contains("example")
        if online {
            let security = browser.connectionSecurity
            let certificate = security?.certificate
            check("security: a public HTTPS site is secure over TLS 1.2 or later",
                  security?.level == .secure && [.tls1_2, .tls1_3, .quic].contains(security?.protocolVersion),
                  detail: "\(String(describing: security?.level)) \(String(describing: security?.protocolVersion))")
            check("security: its certificate names the site and is valid now",
                  certificate.map { $0.subjectAlternativeNames.contains { $0.hasSuffix("example.com") } && $0.isValid() } ?? false,
                  detail: "\(certificate?.subjectAlternativeNames ?? []) \(String(describing: certificate?.validUntil))")
            check("security: the certificate bridges to the Security framework with its chain",
                  certificate?.secCertificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } != nil
                      && (certificate?.issuerChain.count ?? 0) >= 1
                      && certificate?.secCertificateChain.count == 1 + (certificate?.issuerChain.count ?? 0)
                      && certificate?.sha256Fingerprint.count == 32
                      && !(certificate?.issuer.displayName.isEmpty ?? true),
                  detail: "\(String(describing: certificate?.issuer))")
        } else {
            skip("security: a public HTTPS site", because: "https://example.com did not load (offline?)", .environment)
        }

        if await load(URL(string: "https://expired.badssl.com/")!) || recorder.certificateErrors.count > 0 {
            let error = recorder.certificateErrors.first
            check("security: a certificate error carries the certificate and its status",
                  error?.status.contains(.dateInvalid) == true && error?.certificate != nil
                      && error?.certificate?.isValid() == false,
                  detail: "\(String(describing: error))")
        } else {
            skip("security: a certificate error", because: "expired.badssl.com did not answer (offline?)", .environment)
        }

        _ = await load(URL(string: "https://client.badssl.com/")!)
        if let request = recorder.clientCertificateRequests.first {
            check("security: a site asking for a client certificate asks the delegate",
                  request.host == "client.badssl.com" && request.port == 443 && !request.isProxy,
                  detail: "\(request)")
        } else if !online || browser.title.isEmpty {
            skip("security: a client-certificate request", because: "client.badssl.com did not answer (offline?)", .environment)
        } else {
            check("security: a site asking for a client certificate asks the delegate", false, detail: browser.title)
        }

        // The profile's network maintenance.
        let profile = CefProfile.default
        let maintenance: [(String, @MainActor () async -> Void)] = [
            ("clearHTTPCache", profile.clearHTTPCache),
            ("clearCertificateExceptions", profile.clearCertificateExceptions),
            ("clearHTTPAuthenticationCredentials", profile.clearHTTPAuthenticationCredentials),
            ("closeAllConnections", profile.closeAllConnections),
        ]
        for (name, run) in maintenance {
            let finished = await withTimeout(.seconds(10)) { await run(); return true }
            check("security: \(name) completes", finished == true)
        }
        await expect("security: resolveHost resolves localhost") {
            let addresses = try await profile.resolveHost("localhost")
            return addresses.contains("127.0.0.1") || addresses.contains("::1")
        }
        await expect("security: resolveHost throws for a name that does not exist") {
            do {
                _ = try await profile.resolveHost("no-such-host.invalid")
                return false
            } catch { return true }
        }
        browser.close(force: true)
        _ = await waitUntil { browser.state == .closed }
        view.removeFromSuperview()
    }
}

@MainActor
final class SecurityRecorder: CefBrowserDelegate {
    var certificateErrors: [CefCertificateError] = []
    var clientCertificateRequests: [CefClientCertificateRequest] = []

    func browser(_ browser: CefBrowser, shouldProceedDespite error: CefCertificateError) async -> Bool {
        certificateErrors.append(error)
        return false
    }

    func browser(_ browser: CefBrowser, selectClientCertificateFor request: CefClientCertificateRequest) async -> CefCertificate? {
        clientCertificateRequests.append(request)
        return nil
    }
}
