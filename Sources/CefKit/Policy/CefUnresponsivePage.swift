import AppKit
import CCef
import CefBase

/// Who answers when a page stops responding.
public enum CefUnresponsivePagePolicy: Sendable, Equatable {
    /// Chrome-style browsers show Chromium's own “Page Unresponsive”
    /// dialog; other browsers ask
    /// ``CefBrowserDelegate/browserPageIsUnresponsive(_:)``.
    case automatic
    /// Every browser asks the delegate, and Chromium shows no dialog.
    case delegate
}

/// What to do about a page that stopped responding.
public enum CefUnresponsivePageDecision: Sendable, Equatable {
    /// Keep waiting. If the page still does not respond, the delegate is
    /// asked again.
    case wait
    /// End the page's renderer process. The page shows Chromium's crash
    /// page until it is reloaded.
    case terminate
    /// End the page's renderer process and load the page again.
    case reload
}

/// The native sheet behind the default
/// ``CefBrowserDelegate/browserPageIsUnresponsive(_:)``.
@MainActor
public enum CefUnresponsivePagePresenter {
    /// Asks whether to wait for `browser`'s page or reload it, as a sheet
    /// on `window`, or a modal alert without one. Dismisses itself, as
    /// ``CefUnresponsivePageDecision/wait``, when the task is cancelled:
    /// the page started responding again or the browser closed.
    public static func present(for browser: CefBrowser, in window: NSWindow?) async -> CefUnresponsivePageDecision {
        let alert = NSAlert()
        alert.messageText = "Page Unresponsive"
        let site = browser.url?.host() ?? browser.url?.absoluteString
        alert.informativeText = site.map { "\($0) is not responding. You can wait for it or reload it." }
            ?? "The page is not responding. You can wait for it or reload it."
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Force Reload")
        return await withTaskCancellationHandler {
            let response: NSApplication.ModalResponse
            if let window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            return response == .alertSecondButtonReturn ? .reload : .wait
        } onCancel: {
            Task { @MainActor in
                if let sheetParent = alert.window.sheetParent {
                    sheetParent.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
                } else if alert.window.isVisible {
                    NSApp.stopModal(withCode: .alertFirstButtonReturn)
                }
            }
        }
    }
}

extension CefBrowser {
    /// Browsers to reload once their renderer has ended.
    private static var reloadingAfterTermination: Set<ObjectIdentifier> = []

    /// `on_render_process_unresponsive`. Returns whether CefSwift handles
    /// it; `false` lets Chromium show its dialog (Chrome style) or wait.
    func renderProcessBecameUnresponsive(_ callback: CefRef<cef_unresponsive_process_callback_t>) -> Bool {
        isResponsive = false
        if isChromeStyle, options.unresponsivePages == .automatic { return false }
        decide(.unresponsive) { await $0.browserPageIsUnresponsive(self) } then: { [weak self] decision in
            switch decision {
            case .wait:
                callback.pointer.pointee.wait(callback.pointer)
            case .terminate:
                callback.pointer.pointee.terminate(callback.pointer)
            case .reload:
                if let self { Self.reloadingAfterTermination.insert(ObjectIdentifier(self)) }
                callback.pointer.pointee.terminate(callback.pointer)
            }
        }
        return true
    }

    /// `on_render_process_responsive`: a question still open is moot.
    func renderProcessBecameResponsive() {
        isResponsive = true
        cancelDecisions { $0 == .unresponsive }
    }

    /// The renderer ended; a new one starts responsive.
    func renderProcessEnded() {
        isResponsive = true
        cancelDecisions { $0 == .unresponsive }
        if Self.reloadingAfterTermination.remove(ObjectIdentifier(self)) != nil {
            reload()
        }
    }
}

extension CefBrowserClient {
    /// Adds the responsiveness callbacks to the request handler.
    static func installResponsivenessCallbacks(on handler: UnsafeMutablePointer<cef_request_handler_t>) {
        handler.pointee.on_render_process_unresponsive = { s, browser, callback in
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.renderProcessBecameUnresponsive(callback) ? 1 : 0
            }
        }
        handler.pointee.on_render_process_responsive = { s, browser in
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.renderProcessBecameResponsive() }
        }
    }
}

extension CefBrowser {
    /// Sends the page a click and a key press, as the user would, so that
    /// Chromium's hang monitor watches for its answer.
    @_spi(Testing) public func sendTestInput() {
        withHost { host in
            var mouse = cef_mouse_event_t(x: 20, y: 20, modifiers: 0)
            host.pointee.send_mouse_click_event(host, &mouse, MBT_LEFT, 0, 1)
            host.pointee.send_mouse_click_event(host, &mouse, MBT_LEFT, 1, 1)
            for type in [KEYEVENT_RAWKEYDOWN, KEYEVENT_CHAR, KEYEVENT_KEYUP] {
                var event = cef_key_event_t()
                event.size = MemoryLayout<cef_key_event_t>.stride
                event.type = type
                event.windows_key_code = 0x41
                event.character = 0x61
                event.unmodified_character = 0x61
                host.pointee.send_key_event(host, &event)
            }
        }
    }
}
