import os
import AppKit
import CCef
import Foundation
import CefBase

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

    /// A browser Chromium finished creating after its ``CefBrowser`` had
    /// closed. It is closed at once, and forgotten when it has.
    private var abandoned: CefRef<cef_browser_t>?

    /// Features of the popup Chromium is about to create, from
    /// `on_before_popup` until the popup's browser is wrapped.
    var pendingPopupFeatures: CefPopupFeatures?

    /// The most recent context-menu target, for commands that arrive later.
    var contextMenuTarget = CefContextMenuTarget()

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
            guard pending.state != .closed else {
                // Closed while Chromium was creating it.
                abandoned = CefRef(adopting: browser)
                if let host = browser.pointee.get_host(browser) {
                    host.pointee.close_browser(host, 1)
                    cefRelease(host)
                }
                return pending
            }
            pending.adopt(CefRef(adopting: browser))
            return pending
        }
        // Chromium created this one itself: a native popup, a DevTools
        // window, or a tab opened through Chrome's own UI.
        let isPopup = browser.pointee.is_popup(browser) != 0
        let opener = isPopup ? primary : nil
        let profile = opener?.options.profile ?? CefProfile.owning(contextOf: browser)
        let wrapper = CefBrowser(adopting: CefRef(adopting: browser), client: self, opener: opener, profile: profile)
        if isPopup {
            wrapper.popupFeatures = pendingPopupFeatures
            pendingPopupFeatures = nil
        }
        if let opener {
            wrapper.delegate = opener.delegate
            opener.delegate?.browser(opener, didOpen: wrapper)
            CefRuntime.shared.chromiumDidOpenPopup(from: opener)
        }
        if !CefRuntime.shared.routeChromiumBrowser(wrapper, profile: profile) {
            CefRuntime.shared.onBrowserCreated?(wrapper)
        }
        return wrapper
    }

    func browserClosed(_ wrapper: CefBrowser) {
        wrapper.handleClosed()
        lastBrowserMayHaveClosed()
    }

    private func lastBrowserMayHaveClosed() {
        liveBrowserCount -= 1
        if liveBrowserCount == 0, pending == nil, !isDefaultClient {
            handlers.releaseAll()
        }
    }

    /// `on_before_close` for the ``abandoned`` browser. Returns whether
    /// `identifier` was it.
    func abandonedBrowserClosed(_ identifier: Int32) -> Bool {
        guard let abandoned, abandoned.pointer.pointee.get_identifier(abandoned.pointer) == identifier else {
            return false
        }
        self.abandoned = nil
        lastBrowserMayHaveClosed()
        return true
    }

    /// Browser creation failed: Chromium never calls back, so let go of
    /// the browser and of the handlers, whose structs retain this client.
    func cancelCreation() {
        pending = nil
        if liveBrowserCount == 0, !isDefaultClient { handlers.releaseAll() }
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
        handlers.set(makeFrameHandler())
        handlers.set(makeDialogHandler())
        handlers.set(makeFocusHandler())
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
        client.pointee.get_frame_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_dialog_handler = { CefBrowserClient.handler($0) }
        client.pointee.get_focus_handler = { CefBrowserClient.handler($0) }
        client.pointee.on_process_message_received = { s, browser, frame, _, message in
            // Owned before anything can return early.
            let frame = CefRef(adopting: frame)
            guard let owned = CefOwned(message), let frame else {
                cefRelease(browser)
                return 0
            }
            let message = owned.pointer
            // Page-scripting payloads are read in place, by name, without
            // copying the message into Swift values first.
            let name = message.pointee.get_name(message)
            let kind = CefPageScriptingMessage.Kind(name: name)
            cef_string_userfree_utf16_free(name)
            guard let kind else {
                cefRelease(browser)
                return 0
            }
            let received: CefPageScripting.Received
            if kind.isWire {
                guard let payload = CefWirePayload(message: message) else {
                    cefRelease(browser)
                    return 0
                }
                received = .wire(kind, payload)
            } else {
                received = .message(CefProcessMessage(reading: message))
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.pageScripting.received(received, from: frame) ? 1 : 0
            }
        }
        return client
    }

    /// The body of every `get_*_handler` callback: the stored handler of the
    /// requested type with a reference for CEF, or NULL. Any thread.
    private nonisolated static func handler<S, H>(_ cefSelf: UnsafeMutablePointer<S>?) -> UnsafeMutablePointer<H>? {
        cefOwner(CefBrowserClient.self, cefSelf)?.handlers.retained(H.self)
    }

}

// MARK: - Handler table

/// A thread-safe set of handler structs keyed by type, each held with one
/// reference.
final class HandlerTable: Sendable {
    // Pointers to CEF objects, each held with one reference; any thread.
    private let table = OSAllocatedUnfairLock(uncheckedState: [ObjectIdentifier: UnsafeMutableRawPointer]())

    /// Stores `handler`, taking over the caller's reference.
    func set<H>(_ handler: UnsafeMutablePointer<H>) {
        let previous = table.withLockUnchecked { $0.updateValue(UnsafeMutableRawPointer(handler), forKey: ObjectIdentifier(H.self)) }
        cefRelease(previous)
    }

    /// The handler of type `H` with an extra reference for the caller.
    func retained<H>(_ type: H.Type) -> UnsafeMutablePointer<H>? {
        table.withLockUnchecked { handlers in
            guard let raw = handlers[ObjectIdentifier(H.self)] else { return nil }
            cefAddRef(raw)
            return raw.assumingMemoryBound(to: H.self)
        }
    }

    func releaseAll() {
        let released = table.withLockUnchecked { handlers in
            defer { handlers.removeAll() }
            return Array(handlers.values)
        }
        released.forEach { cefRelease($0) }
    }

    deinit {
        table.withLockUnchecked { $0.values.forEach { cefRelease($0) } }
    }
}
