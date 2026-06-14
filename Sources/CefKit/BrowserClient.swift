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
            handlerSelf, browser, frame, _, targetURL, targetFrameName, targetDisposition,
            userGesture, popupFeatures, _, _, _, _, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(frame.map(UnsafeMutableRawPointer.init))
            guard let client = BrowserClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 0 }
            let url = URL(string: CefStringUtil.string(from: targetURL))
            let frameName = CefStringUtil.string(from: targetFrameName)
            let disposition = CefWindowOpenDisposition(cefValue: targetDisposition)
            let gesture = userGesture != 0
            let features = popupFeatures.map { CefPopupFeatures(raw: $0.pointee) } ?? CefPopupFeatures()
            // Returning non-zero from on_before_popup tells CEF to suppress its
            // own popup. We return 0 ONLY for `.allowNativePopup` (windowed/
            // chrome). Everything else is handled in-process and returns 1, so
            // an OSR browser never gets a render-handler-less popup created.
            return MainActor.assumeIsolated {
                guard let cefBrowser = client.browser else { return 0 }
                let isOSR = client.osrHost != nil
                let request = CefWindowOpenRequest(
                    targetURL: url,
                    frameName: frameName,
                    disposition: disposition,
                    userGesture: gesture,
                    features: features,
                    isSourceOffscreen: isOSR
                )
                let raw = cefBrowser.delegate?.browser(cefBrowser, decideWindowOpenFor: request)
                    ?? CefWindowOpenPolicy.defaultAction(for: request)
                // Defense in depth: re-apply the OSR downgrade even if a
                // delegate returned `.allowNativePopup` for an OSR browser.
                switch CefWindowOpenPolicy.resolve(raw, for: request) {
                case .allowNativePopup:
                    return 0  // let CEF create the native popup
                case .openInCurrentBrowser:
                    if let url { cefBrowser.load(url) }
                    return 1
                case .deny, .handled:
                    return 1  // app handled it (or denied); block CEF's popup
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

// MARK: - Extended handlers (JS dialog, context menu, permission, request, keyboard, focus)

/// Builds the JS-dialog, context-menu, permission, request, keyboard, and
/// focus handler structs. Same capi refcount discipline: browser/frame
/// arguments arrive +1 and are released; callback objects are either consumed
/// by a wrapper that owns the +1 or released here.
extension BrowserClient {
    func makeExtendedHandlers() {
        makeJSDialogHandler()
        makeContextMenuHandler()
        makePermissionHandler()
        makeRequestHandler()
        makeKeyboardHandler()
        makeFocusHandler()
    }

    // MARK: JS dialogs

    private func makeJSDialogHandler() {
        let handler = cefAllocate(cef_jsdialog_handler_t.self, owner: self)
        handler.pointee.on_jsdialog = {
            handlerSelf, browser, originURL, dialogType, messageText, defaultPromptText, callback, suppressMessage in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let callback else {
                suppressMessage?.pointee = 0
                return 0
            }
            let dialog = CefJSDialog(
                kind: CefJSDialogKind(cefValue: dialogType),
                message: CefStringUtil.string(from: messageText),
                defaultPromptText: CefStringUtil.string(from: defaultPromptText),
                origin: CefStringUtil.string(from: originURL)
            )
            let wrapper = CefJSDialogCallback(raw: callback)  // owns the +1
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { _, cefBrowser in
                if cefBrowser.delegate?.browser(cefBrowser, runJSDialog: dialog, callback: wrapper) == true {
                    return 1  // app presents + resolves the callback itself
                }
                CefJSDialogPresenter.present(dialog, callback: wrapper)
                return 1  // we handled it natively (callback resolved synchronously)
            }
        }
        handler.pointee.on_before_unload_dialog = { handlerSelf, browser, messageText, isReload, callback in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let callback else { return 0 }
            let message = CefStringUtil.string(from: messageText)
            let reload = isReload != 0
            let wrapper = CefJSDialogCallback(raw: callback)
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { _, cefBrowser in
                if cefBrowser.delegate?.browser(cefBrowser, runBeforeUnloadDialog: message, isReload: reload, callback: wrapper) == true {
                    return 1
                }
                CefJSDialogPresenter.presentBeforeUnload(message: message, isReload: reload, callback: wrapper)
                return 1
            }
        }
        handler.pointee.on_reset_dialog_state = { _, browser in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
        }
        handler.pointee.on_dialog_closed = { _, browser in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
        }
        jsDialogPointer = handler
    }

    // MARK: Context menu

    private func makeContextMenuHandler() {
        let handler = cefAllocate(cef_context_menu_handler_t.self, owner: self)
        handler.pointee.on_before_context_menu = { handlerSelf, browser, frame, params, model in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(frame.map(UnsafeMutableRawPointer.init))
            guard let params, let model else { return }
            let snapshot = CefContextMenuParams(raw: params)
            let menu = CefMenuModel(raw: model)
            BrowserClientCallbacks.run(handlerSelf, default: ()) { client, cefBrowser in
                client.setLastContextMenuParams(snapshot)
                cefBrowser.delegate?.browser(cefBrowser, configureContextMenu: menu, params: snapshot)
            }
        }
        handler.pointee.run_context_menu = { handlerSelf, browser, frame, params, model, callback in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(frame.map(UnsafeMutableRawPointer.init))
            guard let model, let callback else {
                cefRelease(model.map(UnsafeMutableRawPointer.init))
                cefRelease(callback.map(UnsafeMutableRawPointer.init))
                return 0
            }
            // Only intercept for OSR browsers (windowless has no CEF window to
            // present the default menu in); windowed browsers fall through to
            // CEF's native menu by returning 0.
            //
            // IMPORTANT: when returning 0, we must NOT touch the |callback|
            // (must not call cont/cancel — those "disconnect" it on CEF's side).
            // CEF treats a disconnected callback paired with a false return as
            // an error and force-sets is_handled=true, which suppresses the
            // native menu entirely. We simply drop our +1 ref on it.
            let isOSR = BrowserClientCallbacks.run(handlerSelf, default: false) { client, _ in
                client.osrHost != nil
            }
            if !isOSR {
                cefRelease(UnsafeMutableRawPointer(callback))
                return 0
            }
            let menu = CefMenuModel(raw: model)
            let viewPoint = params.map { CGPoint(x: CGFloat($0.pointee.get_xcoord?($0) ?? 0), y: CGFloat($0.pointee.get_ycoord?($0) ?? 0)) } ?? .zero
            let wrapper = CefRunContextMenuCallback(raw: callback)  // owns the +1
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { client, _ in
                guard let host = client.osrHost else {
                    // Defensive: osrHost vanished between the two checks.
                    wrapper.cancel()
                    return 1
                }
                host.osrRunContextMenu(menu, at: viewPoint, callback: wrapper)
                return 1
            }
        }
        handler.pointee.on_context_menu_command = { handlerSelf, browser, frame, params, commandID, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(frame.map(UnsafeMutableRawPointer.init))
            let snapshot = params.map { CefContextMenuParams(raw: $0) }
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { client, cefBrowser in
                let p = snapshot ?? client.currentContextMenuParams
                return (cefBrowser.delegate?.browser(cefBrowser, contextMenuCommand: Int(commandID), params: p) ?? false) ? 1 : 0
            }
        }
        handler.pointee.on_context_menu_dismissed = { handlerSelf, browser, frame in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(frame.map(UnsafeMutableRawPointer.init))
            BrowserClientCallbacks.run(handlerSelf, default: ()) { _, cefBrowser in
                cefBrowser.delegate?.browserContextMenuDidClose(cefBrowser)
            }
        }
        contextMenuPointer = handler
    }

    // MARK: Permissions

    private func makePermissionHandler() {
        let handler = cefAllocate(cef_permission_handler_t.self, owner: self)
        handler.pointee.on_request_media_access_permission = {
            handlerSelf, browser, frame, requestingOrigin, requestedPermissions, callback in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(frame.map(UnsafeMutableRawPointer.init))
            guard let callback else { return 0 }
            let origin = CefStringUtil.string(from: requestingOrigin)
            let kinds = CefPermissionKind.fromMediaTypes(requestedPermissions)
            let request = CefPermissionRequest(kinds: kinds, origin: origin)
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { _, cefBrowser in
                let decision = cefBrowser.delegate?.browser(cefBrowser, requestsPermission: request) ?? .deny
                switch decision {
                case .allow:
                    callback.pointee.cont?(callback, kinds.mediaMask(within: requestedPermissions))
                case .deny, .dismiss:
                    callback.pointee.cancel?(callback)
                }
                cefRelease(UnsafeMutableRawPointer(callback))
                return 1
            }
        }
        handler.pointee.on_show_permission_prompt = {
            handlerSelf, browser, _, requestingOrigin, requestedPermissions, callback in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let callback else { return 0 }
            let origin = CefStringUtil.string(from: requestingOrigin)
            let kinds = CefPermissionKind.fromRequestTypes(requestedPermissions)
            let request = CefPermissionRequest(kinds: kinds, origin: origin)
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { _, cefBrowser in
                let decision = cefBrowser.delegate?.browser(cefBrowser, requestsPermission: request) ?? .deny
                callback.pointee.cont?(callback, decision.cefResult)
                cefRelease(UnsafeMutableRawPointer(callback))
                return 1
            }
        }
        handler.pointee.on_dismiss_permission_prompt = { _, browser, _, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
        }
        permissionPointer = handler
    }

    // MARK: Navigation / requests

    private func makeRequestHandler() {
        let handler = cefAllocate(cef_request_handler_t.self, owner: self)
        handler.pointee.on_before_browse = { handlerSelf, browser, frame, request, userGesture, isRedirect in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(frame.map(UnsafeMutableRawPointer.init))
            var urlString = ""
            if let request {
                urlString = CefStringUtil.takingUserFree(request.pointee.get_url?(request)) ?? ""
                cefRelease(UnsafeMutableRawPointer(request))
            }
            let url = URL(string: urlString)
            let gesture = userGesture != 0
            let redirect = isRedirect != 0
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { _, cefBrowser in
                let decision = cefBrowser.delegate?.browser(
                    cefBrowser, decidePolicyForNavigation: url, isRedirect: redirect, userGesture: gesture
                ) ?? .allow
                return decision == .cancel ? 1 : 0
            }
        }
        handler.pointee.on_open_urlfrom_tab = { handlerSelf, browser, frame, targetURL, _, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(frame.map(UnsafeMutableRawPointer.init))
            let url = URL(string: CefStringUtil.string(from: targetURL))
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { _, cefBrowser in
                (cefBrowser.delegate?.browser(cefBrowser, didRequestNewTab: url) ?? false) ? 1 : 0
            }
        }
        handler.pointee.on_certificate_error = { handlerSelf, browser, certError, requestURL, sslInfo, callback in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            cefRelease(sslInfo.map(UnsafeMutableRawPointer.init))
            let url = URL(string: CefStringUtil.string(from: requestURL))
            let code = Int(certError.rawValue)
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { _, cefBrowser in
                let override = cefBrowser.delegate?.browser(cefBrowser, didEncounterCertificateError: url, errorCode: code) ?? false
                if override, let callback {
                    callback.pointee.cont?(callback)
                    cefRelease(UnsafeMutableRawPointer(callback))
                    return 1
                }
                // Cancel: returning 0 cancels immediately; release the callback.
                cefRelease(callback.map(UnsafeMutableRawPointer.init))
                return 0
            }
        }
        handler.pointee.get_auth_credentials = {
            handlerSelf, browser, originURL, isProxy, host, port, realm, scheme, callback in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let callback else { return 0 }
            let challenge = CefAuthChallenge(
                origin: CefStringUtil.string(from: originURL),
                isProxy: isProxy != 0,
                host: CefStringUtil.string(from: host),
                port: Int(port),
                realm: CefStringUtil.string(from: realm),
                scheme: CefStringUtil.string(from: scheme)
            )
            let wrapper = CefAuthCallback(raw: callback)  // owns the +1
            // get_auth_credentials is invoked on the IO thread; hop to main.
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    guard let client = cefOwner(BrowserClient.self, handlerSelf.map(UnsafeMutableRawPointer.init)),
                          let cefBrowser = client.browser
                    else {
                        wrapper.cancel()
                        return Int32(0)
                    }
                    if cefBrowser.delegate?.browser(cefBrowser, didReceiveAuthChallenge: challenge, callback: wrapper) == true {
                        return 1
                    }
                    wrapper.cancel()
                    return 0
                }
            }
        }
        handler.pointee.on_render_process_terminated = { handlerSelf, browser, status, errorCode, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            let reason = CefTerminationReason(cefValue: status)
            let code = Int(errorCode)
            BrowserClientCallbacks.run(handlerSelf, default: ()) { _, cefBrowser in
                cefBrowser.delegate?.browser(cefBrowser, renderProcessDidTerminate: reason, errorCode: code)
            }
        }
        // get_resource_request_handler left unset (returns NULL by default) —
        // the custom-scheme path already covers app-served content; per-response
        // interception is intentionally out of scope.
        requestPointer = handler
    }

    // MARK: Keyboard

    private func makeKeyboardHandler() {
        let handler = cefAllocate(cef_keyboard_handler_t.self, owner: self)
        handler.pointee.on_pre_key_event = { handlerSelf, browser, event, _, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let event else { return 0 }
            let keyEvent = CefKeyEvent(raw: event.pointee)
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { _, cefBrowser in
                (cefBrowser.delegate?.browser(cefBrowser, handleKeyEvent: keyEvent, isBeforePage: true) ?? false) ? 1 : 0
            }
        }
        handler.pointee.on_key_event = { handlerSelf, browser, event, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let event else { return 0 }
            let keyEvent = CefKeyEvent(raw: event.pointee)
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { _, cefBrowser in
                (cefBrowser.delegate?.browser(cefBrowser, handleKeyEvent: keyEvent, isBeforePage: false) ?? false) ? 1 : 0
            }
        }
        keyboardPointer = handler
    }

    // MARK: Focus

    private func makeFocusHandler() {
        let handler = cefAllocate(cef_focus_handler_t.self, owner: self)
        handler.pointee.on_take_focus = { handlerSelf, browser, next in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            let toNext = next != 0
            BrowserClientCallbacks.run(handlerSelf, default: ()) { _, cefBrowser in
                cefBrowser.delegate?.browser(cefBrowser, willTakeFocusNext: toNext)
            }
        }
        handler.pointee.on_set_focus = { handlerSelf, browser, _ in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            return BrowserClientCallbacks.run(handlerSelf, default: Int32(0)) { _, cefBrowser in
                (cefBrowser.delegate?.browserShouldCancelSetFocus(cefBrowser) ?? false) ? 1 : 0
            }
        }
        handler.pointee.on_got_focus = { handlerSelf, browser in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            BrowserClientCallbacks.run(handlerSelf, default: ()) { _, cefBrowser in
                cefBrowser.delegate?.browserDidGainFocus(cefBrowser)
            }
        }
        focusPointer = handler
    }
}

/// Shared main-actor hop for the extended handlers. CEF invokes these on the
/// UI thread (== the main thread under the external message pump), so this
/// asserts isolation and calls straight through.
enum BrowserClientCallbacks {
    static func run<R: Sendable>(
        _ handlerSelf: UnsafeMutableRawPointer?,
        default fallback: R,
        _ body: @MainActor (BrowserClient, CefBrowser) -> R
    ) -> R {
        guard let client = cefOwner(BrowserClient.self, handlerSelf) else { return fallback }
        return MainActor.assumeIsolated {
            guard let browser = client.browser else { return fallback }
            return body(client, browser)
        }
    }
}
