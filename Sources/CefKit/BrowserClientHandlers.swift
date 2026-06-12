import CCef
import Foundation

/// Builds the JS-dialog, context-menu, permission, request, keyboard, and
/// focus handler structs for ``BrowserClient``. Kept apart from `makeClient()`
/// so the core client graph stays readable. Same capi refcount discipline:
/// browser/frame arguments arrive +1 and are released; callback objects are
/// either consumed by a wrapper that owns the +1 or released here.
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
        // CONTRACT-DEVIATION: get_resource_request_handler left unset (returns
        // NULL by default) — the custom-scheme path already covers app-served
        // content; per-response interception is out of scope for v1.
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
