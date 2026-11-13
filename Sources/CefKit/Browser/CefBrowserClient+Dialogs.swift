import os
import AppKit
import CCef
import Foundation
import CefBase

extension CefBrowserClient {
    // MARK: Downloads

    func makeDownloadHandler() -> UnsafeMutablePointer<cef_download_handler_t> {
        let h = cefAllocate(cef_download_handler_t.self, owner: self)
        // CEF treats a missing callback as "no": without this, every link or
        // navigation that turns into a download is cancelled before
        // on_before_download, where the delegate or the profile's policy
        // decides.
        h.pointee.can_download = { _, browser, _, _ in
            cefRelease(browser)
            return 1
        }
        h.pointee.on_before_download = { s, browser, item, suggestedName, callback in
            var snapshot = item.map { CefDownload.Snapshot(item: $0) }
            cefRelease(item)
            let name = CefStringUtil.string(from: suggestedName)
            if !name.isEmpty { snapshot?.suggestedFilename = name }
            let callback = CefRef(adopting: callback)
            guard let snapshot, let callback else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                // Chromium may have reported the download already, without
                // the name it suggests here.
                let download = b.effectiveProfile.trackDownload(snapshot, startedBy: b)
                download.apply(snapshot)
                b.decide(.browser) { delegate -> URL? in
                    let decision = await delegate.browser(b, decideDestinationFor: download)
                    switch CefDownloadDestination.resolve(decision, suggestedFilename: download.suggestedFilename) {
                    case .file(let file): return file
                    case .cancel: return nil
                    case .ask: return await CefDownloadPresenter.present(download, in: b.hostWindow)
                    }
                } then: { destination in
                    // Dropping the callback without continuing cancels the download.
                    guard let destination else { return }
                    CefStringUtil.withCefString(destination.path) {
                        callback.pointer.pointee.cont(callback.pointer, $0, 0)
                    }
                }
                return 1
            }
        }
        h.pointee.on_download_updated = { s, browser, item, callback in
            let snapshot = item.map { CefDownload.Snapshot(item: $0) }
            cefRelease(item)
            let control = CefRef(adopting: callback)
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                guard let snapshot else { return }
                b.applyDownload(snapshot, control: control)
            }
        }
        return h
    }
}

extension CefBrowserClient {
    // MARK: JavaScript dialogs

    func makeJSDialogHandler() -> UnsafeMutablePointer<cef_jsdialog_handler_t> {
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
                b.decide(.dialog) { await $0.browser(b, runJavaScriptDialog: dialog) } then: { response in
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
                b.decide(.dialog) { await $0.browser(b, confirmLeavingPage: isReload != 0) } then: { leave in
                    // Staying on the page also stays a quit in progress.
                    if !leave { CefRuntime.shared.cancelTermination() }
                    callback.pointer.pointee.cont(callback.pointer, leave ? 1 : 0, nil)
                }
                return 1
            }
        }
        // Navigation and the like: dialogs still open are moot, and CEF
        // has dropped their callbacks.
        h.pointee.on_reset_dialog_state = { s, browser in
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.cancelDecisions { $0 == .dialog } }
        }
        return h
    }
}

extension CefBrowserClient {
    // MARK: Permissions

    func makePermissionHandler() -> UnsafeMutablePointer<cef_permission_handler_t> {
        let h = cefAllocate(cef_permission_handler_t.self, owner: self)
        h.pointee.on_request_media_access_permission = { s, browser, frame, origin, requested, callback in
            cefRelease(frame)
            let kinds = CefPermissionRequest.Kinds.fromMediaTypes(requested)
            let request = CefPermissionRequest(kinds: kinds, origin: CefStringUtil.string(from: origin))
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                // Chromium asks before it reads the site settings for media,
                // so stored values answer here, and only the rest is asked.
                let stored = b.storedAnswer(to: request)
                let answer = { (granted: CefPermissionRequest.Kinds) in
                    let mask = granted.mediaMask(within: requested)
                    if mask != 0 {
                        callback.pointer.pointee.cont(callback.pointer, mask)
                    } else {
                        callback.pointer.pointee.cancel(callback.pointer)
                    }
                }
                guard !stored.undecided.isEmpty else {
                    answer(stored.granted(after: nil))
                    return 1
                }
                let asked = CefPermissionRequest(kinds: stored.undecided, origin: request.origin)
                b.decide(.page) { await $0.browser(b, decidePermissionFor: asked) } then: { decision in
                    b.remember(decision, for: asked.kinds, origin: asked.origin)
                    answer(stored.granted(after: decision))
                }
                return 1
            }
        }
        h.pointee.on_show_permission_prompt = { s, browser, promptID, origin, requested, callback in
            let request = CefPermissionRequest(
                kinds: CefPermissionRequest.Kinds.fromRequestTypes(requested),
                origin: CefStringUtil.string(from: origin)
            )
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.decide(.permissionPrompt(promptID)) { await $0.browser(b, decidePermissionFor: request) } then: { decision in
                    b.remember(decision, for: request.kinds, origin: request.origin)
                    callback.pointer.pointee.cont(callback.pointer, decision.cefResult)
                }
                return 1
            }
        }
        // Chromium dismissed the prompt itself (navigation, closing), or
        // after our answer, which has then been delivered already.
        h.pointee.on_dismiss_permission_prompt = { s, browser, promptID, _ in
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.cancelDecisions { $0 == .permissionPrompt(promptID) } }
        }
        return h
    }
}
