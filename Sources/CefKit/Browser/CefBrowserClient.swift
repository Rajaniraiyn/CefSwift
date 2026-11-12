import AppKit
import CCef
import Foundation

/// The `cef_client_t` and handler structs behind one or more browsers.
///
/// Each explicitly created ``CefBrowser`` gets its own client; browsers
/// Chromium creates on its own (native popups, DevTools, tabs opened through
/// Chrome's UI) share the client of whatever spawned them. Callbacks
/// therefore resolve their ``CefBrowser`` from the `cef_browser_t` CEF passes
/// in, never from the client alone.
///
/// Handler callbacks arrive on CEF's UI thread — the main thread under the
/// external message pump — except where noted.
@MainActor
final class CefBrowserClient {
    /// The browser this client was created for (nil for the default client).
    private(set) weak var primary: CefBrowser?
    /// The explicitly created browser awaiting `on_after_created`.
    private var pending: CefBrowser?
    /// Set for offscreen browsers; presence enables the render handler.
    weak var offscreenHost: CefOffscreenHost?

    let requestFilter: CefRequestFilter?
    let chromeUI: CefChromeUIConfiguration

    /// Handler structs, readable from any thread (CEF calls the getters from
    /// the IO thread too). Emptied when the last browser closes, which breaks
    /// the struct → owner retain cycle.
    nonisolated let handlers = HandlerTable()
    private var liveBrowserCount = 0
    private let isDefaultClient: Bool

    /// Features of the popup Chromium is about to create, from
    /// `on_before_popup` until the popup's browser is wrapped.
    private var pendingPopupFeatures: CefPopupFeatures?

    /// The most recent context-menu target, for commands that arrive later.
    private var contextMenuTarget = CefContextMenuTarget()

    init(browser: CefBrowser?, requestFilter: CefRequestFilter?, chromeUI: CefChromeUIConfiguration) {
        self.primary = browser
        self.pending = browser
        self.requestFilter = requestFilter
        self.chromeUI = chromeUI
        self.isDefaultClient = browser == nil
    }

    // MARK: Callback plumbing

    /// Resolves the client and the ``CefBrowser`` for a callback, consuming
    /// the callback's reference to `browser`. Runs `body` only when both exist.
    nonisolated static func run<S, R: Sendable>(
        _ handlerSelf: UnsafeMutablePointer<S>?,
        _ browser: UnsafeMutablePointer<cef_browser_t>?,
        default fallback: R,
        _ body: @MainActor (CefBrowserClient, CefBrowser) -> R
    ) -> R {
        defer { cefRelease(browser) }
        guard let browser, let client = cefOwner(CefBrowserClient.self, handlerSelf) else { return fallback }
        // CEF objects are thread-safe refcounted, and this already runs on
        // the main thread; the hop is purely a static-isolation formality.
        nonisolated(unsafe) let raw = browser
        return MainActor.assumeIsolated {
            guard let wrapper = client.wrapper(for: raw) else { return fallback }
            return body(client, wrapper)
        }
    }

    private func wrapper(for browser: UnsafeMutablePointer<cef_browser_t>) -> CefBrowser? {
        let identifier = browser.pointee.get_identifier(browser)
        if let primary, primary.identifier == identifier { return primary }
        return CefRuntime.shared.browser(withIdentifier: identifier)
    }

    /// Returns the `CefBrowser` for a live `cef_browser_t`, wrapping it on
    /// first sight. Takes ownership of the +1 `browser` reference.
    ///
    /// Normally first sight is `on_after_created`; a popup's browser view
    /// can reach a window delegate just before that, and asks here too.
    @discardableResult
    func wrapper(adopting browser: UnsafeMutablePointer<cef_browser_t>) -> CefBrowser {
        if let existing = CefRuntime.shared.browser(withIdentifier: browser.pointee.get_identifier(browser)) {
            cefRelease(browser)
            return existing
        }
        liveBrowserCount += 1
        if let pending {
            self.pending = nil
            pending.adopt(CefRef(adopting: browser))
            return pending
        }
        // Chromium created this one itself: a native popup, a DevTools
        // window, or a tab opened through Chrome's own UI.
        let isPopup = browser.pointee.is_popup(browser) != 0
        let opener = isPopup ? primary : nil
        let wrapper = CefBrowser(adopting: CefRef(adopting: browser), client: self, opener: opener)
        if isPopup {
            wrapper.popupFeatures = pendingPopupFeatures
            pendingPopupFeatures = nil
        }
        if let opener {
            wrapper.delegate = opener.delegate
            opener.delegate?.browser(opener, didOpen: wrapper)
        }
        if !CefRuntime.shared.redirectChromiumTab(wrapper) {
            CefRuntime.shared.onBrowserCreated?(wrapper)
        }
        return wrapper
    }

