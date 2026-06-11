import AppKit
import CCef
import Foundation

/// Swift owner behind the `cef_client_t` + handler structs for one browser.
///
/// CEF invokes the struct callbacks on its UI thread, which is the main
/// thread when using the external message pump; callbacks assert main-actor
/// isolation and call straight through. Events that arrive before the
/// ``CefBrowser`` wrapper is attached (browser creation is synchronous but
/// loading starts immediately) are buffered and replayed on attach.
@MainActor
final class BrowserClient {
    private(set) weak var browser: CefBrowser?

    // Buffered early state (pre-attach).
    private var pendingTitle: String?
    private var pendingURL: String?
    private var pendingLoadingState: (isLoading: Bool, canGoBack: Bool, canGoForward: Bool)?

    // The handler getters below may be invoked by CEF from non-UI threads;
    // these pointers are written once during makeClient() and immutable
    // afterwards, hence nonisolated(unsafe) is sound.
    nonisolated(unsafe) private(set) var clientPointer: UnsafeMutablePointer<cef_client_t>?
    nonisolated(unsafe) private var lifeSpanPointer: UnsafeMutablePointer<cef_life_span_handler_t>?
    nonisolated(unsafe) private var loadPointer: UnsafeMutablePointer<cef_load_handler_t>?
    nonisolated(unsafe) private var displayPointer: UnsafeMutablePointer<cef_display_handler_t>?

    func attach(_ browser: CefBrowser) {
        self.browser = browser
        if let pendingTitle { browser.applyTitle(pendingTitle) }
        if let pendingURL { browser.applyURL(pendingURL) }
        if let state = pendingLoadingState {
            browser.applyLoadingState(
                isLoading: state.isLoading,
                canGoBack: state.canGoBack,
                canGoForward: state.canGoForward
            )
        }
        pendingTitle = nil
        pendingURL = nil
        pendingLoadingState = nil
    }

    /// Recovers the BrowserClient from a CEF callback's `self` pointer.
    /// Must run on the main thread (CEF UI thread).
    private nonisolated static func owner(_ cefSelf: UnsafeMutableRawPointer?) -> BrowserClient? {
        cefOwner(BrowserClient.self, cefSelf)
    }

    // MARK: Struct construction

