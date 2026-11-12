import CCef
import CefBase
import CryptoKit
import Foundation
import Security

/// An X.509 certificate a site presented, with the chain of issuers it came
/// with.
///
/// ``derRepresentation`` bridges to the Security framework, so an app can
/// show the system's certificate sheet:
///
/// ```swift
/// if let certificate = browser.connectionSecurity?.certificate?.secCertificate {
///     SFCertificatePanel.shared().beginSheet(for: window, modalDelegate: nil,
///         didEnd: nil, contextInfo: nil, certificates: [certificate], showGroup: false)
/// }
/// ```
public struct CefCertificate: Sendable, Hashable {
    /// A certificate's subject or issuer.
    public struct Principal: Sendable, Hashable {
        /// The name to show: the common name, or failing that the first
        /// organization or organizational unit.
        public var displayName: String
        public var commonName: String
        public var organizations: [String]
        public var organizationalUnits: [String]
        public var locality: String
        public var stateOrProvince: String
        public var country: String
    }

    public var subject: Principal
    public var issuer: Principal
    /// The serial number's bytes.
    public var serialNumber: Data
    public var validFrom: Date
    public var validUntil: Date
    /// The certificate in DER encoding.
    public var derRepresentation: Data
    /// The issuers' certificates, the direct issuer first, in DER encoding.
    public var issuerChain: [Data]

    /// The certificate's SHA-256 fingerprint.
    public var sha256Fingerprint: Data { Data(SHA256.hash(data: derRepresentation)) }