    private func browserClosed(_ wrapper: CefBrowser) {
        wrapper.handleClosed()
        liveBrowserCount -= 1
        if liveBrowserCount == 0, pending == nil, !isDefaultClient {
            handlers.releaseAll()
        }
    }

    // MARK: Struct construction

    /// Builds the client graph. The returned pointer carries one reference
    /// for the caller, which browser creation hands to CEF.
    func makeClient() -> UnsafeMutablePointer<cef_client_t> {
        handlers.set(makeLifeSpanHandler())
        handlers.set(makeLoadHandler())
        handlers.set(makeDisplayHandler())
        handlers.set(makeDownloadHandler())
        handlers.set(makeJSDialogHandler())
        handlers.set(makeContextMenuHandler())
        handlers.set(makePermissionHandler())
        handlers.set(makeRequestHandler())
        handlers.set(makeKeyboardHandler())
        handlers.set(makeFindHandler())
        handlers.set(makeCommandHandler())
        if offscreenHost != nil {
            handlers.set(makeRenderHandler())
            handlers.set(makeAccessibilityHandler())
        }
        if let requestFilter {
            handlers.set(ResourceRequestFilter(filter: requestFilter).makeHandler())
        }

        let client = cefAllocate(cef_client_t.self, owner: self)
        client.pointee.get_life_span_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_load_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_display_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_download_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_jsdialog_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_context_menu_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_permission_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_request_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_keyboard_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_find_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_command_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_render_handler = { CefBrowserClient.handler($0) }
        return client
    }

    /// The body of every `get_*_handler` callback: the stored handler of the
    /// requested type with a reference for CEF, or NULL. Any thread.
    private nonisolated static func handler<S, H>(_ cefSelf: UnsafeMutablePointer<S>?) -> UnsafeMutablePointer<H>? {
        cefOwner(CefBrowserClient.self, cefSelf)?.handlers.retained(H.self)
    }

    // MARK: Life span

