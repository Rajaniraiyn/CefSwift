import AppKit
@_spi(Testing) import CefKit
import CefPasskeys
import CefSwiftUI
import Observation
import os

/// Asynchronous page operations end exactly once: cancelling a call
/// ends it with `CancellationError`, closing ends it with
/// `pageClosed`, and pending delegate decisions end with their page.
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
        let pending = CefPage(url: URL(string: "selftest://edge/never.html")!)
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
        check("operations: closing a browser not yet created ends ready() with pageClosed",
              await waitUntil(timeout: .seconds(2)) { ended } && isPageClosed(closedError),
              detail: "\(String(describing: closedError))")

        let window = CefWindow(page: CefPage(url: URL(string: "selftest://edge/one.html")!))
        window.show()
        let page = window.page
        _ = await loaded(page, title: "one")
        let evaluationError = await errorAfterCancelling {
            try await page.evaluateJavaScript("new Promise(() => {})")
        }
        check("operations: cancelling evaluateJavaScript ends it with CancellationError",
              evaluationError is CancellationError, detail: "\(String(describing: evaluationError))")
        let devToolsError = await errorAfterCancelling {
            try await page.devTools.send(
                "Runtime.evaluate", ["expression": "new Promise(() => {})", "awaitPromise": true])
        }
        check("operations: cancelling a DevTools call ends it with CancellationError",
              devToolsError is CancellationError, detail: "\(String(describing: devToolsError))")
        await expect("operations: the browser answers after cancelled calls") {
            try await page.evaluateJavaScript("1 + 1").intValue == 2
        }

        // A call waiting on the page when the page closes.
        var closeError: Error?
        var closeEnded = false
        Task {
            do { try await page.evaluateJavaScript("new Promise(() => {})") } catch { closeError = error }
            closeEnded = true
        }
        try? await Task.sleep(for: .milliseconds(200))
        window.close()
        check("operations: closing ends a waiting evaluation with pageClosed",
              await waitUntil(timeout: .seconds(5)) { closeEnded } && isPageClosed(closeError),
              detail: "\(String(describing: closeError))")
        _ = await waitUntil { window.isClosed }
    }

    /// `ready()` waits for a page's set-up, not just its creation.
    static func readinessChecks() async {
        var configuration = CefPage.Configuration()
        // An attachment that prepares first sets the page up before
        // its first page.
        let attachment = SlowAttachment()
        configuration.attachments = [attachment]
        let window = CefWindow(
            page: CefPage(url: URL(string: "selftest://edge/ready.html")!, configuration: configuration))
        window.show()
        await expect("operations: ready() returns once the browser's set-up has finished") {
            try await window.page.ready()
            return !window.page.isSettingUp && attachment.created == 1
        }
        check("operations: an attachment that prepares first runs before the first page, with DevTools usable",
              attachment.pageDuringSetUp == "about:blank", detail: attachment.pageDuringSetUp ?? "nil")
        check("operations: the set-up browser loads its page",
              await loaded(window.page, title: "ready"), detail: window.page.title)
        window.close()
        _ = await waitUntil { window.isClosed }
        check("operations: the attachment hears the browser close", attachment.closed == 1,
              detail: "\(attachment.closed)")
        await plainAttachmentReadinessChecks()
    }

    /// `ready()` means the page exists and can be used: it does not
    /// wait for an attachment that does not prepare first, which is told of
    /// the creation once, after it, and of the close after that. With an
    /// attachment that prepares first, every attachment is told before the
    /// first page, and `ready()` waits for all of them.
    static func plainAttachmentReadinessChecks() async {
        do {
            let plain = RecordingAttachment(holdingCreationFor: .milliseconds(500))
            var configuration = CefPage.Configuration()
            configuration.attachments = [plain]
            let window = CefWindow(
                page: CefPage(url: URL(string: "selftest://edge/ready.html")!, configuration: configuration))
            window.show()
            await expect("operations: ready() does not wait for an attachment that does not prepare first") {
                try await window.page.ready()
                return (!plain.events.contains("created"), "\(plain.events)")
            }
            check("operations: … which is told of the creation once",
                  await waitUntil(timeout: .seconds(5)) { plain.events == ["create", "created"] }, detail: "\(plain.events)")
            check("operations: … and its browser loads its page meanwhile", await loaded(window.page, title: "ready"))
            window.close()
            _ = await waitUntil { window.isClosed }
            check("operations: … and of the close after the creation",
                  plain.events == ["create", "created", "close"], detail: "\(plain.events)")
        }
        do {
            let preparing = SlowAttachment()
            let plain = RecordingAttachment(holdingCreationFor: .milliseconds(300))
            var configuration = CefPage.Configuration()
            configuration.attachments = [preparing, plain]
            let window = CefWindow(
                page: CefPage(url: URL(string: "selftest://edge/ready.html")!, configuration: configuration))
            window.show()
            await expect("operations: with an attachment that prepares first, ready() waits for every attachment") {
                try await window.page.ready()
                return (preparing.created == 1 && plain.events == ["create", "created"], "\(plain.events)")
            }
            check("operations: … and every attachment is told before the first page",
                  plain.pageDuringCreation == "about:blank", detail: plain.pageDuringCreation ?? "nil")
            window.close()
            _ = await waitUntil { window.isClosed }
            check("operations: … and each hears the close once",
                  preparing.closed == 1 && plain.events.filter { $0 == "close" }.count == 1, detail: "\(plain.events)")
        }
    }

    /// Two pages in one renderer number their evaluations alike: a
    /// page and its popup share the page's renderer, and their first
    /// evaluations are both request 1.
    static func sharedRendererChecks() async {
        let opener = CefWindow(page: CefPage(url: URL(string: "selftest://edge/opener.html")!))
        var popups: [CefWindow] = []
        opener.onPopup = { popup in
            popups.append(popup)
            popup.show()
        }
        opener.show()
        _ = await loaded(opener.page, title: "opener")
        let renderersBefore = rendererProcesses().count
        _ = try? await opener.page.evaluateJavaScript(
            "window.open('popup.html', 'p', 'width=300,height=200'); 0", userGesture: true)
        guard await waitUntil(timeout: .seconds(5), { popups.first?.page.title == "popup" }), let popup = popups.first
        else {
            check("operations: a page and its popup evaluate at once in one renderer", false, detail: "no popup")
            opener.close()
            return
        }
        let shared = rendererProcesses().count == renderersBefore
        async let slow = withTimeout(.seconds(5)) {
            try await opener.page.evaluateJavaScript("new Promise(r => setTimeout(() => r('opener'), 600))")
        }
        try? await Task.sleep(for: .milliseconds(100))
        async let fast = withTimeout(.seconds(5)) {
            try await popup.page.evaluateJavaScript("new Promise(r => setTimeout(() => r('popup'), 100))")
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
        // Main-actor jobs wait while a modal session runs, so the task is
        // cancelled from the modal run loop, as CefKit's own cancellations
        // arrive (CEF callbacks the message pump delivers there).
        let page = CefPage()
        var answer: CefUnresponsivePageDecision?
        var shown = false
        let task = Task { @MainActor in
            answer = await CefUnresponsivePagePresenter.present(for: page, in: nil)
        }
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated {
                shown = NSApp.modalWindow != nil
                task.cancel()
            }
        }
        // A last resort, should cancelling not end the session.
        let rescue = Timer(timeInterval: 5, repeats: false) { _ in
            MainActor.assumeIsolated { if NSApp.modalWindow != nil { NSApp.abortModal() } }
        }
        RunLoop.main.add(rescue, forMode: .modalPanel)
        let start = ContinuousClock.now
        await task.value
        rescue.invalidate()
        let elapsed = ContinuousClock.now - start
        check("operations: cancelling dismisses a presenter's modal alert",
              shown && answer == .wait && NSApp.modalWindow == nil && elapsed < .seconds(4),
              detail: "shown \(shown), answer \(String(describing: answer)), after \(elapsed)")

        var leaving: Bool?
        var everShown = false
        let early = Task { @MainActor in
            leaving = await CefDialogPresenter.confirmLeaving(isReload: false, in: nil)
        }
        early.cancel()
        let probe = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                everShown = NSApp.modalWindow != nil
                if everShown { NSApp.abortModal() }
            }
        }
        RunLoop.main.add(probe, forMode: .modalPanel)
        await early.value
        probe.invalidate()
        check("operations: a presenter cancelled before it shows shows nothing", !everShown && leaving == false,
              detail: "shown \(everShown), \(String(describing: leaving))")
    }

    /// Delegate decisions end with the page they belong to.
    static func decisionChecks() async {
        let delegate = StallingDelegate()
        let pageWindow = CefWindow(
            page: CefPage(url: URL(string: "selftest://edge/dialog.html")!, delegate: delegate))
        pageWindow.show()
        let page = pageWindow.page
        _ = await loaded(page, title: "dialog")

        // Permission requests in flight when the page goes: a prompt
        // (geolocation), which Chromium dismisses, and a media request.
        if let server = try? await LocalServer.start() {
            _ = await load(URL(string: "http://127.0.0.1:\(server.port)/page")!, in: page, title: "page")
            _ = try? await page.evaluateJavaScript("""
                navigator.geolocation.getCurrentPosition(() => {}, () => {});
                navigator.mediaDevices.getUserMedia({ audio: true }).catch(() => {});
                0
                """, userGesture: true)
            let asked = await waitUntil(timeout: .seconds(5)) { delegate.permissionRequests == 2 }
            page.load(URL(string: "selftest://edge/gone.html")!)
            let ended = await waitUntil(timeout: .seconds(5)) {
                delegate.cancelled == delegate.permissionRequests && page.pendingDecisionCount == 0
                    && page.title == "gone"
            }
            check("operations: leaving a page cancels its pending permission decisions", asked && ended,
                  detail: "asked \(delegate.permissionRequests), cancelled \(delegate.cancelled), pending \(page.pendingDecisionCount)")
            server.stop()
        }

        // A dialog the delegate is still deciding when the page closes.
        let cancelledBefore = delegate.cancelled
        page.executeJavaScript("alert('stay')")
        let shown = await waitUntil(timeout: .seconds(5)) { page.pendingDecisionCount == 1 }
        page.close(force: true)
        let dialogEnded = await waitUntil(timeout: .seconds(5)) {
            page.state == .closed && delegate.cancelled == cancelledBefore + 1 && page.pendingDecisionCount == 0
        }
        check("operations: closing cancels a pending JavaScript dialog decision", shown && dialogEnded,
              detail: "shown \(shown), cancelled \(delegate.cancelled - cancelledBefore), pending \(page.pendingDecisionCount)")
        _ = await waitUntil { pageWindow.isClosed }

        // The default sheet goes with its page, in a window that stays.
        let sheetPage = CefPage(url: URL(string: "selftest://edge/sheet.html")!)
        let view = hostWindowed(sheetPage)
        _ = await loaded(sheetPage, title: "sheet")
        sheetPage.executeJavaScript("alert('sheet')")
        let sheetShown = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }
        sheetPage.close(force: true)
        let sheetGone = await waitUntil(timeout: .seconds(5)) {
            window.attachedSheet == nil && sheetPage.state == .closed
        }
        check("operations: closing dismisses the default dialog sheet", sheetShown && sheetGone,
              detail: "shown \(sheetShown), sheet \(String(describing: window.attachedSheet)), state \(sheetPage.state)")
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        view.removeFromSuperview()
    }

    /// Observation tracks settings CEF reports no changes of.
    static func observableSettingChecks() async {
        let window = CefWindow(page: CefPage(url: URL(string: "selftest://edge/settings.html")!))
        window.show()
        let page = window.page
        _ = await loaded(page, title: "settings")

        let mutedChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = page.isAudioMuted } onChange: { mutedChanged.withLock { $0 = true } }
        page.isAudioMuted = true
        check("operations: isAudioMuted is observable",
              await waitUntil(timeout: .seconds(2)) { mutedChanged.withLock { $0 } } && page.isAudioMuted)
        page.isAudioMuted = false

        let devToolsChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = page.isShowingDevTools } onChange: {
            devToolsChanged.withLock { $0 = true }
        }
        page.showDevTools()
        check("operations: isShowingDevTools is observable",
              await waitUntil(timeout: .seconds(10)) { devToolsChanged.withLock { $0 } && page.isShowingDevTools })
        page.closeDevTools()
        check("operations: isShowingDevTools follows DevTools closing",
              await waitUntil(timeout: .seconds(10)) { !page.isShowingDevTools })
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    /// One user disabling a domain leaves it on for another.
    static func domainLeaseChecks() async {
        let window = CefWindow(page: CefPage(url: URL(string: "selftest://edge/lease.html")!))
        window.show()
        let page = window.page
        _ = await loaded(page, title: "lease")
        await expect("operations: a domain stays enabled while another user holds it") {
            try await page.devTools.send("Runtime.enable")  // one user
            try await page.devTools.send("Runtime.enable")  // another
            try await page.devTools.send("Runtime.disable")  // the first is done
            let logged = page.devTools.events("Runtime.consoleAPICalled")
            page.executeJavaScript("console.log('still on')")
            let event = await withTimeout(.seconds(5)) { () async -> CefJSON? in for await event in logged { return event }; return nil }
            try await page.devTools.send("Runtime.disable")
            return event??["args"][0]["value"].stringValue == "still on"
        }
        window.close()
        _ = await waitUntil { window.isClosed }
    }
}

