import CefKit
import Foundation
import Testing

/// An app's tests and previews can make CefKit's plain values without
/// `@testable`.
struct PublicValueTests {
    let url = URL(string: "https://example.com/")!

    @Test func browserEventValues() {
        #expect(CefLoadError(code: -105, message: "net::ERR_NAME_NOT_RESOLVED", url: url).url == url)
        #expect(CefLoadError(code: -3, message: "aborted").isCancellation)
        #expect(CefConsoleMessage(level: .warning, text: "hi").line == 0)
        #expect(!CefNavigationAction(url: url).hasUserGesture)
        #expect(CefJavaScriptError(message: "boom").description == "boom")
        #expect(CefBrowser.FindResult(matchCount: 3, activeMatchIndex: 1).isFinal)
        #expect(CefDevToolsError(method: "Page.reload", code: -32000, message: "x").description == "Page.reload failed (-32000): x")
        #expect(CefMediaRouteError(message: "no sink").description == "no sink")
        #expect(CefAccessibilityChanges.Event(type: "focus").node == nil)
        #expect(CefResourceRequest(url: url, referrer: url).referrer == url)
    }

    @Test func securityValues() {
        let principal = CefCertificate.Principal(displayName: "Example", commonName: "example.com")
        let certificate = CefCertificate(
            subject: principal, issuer: principal, serialNumber: Data([1]), validFrom: .distantPast,
            validUntil: .distantFuture, derRepresentation: Data([0x30]))
        #expect(certificate.issuerChain.isEmpty)
        let error = CefCertificateError(code: -202, url: url, status: .authorityInvalid, certificate: certificate)
        #expect(error.status == .authorityInvalid)
        let secure = CefConnectionSecurity(url: url, isSecureConnection: true, protocolVersion: .tls1_3, certificate: certificate)
        #expect(secure.level == .secure)
        #expect(CefConnectionSecurity(url: url, isSecureConnection: false).level == .notSecure)
        #expect(CefClientCertificateRequest(host: "example.com", certificates: [certificate]).port == 443)
        #expect(!CefAppCapabilities(signature: .developerID, teamIdentifier: "ABCDE12345").isAppSandboxed)
    }

    @Test func settingsAndTaskValues() {
        let exception = CefSiteSettings.Exception(permission: .camera, origin: url, pattern: "https://example.com:443", setting: .allow)
        #expect(exception.applies(to: url))
        #expect(CefSiteSettings.Change(permission: .camera, origin: url).topLevelOrigin == nil)
        let task = CefTaskManager.Task(id: 7, kind: .renderer, title: "Tab: Example", memory: 1_000, process: 7)
        let process = CefTaskManager.Process(id: 7, tasks: [task])
        #expect(process.memory == 1_000 && CefTaskManager.Process.estimatedTotalMemory(of: [process]) == 1_000)
    }
}