    private func makeLifeSpanHandler() -> UnsafeMutablePointer<cef_life_span_handler_t> {
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
            CefBrowserClient.run(s, browser, default: ()) { client, b in client.browserClosed(b) }
        }
        h.pointee.on_before_popup = {
            s, browser, frame, _, targetURL, targetFrameName, disposition, userGesture, features, _, _, _, _, _ in
            cefRelease(frame)
            let url = URL(string: CefStringUtil.string(from: targetURL))
            let frameName = CefStringUtil.string(from: targetFrameName)
            let popupFeatures = features.map { CefPopupFeatures(raw: $0.pointee) } ?? CefPopupFeatures()
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
                return isHandled ? 1 : 0
            }
        }
        return h
    }

    // MARK: Load

    private func makeLoadHandler() -> UnsafeMutablePointer<cef_load_handler_t> {
        let h = cefAllocate(cef_load_handler_t.self, owner: self)
        h.pointee.on_loading_state_change = { s, browser, isLoading, canGoBack, canGoForward in
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                b.applyLoadingState(isLoading: isLoading != 0, canGoBack: canGoBack != 0, canGoForward: canGoForward != 0)
            }
        }
        h.pointee.on_load_start = { s, browser, frame, _ in
            let isMain = frame.map { $0.pointee.is_main($0) != 0 } ?? false
            let url = frame.flatMap { CefStringUtil.takingUserFree($0.pointee.get_url($0)) }
            cefRelease(frame)
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                if isMain { b.mainFrameDidStartLoading(url.flatMap(URL.init(string:))) }
            }
        }
        h.pointee.on_load_end = { s, browser, frame, httpStatus in
            let isMain = frame.map { $0.pointee.is_main($0) != 0 } ?? false
            cefRelease(frame)
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                guard isMain, !b.isBootstrapping else { return }
                b.delegate?.browser(b, didFinishLoadWithStatus: Int(httpStatus))
            }
        }
        h.pointee.on_load_error = { s, browser, frame, errorCode, errorText, failedURL in
            let isMain = frame.map { $0.pointee.is_main($0) != 0 } ?? false
            cefRelease(frame)
            let error = CefLoadError(
                code: Int(errorCode.rawValue),
                message: CefStringUtil.string(from: errorText),
                url: URL(string: CefStringUtil.string(from: failedURL))
            )
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                guard isMain else { return }
                b.mainFrameDidFailLoad(error)
            }
        }
        return h
    }

    // MARK: Display

    private func makeDisplayHandler() -> UnsafeMutablePointer<cef_display_handler_t> {
        let h = cefAllocate(cef_display_handler_t.self, owner: self)
        h.pointee.on_title_change = { s, browser, title in
            let title = CefStringUtil.string(from: title)
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.applyTitle(title) }
        }
        h.pointee.on_address_change = { s, browser, frame, url in
            let isMain = frame.map { $0.pointee.is_main($0) != 0 } ?? false
            cefRelease(frame)
            let url = CefStringUtil.string(from: url)
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                if isMain { b.applyURL(url) }
            }
        }
        h.pointee.on_favicon_urlchange = { s, browser, iconURLs in
            let urls = cefStrings(from: iconURLs).compactMap(URL.init(string:))
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.applyFavicon(urls) }
        }
        h.pointee.on_fullscreen_mode_change = { s, browser, fullscreen in
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.applyFullscreen(fullscreen != 0) }
        }
        h.pointee.on_loading_progress_change = { s, browser, progress in
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.applyProgress(progress) }
        }
        h.pointee.on_status_message = { s, browser, value in
            let text = CefStringUtil.string(from: value)
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.applyStatusText(text) }
        }
        h.pointee.on_console_message = { s, browser, level, message, source, line in
            let entry = CefConsoleMessage(
                level: CefLogSeverity(cefValue: level),
                text: CefStringUtil.string(from: message),
                source: CefStringUtil.string(from: source),
                line: Int(line)
            )
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.delegate?.browser(b, didLog: entry) }
            return 0  // keep Chromium's own logging
        }
        h.pointee.on_cursor_change = { s, browser, _, type, _ in
            let cursor = CefCursorType(cefValue: type)
            // Windowed browsers apply the cursor themselves; offscreen ones
            // have no window, so the host does it.
            CefBrowserClient.run(s, browser, default: ()) { client, _ in client.offscreenHost?.offscreenDidChangeCursor(cursor) }
            return 0
        }
        return h
    }

    // MARK: Downloads

    private func makeDownloadHandler() -> UnsafeMutablePointer<cef_download_handler_t> {
        let h = cefAllocate(cef_download_handler_t.self, owner: self)
        // CEF treats a missing callback as "no": without this, every link or
        // navigation that turns into a download is cancelled before
        // on_before_download, where the delegate decides.
        h.pointee.can_download = { _, browser, _, _ in
            cefRelease(browser)
            return 1
        }
        h.pointee.on_before_download = { s, browser, item, suggestedName, callback in
            let download = item.map { CefDownload(item: $0) }
            cefRelease(item)
            let name = CefStringUtil.string(from: suggestedName)
            guard let download, let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.decide { await $0.browser(b, decideDestinationFor: download, suggestedName: name) } then: { decision in
                    // Dropping the callback without continuing cancels the download.
                    guard let destination = CefDownloadDestination.resolve(decision: decision, suggestedName: name)
                    else { return }
                    CefStringUtil.withCefString(destination.path) {
                        callback.pointer.pointee.cont(callback.pointer, $0, 0)
                    }
                }
                return 1
            }
        }
        h.pointee.on_download_updated = { s, browser, item, callback in
            let download = item.map { CefDownload(item: $0) }
            cefRelease(item)
            let control = CefRef(adopting: callback)
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                guard let download else { return }
                b.applyDownload(download, control: control)
            }
        }
        return h
    }

    // MARK: JavaScript dialogs

    private func makeJSDialogHandler() -> UnsafeMutablePointer<cef_jsdialog_handler_t> {
        let h = cefAllocate(cef_jsdialog_handler_t.self, owner: self)
        h.pointee.on_jsdialog = { s, browser, originURL, dialogType, message, defaultPrompt, callback, _ in
            let dialog = CefJavaScriptDialog(
                kind: CefJavaScriptDialog.Kind(cefValue: dialogType),
                message: CefStringUtil.string(from: message),
                defaultPromptText: CefStringUtil.string(from: defaultPrompt),
                origin: CefStringUtil.string(from: originURL)
            )
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.decide { await $0.browser(b, runJavaScriptDialog: dialog) } then: { response in
                    switch response {
                    case .accept(let text):
                        CefStringUtil.withCefString(text) { callback.pointer.pointee.cont(callback.pointer, 1, $0) }
                    case .dismiss:
                        callback.pointer.pointee.cont(callback.pointer, 0, nil)
                    }
                }
                return 1
            }
        }
        h.pointee.on_before_unload_dialog = { s, browser, _, isReload, callback in
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.decide { await $0.browser(b, confirmLeavingPage: isReload != 0) } then: { leave in
                    // Staying on the page also stays a quit in progress.
                    if !leave { CefRuntime.shared.cancelTermination() }
                    callback.pointer.pointee.cont(callback.pointer, leave ? 1 : 0, nil)
                }
                return 1
            }
        }
        return h
    }

    // MARK: Context menu

    private func makeContextMenuHandler() -> UnsafeMutablePointer<cef_context_menu_handler_t> {
        let h = cefAllocate(cef_context_menu_handler_t.self, owner: self)
        h.pointee.on_before_context_menu = { s, browser, frame, params, model in
            cefRelease(frame)
            defer {
                cefRelease(params)
                cefRelease(model)
            }
            guard let params, let model else {
                cefRelease(browser)
                return
            }
            let target = CefContextMenuTarget(raw: params)
            let menu = CefMenuModel(raw: model)
            CefBrowserClient.run(s, browser, default: ()) { client, b in
                client.contextMenuTarget = target
                b.options.contextMenu.apply(to: menu, for: target)
                b.delegate?.browser(b, configureContextMenu: menu, for: target)
            }
        }
        h.pointee.run_context_menu = { s, browser, frame, params, model, callback in
            cefRelease(frame)
            let point = params.map { CGPoint(x: CGFloat($0.pointee.get_xcoord($0)), y: CGFloat($0.pointee.get_ycoord($0))) }
            cefRelease(params)
            defer { cefRelease(model) }
            guard let model, let callback else {
                cefRelease(browser)
                cefRelease(callback)
                return 0
            }
            // Windowed browsers show Chromium's own menu (return 0 and leave
            // the callback untouched — cancelling it would suppress the menu).
            // Offscreen browsers have no window to show it in, so the host
            // presents a native menu from a snapshot of the model.
            let handled = CefBrowserClient.run(s, browser, default: false) { client, _ in
                guard let host = client.offscreenHost else { return false }
                host.offscreenShowContextMenu(
                    CefMenuModel(raw: model), at: point ?? .zero,
                    completion: CefContextMenuCompletion(raw: callback))
                return true
            }
            if !handled { cefRelease(callback) }
            return handled ? 1 : 0
        }
        h.pointee.on_context_menu_command = { s, browser, frame, params, commandID, _ in
            cefRelease(frame)
            let snapshot = params.map { CefContextMenuTarget(raw: $0) }
            cefRelease(params)
            return CefBrowserClient.run(s, browser, default: 0) { client, b in
                let target = snapshot ?? client.contextMenuTarget
                if b.options.contextMenu.perform(commandID: Int(commandID), in: b, for: target) { return 1 }
                return (b.delegate?.browser(b, handleContextMenuCommand: Int(commandID), for: target) ?? false) ? 1 : 0
            }
        }
        return h
    }

    // MARK: Permissions

    private func makePermissionHandler() -> UnsafeMutablePointer<cef_permission_handler_t> {
        let h = cefAllocate(cef_permission_handler_t.self, owner: self)
        h.pointee.on_request_media_access_permission = { s, browser, frame, origin, requested, callback in
            cefRelease(frame)
            let kinds = CefPermissionKind.fromMediaTypes(requested)
            let request = CefPermissionRequest(kinds: kinds, origin: CefStringUtil.string(from: origin))
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.decide { await $0.browser(b, decidePermissionFor: request) } then: { decision in
                    if decision == .allow {
                        callback.pointer.pointee.cont(callback.pointer, kinds.mediaMask(within: requested))
                    } else {
                        callback.pointer.pointee.cancel(callback.pointer)
                    }
                }
                return 1
            }
        }
        h.pointee.on_show_permission_prompt = { s, browser, _, origin, requested, callback in
            let request = CefPermissionRequest(
                kinds: CefPermissionKind.fromRequestTypes(requested),
                origin: CefStringUtil.string(from: origin)
            )
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.decide { await $0.browser(b, decidePermissionFor: request) } then: { decision in
                    callback.pointer.pointee.cont(callback.pointer, decision.cefResult)
                }
                return 1
            }
        }
        return h
    }

    // MARK: Navigation and requests

    private func makeRequestHandler() -> UnsafeMutablePointer<cef_request_handler_t> {
        let h = cefAllocate(cef_request_handler_t.self, owner: self)
        h.pointee.on_before_browse = { s, browser, frame, request, userGesture, isRedirect in
            let isMain = frame.map { $0.pointee.is_main($0) != 0 } ?? false
            cefRelease(frame)
            let url = request.flatMap { CefStringUtil.takingUserFree($0.pointee.get_url($0)) }
            cefRelease(request)
            guard isMain else {
                cefRelease(browser)
                return 0
            }
            let action = CefNavigationAction(
                url: url.flatMap(URL.init(string:)), isRedirect: isRedirect != 0, hasUserGesture: userGesture != 0)
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                guard let delegate = b.delegate, !b.isBootstrapping else { return 0 }
                return delegate.browser(b, decidePolicyFor: action) == .cancel ? 1 : 0
            }
        }
        h.pointee.on_open_urlfrom_tab = { s, browser, frame, targetURL, disposition, userGesture in
            cefRelease(frame)
            let url = URL(string: CefStringUtil.string(from: targetURL))
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                let request = CefWindowOpenRequest(
                    targetURL: url,
                    disposition: CefWindowOpenDisposition(cefValue: disposition),
                    hasUserGesture: userGesture != 0,
                    isSourceOffscreen: b.isOffscreen,
                    isSourceChromeStyle: b.isChromeStyle
                )
                return b.route(request) ? 1 : 0
            }
        }
        h.pointee.on_certificate_error = { s, browser, certError, requestURL, sslInfo, callback in
            cefRelease(sslInfo)
            let error = CefCertificateError(
                code: Int(certError.rawValue), url: URL(string: CefStringUtil.string(from: requestURL)))
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.decide { await $0.browser(b, shouldProceedDespite: error) } then: { proceed in
                    if proceed {
                        callback.pointer.pointee.cont(callback.pointer)
                    } else {
                        callback.pointer.pointee.cancel(callback.pointer)
                    }
                }
                return 1
            }
        }
        // IO thread. The decision is made on the main actor and delivered
        // through the callback, which CEF accepts from any thread.
        h.pointee.get_auth_credentials = { s, browser, originURL, isProxy, host, port, realm, scheme, callback in
            let challenge = CefAuthenticationChallenge(
                origin: CefStringUtil.string(from: originURL),
                isProxy: isProxy != 0,
                host: CefStringUtil.string(from: host),
                port: Int(port),
                realm: CefStringUtil.string(from: realm),
                scheme: CefStringUtil.string(from: scheme)
            )
            let identifier = browser.map { $0.pointee.get_identifier($0) }
            cefRelease(browser)
            guard let identifier, let callback = CefRef(adopting: callback) else { return 0 }
            Task { @MainActor in
                guard let b = CefRuntime.shared.browser(withIdentifier: identifier) else {
                    callback.pointer.pointee.cancel(callback.pointer)
                    return
                }
                let delegate = b.delegate ?? CefDefaultBrowserDelegate.shared
                if let credential = await delegate.browser(b, credentialFor: challenge) {
                    CefStringUtil.withCefString(credential.username) { user in
                        CefStringUtil.withCefString(credential.password) { password in
                            callback.pointer.pointee.cont(callback.pointer, user, password)
                        }
                    }
                } else {
                    callback.pointer.pointee.cancel(callback.pointer)
                }
            }
            return 1
        }
        h.pointee.on_render_process_terminated = { s, browser, status, _, _ in
            let reason = CefTerminationReason(cefValue: status)
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                b.delegate?.browser(b, renderProcessDidTerminate: reason)
            }
        }
        // IO thread.
        h.pointee.get_resource_request_handler = { s, browser, frame, request, _, _, _, _ in
            cefRelease(browser)
            cefRelease(frame)
            cefRelease(request)
            return cefOwner(CefBrowserClient.self, s)?.handlers.retained(cef_resource_request_handler_t.self)
        }
        return h
    }

    // MARK: Keyboard

    private func makeKeyboardHandler() -> UnsafeMutablePointer<cef_keyboard_handler_t> {
        let h = cefAllocate(cef_keyboard_handler_t.self, owner: self)
        h.pointee.on_pre_key_event = { s, browser, event, _, _ in
            let keyEvent = event.map { CefKeyEvent(raw: $0.pointee) }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                guard let keyEvent, let delegate = b.delegate else { return 0 }
                return delegate.browser(b, handleKeyEvent: keyEvent, isBeforePage: true) ? 1 : 0
            }
        }
        h.pointee.on_key_event = { s, browser, event, _ in
            let keyEvent = event.map { CefKeyEvent(raw: $0.pointee) }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                guard let keyEvent, let delegate = b.delegate else { return 0 }
                return delegate.browser(b, handleKeyEvent: keyEvent, isBeforePage: false) ? 1 : 0
            }
        }
        return h
    }

    // MARK: Find

    private func makeFindHandler() -> UnsafeMutablePointer<cef_find_handler_t> {
        let h = cefAllocate(cef_find_handler_t.self, owner: self)
        h.pointee.on_find_result = { s, browser, _, count, _, activeMatch, finalUpdate in
            let result = CefFindResult(
                matchCount: Int(count), activeMatchIndex: Int(activeMatch), isFinal: finalUpdate != 0)
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.applyFindResult(result) }
        }
        return h
    }

    // MARK: Chrome commands and UI

    private func makeCommandHandler() -> UnsafeMutablePointer<cef_command_handler_t> {
        let h = cefAllocate(cef_command_handler_t.self, owner: self)
        h.pointee.on_chrome_command = { s, browser, commandID, disposition in
            CefBrowserClient.run(s, browser, default: 0) { _, b in
                let command = CefChromeCommand(rawValue: Int(commandID))
                let handled = b.delegate?.browser(
                    b, handleChromeCommand: command,
                    disposition: CefWindowOpenDisposition(cefValue: disposition)) ?? false
                // Chrome runs the command after this returns.
                if !handled, command.isZoomCommand { CefBrowser.refreshZoomLevels() }
                return handled ? 1 : 0
            }
        }
        h.pointee.is_chrome_app_menu_item_visible = { s, browser, commandID in
            CefBrowserClient.run(s, browser, default: 1) { client, _ in
                client.chromeUI.hiddenAppMenuCommands.contains(CefChromeCommand(rawValue: Int(commandID))) ? 0 : 1
            }
        }
        h.pointee.is_chrome_app_menu_item_enabled = { s, browser, commandID in
            CefBrowserClient.run(s, browser, default: 1) { client, _ in
                client.chromeUI.disabledAppMenuCommands.contains(CefChromeCommand(rawValue: Int(commandID))) ? 0 : 1
            }
        }
        h.pointee.is_chrome_page_action_icon_visible = { s, _ in
            guard let client = cefOwner(CefBrowserClient.self, s) else { return 1 }
            return MainActor.assumeIsolated { client.chromeUI.showsPageActionIcons ? 1 : 0 }
        }
        h.pointee.is_chrome_toolbar_button_visible = { s, _ in
            guard let client = cefOwner(CefBrowserClient.self, s) else { return 1 }
            return MainActor.assumeIsolated { client.chromeUI.showsToolbarButtons ? 1 : 0 }
        }
        return h
    }
}