func isPageClosed(_ error: Error?) -> Bool {
    if case .pageClosed? = error as? CefError { return true }
    return false
}

/// An attachment, written with public API only, that takes its time to
/// set a page up and records what it saw.
@MainActor
final class SlowAttachment: CefPageAttachment {
    private(set) var created = 0
    private(set) var closed = 0
    /// The document the page had while the attachment set it up.
    private(set) var pageDuringSetUp: String?

    var preparesBeforeFirstDocument: Bool { true }

    func pageDidCreate(_ page: CefPage) async {
        try? await Task.sleep(for: .milliseconds(300))
        let href = try? await page.devTools.send("Runtime.evaluate", ["expression": "location.href", "returnByValue": true])
        pageDuringSetUp = href?["result"]["value"].stringValue
        created += 1
    }

    func pageDidClose(_ page: CefPage) {
        closed += 1
    }
}

/// An attachment that does not prepare first, written with public API
/// only, recording what it is told, in order: `create` and `created`
/// around its set-up, `restore` and `close`.
@MainActor
final class RecordingAttachment: CefPageAttachment {
    private(set) var events: [String] = []
    /// The document the page had while the attachment set it up, and
    /// while it restored it.
    private(set) var pageDuringCreation: String?
    private(set) var pageDuringRestore: String?
    private let creationTime: Duration

