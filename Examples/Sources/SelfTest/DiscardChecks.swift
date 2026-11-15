import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import Darwin

/// Tab discarding: Chromium's own discard for Chrome-style windows, closing
/// and re-creating for views, blockers, and quitting with discarded
/// pages. When to discard is the app's policy (the Browser example's
/// Memory Saver, tested in Examples/Tests/BrowserTests).
extension SelfTest {
    static func discardChecks() async {
        await windowDiscardChecks()
        await discardBlockerChecks()
        await viewDiscardBlockerChecks()
        await beforeUnloadBlockerChecks()
        await viewDiscardChecks()
    }

    /// Records the discard events a page's delegate receives.
    final class DiscardRecorder: CefPageDelegate {
        var events: [String] = []
        func pageWillDiscard(_ page: CefPage) { events.append("will") }
        func pageDidDiscard(_ page: CefPage) { events.append("did") }
        func pageDidRestore(_ page: CefPage) { events.append("restore") }
        func page(_ page: CefPage, renderProcessDidTerminate reason: CefTerminationReason) {
            events.append("terminated")
        }
    }

    static func discardConfiguration() -> CefPage.Configuration {
        var configuration = CefPage.Configuration()
        configuration.bridges = [bridge]
        configuration.userScripts = [CefUserScript(source: "window.__injected = 42;")]
        return configuration
    }

    // MARK: Chrome-style windows

    static func windowDiscardChecks() async {
        let recorder = DiscardRecorder()
        let page = CefPage(url: URL(string: "selftest://edge/heavy.html?1")!, configuration: discardConfiguration(), delegate: recorder)
        let pageWindow = CefWindow(page: page)
        pageWindow.show()
        _ = await loaded(page, title: "heavy")
        page.load(URL(string: "selftest://edge/heavy.html?2")!)
        _ = await waitUntil { page.url?.query == "2" && !page.isLoading && page.favicon != nil }
        let renderer = await allocateInRenderer(page)
        _ = try? await page.evaluateJavaScript("scrollTo(0, 1500)")
        // Chromium saves a page's scroll position within a second of it
        // changing.
        try? await Task.sleep(for: .milliseconds(1500))

        do {
            try await page.discard()
            check("discard: the frontmost tab is refused", false, detail: "discarded")
        } catch {
            check("discard: the frontmost tab is refused", error == .blocked([.visible]), detail: "\(error)")
        }

        // A DevTools consumer subscribed before the discard.
        _ = try? await page.devTools.send("Runtime.enable")
        var consoleMessages: [String] = []
        let consoleWatcher = Task {
            for await event in page.devTools.events("Runtime.consoleAPICalled") {
                consoleMessages.append(event["args"][0]["value"].stringValue ?? "")
            }
        }
        defer { consoleWatcher.cancel() }

        pageWindow.hide()
        let title = page.title, url = page.url
        await expect("discard: a hidden tab is discarded") {
            try await page.discard()
            return page.isDiscarded && page.state == .live
        }
        check("discard: delegate hears will and did", recorder.events == ["will", "did"], detail: "\(recorder.events)")
        if let renderer {
            let exited = await waitUntil(timeout: .seconds(10)) { footprint(of: renderer.pid) == nil }
            print("INFO discard (window): renderer \(renderer.pid) at \(renderer.megabytes) MB \(exited ? "exited" : "is still running at \(footprint(of: renderer.pid) ?? 0) MB")")
            check("discard: the tab's renderer process exits", exited)
        } else {
            check("discard: the tab's renderer process exits", false, detail: "renderer not found")
        }
        check("discard: URL, title and favicon stay", page.url == url && page.title == title && page.favicon != nil)
        check("discard: snapshot of the page kept", page.discardSnapshot != nil)
        check("discard: no renderer crash reported", !recorder.events.contains("terminated"))

        pageWindow.show()
        check("discard: showing the tab restores it", await waitUntil { !page.isDiscarded && !page.isLoading },
              detail: "\(recorder.events)")
        check("discard: restored on the same URL", page.url == url && recorder.events.last == "restore")
        var scrollY: Int?
        check("discard: scroll position restored", await waitUntilAsync(timeout: .seconds(3)) {
            scrollY = try? await page.evaluateJavaScript("scrollY").intValue
            return scrollY == 1500
        }, detail: "scrollY \(String(describing: scrollY))")
        await expect("discard: user script and bridge work after restore") {
            let injected = try await page.evaluateJavaScript("window.__injected").intValue
            let greeting = try await page.evaluateJavaScript("app.greet({name: 'Ada'})").stringValue
            return injected == 42 && greeting == "Hello, Ada from main!"
        }
        await expect("discard: DevTools event stream keeps delivering") {
            try await page.evaluateJavaScript("console.log('after restore')")
            return await waitUntil(timeout: .seconds(5)) { consoleMessages.contains("after restore") }
        }
        await expect("discard: executeJavaScript reaches the restored page") {
            page.executeJavaScript("window.__executed = 7")
            return await waitUntilAsync(timeout: .seconds(5)) {
                (try? await page.evaluateJavaScript("window.__executed").intValue) == 7
            }
        }
        check("discard: back/forward list survives", page.canGoBack)
        page.goBack()
        check("discard: going back reaches the first page", await waitUntil { page.url?.query == "1" && !page.isLoading })

        // A command restores a hidden discarded tab.
        pageWindow.hide()
        await expect("discard: evaluateJavaScript restores a hidden discarded tab") {
            try await page.discard()
            let href = try await page.evaluateJavaScript("location.href").stringValue
            return href == "selftest://edge/heavy.html?1" && !page.isDiscarded
        }

        await waitUntilDiscardable(page)
        check("discard: a restored tab is discarded again", (try? await page.discard()) != nil && page.isDiscarded)
        pageWindow.close()
        check("discard: a discarded tab's window closes",
              await waitUntil { pageWindow.isClosed && page.state == .closed })
    }

