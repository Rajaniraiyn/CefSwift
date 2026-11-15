import CCef
import Foundation
import Testing

@testable import CefKit

/// What a connection's security state adds up to, without Chromium.
struct ConnectionSecurityTests {
    private func security(_ url: String, tls: Bool, status: CefCertificateStatus = [], displayed: Bool = false) -> CefConnectionSecurity {
        CefConnectionSecurity(
            url: URL(string: url), isSecureConnection: tls, protocolVersion: tls ? .tls1_3 : nil,
            certificateStatus: status, certificate: nil, displayedInsecureContent: displayed, ranInsecureContent: false)
    }

    @Test func levelsFollowTheConnection() {
        #expect(security("https://a.example/", tls: true).level == .secure)
        #expect(security("https://a.example/", tls: true, status: .extendedValidation).level == .secure)
        #expect(security("https://a.example/", tls: true, status: .dateInvalid).level == .partiallySecure)
        #expect(security("https://a.example/", tls: true, displayed: true).level == .partiallySecure)
        #expect(security("http://a.example/", tls: false).level == .notSecure)
        #expect(security("myapp://index.html", tls: false).level == .local)
        #expect(security("chrome://settings", tls: false).level == .local)
    }

    @Test func revocationCheckingIsNotAnError() {
        #expect(!CefCertificateStatus([.unableToCheckRevocation, .noRevocationMechanism, .extendedValidation]).hasErrors)
        #expect(CefCertificateStatus.authorityInvalid.hasErrors)
        #expect(CefCertificateStatus.transparencyFailed.hasErrors)
        #expect(CefCertificateStatus(rawValue: UInt32(CERT_STATUS_DATE_INVALID.rawValue)) == .dateInvalid)
    }

    @Test func protocolVersionsMapFromChromium() {
        #expect(CefConnectionSecurity.ProtocolVersion(cefValue: SSL_CONNECTION_VERSION_TLS1_3) == .tls1_3)
        #expect(CefConnectionSecurity.ProtocolVersion(cefValue: SSL_CONNECTION_VERSION_QUIC) == .quic)
        #expect(CefConnectionSecurity.ProtocolVersion(cefValue: SSL_CONNECTION_VERSION_SSL3) == .other)
        #expect(CefConnectionSecurity.ProtocolVersion(cefValue: SSL_CONNECTION_VERSION_UNKNOWN) == nil)
    }

    @Test func fingerprintsAreSHA256() {
        let certificate = CefCertificate(
            subject: .init(displayName: "", commonName: "", organizations: [], organizationalUnits: [], locality: "",
                           stateOrProvince: "", country: ""),
            issuer: .init(displayName: "", commonName: "", organizations: [], organizationalUnits: [], locality: "",
                          stateOrProvince: "", country: ""),
            serialNumber: Data(), validFrom: .distantPast, validUntil: .distantFuture,
            derRepresentation: Data("abc".utf8), issuerChain: [])
        #expect(certificate.sha256FingerprintText.hasPrefix("BA:78:16:BF"))
        #expect(certificate.secCertificate == nil)
        #expect(certificate.subjectAlternativeNames.isEmpty)
        #expect(certificate.isValid())
    }
}
