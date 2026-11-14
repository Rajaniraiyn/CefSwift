import os
import AppKit
import CCef
import Foundation
import CefBase

extension CefBrowserClient {
    // MARK: Life span

    func makeLifeSpanHandler() -> UnsafeMutablePointer<cef_life_span_handler_t> {
        let h = cefAllocate(cef_life_span_handler_t.self, owner: self)
        h.pointee.on_after_created = { s, browser in
            guard let browser else { return }
            guard let client = cefOwner(CefBrowserClient.self, s) else {
                cefRelease(browser)
                return
            }
            nonisolated(unsafe) let created = browser
            MainActor.assumeIsolated { _ = client.wrapper(adopting: created) }
        }
        h.pointee.do_close = { s, browser in
            // Non-zero means "the app closes the host itself". Left to CEF, a
            // browser embedded in one of the app's views would close by
            // sending performClose: to the app's whole window.
            CefBrowserClient.run(s, browser, default: 0) { _, b in b.detachEmbeddedView() ? 1 : 0 }
        }
        h.pointee.on_before_close = { s, browser in
            if let browser, let client = cefOwner(CefBrowserClient.self, s) {
                let identifier = browser.pointee.get_identifier(browser)
                if MainActor.assumeIsolated({ client.abandonedBrowserClosed(identifier) }) {
                    cefRelease(browser)
                    return
                }
            }
            CefBrowserClient.run(s, browser, default: ()) { client, b in client.browserClosed(b) }
        }
        h.pointee.on_before_popup = {
            s, browser, frame, _, targetURL, targetFrameName, disposition, userGesture, features, _, client, _, extraInfo, _ in
            cefRelease(frame)
            // `*client` (the opener's client) arrives with a reference for
            // this callback. CEF takes a reference back only for a client
            // put in its place, so the one it gave must be released here or
            // the opener's client outlives every browser.
            cefRelease(client?.pointee)
            let url = URL(string: CefStringUtil.string(from: targetURL))
            let frameName = CefStringUtil.string(from: targetFrameName)
            let popupFeatures = features.map { CefPopupFeatures(raw: $0.pointee) } ?? CefPopupFeatures()
            nonisolated(unsafe) let extraInfo = extraInfo
            // Non-zero cancels CEF's own popup.
            return CefBrowserClient.run(s, browser, default: 0) { client, b in
                let request = CefWindowOpenRequest(
                    targetURL: url,
                    frameName: frameName,
                    disposition: CefWindowOpenDisposition(cefValue: disposition),
                    hasUserGesture: userGesture != 0,
                    features: popupFeatures,
                    isSourceOffscreen: b.isOffscreen,
                    isSourceChromeStyle: b.isChromeStyle
                )
                let isHandled = b.route(request)
                client.pendingPopupFeatures = isHandled ? nil : popupFeatures
                // A popup gets its opener's bridges and user scripts, like
                // the CefBrowser that wraps it.
                if !isHandled, let extraInfo, extraInfo.pointee == nil {
                    extraInfo.pointee = b.pageScripting.makeExtraInfoForPopup()
                }
                return isHandled ? 1 : 0
            }
        }
        return h
    }
}