// MARK: - Handler table

/// A thread-safe set of handler structs keyed by type, each held with one
/// reference.
final class HandlerTable: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [ObjectIdentifier: UnsafeMutableRawPointer] = [:]

    /// Stores `handler`, taking over the caller's reference.
    func set<H>(_ handler: UnsafeMutablePointer<H>) {
        let previous = lock.withLock { handlers.updateValue(UnsafeMutableRawPointer(handler), forKey: ObjectIdentifier(H.self)) }
        cefRelease(previous)
    }

    /// The handler of type `H` with an extra reference for the caller.
    func retained<H>(_ type: H.Type) -> UnsafeMutablePointer<H>? {
        lock.withLock {
            guard let raw = handlers[ObjectIdentifier(H.self)] else { return nil }
            cefAddRef(raw)
            return raw.assumingMemoryBound(to: H.self)
        }
    }

    func releaseAll() {
        let released = lock.withLock {
            defer { handlers.removeAll() }
            return Array(handlers.values)
        }
        released.forEach { cefRelease($0) }
    }

    deinit {
        handlers.values.forEach { cefRelease($0) }
    }
}

// MARK: - Resource request filtering

/// A network request about to be sent, as seen by a ``CefRequestFilter``.
public struct CefResourceRequest: Sendable, Equatable {
    public var url: URL?
    public var method: String
    /// The page URL that initiated the request, when known.
    public var referrer: URL?
    /// Whether this is a main-frame or subframe navigation.
    public var isNavigation: Bool
}