    /// The fingerprint as colon-separated hexadecimal, as certificate
    /// viewers show it.
    public var sha256FingerprintText: String {
        sha256Fingerprint.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The certificate for the Security framework.
    public var secCertificate: SecCertificate? {
        SecCertificateCreateWithData(nil, derRepresentation as CFData)
    }

    /// The certificate and its issuers for the Security framework, the
    /// certificate first.
    public var secCertificateChain: [SecCertificate] {
        ([derRepresentation] + issuerChain).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    /// The DNS names and IP addresses the certificate covers.
    public var subjectAlternativeNames: [String] {
        guard let certificate = secCertificate,
              let values = SecCertificateCopyValues(certificate, [kSecOIDSubjectAltName] as CFArray, nil) as? [CFString: Any],
              let entry = values[kSecOIDSubjectAltName] as? [CFString: Any],
              let names = entry[kSecPropertyKeyValue] as? [[CFString: Any]]
        else { return [] }
        return names.compactMap { $0[kSecPropertyKeyValue] as? String }
    }

    /// Whether `date` falls within the certificate's validity.
    public func isValid(at date: Date = .now) -> Bool { validFrom <= date && date <= validUntil }
}

extension CefCertificate {
    /// Reads a borrowed `cef_x509_certificate_t`.
    init?(borrowing certificate: UnsafeMutablePointer<cef_x509_certificate_t>) {
        guard let der = Self.data(taking: certificate.pointee.get_derencoded(certificate)), !der.isEmpty else { return nil }
        derRepresentation = der
        subject = Principal(taking: certificate.pointee.get_subject(certificate))
        issuer = Principal(taking: certificate.pointee.get_issuer(certificate))
        serialNumber = Self.data(taking: certificate.pointee.get_serial_number(certificate)) ?? Data()
        validFrom = certificate.pointee.get_valid_start(certificate).date
        validUntil = certificate.pointee.get_valid_expiry(certificate).date
        var count = certificate.pointee.get_issuer_chain_size(certificate)
        var chain = [UnsafeMutablePointer<cef_binary_value_t>?](repeating: nil, count: count)
        if count > 0 { certificate.pointee.get_derencoded_issuer_chain(certificate, &count, &chain) }
        issuerChain = chain.prefix(count).compactMap { Self.data(taking: $0) }
    }

    /// The bytes of a +1 binary value, which this releases.
    static func data(taking value: UnsafeMutablePointer<cef_binary_value_t>?) -> Data? {
        guard let value else { return nil }
        defer { cefRelease(value) }
        let size = value.pointee.get_size(value)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { _ = value.pointee.get_data(value, $0.baseAddress, size, 0) }
        return data
    }
}

extension CefCertificate.Principal {
    /// Reads a +1 principal, which this releases.
    init(taking principal: UnsafeMutablePointer<cef_x509_cert_principal_t>?) {
        defer { cefRelease(principal) }
        func string(_ get: ((UnsafeMutablePointer<cef_x509_cert_principal_t>?) -> cef_string_userfree_t?)?) -> String {
            guard let principal, let get else { return "" }
            return CefStringUtil.takingUserFree(get(principal)) ?? ""
        }
        func list(_ get: ((UnsafeMutablePointer<cef_x509_cert_principal_t>?, cef_string_list_t?) -> Void)?) -> [String] {
            guard let principal, let get, let names = cef_string_list_alloc() else { return [] }
            defer { cef_string_list_free(names) }
            get(principal, names)
            return cefStrings(from: names)
        }
        displayName = string(principal?.pointee.get_display_name)
        commonName = string(principal?.pointee.get_common_name)
        locality = string(principal?.pointee.get_locality_name)
        stateOrProvince = string(principal?.pointee.get_state_or_province_name)
        country = string(principal?.pointee.get_country_name)
        organizations = list(principal?.pointee.get_organization_names)
        organizationalUnits = list(principal?.pointee.get_organization_unit_names)
    }
}

/// Problems Chromium found with a certificate, and facts about it.
public struct CefCertificateStatus: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// The certificate does not name the site.
    public static let nameMismatch = Self(rawValue: UInt32(CERT_STATUS_COMMON_NAME_INVALID.rawValue))
    /// The certificate has expired or is not valid yet.
    public static let dateInvalid = Self(rawValue: UInt32(CERT_STATUS_DATE_INVALID.rawValue))
    /// No trusted authority issued it, as with a self-signed certificate.
    public static let authorityInvalid = Self(rawValue: UInt32(CERT_STATUS_AUTHORITY_INVALID.rawValue))
    public static let noRevocationMechanism = Self(rawValue: UInt32(CERT_STATUS_NO_REVOCATION_MECHANISM.rawValue))
    public static let unableToCheckRevocation = Self(rawValue: UInt32(CERT_STATUS_UNABLE_TO_CHECK_REVOCATION.rawValue))
    public static let revoked = Self(rawValue: UInt32(CERT_STATUS_REVOKED.rawValue))
    public static let invalid = Self(rawValue: UInt32(CERT_STATUS_INVALID.rawValue))
    public static let weakSignatureAlgorithm = Self(rawValue: UInt32(CERT_STATUS_WEAK_SIGNATURE_ALGORITHM.rawValue))
    public static let nonUniqueName = Self(rawValue: UInt32(CERT_STATUS_NON_UNIQUE_NAME.rawValue))
    public static let weakKey = Self(rawValue: UInt32(CERT_STATUS_WEAK_KEY.rawValue))
    public static let pinnedKeyMissing = Self(rawValue: UInt32(CERT_STATUS_PINNED_KEY_MISSING.rawValue))
    public static let nameConstraintViolation = Self(rawValue: UInt32(CERT_STATUS_NAME_CONSTRAINT_VIOLATION.rawValue))
    public static let validityTooLong = Self(rawValue: UInt32(CERT_STATUS_VALIDITY_TOO_LONG.rawValue))
    /// Certificate Transparency requirements were not met.
    public static let transparencyFailed = Self(rawValue: UInt32(CERT_STATUS_CT_COMPLIANCE_FAILED.rawValue))
    /// An Extended Validation certificate. Not a problem.
    public static let extendedValidation = Self(rawValue: UInt32(CERT_STATUS_IS_EV.rawValue))

    /// The statuses that are errors: bits 0 to 15, and transparency.
    public static let errors = Self(rawValue: 0xFFFF).union(.transparencyFailed)
        .subtracting([.noRevocationMechanism, .unableToCheckRevocation])

    /// Whether any status is an error.
    public var hasErrors: Bool { !intersection(.errors).isEmpty }
}
