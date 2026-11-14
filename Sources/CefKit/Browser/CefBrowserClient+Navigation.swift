import os
import AppKit
import CCef
import Foundation
import CefBase

extension CefBrowserClient {
    // MARK: Load

    func makeLoadHandler() -> UnsafeMutablePointer<cef_load_handler_t> {
        let h = cefAllocate(cef_load_handler_t.self, owner: self)
        h.pointee.on_loading_state_change = { s, browser, isLoading, canGoBack, canGoForward in
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                b.applyLoadingState(isLoading: isLoading != 0, canGoBack: canGoBack != 0, canGoForward: canGoForward != 0)
                b.trackLoadingStateDidChange(isLoading: isLoading != 0)
                b.refreshConnectionSecurity()
            }
        }
        h.pointee.on_load_start = { s, browser, frame, transition in
            let isMain = frame.map { $0.pointee.is_main($0) != 0 } ?? false
            let url = frame.flatMap { CefStringUtil.takingUserFree($0.pointee.get_url($0)) }
            let id = frame.flatMap { CefStringUtil.takingUserFree($0.pointee.get_identifier($0)) }
            cefRelease(frame)
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                if let id { b.frameDidUpdate(id, url: url.flatMap(URL.init(string:))) }
                if isMain { b.mainFrameDidStartLoading(url.flatMap(URL.init(string:))) }
                if isMain { b.trackMainFrameDidCommit(url: url.flatMap(URL.init(string:)), transition: transition) }
            }
        }
        h.pointee.on_load_end = { s, browser, frame, httpStatus in
            let isMain = frame.map { $0.pointee.is_main($0) != 0 } ?? false
            let url = frame.flatMap { CefStringUtil.takingUserFree($0.pointee.get_url($0)) }
            let id = frame.flatMap { CefStringUtil.takingUserFree($0.pointee.get_identifier($0)) }
            cefRelease(frame)
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                if let id { b.frameDidUpdate(id, url: url.flatMap(URL.init(string:))) }
                if isMain { b.mainFrameDidFinishLoad(status: Int(httpStatus)) }
                if isMain { b.trackMainFrameDidFinish(url: url.flatMap(URL.init(string:)), httpStatus: Int(httpStatus)) }
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
                b.trackMainFrameDidFail(error)
            }
        }
        return h
    }
}

extension CefBrowserClient {
    // MARK: Navigation and requests

    func makeRequestHandler() -> UnsafeMutablePointer<cef_request_handler_t> {
        let h = cefAllocate(cef_request_handler_t.self, owner: self)
        h.pointee.on_before_browse = { s, browser, frame, request, userGesture, isRedirect in
            let frameValue = frame.map(CefFrame.init(reading:))
            cefRelease(frame)
            let url = request.flatMap { CefStringUtil.takingUserFree($0.pointee.get_url($0)) }
            let transition = request.map { $0.pointee.get_transition_type($0) } ?? TT_EXPLICIT
            cefRelease(request)
            guard let frameValue else {
                cefRelease(browser)
                return 0
            }
            let action = CefNavigationAction(
                url: url.flatMap(URL.init(string:)), frame: frameValue, isRedirect: isRedirect != 0,
                hasUserGesture: userGesture != 0, transition: CefNavigationTransition(cefValue: transition.rawValue))
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                let cancels = b.cancelsNavigation(action)
                if action.isMainFrame {
                    b.trackNavigationWillStart(
                        url: action.url, transition: transition, isRedirect: action.isRedirect, isCancelled: cancels)
                }
                return cancels ? 1 : 0
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
            var error = CefCertificateError(
                code: Int(certError.rawValue), url: URL(string: CefStringUtil.string(from: requestURL)))
            if let sslInfo {
                error.status = CefCertificateStatus(rawValue: UInt32(sslInfo.pointee.get_cert_status(sslInfo).rawValue))
                if let x509 = sslInfo.pointee.get_x509_certificate(sslInfo) {
                    error.certificate = CefCertificate(borrowing: x509)
                    cefRelease(x509)
                }
                cefRelease(sslInfo)
            }
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.decide(.page) { await $0.browser(b, shouldProceedDespite: error) } then: { proceed in
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
                url: URL(string: CefStringUtil.string(from: originURL)),
                isProxy: isProxy != 0,
                host: CefStringUtil.string(from: host),
                port: Int(port),
                realm: CefStringUtil.string(from: realm),
                scheme: CefStringUtil.string(from: scheme)
            )
            // No closures here: one written in this main-actor method is
            // main-actor isolated, and traps on the IO thread.
            let identifier: Int32? = if let browser { browser.pointee.get_identifier(browser) } else { nil }
            cefRelease(browser)
            let callback = CefRef(adopting: callback)
            guard let identifier, let callback else { return 0 }
            // A decision of the page: it ends, and the default sheet
            // dismisses itself, when the browser navigates or closes.
            // Releasing the callback unanswered cancels the sign-in.
            Task { @MainActor in
                guard let b = CefRuntime.shared.browser(withIdentifier: identifier) else {
                    callback.pointer.pointee.cancel(callback.pointer)
                    return
                }
                b.decide(.page) { await $0.browser(b, credentialFor: challenge) } then: { credential in
                    guard let credential else {
                        callback.pointer.pointee.cancel(callback.pointer)
                        return
                    }
                    CefStringUtil.withCefString(credential.username) { user in
                        CefStringUtil.withCefString(credential.password) { password in
                            callback.pointer.pointee.cont(callback.pointer, user, password)
                        }
                    }
                }
            }
            return 1
        }
        h.pointee.on_render_process_terminated = { s, browser, status, _, _ in
            let reason = CefTerminationReason(cefValue: status)
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                b.trackRenderProcessDidTerminate(reason)
                b.renderProcessDidTerminate(reason)
            }
        }
        Self.installResponsivenessCallbacks(on: h)
        Self.installClientCertificateCallback(on: h)
        // IO thread. A page without a filter of its own returns no handler,
        // so its profile's request context handler decides its requests.
        h.pointee.get_resource_request_handler = { s, browser, frame, request, isNavigation, _, initiator, _ in
            defer {
                cefRelease(browser)
                cefRelease(frame)
                cefRelease(request)
            }
            guard let client = cefOwner(CefBrowserClient.self, s) else { return nil }
            switch client.requestFiltering {
            case .profile:
                return nil
            case .page(let filter):
                return CefResourceRequestHandlers.handler(
                    filter: filter, browser: browser, request: request, isNavigation: isNavigation != 0,
                    initiator: initiator)
            case .unfiltered:
                return CefResourceRequestHandlers.unfilteredHandler()
            }
        }
        return h
    }
}