    // MARK: Blockers

    static func discardBlockerChecks() async {
        let audible = CefWindow(page: CefPage(url: URL(string: "selftest://edge/tab.html?audio")!))
        let leaving = CefWindow(page: CefPage(url: URL(string: "selftest://edge/leave.html")!))
        let windows = [audible, leaving]
        windows.forEach { $0.show() }
        _ = await allLoaded(windows.map(\.page))

        audible.page.isAudioMuted = true
        _ = try? await audible.page.evaluateJavaScript("""
            const context = new AudioContext(), tone = context.createOscillator(), gain = context.createGain();
            gain.gain.value = 0.05;
            tone.connect(gain).connect(context.destination);
            tone.start();
            context.state
            """, userGesture: true)  // Audio starts only after a user gesture.
        try? await Task.sleep(for: .seconds(1))
        windows.forEach { $0.hide() }

        let audio = await audible.page.discardBlockers()
        check("discard blockers: a page playing audio is kept", audio.contains(.playingAudio), detail: "\(audio)")
        await expect("discard blockers: a page with a beforeunload handler is kept") {
            do {
                try await leaving.page.discard()
                return false
            } catch let error as CefPage.DiscardError {
                guard case .blocked(let blockers) = error else { return false }
                return blockers.contains(.beforeUnloadHandler) && !leaving.page.isDiscarded
            }
        }

        for window in windows { window.close() }
        // The beforeunload page asks before it closes; answer for it.
        leaving.page.close(force: true)
        _ = await waitUntil { windows.allSatisfy(\.isClosed) }
        await discardIdentityChecks()
    }

    /// Runs `body` when a page is about to be discarded.
    final class WillDiscardHook: CefPageDelegate {
        var body: (CefPage) -> Void = { _ in }
        func pageWillDiscard(_ page: CefPage) { body(page) }
    }

