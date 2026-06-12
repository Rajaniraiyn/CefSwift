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
    nonisolated(unsafe) private var downloadPointer: UnsafeMutablePointer<cef_download_handler_t>?
    nonisolated(unsafe) var jsDialogPointer: UnsafeMutablePointer<cef_jsdialog_handler_t>?
    nonisolated(unsafe) var contextMenuPointer: UnsafeMutablePointer<cef_context_menu_handler_t>?
    nonisolated(unsafe) var permissionPointer: UnsafeMutablePointer<cef_permission_handler_t>?
    nonisolated(unsafe) var requestPointer: UnsafeMutablePointer<cef_request_handler_t>?
    nonisolated(unsafe) var keyboardPointer: UnsafeMutablePointer<cef_keyboard_handler_t>?
    nonisolated(unsafe) var focusPointer: UnsafeMutablePointer<cef_focus_handler_t>?
    nonisolated(unsafe) var renderPointer: UnsafeMutablePointer<cef_render_handler_t>?
    nonisolated(unsafe) var accessibilityPointer: UnsafeMutablePointer<cef_accessibility_handler_t>?

    /// The OSR host (set for offscreen browsers only). When non-nil,
    /// `makeRenderHandler()` is invoked so CEF's `get_render_handler` returns a
    /// live handler and the browser renders windowless.
    weak var osrHost: CefOSRHost?

    /// The OSR browser wrapper awaiting its async-created raw cef_browser_t
    /// (adopted in on_after_created).
    var pendingOSRBrowser: CefBrowser?

    // The most recent context-menu params, captured in on_before_context_menu
    // and replayed to the command/dismiss callbacks (which also receive params,
    // but keeping the snapshot avoids re-reading the borrowed struct).
    private var lastContextMenuParams = CefContextMenuParams()

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
        lifeSpan.pointee.on_after_created = { handlerSelf, browser in
            // For windowed browsers the wrapper already owns the raw browser
            // (sync creation), so just release this +1. For OSR browsers
            // (async creation) the wrapper has no raw yet — adopt it here.
            guard let browser else { return }
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                cefRelease(UnsafeMutableRawPointer(browser))
                return
            }
            MainActor.assumeIsolated {
                if let pending = client.pendingOSRBrowser, !pending.hasRawBrowser {
                    cefAddRef(UnsafeMutableRawPointer(browser))  // adoptRaw takes a +1 it owns
                    pending.adoptRaw(browser)
                    client.pendingOSRBrowser = nil
                }
            }
            cefRelease(UnsafeMutableRawPointer(browser))
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
        load.pointee.on_load_end = { handlerSelf, browser, frame, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            defer { cefRelease(frame.map(UnsafeMutableRawPointer.init)) }
            guard let frame, frame.pointee.is_main?(frame) != 0 else { return }
            guard BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) != nil else { return }
            MainActor.assumeIsolated {
                // JS ↔ Swift bridge: late shim injection (see CefBridge docs;
                // production pages should embed CefBridge.javascriptShim).
                let bridge = CefRuntime.shared.bridge
                guard bridge.autoInjectsShim, bridge.hasRegisteredFunctions else { return }
                CefStringUtil.withCefString(CefBridge.javascriptShim) { code in
                    CefStringUtil.withCefString("cefswift://shim") { shimURL in
                        frame.pointee.execute_java_script?(frame, code, shimURL, 0)
                    }
                }
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
        display.pointee.on_status_message = { handlerSelf, browser, value in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            let message = CefStringUtil.string(from: value)
            BrowserClient.withBrowser(handlerSelf.map(UnsafeMutableRawPointer.init), default: ()) { _, cefBrowser in
                cefBrowser.delegate?.browser(cefBrowser, didChangeStatusMessage: message)
            }
        }
        display.pointee.on_tooltip = { handlerSelf, browser, text in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            let tip = CefStringUtil.string(from: text.map { UnsafePointer($0) })
            return BrowserClient.withBrowser(handlerSelf.map(UnsafeMutableRawPointer.init), default: Int32(0)) { _, cefBrowser in
                (cefBrowser.delegate?.browser(cefBrowser, showTooltip: tip) ?? false) ? 1 : 0
            }
        }
        display.pointee.on_cursor_change = { handlerSelf, browser, _, type, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            let cursor = CefCursorType(cefValue: type)
            return BrowserClient.withBrowser(handlerSelf.map(UnsafeMutableRawPointer.init), default: Int32(0)) { client, cefBrowser in
                cefBrowser.delegate?.browser(cefBrowser, didChangeCursor: cursor)
                // OSR has no CEF window, so the host must apply the cursor.
                client.osrHost?.osrDidChangeCursor(cursor)
                return 0  // let CEF apply the cursor for windowed browsers
            }
        }
        displayPointer = display

        let download = cefAllocate(cef_download_handler_t.self, owner: self)
        download.pointee.can_download = { _, browser, _, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            // Policy is decided in on_before_download where the suggested
            // name and a CefDownload snapshot are available.
            return 1
        }
        download.pointee.on_before_download = { handlerSelf, browser, item, suggestedName, callback in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let item, let callback else {
                cefRelease(item.map(UnsafeMutableRawPointer.init))
                cefRelease(callback.map(UnsafeMutableRawPointer.init))
                return 0  // default handling
            }
            // Snapshot the item; references to it must not outlive this call.
            let download = CefDownload(item: item)
            cefRelease(UnsafeMutableRawPointer(item))
            let name = CefStringUtil.string(from: suggestedName)
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else {
                cefRelease(UnsafeMutableRawPointer(callback))
                return 0
            }
            return MainActor.assumeIsolated {
                defer { cefRelease(UnsafeMutableRawPointer(callback)) }
                guard let cefBrowser = client.browser else { return 0 }
                let decision = cefBrowser.delegate?.browser(
                    cefBrowser, decidePolicyForDownload: download, suggestedName: name
                ) ?? .allow(destination: nil)
                if let destination = CefDownloadDestination.resolve(decision: decision, suggestedName: name) {
                    CefStringUtil.withCefString(destination.path) { path in
                        callback.pointee.cont?(callback, path, 0)
                    }
                }
                // .deny: return 1 without executing the callback — CEF
                // cancels the download when the callback is destroyed
                // unexecuted.
                return 1
            }
        }
        download.pointee.on_download_updated = { handlerSelf, browser, item, callback in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(callback.map(UnsafeMutableRawPointer.init))  // cancel/pause/resume unused
            guard let item else { return }
            let download = CefDownload(item: item)
            cefRelease(UnsafeMutableRawPointer(item))
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated {
                guard let cefBrowser = client.browser else { return }
                cefBrowser.delegate?.browser(cefBrowser, downloadDidProgress: download)
            }
        }
        downloadPointer = download

        makeExtendedHandlers()

        // OSR browsers get a render handler; windowed browsers leave
        // renderPointer nil so get_render_handler returns NULL.
        if osrHost != nil {
            makeRenderHandler()
        }

        let client = cefAllocate(cef_client_t.self, owner: self)
        client.pointee.get_render_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.renderPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
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
        client.pointee.get_download_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.downloadPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_jsdialog_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.jsDialogPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_context_menu_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.contextMenuPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_permission_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.permissionPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_request_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.requestPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_keyboard_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.keyboardPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
        client.pointee.get_focus_handler = { clientSelf in
            guard let me = BrowserClient.owner(clientSelf.map(UnsafeMutableRawPointer.init)),
                  let handler = me.focusPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(handler))
            return handler
        }
        clientPointer = client
        return client
    }

    /// Helper: resolves the owning client and its attached browser+delegate
    /// on the main actor, calling `body` only when both exist.
    nonisolated static func withBrowser<R: Sendable>(
        _ handlerSelf: UnsafeMutableRawPointer?,
        default fallback: R,
        _ body: @MainActor (BrowserClient, CefBrowser) -> R
    ) -> R {
        guard let client = BrowserClient.owner(handlerSelf) else { return fallback }
        return MainActor.assumeIsolated {
            guard let browser = client.browser else { return fallback }
            return body(client, browser)
        }
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

    func setLastContextMenuParams(_ params: CefContextMenuParams) {
        lastContextMenuParams = params
    }

    var currentContextMenuParams: CefContextMenuParams {
        lastContextMenuParams
    }

    private func updateLoadingState(isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        if let browser {
            browser.applyLoadingState(isLoading: isLoading, canGoBack: canGoBack, canGoForward: canGoForward)
        } else {
            pendingLoadingState = (isLoading, canGoBack, canGoForward)
        }
    }
}
