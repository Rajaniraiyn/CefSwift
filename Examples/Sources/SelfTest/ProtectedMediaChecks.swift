import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// Protected media (Encrypted Media Extensions): Clear Key, and Widevine
/// with Chromium's component updater on and off.
extension SelfTest {
    /// How long the Widevine probe waits for Chromium to download the CDM
    /// before it skips.
    static let widevineDownloadLimit: Duration = .seconds(20)

    /// Asks the page in `browser` for a key system and returns "OK" or the
    /// error's name.
    static func requestKeySystem(_ keySystem: String, in browser: CefBrowser) async throws -> String {
        try await browser.evaluateJavaScript("""
            navigator.requestMediaKeySystemAccess('\(keySystem)', [{
              initDataTypes: ['webm'],
              videoCapabilities: [{ contentType: 'video/webm; codecs="vp9"' }],
            }]).then(() => 'OK', e => e.name)
            """).stringValue ?? "no result"
    }

    static func protectedMediaChecks() async {
        let browser = CefBrowser(url: URL(string: "selftest://app/eme.html")!)
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        view.browser = browser
        defer {
            browser.close(force: true)
            view.removeFromSuperview()
        }
        guard await waitUntil(timeout: .seconds(15), { browser.state == .live && !browser.isLoading }) else {
            check("protected media: page loads", false)
            return
        }
        await expect("protected media: Clear Key plays without a download") {
            try await requestKeySystem("org.w3.clearkey", in: browser) == "OK"
        }
        // SelfTest runs on CefRuntime.Configuration.embedded, whose protectedMedia
        // is .disabled.
        let installResult = await CefRuntime.shared.installWidevine()
        check("protected media: .disabled reports Widevine unavailable",
              CefRuntime.shared.widevine == .unavailable && installResult == .unavailable,
              detail: "\(CefRuntime.shared.widevine), \(installResult)")
        await expect("protected media: .disabled refuses Widevine") {
            try await requestKeySystem("com.widevine.alpha", in: browser) == "NotSupportedError"
        }
        let capabilities = CefRuntime.shared.capabilities
        check("protected media: the base helper can load Widevine (\(capabilities.signature.rawValue))",
              capabilities.canLoadWidevine || capabilities.teamIdentifier != nil)
        // A second instance with `.automatic` on a fresh cache directory.
        await runProbe("widevine", label: "widevine", timeout: widevineDownloadLimit + .seconds(25))
    }

    /// The probe: with `.automatic`, fetch Widevine and ask for it in
    /// an Alloy-style (embedded) and a Chrome-style browser.
    static func widevineProbeChecks() async {
        let embedded = CefBrowser(url: URL(string: "selftest://app/eme.html")!)
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        view.browser = embedded
        defer {
            embedded.close(force: true)
            view.removeFromSuperview()
        }
        guard await waitUntil(timeout: .seconds(15), { embedded.state == .live && !embedded.isLoading }) else {
            check("embedded page loads", false)
            return
        }
        let before = CefRuntime.shared.widevine
        if case .failed = before {
            // Offline, the component updater gives up at once.
            skip("the CDM's first state", because: "the update check failed at once (offline?)", .environment)
        } else {
            check(".automatic reports the CDM missing or arriving on a fresh profile",
                  before == .notInstalled || before == .installing, detail: "\(before)")
        }

        let started = ContinuousClock.now
        var result: CefRuntime.WidevineState?
        // Chromium's update service fetches nothing until the first browser
        // exists, so ask only now.
        Task { result = await CefRuntime.shared.installWidevine() }
        _ = await waitUntil(timeout: widevineDownloadLimit) { result != nil }
        guard let state = result, state.isInstalled else {
            skip("the CDM arrives within \(widevineDownloadLimit)",
                 because: "offline, or Google's update server is slow: " +
                     (result.map { "\($0)" } ?? "still \(CefRuntime.shared.widevine)"), .environment)
            return
        }
        print("NOTE \(state) after \((ContinuousClock.now - started).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")

        await expect("an embedded (Alloy) browser gets com.widevine.alpha") {
            try await requestKeySystem("com.widevine.alpha", in: embedded) == "OK"
        }

        let chrome = CefBrowser(url: URL(string: "selftest://app/eme.html")!)
        let chromeWindow = CefBrowserWindow(browser: chrome)
        chromeWindow.show()
        if await waitUntil(timeout: .seconds(15), { chrome.state == .live && !chrome.isLoading }) {
            await expect("a Chrome-style browser gets com.widevine.alpha") {
                try await requestKeySystem("com.widevine.alpha", in: chrome) == "OK"
            }
        } else {
            check("Chrome-style page loads", false)
        }
        chromeWindow.close()
        _ = await waitUntil(timeout: .seconds(5)) { CefRuntime.shared.browsers.count <= 1 }
    }
}