    /// Builds the cef_client_t graph. The returned pointer carries one
    /// reference owned by the caller (transferred to CEF at browser
    /// creation).
    func makeClient() -> UnsafeMutablePointer<cef_client_t> {
        let lifeSpan = cefAllocate(cef_life_span_handler_t.self, owner: self)
        lifeSpan.pointee.on_after_created = { _, browser in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
        }
        lifeSpan.pointee.do_close = { _, browser in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            return 0  // proceed with the close
        }
        lifeSpan.pointee.on_before_close = { handlerSelf, browser in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                client.browser?.handleBeforeClose()
            }
        }
        lifeSpan.pointee.on_before_popup = {
            handlerSelf, browser, frame, _, targetURL, _, _, _, _, _, _, _, _, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(frame.map(UnsafeMutableRawPointer.init))
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 0 }
            let urlString = CefStringUtil.string(from: targetURL)
            let url = URL(string: urlString)
            return MainActor.assumeIsolated {
                guard let cefBrowser = client.browser else { return 0 }
                let decision = cefBrowser.delegate?.browser(cefBrowser, requestsPopupFor: url) ?? .allow
                switch decision {
                case .allow:
                    return 0
                case .block:
                    return 1
                case .openInSameBrowser:
                    if let url { cefBrowser.load(url) }
                    return 1
                }
            }
        }
        lifeSpanPointer = lifeSpan

        let load = cefAllocate(cef_load_handler_t.self, owner: self)
        load.pointee.on_loading_state_change = { handlerSelf, browser, isLoading, canGoBack, canGoForward in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                client.updateLoadingState(
                    isLoading: isLoading != 0,
                    canGoBack: canGoBack != 0,
                    canGoForward: canGoForward != 0
                )
            }
        }
        load.pointee.on_load_error = { handlerSelf, browser, frame, errorCode, errorText, failedURL in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            defer { cefRelease(frame.map(UnsafeMutableRawPointer.init)) }
            guard let frame, frame.pointee.is_main?(frame) != 0 else { return }
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            let text = CefStringUtil.string(from: errorText)
            let failed = CefStringUtil.string(from: failedURL)
            let code = Int(errorCode.rawValue)
            MainActor.assumeIsolated {
                guard let cefBrowser = client.browser else { return }
                cefBrowser.delegate?.browser(cefBrowser, didFailLoad: code, errorText: text, failedURL: failed)
            }
        }
        loadPointer = load

        let display = cefAllocate(cef_display_handler_t.self, owner: self)
        display.pointee.on_title_change = { handlerSelf, browser, title in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            let title = CefStringUtil.string(from: title)
            MainActor.assumeIsolated { client.updateTitle(title) }
        }
        display.pointee.on_address_change = { handlerSelf, browser, frame, url in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            defer { cefRelease(frame.map(UnsafeMutableRawPointer.init)) }
            guard let frame, frame.pointee.is_main?(frame) != 0 else { return }
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            let urlString = CefStringUtil.string(from: url)
            MainActor.assumeIsolated { client.updateURL(urlString) }
        }
        display.pointee.on_favicon_urlchange = { handlerSelf, browser, iconURLs in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            var urls: [URL] = []
            if let iconURLs {
                for index in 0..<cef_string_list_size(iconURLs) {
                    var value = cef_string_t()
                    if cef_string_list_value(iconURLs, index, &value) != 0 {
                        if let url = URL(string: CefStringUtil.string(from: value)) {
                            urls.append(url)
                        }
                        cef_string_utf16_clear(&value)
                    }
                }
            }
            let collected = urls
            MainActor.assumeIsolated {
                guard let cefBrowser = client.browser else { return }
                cefBrowser.delegate?.browser(cefBrowser, didChangeFavicon: collected)
            }
        }
        display.pointee.on_fullscreen_mode_change = { handlerSelf, browser, fullscreen in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            let isFullscreen = fullscreen != 0
            MainActor.assumeIsolated {
                guard let cefBrowser = client.browser else { return }
                cefBrowser.delegate?.browser(cefBrowser, didChangeFullscreen: isFullscreen)
            }
        }
        display.pointee.on_loading_progress_change = { handlerSelf, browser, progress in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                guard let cefBrowser = client.browser else { return }
                cefBrowser.delegate?.browser(cefBrowser, didChangeProgress: progress)
            }
        }
        display.pointee.on_console_message = { handlerSelf, browser, level, message, source, line in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 0 }
            let message = CefStringUtil.string(from: message)
            let source = CefStringUtil.string(from: source)
            let severity = CefLogSeverity(cefValue: level)
            let lineNumber = Int(line)
            MainActor.assumeIsolated {
                guard let cefBrowser = client.browser else { return }
                cefBrowser.delegate?.browser(
                    cefBrowser,
                    didReceiveConsoleMessage: message,
                    level: severity,
                    source: source,
                    line: lineNumber
                )
            }
            return 0  // keep default logging behavior
        }
        displayPointer = display

        let client = cefAllocate(cef_client_t.self, owner: self)
        client.pointee.get_life_span_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.lifeSpanPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_load_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.loadPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_display_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.displayPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
        clientPointer = client
        return client
    }

    // MARK: State routing (main thread)

    private func updateTitle(_ title: String) {
        if let browser {
            browser.applyTitle(title)
        } else {
            pendingTitle = title
        }
    }

    private func updateURL(_ urlString: String) {
        if let browser {
            browser.applyURL(urlString)
        } else {
            pendingURL = urlString
        }
    }

    private func updateLoadingState(isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        if let browser {
            browser.applyLoadingState(isLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
        } else {
            pendingLoadingState = (isLoading, canGoBack, canGoForward)
        }
    }
}
