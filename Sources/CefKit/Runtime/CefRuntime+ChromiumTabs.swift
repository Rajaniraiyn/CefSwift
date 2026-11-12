import AppKit

@MainActor private var chromiumTabHandler: ((URL) -> Void)?

extension CefRuntime {
    /// Takes over the tabs and windows Chromium opens on its own initiative
    /// — following a link from `chrome://settings` to the password manager,
    /// say, or restoring a session after a crash. Each would otherwise
    /// appear in a window of Chrome's design, with its tab strip and
    /// toolbar. Instead its window is closed before it is ever seen, and
    /// this handler receives the URL it was opening, to show in your own UI:
    ///
    /// ```swift
    /// CefRuntime.shared.onChromiumOpensTab = { url in openTab(url) }
    /// ```
    ///
    /// Popups and DevTools, which have an opener, are not affected. Pages
    /// CefKit itself keeps in hidden windows (for ``CefProfile/bookmarks``
    /// and the like) that Chromium restores from a crashed session are
    /// closed, never handed over. Leave
    /// this `nil` in apps that use ``openChromeWindow(url:frame:options:delegate:)``,
    /// whose new tabs Chromium also opens itself.
    public var onChromiumOpensTab: ((URL) -> Void)? {
        get { chromiumTabHandler }
        set { chromiumTabHandler = newValue }
    }

    /// Redirects `browser`, which Chromium just created, to
    /// ``onChromiumOpensTab``. Returns whether it did.
    ///
    /// Either way, a restored service page is closed: Chromium saves the
    /// hidden windows of ``CefInternalServices`` in its session like any
    /// other and reopens them after a crash.
    func redirectChromiumTab(_ browser: CefBrowser) -> Bool {
        guard browser.opener == nil else { return false }
        guard let handler = chromiumTabHandler else {
            Task {
                if let url = await browser.firstNavigationURL(), CefInternalServices.isServicePage(url) {
                    browser.close(force: true)
                }
            }
            return false
        }
        ChromiumWindowHider.hide(browser)
        Task {
            let url = await browser.firstNavigationURL()
            browser.close(force: true)
            if let url, !CefInternalServices.isServicePage(url) { handler(url) }
        }
        return true
    }
}

/// Keeps the window of a browser Chromium created off screen. Chromium
/// creates and shows that window after announcing the browser, and gives
/// no handle to it, so every window update is checked until another
/// top-level window that is not a ``CefBrowserWindow`` appears. Chromium
/// fades new windows in, which leaves time to take it off screen before
/// it is seen.
@MainActor
private enum ChromiumWindowHider {
    static func hide(_ browser: CefBrowser) {
        // The window may exist already, but is not yet on screen.
        let existing = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        nonisolated(unsafe) var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { [weak browser] _ in
            MainActor.assumeIsolated {
                let ours = Set(CefBrowserWindow.all.compactMap(\.window).map(ObjectIdentifier.init))
                let opened = NSApp.windows.filter {
                    !existing.contains(ObjectIdentifier($0)) && !ours.contains(ObjectIdentifier($0))
                        && $0.isVisible && $0.parent == nil && $0.styleMask.contains(.titled)
                }
                for window in opened {
                    window.alphaValue = 0
                    window.orderOut(nil)
                }
                if browser == nil || browser?.state == .closed {
                    observer.map(NotificationCenter.default.removeObserver)
                }
            }
        }
    }
}

extension CefBrowser {
    /// The first URL a browser Chromium created navigates to; `nil` if it
    /// shows nothing within `timeout`.
    func firstNavigationURL(timeout: Duration = .seconds(3)) async -> URL? {
        let deadline = ContinuousClock.now + timeout
        while url == nil || url?.absoluteString == "about:blank", state != .closed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return url?.absoluteString == "about:blank" ? nil : url
    }
}
