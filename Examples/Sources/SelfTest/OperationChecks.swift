import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import Observation
import os

/// Asynchronous browser operations end exactly once: cancelling a call
/// ends it with `CancellationError`, closing ends it with
/// `browserClosed`, and pending delegate decisions end with their page.
extension SelfTest {
    static func operationChecks() async {
        await cancellationChecks()
        await readinessChecks()
        await sharedRendererChecks()
        await decisionChecks()
        await presenterCancellationChecks()
        await observableSettingChecks()
        await domainLeaseChecks()
    }

    /// Runs `operation` in a task, cancels it once it is suspended, and
    /// returns the error it ended with, or `nil` when it did not end soon.
    static func errorAfterCancelling(_ operation: @escaping @MainActor () async throws -> Void) async -> Error? {
        var outcome: Error??
        let task = Task { @MainActor in
            do {
                try await operation()
                outcome = .some(nil)
            } catch {
                outcome = .some(error)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        guard await waitUntil(timeout: .seconds(2), { outcome != nil }) else { return nil }
        return outcome ?? nil
    }

    static func cancellationChecks() async {
        let pending = CefBrowser(url: URL(string: "selftest://edge/never.html")!)
        let readyError = await errorAfterCancelling { try await pending.ready() }
        check("operations: cancelling ready() ends it with CancellationError", readyError is CancellationError,
              detail: "\(String(describing: readyError))")

        var closedError: Error?
        var ended = false
        Task {
            do { try await pending.ready() } catch { closedError = error }
            ended = true
        }
        try? await Task.sleep(for: .milliseconds(100))
        pending.close()
        check("operations: closing a browser not yet created ends ready() with browserClosed",
              await waitUntil(timeout: .seconds(2)) { ended } && isBrowserClosed(closedError),
              detail: "\(String(describing: closedError))")

        let window = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://edge/one.html")!))
        window.show()
        let browser = window.browser
        _ = await waitUntil { browser.title == "one" }
        let evaluationError = await errorAfterCancelling {
            try await browser.evaluateJavaScript("new Promise(() => {})")
        }
        check("operations: cancelling evaluateJavaScript ends it with CancellationError",
              evaluationError is CancellationError, detail: "\(String(describing: evaluationError))")
        let devToolsError = await errorAfterCancelling {
            try await browser.devTools.send(
                "Runtime.evaluate", ["expression": "new Promise(() => {})", "awaitPromise": true])
        }
        check("operations: cancelling a DevTools call ends it with CancellationError",
              devToolsError is CancellationError, detail: "\(String(describing: devToolsError))")
        await expect("operations: the browser answers after cancelled calls") {
            try await browser.evaluateJavaScript("1 + 1").intValue == 2
        }

        // A call waiting on the page when the browser closes.
        var closeError: Error?
        var closeEnded = false
        Task {
            do { try await browser.evaluateJavaScript("new Promise(() => {})") } catch { closeError = error }
            closeEnded = true
        }
        try? await Task.sleep(for: .milliseconds(200))
        window.close()
        check("operations: closing ends a waiting evaluation with browserClosed",
              await waitUntil(timeout: .seconds(5)) { closeEnded } && isBrowserClosed(closeError),
              detail: "\(String(describing: closeError))")
        _ = await waitUntil { window.isClosed }
    }

    /// `ready()` waits for a browser's set-up, not just its creation.
    static func readinessChecks() async {
        var configuration = CefBrowser.Configuration()
        // Taking WebAuthn over sets the browser up before its first page.
        configuration.passkeys = .disabled
        let window = CefBrowserWindow(
            browser: CefBrowser(url: URL(string: "selftest://edge/ready.html")!, configuration: configuration))
        window.show()
        await expect("operations: ready() returns once the browser's set-up has finished") {
            try await window.browser.ready()
            return !window.browser.isSettingUp
        }
        check("operations: the set-up browser loads its page",
              await waitUntil { window.browser.title == "ready" }, detail: window.browser.title)
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    /// Two browsers in one renderer number their evaluations alike: a
    /// page and its popup share the page's renderer, and their first
    /// evaluations are both request 1.
    static func sharedRendererChecks() async {
        let opener = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://edge/opener.html")!))
        var popups: [CefBrowserWindow] = []
        opener.onPopup = { popup in
            popups.append(popup)
            popup.show()
        }
        opener.show()
        _ = await waitUntil { opener.browser.title == "opener" }
        let renderersBefore = rendererProcesses().count
        _ = try? await opener.browser.evaluateJavaScript(
            "window.open('popup.html', 'p', 'width=300,height=200'); 0", userGesture: true)
        guard await waitUntil(timeout: .seconds(5), { popups.first?.browser.title == "popup" }), let popup = popups.first
        else {
            check("operations: a page and its popup evaluate at once in one renderer", false, detail: "no popup")
            opener.close()
            return
        }
        let shared = rendererProcesses().count == renderersBefore
        async let slow = withTimeout(.seconds(5)) {
            try await opener.browser.evaluateJavaScript("new Promise(r => setTimeout(() => r('opener'), 600))")
        }
        try? await Task.sleep(for: .milliseconds(100))
        async let fast = withTimeout(.seconds(5)) {
            try await popup.browser.evaluateJavaScript("new Promise(r => setTimeout(() => r('popup'), 100))")
        }
        let (first, second) = await (slow, fast)
        check("operations: a page and its popup evaluate at once in one renderer",
              shared && first?.stringValue == "opener" && second?.stringValue == "popup",
              detail: "shared renderer: \(shared); opener \(String(describing: first)), popup \(String(describing: second))")
        popup.close()
        opener.close()
        _ = await waitUntil { opener.isClosed && popup.isClosed }
    }

    /// A default presenter with no window shows a modal alert; cancelling
    /// its task stops that modal session, and a task cancelled before it is
    /// shown shows nothing. The unresponsive-page, dialog and
    /// client-certificate presenters share this presentation.
    static func presenterCancellationChecks() async {
        let browser = CefBrowser()
        var answer: CefUnresponsivePageDecision?
        let task = Task { @MainActor in
            answer = await CefUnresponsivePagePresenter.present(for: browser, in: nil)
        }
        let shown = await waitUntil(timeout: .seconds(5)) { NSApp.modalWindow != nil }
        task.cancel()
        let dismissed = await waitUntil(timeout: .seconds(5)) { answer != nil && NSApp.modalWindow == nil }
        check("operations: cancelling dismisses a presenter's modal alert", shown && dismissed && answer == .wait,
              detail: "shown \(shown), answer \(String(describing: answer)), modal \(String(describing: NSApp.modalWindow))")
        if let modal = NSApp.modalWindow, !dismissed {
            NSApp.stopModal()
            modal.orderOut(nil)
        }

        var leaving: Bool?
        var everShown = false
        let early = Task { @MainActor in
            leaving = await CefDialogPresenter.confirmLeaving(isReload: false, in: nil)
        }
        early.cancel()
        let ended = await waitUntil(timeout: .seconds(5)) {
            everShown = everShown || NSApp.modalWindow != nil
            return leaving != nil
        }
        check("operations: a presenter cancelled before it shows shows nothing",
              ended && !everShown && leaving == false,
              detail: "ended \(ended), shown \(everShown), \(String(describing: leaving))")
        if NSApp.modalWindow != nil { NSApp.stopModal() }
    }

    /// Delegate decisions end with the page they belong to.
    static func decisionChecks() async {
        let delegate = StallingDelegate()
        let browserWindow = CefBrowserWindow(
            browser: CefBrowser(url: URL(string: "selftest://edge/dialog.html")!, delegate: delegate))
        browserWindow.show()
        let browser = browserWindow.browser
        _ = await waitUntil { browser.title == "dialog" }

        // Permission requests in flight when the page goes: a prompt
        // (geolocation), which Chromium dismisses, and a media request.
        if let server = try? await LocalServer.start() {
            browser.load(URL(string: "http://127.0.0.1:\(server.port)/page")!)
            _ = await waitUntil { browser.title == "page" }
            _ = try? await browser.evaluateJavaScript("""
                navigator.geolocation.getCurrentPosition(() => {}, () => {});
                navigator.mediaDevices.getUserMedia({ audio: true }).catch(() => {});
                0
                """, userGesture: true)
            let asked = await waitUntil(timeout: .seconds(5)) { delegate.permissionRequests == 2 }
            browser.load(URL(string: "selftest://edge/gone.html")!)
            let ended = await waitUntil(timeout: .seconds(5)) {
                delegate.cancelled == delegate.permissionRequests && browser.pendingDecisionCount == 0
                    && browser.title == "gone"
            }
            check("operations: leaving a page cancels its pending permission decisions", asked && ended,
                  detail: "asked \(delegate.permissionRequests), cancelled \(delegate.cancelled), pending \(browser.pendingDecisionCount)")
            server.stop()
        }

        // A dialog the delegate is still deciding when the browser closes.
        let cancelledBefore = delegate.cancelled
        browser.executeJavaScript("alert('stay')")
        let shown = await waitUntil(timeout: .seconds(5)) { browser.pendingDecisionCount == 1 }
        browser.close(force: true)
        let dialogEnded = await waitUntil(timeout: .seconds(5)) {
            browser.state == .closed && delegate.cancelled == cancelledBefore + 1 && browser.pendingDecisionCount == 0
        }
        check("operations: closing cancels a pending JavaScript dialog decision", shown && dialogEnded,
              detail: "shown \(shown), cancelled \(delegate.cancelled - cancelledBefore), pending \(browser.pendingDecisionCount)")
        _ = await waitUntil { browserWindow.isClosed }

        // The default sheet goes with its browser, in a window that stays.
        let sheetBrowser = CefBrowser(url: URL(string: "selftest://edge/sheet.html")!)
        let view = hostWindowed(sheetBrowser)
        _ = await waitUntil { sheetBrowser.title == "sheet" }
        sheetBrowser.executeJavaScript("alert('sheet')")
        let sheetShown = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }
        sheetBrowser.close(force: true)
        let sheetGone = await waitUntil(timeout: .seconds(5)) {
            window.attachedSheet == nil && sheetBrowser.state == .closed
        }
        check("operations: closing dismisses the default dialog sheet", sheetShown && sheetGone,
              detail: "shown \(sheetShown), sheet \(String(describing: window.attachedSheet)), state \(sheetBrowser.state)")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        view.removeFromSuperview()
    }

    /// Observation tracks settings CEF reports no changes of.
    static func observableSettingChecks() async {
        let window = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://edge/settings.html")!))
        window.show()
        let browser = window.browser
        _ = await waitUntil { browser.title == "settings" }

        let mutedChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = browser.isAudioMuted } onChange: { mutedChanged.withLock { $0 = true } }
        browser.isAudioMuted = true
        check("operations: isAudioMuted is observable",
              await waitUntil(timeout: .seconds(2)) { mutedChanged.withLock { $0 } } && browser.isAudioMuted)
        browser.isAudioMuted = false

        let devToolsChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = browser.isShowingDevTools } onChange: {
            devToolsChanged.withLock { $0 = true }
        }
        browser.showDevTools()
        check("operations: isShowingDevTools is observable",
              await waitUntil(timeout: .seconds(10)) { devToolsChanged.withLock { $0 } && browser.isShowingDevTools })
        browser.closeDevTools()
        check("operations: isShowingDevTools follows DevTools closing",
              await waitUntil(timeout: .seconds(10)) { !browser.isShowingDevTools })
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    /// One user disabling a domain leaves it on for another.
    static func domainLeaseChecks() async {
        let window = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://edge/lease.html")!))
        window.show()
        let browser = window.browser
        _ = await waitUntil { browser.title == "lease" }
        await expect("operations: a domain stays enabled while another user holds it") {
            try await browser.devTools.send("Runtime.enable")  // one user
            try await browser.devTools.send("Runtime.enable")  // another
            try await browser.devTools.send("Runtime.disable")  // the first is done
            let logged = browser.devTools.events("Runtime.consoleAPICalled")
            browser.executeJavaScript("console.log('still on')")
            let event = await withTimeout(.seconds(5)) { () async -> CefJSON? in for await event in logged { return event }; return nil }
            try await browser.devTools.send("Runtime.disable")
            return event??["args"][0]["value"].stringValue == "still on"
        }
        window.close()
        _ = await waitUntil { window.isClosed }
    }
}

private func isBrowserClosed(_ error: Error?) -> Bool {
    if case .browserClosed? = error as? CefError { return true }
    return false
}

/// Answers nothing until its task is cancelled.
@MainActor
final class StallingDelegate: CefBrowserDelegate {
    private(set) var started = 0
    private(set) var cancelled = 0
    private(set) var permissionRequests = 0

    private func stall() async {
        started += 1
        try? await Task.sleep(for: .seconds(60))
        if Task.isCancelled { cancelled += 1 }
    }

    func browser(_ browser: CefBrowser, runJavaScriptDialog dialog: CefJavaScriptDialog) async -> CefJavaScriptDialogResponse {
        await stall()
        return .accept()
    }

    func browser(_ browser: CefBrowser, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        permissionRequests += 1
        await stall()
        return .allow
    }

    func browser(_ browser: CefBrowser, decidePasskeyFor request: CefPasskeyRequest) async -> CefPasskeyDecision {
        await stall()
        return .createPasskey
    }
}

/// Runs `body`, giving up after `timeout`.
@MainActor
func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @MainActor () async throws -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await body() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        return await group.next() ?? nil
    }
}