    /// Chromium names tabs only by address and title, so tabs it cannot
    /// tell apart are kept; and a page that is shown or navigates while
    /// it is being discarded stays loaded.
    static func discardIdentityChecks() async {
        let twinURL = URL(string: "selftest://edge/tab.html?twin")!
        let twins = [CefWindow(page: CefPage(url: twinURL)), CefWindow(page: CefPage(url: twinURL))]
        twins.forEach { $0.show() }
        _ = await allLoaded(twins.map(\.page), title: "tab")
        twins.forEach { $0.hide() }
        // Kept only for being ambiguous, once both are hidden.
        for twin in twins {
            await waitUntilDiscardable(twin.page) { if case .unknown = $0 { true } else { false } }
        }
        var twinError: CefPage.DiscardError?
        do { try await twins[0].page.discard() } catch { twinError = error }
        let ambiguous: Bool
        if case .blocked(let blockers) = twinError {
            ambiguous = blockers.contains { if case .unknown = $0 { true } else { false } }
        } else {
            ambiguous = false
        }
        check("discard identity: tabs with the same address and title are kept",
              ambiguous && twins.allSatisfy { !$0.page.isDiscarded }, detail: "\(String(describing: twinError))")
        // One of them navigating apart makes each tab identifiable again.
        _ = await load(URL(string: "selftest://edge/tab.html?other")!, in: twins[1].page)
        await waitUntilDiscardable(twins[0].page)
        await expect("discard identity: a tab told apart by its address is discarded, and only it") {
            try await twins[0].page.discard()
            return twins[0].page.isDiscarded && !twins[1].page.isDiscarded
        }
        for window in twins { window.close() }
        _ = await waitUntil { twins.allSatisfy(\.isClosed) }

        let hook = WillDiscardHook()
        let page = CefPage(url: URL(string: "selftest://edge/tab.html?revalidate")!, delegate: hook)
        let window = CefWindow(page: page)
        window.show()
        _ = await loaded(page, title: "tab")
        window.hide()
        await waitUntilDiscardable(page)
        hook.body = { _ in window.show() }
        var shownError: CefPage.DiscardError?
        do { try await page.discard() } catch { shownError = error }
        check("discard identity: a tab shown while it is being discarded stays loaded",
              shownError == .blocked([.visible]) && !page.isDiscarded, detail: "\(String(describing: shownError))")

        _ = await waitUntil { !page.isLoading }
        window.hide()
        await waitUntilDiscardable(page)
        hook.body = { page in page.load(URL(string: "selftest://edge/tab.html?moved")!) }
        var movedError: CefPage.DiscardError?
        do { try await page.discard() } catch { movedError = error }
        hook.body = { _ in }
        check("discard identity: a tab that navigates while it is being discarded stays loaded",
              movedError != nil && !page.isDiscarded, detail: "\(String(describing: movedError))")
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: View blockers

    /// Audio and form input for pages in views, which Chromium's tab
    /// rules do not cover, read from its performance-manager graph on
    /// `chrome://discards`. The graph is Chromium-private: when a CEF
    /// update changes it, these fail (a quiet page reports `.unknown`).
    static func viewDiscardBlockerChecks() async {
        func makePage(_ name: String, _ script: String? = nil, hidden: Bool = true) async -> (CefPage, NSView) {
            let page = CefPage(url: URL(string: "selftest://edge/tab.html?\(name)")!)
            let view = hostWindowed(page)
            _ = await loaded(page, title: "tab")
            if let script {
                // Playback starts only after a user gesture.
                let reply = try? await page.evaluateJavaScript(script, userGesture: true)
                if reply?.stringValue != "ok" { print("     \(name): \(reply?.text ?? "script failed")") }
            }
            view.isHidden = hidden
            return (page, view)
        }
        let play = "window.player = %@; player.loop = true; player.play().then(() => 'ok', e => String(e))"
        // The first look-up starts the discards host; pages opened after it
        // reach its graph subscription as they are created.
        let (silent, silentView) = await makePage("view-silent")
        var silentBlockers: Set<CefPage.DiscardBlocker> = []
        let coldCall = await ContinuousClock().measure { silentBlockers = await silent.discardBlockers() }

        let (element, elementView) = await makePage("view-audio", play.replacingOccurrences(of: "%@", with: "new Audio('tone.wav')"))
        let (webAudio, webAudioView) = await makePage("view-webaudio", """
            const context = new AudioContext(), tone = context.createOscillator(), gain = context.createGain();
            gain.gain.value = 0.05;
            tone.connect(gain).connect(context.destination);
            tone.start();
            context.state === 'running' ? 'ok' : context.state
            """)
        // Kept on screen: Chromium pauses a muted video in a hidden page.
        let (muted, mutedView) = await makePage("view-muted", """
            document.body.innerHTML = '<video muted src=tone.wav></video>';
            \(play.replacingOccurrences(of: "%@", with: "document.querySelector('video')"))
            """, hidden: false)
        let (typed, typedView) = await makePage("view-typed", "document.body.innerHTML = '<input>'; document.querySelector('input').focus(); 'ok'")
        typedView.isHidden = false
        _ = try? await typed.devTools.send("Input.insertText", ["text": "unsent"])
        typedView.isHidden = true

        check("discard blockers (view): Chromium's page graph describes a quiet page, and it is not blocked",
              silentBlockers.isEmpty, detail: "\(silentBlockers)")
        var blockers: Set<CefPage.DiscardBlocker> = []
        check("discard blockers (view): a page playing an audio element is kept",
              await waitUntilAsync(timeout: .seconds(5)) {
                  blockers = await element.discardBlockers()
                  return blockers == [.playingAudio]
              }, detail: "\(blockers)")
        check("discard blockers (view): a page playing Web Audio is kept",
              await waitUntilAsync(timeout: .seconds(5)) {
                  blockers = await webAudio.discardBlockers()
                  return blockers == [.playingAudio]
              }, detail: "\(blockers)")
        check("discard blockers (view): a page with an edited text field is kept",
              await waitUntilAsync(timeout: .seconds(5)) {
                  blockers = await typed.discardBlockers()
                  return blockers == [.formInteraction]
              }, detail: "\(blockers)")
        // Checked after the audible pages had time to be reported.
        let mutedBlockers = await muted.discardBlockers()
        let mutedPlaying = (try? await muted.evaluateJavaScript("!player.paused && player.currentTime > 0").boolValue) ?? false
        check("discard blockers (view): a playing muted video is not audio", mutedPlaying && mutedBlockers == [.visible],
              detail: "playing \(mutedPlaying), \(mutedBlockers)")
        let quiet = await silent.discardBlockers()
        check("discard blockers (view): a silent, untouched page reports neither", quiet.isEmpty, detail: "\(quiet)")
        // The DevTools scan runs only when nothing native keeps the page,
        // so a policy polling visible pages never attaches them. (The
        // audible pages above were set up with a user gesture, which is
        // itself sent through DevTools.)
        let (shown, shownView) = await makePage("view-shown", hidden: false)
        let shownBlockers = await shown.discardBlockers()
        check("discard blockers (view): a visible page is not asked of DevTools",
              shownBlockers == [.visible] && !shown.devTools.isAttached,
              detail: "\(shownBlockers), attached \(shown.devTools.isAttached)")
        await closeHosted(shown, shownView)
        check("discard blockers (view): a page nothing native keeps is asked of DevTools, which stays attached",
              silent.devTools.isAttached)

        _ = try? await element.evaluateJavaScript("player.pause(); 'ok'")
        try? await Task.sleep(for: .milliseconds(500))
        let recent = await element.discardBlockers()
        check("discard blockers (view): a page that fell silent is kept for a minute", recent == [.playingAudio],
              detail: "\(recent)")
        var refusal: CefPage.DiscardError?
        do { try await webAudio.discard() } catch { refusal = error }
        check("discard blockers (view): discard() refuses a page playing audio",
              refusal == .blocked([.playingAudio]) && !webAudio.isDiscarded, detail: "\(String(describing: refusal))")

        let warmCall = await ContinuousClock().measure { _ = await silent.discardBlockers() }
        print("INFO discard blockers (view): first call \(coldCall) (starts the discards host unless it runs), then \(warmCall)")
        check("discard blockers (view): a look-up with the host running is quick", warmCall < .milliseconds(500),
              detail: "\(warmCall)")

        for (page, view) in [(silent, silentView), (element, elementView), (webAudio, webAudioView),
                                (muted, mutedView), (typed, typedView)] {
            await closeHosted(page, view)
        }
    }

    // MARK: beforeunload

    /// `beforeunload` listeners in any frame, added and removed after load,
    /// and `onbeforeunload` assigned, for both runtime styles. Chromium
    /// asks every frame, so a listener in a same-site or a cross-site
    /// (out-of-process) `iframe` keeps the page too.
    static func beforeUnloadBlockerChecks() async {
        for style in ["view", "window"] {
            func open(_ path: String) async -> (page: CefPage, close: () async -> Void) {
                let page = CefPage(url: URL(string: "selftest://edge/\(path)")!)
                if style == "view" {
                    let view = hostWindowed(page)
                    _ = await loaded(page)
                    view.isHidden = true
                    return (page, { await closeHosted(page, view) })
                }
                let window = CefWindow(page: page)
                window.show()
                _ = await loaded(page)
                window.hide()
                return (page, {
                    page.close(force: true)
                    _ = await waitUntil { window.isClosed && page.state == .closed }
                })
            }
            /// Runs `script` (in the page's first subframe if `inFrame`),
            /// then checks whether the page is kept for its listeners.
            func expectKept(
                _ name: String, _ page: CefPage, _ script: String?, inFrame: Bool = false, kept: Bool
            ) async {
                if let script {
                    if inFrame, let frame = page.frames.first(where: { !$0.isMain }) {
                        _ = try? await page.evaluateJavaScript(script, in: frame)
                    } else {
                        _ = try? await page.evaluateJavaScript(script)
                    }
                }
                // Hidden windows take a moment to reach Chromium's tab state.
                var blockers: Set<CefPage.DiscardBlocker> = []
                let agreed = await waitUntilAsync(timeout: .seconds(5)) {
                    blockers = await page.discardBlockers()
                    return blockers == (kept ? [.beforeUnloadHandler] : [])
                }
                check("discard blockers (\(style)): \(name)", agreed, detail: "\(blockers)")
            }

            let opened = await open("tab.html?beforeunload")
            await expectKept("a page without beforeunload listeners is not kept", opened.page, nil, kept: false)
            await expectKept("a beforeunload listener added after load keeps the page", opened.page,
                             "window.__leave = event => event.preventDefault(); addEventListener('beforeunload', __leave)",
                             kept: true)
            await expectKept("removing the listener again releases it", opened.page,
                             "removeEventListener('beforeunload', __leave)", kept: false)
            await expectKept("window.onbeforeunload keeps the page", opened.page,
                             "onbeforeunload = () => 'stay'", kept: true)
            await expectKept("window.onbeforeunload = null releases it", opened.page,
                             "onbeforeunload = null", kept: false)
            await opened.close()

            let sameSite = await open("leave-frame.html")
            await expectKept("a listener in a same-site iframe keeps the page", sameSite.page, nil, kept: true)
            await sameSite.close()

            let crossSite = await open("plain-xframe.html")
            let separate = crossSite.page.frames.count == 2
                && Set(crossSite.page.frames.map { $0.id.split(separator: "-").first }).count == 2
            check("discard blockers (\(style)): the cross-site iframe is in a renderer of its own", separate,
                  detail: "\(crossSite.page.frames.map(\.id))")
            await expectKept("a cross-site iframe without listeners does not keep the page", crossSite.page,
                             nil, kept: false)
            await expectKept("a listener a cross-site iframe adds after load keeps the page", crossSite.page,
                             "window.__leave = () => {}; addEventListener('beforeunload', __leave)",
                             inFrame: true, kept: true)
            await expectKept("the cross-site iframe removing it releases the page", crossSite.page,
                             "removeEventListener('beforeunload', __leave)", inFrame: true, kept: false)
            await crossSite.close()
        }
    }

    // MARK: Views

    static func viewDiscardChecks() async {
        let recorder = DiscardRecorder()
        let attachment = RecordingAttachment()
        var configuration = discardConfiguration()
        configuration.attachments = [attachment]
        let page = CefPage(url: URL(string: "selftest://edge/heavy.html?view")!, configuration: configuration, delegate: recorder)
        let view = hostWindowed(page)
        _ = await loaded(page, title: "heavy")
        let renderer = await allocateInRenderer(page)
        _ = try? await page.devTools.send("Runtime.enable")
        var consoleMessages: [String] = []
        let consoleWatcher = Task {
            for await event in page.devTools.events("Runtime.consoleAPICalled") {
                consoleMessages.append(event["args"][0]["value"].stringValue ?? "")
            }
        }
        defer { consoleWatcher.cancel() }

        let url = page.url
        view.isHidden = true
        await expect("discard (view): a hidden view's browser is discarded") {
            try await page.discard()
            return page.isDiscarded && page.state == .live && page.url == url && page.title == "heavy"
        }
        if let renderer {
            let exited = await waitUntil(timeout: .seconds(10)) { footprint(of: renderer.pid) == nil }
            print("INFO discard (view): renderer \(renderer.pid) at \(renderer.megabytes) MB \(exited ? "exited" : "is still running at \(footprint(of: renderer.pid) ?? 0) MB")")
            check("discard (view): the renderer process exits", exited)
        } else {
            check("discard (view): the renderer process exits", false, detail: "renderer not found")
        }
        check("discard (view): stays in CefRuntime.pages", CefRuntime.shared.pages.contains { $0 === page })

        view.isHidden = false
        check("discard (view): showing the view restores the page",
              await waitUntil { !page.isDiscarded && !page.isLoading && page.url == url },
              detail: "\(recorder.events)")
        await expect("discard (view): user script and bridge work after restore") {
            let injected = try await page.evaluateJavaScript("window.__injected").intValue
            let greeting = try await page.evaluateJavaScript("app.greet({name: 'Ada'})").stringValue
            return injected == 42 && greeting == "Hello, Ada from main!"
        }
        await expect("discard (view): DevTools event stream keeps delivering") {
            try await page.evaluateJavaScript("console.log('view restored')")
            return await waitUntil(timeout: .seconds(5)) { consoleMessages.contains("view restored") }
        }
        check("discard (view): delegate hears will, did and restore",
              recorder.events == ["will", "did", "restore"], detail: "\(recorder.events)")
        check("discard (view): an attachment is told of the restore, once, before the page loads again",
              attachment.events == ["create", "created", "restore"] && attachment.pageDuringRestore == "about:blank",
              detail: "\(attachment.events), \(attachment.pageDuringRestore ?? "nil")")

        view.isHidden = true
        check("discard (view): a restored browser is discarded again", (try? await page.discard()) != nil && page.isDiscarded)
        page.close()
        view.removeFromSuperview()
        check("discard (view): a discarded browser closes", await waitUntil { page.state == .closed })
        check("discard (view): … and its attachment hears the close once, after the creation",
              attachment.events == ["create", "created", "restore", "close"], detail: "\(attachment.events)")
    }

    // MARK: Quitting

    /// Pages left discarded for the quit, opened after the census check
    /// so that it sees only what CefKit leaked.
    static var pagesDiscardedForQuitting: [AnyObject] = []

    /// Leaves a discarded Chrome-style window and a discarded view-hosted
    /// page open, so that quitting runs with both.
    static func discardPagesForQuitting() async {
        SelfTestResults.shared.group = "quit"
        let tab = CefPage(url: URL(string: "selftest://edge/tab.html?quit")!)
        let tabWindow = CefWindow(page: tab)
        tabWindow.show()
        let viewed = CefPage(url: URL(string: "selftest://edge/tab.html?quit-view")!)
        let view = hostWindowed(viewed)
        _ = await allLoaded([tab, viewed], title: "tab")
        tabWindow.hide()
        view.isHidden = true
        await waitUntilDiscardable(tab)
        let discarded = (try? await tab.discard()) != nil && tab.isDiscarded
        let viewDiscarded = (try? await viewed.discard()) != nil && viewed.isDiscarded
        check("quit: a Chrome-style tab and a view's browser are discarded for quitting", discarded && viewDiscarded,
              detail: "tab \(discarded), view \(viewDiscarded)")
        pagesDiscardedForQuitting = [tabWindow, view]
    }

    /// Waits until nothing keeps `page` loaded but what `allowed`
    /// accepts: a hidden window takes a moment to reach Chromium's tab
    /// state, and a page that just loaded to settle.
    static func waitUntilDiscardable(
        _ page: CefPage, allowing allowed: (CefPage.DiscardBlocker) -> Bool = { _ in false }
    ) async {
        _ = await waitUntilAsync(timeout: .seconds(5)) { await page.discardBlockers().allSatisfy(allowed) }
    }

    // MARK: Processes

    /// Fills 200 MB in the page's renderer and returns that renderer: the
    /// one renderer process whose footprint grew by more than 150 MB.
    static func allocateInRenderer(_ page: CefPage) async -> (pid: Int32, megabytes: Int)? {
        let before = Dictionary(uniqueKeysWithValues: rendererProcesses().map { ($0, footprint(of: $0) ?? 0) })
        _ = try? await page.evaluateJavaScript("__allocate()")
        try? await Task.sleep(for: .milliseconds(300))
        for pid in rendererProcesses() {
            let now = footprint(of: pid) ?? 0
            if now - (before[pid] ?? 0) > 150 { return (pid, now) }
        }
        return nil
    }

    /// The physical footprint of `pid` in megabytes; `nil` once it has exited.
    static func footprint(of pid: Int32) -> Int? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0, kill(pid, 0) == 0 else { return nil }
        return Int(info.ri_phys_footprint / 1_048_576)
    }

    /// This app's renderer processes.
    static func rendererProcesses() -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-x", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), Int32(fields[1]) == getpid(),
                  fields[2].contains("--type=renderer") else { return nil }
            return pid
        }
    }
}