    init(holdingCreationFor creationTime: Duration = .zero) {
        self.creationTime = creationTime
    }

    private func location(of page: CefPage) async -> String? {
        let href = try? await page.devTools.send("Runtime.evaluate", ["expression": "location.href", "returnByValue": true])
        return href?["result"]["value"].stringValue
    }

    func pageDidCreate(_ page: CefPage) async {
        events.append("create")
        pageDuringCreation = await location(of: page)
        try? await Task.sleep(for: creationTime)
        events.append("created")
    }

    func pageDidRestore(_ page: CefPage) async {
        pageDuringRestore = await location(of: page)
        events.append("restore")
    }

    func pageDidClose(_ page: CefPage) {
        events.append("close")
    }
}

/// Answers nothing until its task is cancelled.
@MainActor
final class StallingDelegate: CefPageDelegate, CefPasskeyDelegate {
    private(set) var started = 0
    private(set) var cancelled = 0
    private(set) var permissionRequests = 0

    private func stall() async {
        started += 1
        try? await Task.sleep(for: .seconds(60))
        if Task.isCancelled { cancelled += 1 }
    }

    func page(_ page: CefPage, runJavaScriptDialog dialog: CefJavaScriptDialog) async -> CefJavaScriptDialogResponse {
        await stall()
        return .accept()
    }

    func page(_ page: CefPage, decidePermissionFor request: CefPermissionRequest) async -> CefPermissionDecision {
        permissionRequests += 1
        await stall()
        return .allow
    }

    func page(_ page: CefPage, decidePasskeyFor request: CefPasskeyRequest) async -> CefPasskeyDecision {
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