/// What a ``CefRequestFilter`` does with a request.
public enum CefResourceRequestAction: Sendable, Equatable {
    /// Send it unchanged.
    case allow
    /// Fail it with `ERR_BLOCKED_BY_CLIENT`.
    case block
    /// Send it to a different URL.
    case redirect(URL)
    /// Send it with these headers added or replaced.
    case setHeaders([String: String])
}

/// Inspects every network request a browser makes — the hook for content
/// blocking, header injection and redirects. Called on Chromium's IO thread,
/// so it must be fast and thread-safe.
public typealias CefRequestFilter = @Sendable (CefResourceRequest) -> CefResourceRequestAction

/// Owner of the `cef_resource_request_handler_t` that applies a filter.
final class ResourceRequestFilter: Sendable {
    let filter: CefRequestFilter

    init(filter: @escaping CefRequestFilter) {
        self.filter = filter
    }

    func makeHandler() -> UnsafeMutablePointer<cef_resource_request_handler_t> {
        let h = cefAllocate(cef_resource_request_handler_t.self, owner: self)
        h.pointee.on_before_resource_load = { s, browser, frame, request, callback in
            cefRelease(browser)
            cefRelease(frame)
            cefRelease(callback)
            defer { cefRelease(request) }
            guard let request, let owner = cefOwner(ResourceRequestFilter.self, s) else { return RV_CONTINUE }
            let resourceType = request.pointee.get_resource_type(request)
            let snapshot = CefResourceRequest(
                url: CefStringUtil.takingUserFree(request.pointee.get_url(request)).flatMap(URL.init(string:)),
                method: CefStringUtil.takingUserFree(request.pointee.get_method(request)) ?? "GET",
                referrer: CefStringUtil.takingUserFree(request.pointee.get_referrer_url(request)).flatMap(URL.init(string:)),
                isNavigation: resourceType == RT_MAIN_FRAME || resourceType == RT_SUB_FRAME
            )
            switch owner.filter(snapshot) {
            case .allow:
                break
            case .block:
                return RV_CANCEL
            case .redirect(let url):
                CefStringUtil.withCefString(url.absoluteString) { request.pointee.set_url(request, $0) }
            case .setHeaders(let headers):
                for (name, value) in headers {
                    CefStringUtil.withCefString(name) { cefName in
                        CefStringUtil.withCefString(value) { cefValue in
                            request.pointee.set_header_by_name(request, cefName, cefValue, 1)
                        }
                    }
                }
            }
            return RV_CONTINUE
        }
        return h
    }
}
