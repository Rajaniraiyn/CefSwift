import AppKit
import CCef
import CefBase
import Foundation

/// How the page a browser shows was loaded: over a secure connection or
/// not, with which certificate, and whether the page also loaded insecure
/// content. ``CefBrowser/connectionSecurity`` holds it for the page shown.
public struct CefConnectionSecurity: Sendable, Equatable {
    /// The overall state, as an address field shows it.
    public enum Level: Sendable, Equatable {
        /// A secure connection with a valid certificate and no insecure
        /// content.
        case secure
        /// A secure connection, but the page shows insecure images or
        /// media, or its certificate has an error the user accepted.
        case partiallySecure
        /// Not a secure connection: plain HTTP.
        case notSecure
        /// Not loaded over the network: the app's own scheme, a file,
        /// `about:` or a Chromium page.
        case local
    }

    /// The TLS version of the connection.
    public enum ProtocolVersion: Sendable, Equatable {
        case tls1_0, tls1_1, tls1_2, tls1_3
        /// QUIC, which uses TLS 1.3.
        case quic
        /// An older or unknown version.
        case other
    }

    /// The URL these describe.
    public var url: URL?
    /// Whether the page came over TLS.
    public var isSecureConnection: Bool
    /// The TLS version; `nil` for an insecure connection.
    public var protocolVersion: ProtocolVersion?
    /// What Chromium found checking the certificate.
    public var certificateStatus: CefCertificateStatus
    /// The certificate the server presented; `nil` without TLS.
    public var certificate: CefCertificate?
    /// The page displayed images or media loaded over HTTP.
    public var displayedInsecureContent: Bool
    /// The page ran scripts or loaded frames over HTTP.
    public var ranInsecureContent: Bool

    /// The overall state.
    public var level: Level {
        guard let scheme = url?.scheme?.lowercased(), ["https", "http", "wss", "ws"].contains(scheme) else { return .local }
        guard isSecureConnection else { return .notSecure }
        if certificateStatus.hasErrors || displayedInsecureContent || ranInsecureContent { return .partiallySecure }
        return .secure
    }
}

extension CefConnectionSecurity.ProtocolVersion {
    init?(cefValue: cef_ssl_version_t) {
        switch cefValue {
        case SSL_CONNECTION_VERSION_TLS1: self = .tls1_0
        case SSL_CONNECTION_VERSION_TLS1_1: self = .tls1_1
        case SSL_CONNECTION_VERSION_TLS1_2: self = .tls1_2
        case SSL_CONNECTION_VERSION_TLS1_3: self = .tls1_3
        case SSL_CONNECTION_VERSION_QUIC: self = .quic
        case SSL_CONNECTION_VERSION_UNKNOWN: return nil
        default: self = .other
        }
    }
}

extension CefConnectionSecurity {
    /// Reads the visible navigation entry of `host`.
    @MainActor
    init?(visibleEntryOf host: UnsafeMutablePointer<cef_browser_host_t>) {
        guard let entry = host.pointee.get_visible_navigation_entry(host) else { return nil }
        defer { cefRelease(entry) }
        guard entry.pointee.is_valid(entry) != 0 else { return nil }
        url = CefStringUtil.takingUserFree(entry.pointee.get_url(entry)).flatMap(URL.init(string:))
        guard let status = entry.pointee.get_sslstatus(entry) else {
            isSecureConnection = false
            certificateStatus = []
            displayedInsecureContent = false
            ranInsecureContent = false
            return
        }
        defer { cefRelease(status) }
        isSecureConnection = status.pointee.is_secure_connection(status) != 0
        protocolVersion = isSecureConnection ? ProtocolVersion(cefValue: status.pointee.get_sslversion(status)) : nil
        certificateStatus = CefCertificateStatus(rawValue: UInt32(status.pointee.get_cert_status(status).rawValue))
        let content = status.pointee.get_content_status(status).rawValue
        displayedInsecureContent = content & UInt32(SSL_CONTENT_DISPLAYED_INSECURE_CONTENT.rawValue) != 0
        ranInsecureContent = content & UInt32(SSL_CONTENT_RAN_INSECURE_CONTENT.rawValue) != 0
        if let x509 = status.pointee.get_x509_certificate(status) {
            certificate = CefCertificate(borrowing: x509)
            cefRelease(x509)
        }
    }
}

