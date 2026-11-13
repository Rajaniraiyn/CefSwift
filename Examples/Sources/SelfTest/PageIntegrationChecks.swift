import AppKit
import UniformTypeIdentifiers
@_spi(Testing) import CefKit
import CefSwiftUI

/// The frame tree, file choosers and keyboard focus traversal: the native
/// routes of `cef_frame_handler_t`, `cef_dialog_handler_t` and
/// `cef_focus_handler_t`.
extension SelfTest {
    static func pageIntegrationChecks() async {
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "frames", handler: FramePages())
        CefRuntime.shared.registerSchemeHandler(scheme: "selftest", domain: "frames-other", handler: FramePages())
        await frameTreeChecks()
        await fileDialogChecks()
        await focusTraversalChecks()
    }

    /// A windowed browser in the test window's content view.
    static func hostedBrowser(_ url: URL, delegate: CefBrowserDelegate? = nil) -> (CefBrowser, CefWindowedBrowserView) {
        let browser = CefBrowser(url: url, delegate: delegate)
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds.insetBy(dx: 0, dy: 40)
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        view.browser = browser
        return (browser, view)
    }

    static func closeHosted(_ browser: CefBrowser, _ view: NSView) async {
        browser.close(force: true)
        _ = await waitUntil { browser.state == .closed }
        view.removeFromSuperview()
    }

    // MARK: Frames

    static func frameTreeChecks() async {
        let (browser, view) = hostedBrowser(URL(string: "selftest://frames/top.html")!)
        let attached = await waitUntil { browser.frames.count == 3 && browser.frames.allSatisfy { $0.url != nil } }
        check("frames: the main frame and both iframes are listed", attached,
              detail: browser.frames.map { "\($0.name) \($0.url?.absoluteString ?? "-")" }.joined(separator: "; "))
        let main = browser.mainFrame
        check("frames: the main frame comes first, with the page's address",
              browser.frames.first?.isMain == true && main?.url?.absoluteString == "selftest://frames/top.html"
                && main?.parentID == nil)
        let same = browser.frames.first { $0.name == "same" }
        let cross = browser.frames.first { $0.name == "cross" }
        check("frames: iframes have their names and the main frame as parent",
              same?.parentID == main?.id && cross?.parentID == main?.id && same?.isMain == false,
              detail: "\(String(describing: same)) \(String(describing: cross))")
        if let same, let cross {
            await expect("frames: evaluateJavaScript runs in a same-site iframe") {
                try await browser.evaluateJavaScript("location.href + ' ' + window.name", in: same).stringValue
                    == "selftest://frames/child.html?same same"
            }
            await expect("frames: evaluateJavaScript runs in a cross-site iframe") {
                try await browser.evaluateJavaScript("location.host", as: String.self, in: cross) == "frames-other"
            }
            browser.executeJavaScript("document.getElementById('same').src = 'child.html?moved'")
            check("frames: an iframe's navigation updates its address", await waitUntil {
                browser.frames.contains { $0.url?.query == "moved" }
            }, detail: browser.frames.map { $0.url?.absoluteString ?? "-" }.joined(separator: "; "))
            browser.executeJavaScript("document.getElementById('cross').remove()")
            check("frames: a removed iframe is no longer listed",
                  await waitUntil { !browser.frames.contains { $0.id == cross.id } && browser.frames.count == 2 })
            do {
                _ = try await browser.evaluateJavaScript("1", in: cross)
                check("frames: evaluating in a removed frame throws frameDetached", false, detail: "returned")
            } catch {
                check("frames: evaluating in a removed frame throws frameDetached",
                      (error as? CefError).map { if case .frameDetached = $0 { true } else { false } } ?? false,
                      detail: "\(error)")
            }
        }
        // A cross-site navigation of the main frame replaces it.
        let oldMain = browser.mainFrame?.id
        browser.load(URL(string: "selftest://frames-other/child.html?top")!)
        check("frames: a cross-site navigation gives a new main frame and drops the iframes", await waitUntil {
            browser.frames.count == 1 && browser.mainFrame?.url?.query == "top" && !browser.isLoading
        }, detail: browser.frames.map { "\($0.isMain) \($0.url?.absoluteString ?? "-")" }.joined(separator: "; "))
        print("INFO frames: main frame \(oldMain ?? "-") → \(browser.mainFrame?.id ?? "-")")
        await closeHosted(browser, view)
        check("frames: a closed browser lists none", browser.frames.isEmpty)

        // Chrome style reports frames the same way.
        let tab = CefBrowser(url: URL(string: "selftest://frames/top.html")!)
        let tabWindow = CefBrowserWindow(browser: tab)
        tabWindow.show()
        check("frames: a Chrome-style browser lists its frames", await waitUntil { tab.frames.count == 3 },
              detail: "\(tab.frames.count)")
        tabWindow.close()
        _ = await waitUntil { tabWindow.isClosed }
    }

    // MARK: File dialogs

    /// Answers file choosers with ``answer`` and records what was asked.
    final class FileDialogRecorder: CefBrowserDelegate {
        var dialogs: [CefFileDialog] = []
        var answer: [URL]?
        func browser(_ browser: CefBrowser, runFileDialog dialog: CefFileDialog) async -> [URL]? {
            dialogs.append(dialog)
            return answer
        }
    }

    static func fileDialogChecks() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("selftest-files-\(getpid())")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["one.txt", "two.txt"].map { directory.appendingPathComponent($0) }
        for file in files { try? Data("hello".utf8).write(to: file) }

        let recorder = FileDialogRecorder()
        let (browser, view) = hostedBrowser(URL(string: "selftest://frames/files.html")!, delegate: recorder)
        _ = await waitUntil { browser.title == "files" && !browser.isLoading }

        recorder.answer = [files[0]]
        _ = try? await browser.evaluateJavaScript("single.click(); 0", userGesture: true)
        check("file dialog: the delegate is asked for <input type=file>", await waitUntil { recorder.dialogs.count == 1 })
        let first = recorder.dialogs.first
        check("file dialog: mode and accepted types reach the delegate",
              first?.mode == .open && first?.acceptedTypes.map(\.filter).contains(".txt") == true
                && first?.acceptedTypes.map(\.filter).contains("image/*") == true,
              detail: "\(String(describing: first))")
        check("file dialog: accepted types map to uniform types",
              first.map { dialog in dialog.acceptedTypes.flatMap(\.contentTypes).contains(.plainText) } == true)
        await expect("file dialog: the chosen file reaches the page") {
            await waitUntilAsync(timeout: .seconds(5)) {
                (try? await browser.evaluateJavaScript("single.files.length ? single.files[0].name : ''").stringValue) == "one.txt"
            }
        }

        recorder.answer = files
        _ = try? await browser.evaluateJavaScript("multiple.click(); 0", userGesture: true)
        _ = await waitUntil { recorder.dialogs.count == 2 }
        check("file dialog: <input multiple> asks for several files", recorder.dialogs.last?.mode == .openMultiple)
        await expect("file dialog: several chosen files reach the page") {
            await waitUntilAsync(timeout: .seconds(5)) {
                (try? await browser.evaluateJavaScript("multiple.files.length").intValue) == 2
            }
        }

        recorder.answer = nil
        _ = try? await browser.evaluateJavaScript("single.click(); 0", userGesture: true)
        _ = await waitUntil { recorder.dialogs.count == 3 }
        await expect("file dialog: cancelling fires the input's cancel event") {
            await waitUntilAsync(timeout: .seconds(5)) {
                (try? await browser.evaluateJavaScript("window.__cancelled").intValue) == 1
            }
        }

        // The default: an NSOpenPanel sheet on the browser's window.
        browser.delegate = nil
        _ = try? await browser.evaluateJavaScript("single.click(); 0", userGesture: true)
        let sheetShown = await waitUntil(timeout: .seconds(10)) { window.attachedSheet is NSOpenPanel }
        check("file dialog: the default is an NSOpenPanel sheet", sheetShown,
              detail: "\(String(describing: window.attachedSheet))")
        (window.attachedSheet as? NSOpenPanel)?.cancel(nil)
        check("file dialog: cancelling the default panel reaches the page", await waitUntilAsync(timeout: .seconds(5)) {
            (try? await browser.evaluateJavaScript("window.__cancelled").intValue) == 2
        })
        await closeHosted(browser, view)

        // Chrome style asks the delegate too.
        let tabRecorder = FileDialogRecorder()
        tabRecorder.answer = [files[1]]
        let tab = CefBrowser(url: URL(string: "selftest://frames/files.html")!, delegate: tabRecorder)
        let tabWindow = CefBrowserWindow(browser: tab)
        tabWindow.show()
        _ = await waitUntil { tab.title == "files" && !tab.isLoading }
        _ = try? await tab.evaluateJavaScript("single.click(); 0", userGesture: true)
        check("file dialog: a Chrome-style browser asks the delegate", await waitUntil(timeout: .seconds(5)) {
            tabRecorder.dialogs.count == 1
        })
        await expect("file dialog: the file reaches a Chrome-style page") {
            await waitUntilAsync(timeout: .seconds(5)) {
                (try? await tab.evaluateJavaScript("single.files.length ? single.files[0].name : ''").stringValue) == "two.txt"
            }
        }
        tabWindow.close()
        _ = await waitUntil { tabWindow.isClosed }
    }

    // MARK: Focus

    static func focusTraversalChecks() async {
        let before = NSTextField(frame: NSRect(x: 10, y: 5, width: 200, height: 24))
        let after = NSTextField(frame: NSRect(x: 220, y: 5, width: 200, height: 24))
        let (browser, view) = hostedBrowser(URL(string: "selftest://frames/focus.html")!)
        window.contentView!.addSubview(before)
        window.contentView!.addSubview(after)
        window.autorecalculatesKeyViewLoop = false
        before.nextKeyView = view
        view.nextKeyView = after
        after.nextKeyView = before
        window.makeKeyAndOrderFront(nil)
        _ = await waitUntil { browser.title == "focus" && !browser.isLoading }

        func activeID() async -> String {
            (try? await browser.evaluateJavaScript("document.activeElement?.id ?? ''").stringValue) ?? "?"
        }
        func isEditing(_ field: NSTextField) -> Bool {
            window.firstResponder === field || (window.firstResponder as? NSText)?.delegate === field
        }
        /// A Tab press as the keyboard delivers it, to the page's view.
        func pressTab(shift: Bool) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: shift ? [.shift] : [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: shift ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
                else { continue }
                window.sendEvent(event)
            }
        }

        window.makeFirstResponder(before)
        window.selectKeyView(following: before)
        var active = ""
        check("focus: Tab into the page focuses its first element", await waitUntilAsync(timeout: .seconds(5)) {
            active = await activeID()
            return active == "first"
        }, detail: "active \(active), responder \(String(describing: window.firstResponder))")
        // Tab past the last element leaves the page for the next key view.
        _ = try? await browser.evaluateJavaScript("last.focus(), 0")
        pressTab(shift: false)
        check("focus: Tab past the last element moves to the next AppKit key view",
              await waitUntil(timeout: .seconds(5)) { isEditing(after) },
              detail: "\(String(describing: window.firstResponder))")

        window.selectKeyView(preceding: after)
        check("focus: Shift-Tab into the page focuses its last element", await waitUntilAsync(timeout: .seconds(5)) {
            active = await activeID()
            return active == "last"
        }, detail: "active \(active), responder \(String(describing: window.firstResponder))")
        _ = try? await browser.evaluateJavaScript("first.focus(), 0")
        pressTab(shift: true)
        check("focus: Shift-Tab past the first element moves to the previous AppKit key view",
              await waitUntil(timeout: .seconds(5)) { isEditing(before) },
              detail: "\(String(describing: window.firstResponder))")

        window.makeFirstResponder(nil)
        await closeHosted(browser, view)

        // Offscreen: the view CefKit draws into enters the loop the same way.
        var options = CefBrowserOptions()
        options.rendering = .offscreen
        let offscreen = CefBrowser(url: URL(string: "selftest://frames/focus.html")!, options: options)
        let offscreenView = CefOffscreenBrowserView()
        offscreenView.frame = window.contentView!.bounds.insetBy(dx: 0, dy: 40)
        window.contentView!.addSubview(offscreenView)
        offscreenView.browser = offscreen
        before.nextKeyView = offscreenView
        offscreenView.nextKeyView = after
        _ = await waitUntil { offscreen.title == "focus" && !offscreen.isLoading }
        window.makeFirstResponder(before)
        window.selectKeyView(following: before)
        check("focus (offscreen): Tab into the page focuses its first element", await waitUntilAsync(timeout: .seconds(5)) {
            active = (try? await offscreen.evaluateJavaScript("document.activeElement?.id ?? ''").stringValue) ?? "?"
            return active == "first"
        }, detail: "active \(active)")
        window.makeFirstResponder(nil)
        before.removeFromSuperview()
        after.removeFromSuperview()
        window.autorecalculatesKeyViewLoop = true
        await closeHosted(offscreen, offscreenView)
    }
}

/// Pages for the frame, file and focus checks, at `selftest://frames/…`
/// and `selftest://frames-other/…` (another site).
struct FramePages: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        let html: String
        switch request.url?.path {
        case "/top.html":
            html = """
                <title>top</title>
                <iframe id=same name=same src="child.html?same"></iframe>
                <iframe id=cross name=cross src="selftest://frames-other/child.html?cross"></iframe>
                """
        case "/files.html":
            html = """
                <title>files</title>
                <input id=single type=file accept=".txt,image/*">
                <input id=multiple type=file multiple>
                <script>
                  window.__cancelled = 0;
                  single.addEventListener('cancel', () => window.__cancelled++);
                </script>
                """
        case "/focus.html":
            html = "<title>focus</title><input id=first><button id=middle>middle</button><input id=last>"
        default:
            html = "<title>child</title><p>child</p>"
        }
        return CefSchemeResponse(mimeType: "text/html", body: Data(html.utf8))
    }
}
