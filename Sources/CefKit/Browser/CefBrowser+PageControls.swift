import AppKit
import CCef
import Foundation
import Observation
import CefBase

extension CefBrowser {
    // MARK: Page controls

    /// The page's zoom level: 0 is 100%, and each step of 1 scales the page
    /// by 20% (1.2ⁿ).
    ///
    /// The value is observable. Besides your own changes, it follows the
    /// zoom Chromium applies itself: the level it remembers for each site,
    /// which changes as the browser moves between sites and when another
    /// browser zooms the same site, and Chrome's zoom commands
    /// (``CefChromeCommand/zoomIn``, ``CefChromeCommand/zoomOut``,
    /// ``CefChromeCommand/resetZoom``), whether run through
    /// ``execute(_:disposition:)`` or chosen in a Chrome-style browser. CEF
    /// reports no zoom changes, so CefKit reads the level back after each of
    /// those events; a change Chromium makes in any other way shows up at
    /// the next navigation.
    ///
    /// In a windowed browser, pinching magnifies the page without changing
    /// its zoom level; `CefOffscreenBrowserView` turns pinches into
    /// zoom-level changes. Setting the level before the browser is live
    /// has no effect.
    public var zoomLevel: Double {
        get { observedZoomLevel }
        set {
            withHost { $0.pointee.set_zoom_level($0, newValue) }
            // Chromium applies the level per site, so other browsers on the
            // same site follow.
            CefBrowser.refreshZoomLevels()
        }
    }

    /// Reads the zoom level back from Chromium.
    func refreshZoomLevel() {
        let level = withHost { $0.pointee.get_zoom_level($0) } ?? observedZoomLevel
        if level != observedZoomLevel { observedZoomLevel = level }
    }

    /// Reads every browser's zoom level back, now and once Chromium has
    /// finished applying an asynchronous change.
    static func refreshZoomLevels() {
        refreshAll { $0.refreshZoomLevel() }
    }

    /// Runs `refresh` on every browser now, after Chromium's pending work,
    /// and again 250 ms later, for state Chromium changes asynchronously.
    private static func refreshAll(_ refresh: @escaping @MainActor (CefBrowser) -> Void) {
        let refreshAll = { CefRuntime.shared.browsers.forEach(refresh) }
        refreshAll()
        Task {
            await Task.yield()
            refreshAll()
            try? await Task.sleep(for: .milliseconds(250))
            refreshAll()
        }
    }

    /// Whether the browser's audio is muted.
    ///
    /// The value is observable. CEF reports no mute changes, so CefKit
    /// reads the state back after setting it, when the browser is created
    /// and at each loading-state change; a change made elsewhere, such as
    /// with the speaker icon of a Chrome-style tab, shows up then.
    /// Setting it before the browser is live has no effect.
    public var isAudioMuted: Bool {
        get { observedAudioMuted }
        set {
            withHost { $0.pointee.set_audio_muted($0, newValue ? 1 : 0) }
            refreshAudioMuted()
        }
    }

    /// Reads the mute state back from Chromium.
    func refreshAudioMuted() {
        let muted = withHost { $0.pointee.is_audio_muted($0) != 0 } ?? false
        if muted != observedAudioMuted { observedAudioMuted = muted }
    }

    /// Searches the page, or advances to the next match when `text` repeats
    /// the previous search — the previous one when `backwards` is set.
    /// Results arrive in ``findResult``.
    public func find(_ text: String, backwards: Bool = false, caseSensitive: Bool = false) {
        guard !isDiscarded else {
            whenRestored { [weak self] in self?.find(text, backwards: backwards, caseSensitive: caseSensitive) }
            return
        }
        let isRepeat = text == lastFindText
        lastFindText = text
        withHost { host in
            CefStringUtil.withCefString(text) {
                host.pointee.find(host, $0, backwards ? 0 : 1, caseSensitive ? 1 : 0, isRepeat ? 1 : 0)
            }
        }
    }

    /// Ends the find session.
    public func stopFinding(clearingSelection: Bool = true) {
        lastFindText = nil
        findResult = nil
        withHost { $0.pointee.stop_finding($0, clearingSelection ? 1 : 0) }
    }

    /// Opens the system print dialog for the page.
    public func print() {
        guard !isDiscarded else {
            whenRestored { [weak self] in self?.print() }
            return
        }
        withHost { $0.pointee.print($0) }
    }