extension CefBrowser {
    /// Reads the security of the page shown into ``connectionSecurity``.
    func refreshConnectionSecurity() {
        let security = withHost { CefConnectionSecurity(visibleEntryOf: $0) } ?? nil
        if security != connectionSecurity { connectionSecurity = security }
    }
}

// MARK: - Client certificates

extension CefBrowser {
    /// Who picks the certificate a site asks the user to identify with.
    public enum ClientCertificatePolicy: Sendable, Equatable {
        /// Chromium's own certificate picker.
        case automatic
        /// ``CefBrowserDelegate/browser(_:selectClientCertificateFor:)``.
        case delegate
    }
}

/// A site asking for a certificate to identify the user, delivered to
/// ``CefBrowserDelegate/browser(_:selectClientCertificateFor:)``.
public struct CefClientCertificateRequest: Sendable, Equatable {
    /// The server asking, `host:port`.
    public var host: String
    public var port: Int
    /// Whether an HTTPS proxy asks, rather than the site.
    public var isProxy: Bool
    /// The certificates of the user's identities whose issuers the server
    /// accepts, from the keychain. Their private keys stay there.
    public var certificates: [CefCertificate]
}

/// The native sheet behind the default
/// ``CefBrowserDelegate/browser(_:selectClientCertificateFor:)``.
@MainActor
public enum CefClientCertificatePresenter {
    /// Asks which certificate to identify with, as a sheet on `window` or
    /// a modal alert without one; `nil` to continue without one. Dismisses
    /// itself, as `nil`, when the task is cancelled: the page navigated or
    /// the browser closed.
    public static func present(_ request: CefClientCertificateRequest, in window: NSWindow?) async -> CefCertificate? {
        guard !request.certificates.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = "Select a certificate"
        alert.informativeText = "\(request.host) requests a certificate to identify you."
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        for certificate in request.certificates {
            menu.addItem(withTitle: "\(certificate.subject.displayName) (\(certificate.issuer.displayName))")
        }
        alert.accessoryView = menu
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        // Dismissed, as Cancel, when the task is cancelled: before it is
        // shown, as a sheet or as a modal alert.
        let response = await CefDialogPresenter.run(alert, in: window)
        guard response == .alertFirstButtonReturn, menu.indexOfSelectedItem >= 0 else { return nil }
        return request.certificates[menu.indexOfSelectedItem]
    }
}

extension CefBrowserClient {
    /// Adds the client-certificate callback to the request handler.
    static func installClientCertificateCallback(on handler: UnsafeMutablePointer<cef_request_handler_t>) {
        handler.pointee.on_select_client_certificate = { s, browser, isProxy, host, port, count, certificates, callback in
            // Each certificate comes with a reference for this callback.
            var offered: [(CefCertificate, CefRef<cef_x509_certificate_t>)] = []
            for index in 0..<count {
                guard let raw = certificates?[index] else { continue }
                let reference = CefRef(adopting: raw)
                if let certificate = CefCertificate(borrowing: raw) { offered.append((certificate, reference)) }
            }
            let request = CefClientCertificateRequest(
                host: CefStringUtil.string(from: host), port: Int(port), isProxy: isProxy != 0,
                certificates: offered.map(\.0))
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            let references = offered.map(\.1)
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                guard b.configuration.clientCertificates == .delegate else { return 0 }
                b.decide(.page) { await $0.browser(b, selectClientCertificateFor: request) } then: { chosen in
                    let index = chosen.flatMap { chosen in request.certificates.firstIndex(of: chosen) }
                    // Select consumes the certificate reference it is given.
                    let selected = index.map { references[$0].retainedPointer() }
                    callback.pointer.pointee.select(callback.pointer, selected)
                }
                return 1
            }
        }
    }
}
