import AppKit
import CefSwiftUI
import Darwin

/// Tab discarding: Chromium's own discard for Chrome-style windows, closing
/// and re-creating for views, blockers, the Memory Saver policy, and
/// quitting with discarded browsers.
extension SelfTest {
    static func discardChecks() async {
        await windowDiscardChecks()
        await discardBlockerChecks()
        await memorySaverChecks()
        await viewDiscardChecks()
    }

    /// Records the discard events a browser's delegate receives.
    final class DiscardRecorder: CefBrowserDelegate {
        var events: [String] = []
        func browserWillDiscard(_ browser: CefBrowser) { events.append("will") }
        func browserDidDiscard(_ browser: CefBrowser) { events.append("did") }
        func browserDidRestore(_ browser: CefBrowser) { events.append("restore") }
        func browser(_ browser: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason) {
            events.append("terminated")
        }
    }

    static func discardOptions() -> CefBrowserOptions {
        var options = CefBrowserOptions()
        options.bridges = [bridge]
        options.userScripts = [CefUserScript(source: "window.__injected = 42;")]
        return options
    }

    // MARK: Chrome-style windows

    /// A window kept for the quit check, discarded.
    static var discardedWindow: CefBrowserWindow?

    static func windowDiscardChecks() async {
        let recorder = DiscardRecorder()
        let browser = CefBrowser(url: URL(string: "selftest://edge/heavy.html?1")!, options: discardOptions(), delegate: recorder)
        let browserWindow = CefBrowserWindow(browser: browser)
        browserWindow.show()
        _ = await waitUntil { browser.title == "heavy" && !browser.isLoading }
        browser.load(URL(string: "selftest://edge/heavy.html?2")!)
        _ = await waitUntil { browser.url?.query == "2" && !browser.isLoading && browser.favicon != nil }
        let renderer = await allocateInRenderer(browser)
        _ = try? await browser.evaluateJavaScript("scrollTo(0, 1500)")
        // Chromium saves a page's scroll position within a second of it
        // changing.
        try? await Task.sleep(for: .milliseconds(1500))

        do {
            try await browser.discard()
            check("discard: the frontmost tab is refused", false, detail: "discarded")
        } catch {
            check("discard: the frontmost tab is refused", error == .blocked([.visible]), detail: "\(error)")
        }

        // A DevTools consumer subscribed before the discard.
        _ = try? await browser.devTools.send("Runtime.enable")
        var consoleMessages: [String] = []
        let consoleWatcher = Task {
            for await event in browser.devTools.events("Runtime.consoleAPICalled") {
                consoleMessages.append(event["args"][0]["value"].stringValue ?? "")
            }
        }
        defer { consoleWatcher.cancel() }

        browserWindow.hide()
        let title = browser.title, url = browser.url
        await expect("discard: a hidden tab is discarded") {
            try await browser.discard()
            return browser.isDiscarded && browser.state == .live
        }
        check("discard: delegate hears will and did", recorder.events == ["will", "did"], detail: "\(recorder.events)")
        if let renderer {
            let exited = await waitUntil(timeout: .seconds(10)) { footprint(of: renderer.pid) == nil }
            print("INFO discard (window): renderer \(renderer.pid) at \(renderer.megabytes) MB \(exited ? "exited" : "is still running at \(footprint(of: renderer.pid) ?? 0) MB")")
            check("discard: the tab's renderer process exits", exited)
        } else {
            check("discard: the tab's renderer process exits", false, detail: "renderer not found")
        }
        check("discard: URL, title and favicon stay", browser.url == url && browser.title == title && browser.favicon != nil)
        check("discard: snapshot of the page kept", browser.discardSnapshot != nil)
        check("discard: no renderer crash reported", !recorder.events.contains("terminated"))

        browserWindow.show()
        check("discard: showing the tab restores it", await waitUntil { !browser.isDiscarded && !browser.isLoading },
              detail: "\(recorder.events)")
        check("discard: restored on the same URL", browser.url == url && recorder.events.last == "restore")
        var scrollY: Int?
        check("discard: scroll position restored", await waitUntilAsync(timeout: .seconds(3)) {
            scrollY = try? await browser.evaluateJavaScript("scrollY").intValue
            return scrollY == 1500
        }, detail: "scrollY \(String(describing: scrollY))")
        await expect("discard: user script and bridge work after restore") {
            let injected = try await browser.evaluateJavaScript("window.__injected").intValue
            let greeting = try await browser.evaluateJavaScript("app.greet({name: 'Ada'})").stringValue
            return injected == 42 && greeting == "Hello, Ada from main!"
        }
        await expect("discard: DevTools event stream keeps delivering") {
            try await browser.evaluateJavaScript("console.log('after restore')")
            return await waitUntil(timeout: .seconds(5)) { consoleMessages.contains("after restore") }
        }
        await expect("discard: executeJavaScript reaches the restored page") {
            browser.executeJavaScript("window.__executed = 7")
            return await waitUntilAsync(timeout: .seconds(5)) {
                (try? await browser.evaluateJavaScript("window.__executed").intValue) == 7
            }
        }
        check("discard: back/forward list survives", browser.canGoBack)
        browser.goBack()
        check("discard: going back reaches the first page", await waitUntil { browser.url?.query == "1" && !browser.isLoading })

        // A command restores a hidden discarded tab.
        browserWindow.hide()
        await expect("discard: evaluateJavaScript restores a hidden discarded tab") {
            try await browser.discard()
            let href = try await browser.evaluateJavaScript("location.href").stringValue
            return href == "selftest://edge/heavy.html?1" && !browser.isDiscarded
        }

        // Left discarded for the quit check.
        _ = await waitUntil { !browser.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        check("discard: discarded again for quitting", (try? await browser.discard()) != nil && browser.isDiscarded)
        discardedWindow = browserWindow
    }

    // MARK: Blockers

    static func discardBlockerChecks() async {
        let audible = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://edge/tab.html?audio")!))
        let leaving = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://edge/leave.html")!))
        let pinned = CefBrowserWindow(browser: CefBrowser(url: URL(string: "selftest://edge/tab.html?pinned")!))
        let windows = [audible, leaving, pinned]
        windows.forEach { $0.show() }
        _ = await waitUntil { windows.allSatisfy { !$0.browser.isLoading && !$0.browser.title.isEmpty } }

        audible.browser.isAudioMuted = true
        _ = try? await audible.browser.evaluateJavaScript("""
            const context = new AudioContext(), tone = context.createOscillator(), gain = context.createGain();
            gain.gain.value = 0.05;
            tone.connect(gain).connect(context.destination);
            tone.start();
            context.state
            """)
        pinned.browser.allowsDiscarding = false
        try? await Task.sleep(for: .seconds(1))
        windows.forEach { $0.hide() }

        let audio = await audible.browser.discardBlockers()
        check("discard blockers: a page playing audio is kept", audio.contains(.playingAudio), detail: "\(audio)")
        await expect("discard blockers: a page with a beforeunload handler is kept") {
            do {
                try await leaving.browser.discard()
                return false
            } catch let error as CefDiscardError {
                guard case .blocked(let blockers) = error else { return false }
                return blockers.contains(.beforeUnloadHandler) && !leaving.browser.isDiscarded
            }
        }
        let exempt = await pinned.browser.discardBlockers()
        check("discard blockers: allowsDiscarding = false exempts a tab", exempt == [.exempt], detail: "\(exempt)")

        for window in windows { window.close() }
        // The beforeunload page asks before it closes; answer for it.
        leaving.browser.close(force: true)
        _ = await waitUntil { windows.allSatisfy(\.isClosed) }
    }

    // MARK: Memory Saver

    static func memorySaverChecks() async {
        let browser = CefBrowser(url: URL(string: "selftest://edge/tab.html?saver")!)
        let window = CefBrowserWindow(browser: browser)
        window.show()
        _ = await waitUntil { browser.title == "tab" && !browser.isLoading }
        CefRuntime.shared.memorySaver = .after(.seconds(2), orUnderMemoryPressure: false)
        try? await Task.sleep(for: .seconds(3))
        check("memory saver: a visible tab stays loaded", !browser.isDiscarded)
        window.hide()
        check("memory saver: a hidden tab is discarded after the interval",
              await waitUntil(timeout: .seconds(15)) { browser.isDiscarded })
        CefRuntime.shared.memorySaver = .off
        window.show()
        check("memory saver: the tab comes back when shown", await waitUntil { !browser.isDiscarded && !browser.isLoading })
        window.close()
        _ = await waitUntil { window.isClosed }
    }

    // MARK: Views

    /// A view-hosted browser kept discarded for the quit check.
    static var discardedViewBrowser: CefBrowser?

    static func viewDiscardChecks() async {
        let recorder = DiscardRecorder()
        let browser = CefBrowser(url: URL(string: "selftest://edge/heavy.html?view")!, options: discardOptions(), delegate: recorder)
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        view.browser = browser
        _ = await waitUntil { browser.title == "heavy" && !browser.isLoading }
        let renderer = await allocateInRenderer(browser)
        _ = try? await browser.devTools.send("Runtime.enable")
        var consoleMessages: [String] = []
        let consoleWatcher = Task {
            for await event in browser.devTools.events("Runtime.consoleAPICalled") {
                consoleMessages.append(event["args"][0]["value"].stringValue ?? "")
            }
        }
        defer { consoleWatcher.cancel() }

        let url = browser.url
        view.isHidden = true
        await expect("discard (view): a hidden view's browser is discarded") {
            try await browser.discard()
            return browser.isDiscarded && browser.state == .live && browser.url == url && browser.title == "heavy"
        }
        if let renderer {
            let exited = await waitUntil(timeout: .seconds(10)) { footprint(of: renderer.pid) == nil }
            print("INFO discard (view): renderer \(renderer.pid) at \(renderer.megabytes) MB \(exited ? "exited" : "is still running at \(footprint(of: renderer.pid) ?? 0) MB")")
            check("discard (view): the renderer process exits", exited)
        } else {
            check("discard (view): the renderer process exits", false, detail: "renderer not found")
        }
        check("discard (view): stays in CefRuntime.browsers", CefRuntime.shared.browsers.contains { $0 === browser })

        view.isHidden = false
        check("discard (view): showing the view restores the page",
              await waitUntil { !browser.isDiscarded && !browser.isLoading && browser.url == url },
              detail: "\(recorder.events)")
        await expect("discard (view): user script and bridge work after restore") {
            let injected = try await browser.evaluateJavaScript("window.__injected").intValue
            let greeting = try await browser.evaluateJavaScript("app.greet({name: 'Ada'})").stringValue
            return injected == 42 && greeting == "Hello, Ada from main!"
        }
        await expect("discard (view): DevTools event stream keeps delivering") {
            try await browser.evaluateJavaScript("console.log('view restored')")
            return await waitUntil(timeout: .seconds(5)) { consoleMessages.contains("view restored") }
        }
        check("discard (view): delegate hears will, did and restore",
              recorder.events == ["will", "did", "restore"], detail: "\(recorder.events)")

        // Left discarded for the quit check.
        view.isHidden = true
        check("discard (view): discarded again for quitting", (try? await browser.discard()) != nil && browser.isDiscarded)
        discardedViewBrowser = browser
    }

    // MARK: Processes

    /// Fills 200 MB in the page's renderer and returns that renderer: the
    /// one renderer process whose footprint grew by more than 150 MB.
    static func allocateInRenderer(_ browser: CefBrowser) async -> (pid: Int32, megabytes: Int)? {
        let before = Dictionary(uniqueKeysWithValues: rendererProcesses().map { ($0, footprint(of: $0) ?? 0) })
        _ = try? await browser.evaluateJavaScript("__allocate()")
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