    /// Captures the visible page as PNG data.
    ///
    /// An offscreen browser returns the frame its view shows, at the view's
    /// pixel size, with an open popup widget (a `<select>` list, a date
    /// picker) drawn where it is (``CefOffscreenHost/offscreenSnapshot()``);
    /// nothing is asked of the page. A windowed browser, and an offscreen
    /// one before its first frame, use the DevTools Protocol's
    /// `Page.captureScreenshot`, since CEF has no capture API for windowed
    /// browsers: it attaches ``devTools`` to the browser and enables no
    /// domain. That image is the page alone, without popup widgets.
    public func snapshot() async throws -> Data {
        if let image = client?.offscreenHost?.offscreenSnapshot() {
            guard let data = Self.pngData(image) else { throw CefError.operationFailed("could not encode the frame as PNG") }
            return data
        }
        let reply = try await devTools.send("Page.captureScreenshot", ["format": "png"])
        guard let base64 = reply["data"].stringValue, let data = Data(base64Encoded: base64) else {
            throw CefError.operationFailed("Page.captureScreenshot returned no image data")
        }
        return data
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: DevTools

    /// Opens Chrome DevTools for this browser in its own window, optionally
    /// inspecting the element at `point` (view coordinates).
    public func showDevTools(inspecting point: CGPoint? = nil) {
        guard !isDiscarded else {
            whenRestored { [weak self] in self?.showDevTools(inspecting: point) }
            return
        }
        withHost { host in
            var windowInfo = cef_window_info_t()
            windowInfo.size = MemoryLayout<cef_window_info_t>.stride
            windowInfo.bounds = cef_rect_t(x: 0, y: 0, width: 900, height: 700)
            var settings = cef_browser_settings_t()
            settings.size = MemoryLayout<cef_browser_settings_t>.stride
            if let point {
                var target = cef_point_t(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()))
                host.pointee.show_dev_tools(host, &windowInfo, nil, &settings, &target)
            } else {
                host.pointee.show_dev_tools(host, &windowInfo, nil, &settings, nil)
            }
        }
        CefBrowser.refreshDevToolsStates()
    }

    public func closeDevTools() {
        withHost { $0.pointee.close_dev_tools($0) }
        CefBrowser.refreshDevToolsStates()
    }
    /// Reads whether DevTools is open back from Chromium.
    private func refreshDevToolsState() {
        let showing = withHost { $0.pointee.has_dev_tools($0) != 0 } ?? false
        if showing != isShowingDevTools { isShowingDevTools = showing }
    }

    /// Reads every browser's DevTools state back, now and once Chromium
    /// has finished opening or closing a DevTools window.
    static func refreshDevToolsStates() {
        refreshAll { $0.refreshDevToolsState() }
    }

    // MARK: Chrome commands

    /// Whether Chrome can currently run `command` for this browser.
    /// Chrome-style browsers only.
    public func canExecute(_ command: CefChromeCommand) -> Bool {
        withHost { $0.pointee.can_execute_chrome_command($0, Int32(command.rawValue)) != 0 } ?? false
    }

    /// Runs one of Chrome's own commands — open history, zoom, find, print,
    /// bookmark, and so on. Chrome-style browsers only.
    ///
    /// In a ``CefWindow``, a command whose surface the window
    /// presents with your interface or hides (CefChromium's `chromiumUI`)
    /// goes there instead of to Chrome.
    public func execute(_ command: CefChromeCommand, disposition: CefWindowOpenDisposition = .currentTab) {
        if let window = CefWindow.hosting(self), window.intercept(command) { return }
        guard !isDiscarded else {
            whenRestored { [weak self] in self?.execute(command, disposition: disposition) }
            return
        }
        withHost { $0.pointee.execute_chrome_command($0, Int32(command.rawValue), disposition.cefValue) }
        if command.isZoomCommand { CefBrowser.refreshZoomLevels() }
    }

    // MARK: Downloads

    public func cancelDownload(_ id: CefDownload.ID) {
        downloadControls[id].map { $0.pointer.pointee.cancel($0.pointer) }
    }

    public func pauseDownload(_ id: CefDownload.ID) {
        downloadControls[id].map { $0.pointer.pointee.pause($0.pointer) }
    }

    public func resumeDownload(_ id: CefDownload.ID) {
        downloadControls[id].map { $0.pointer.pointee.resume($0.pointer) }
    }

    /// Downloads `url` as if the user had clicked a download link.
    public func startDownload(_ url: URL) {
        guard !isDiscarded else {
            whenRestored { [weak self] in self?.startDownload(url) }
            return
        }
        withHost { host in
            CefStringUtil.withCefString(url.absoluteString) { host.pointee.start_download(host, $0) }
        }
    }
}
