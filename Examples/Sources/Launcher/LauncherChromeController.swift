import AppKit
import CefKit
import CefSwiftUI
import Observation
import SwiftUI

/// Owns the Chrome-runtime demo windows. Because a ``CefChromeWindow`` is a
/// CEF-owned NSWindow (inverted ownership), it lives outside SwiftUI's scene
/// graph; this controller opens/tracks them so the launcher can spawn several
/// and they each close cleanly.
@Observable
@MainActor
final class LauncherChromeController {
    private var windows: [ObjectIdentifier: CefChromeWindow] = [:]

    init() {}

    /// Number of live chrome windows (for the launcher's status text).
    var liveWindowCount: Int { windows.count }

    /// Opens a new Chrome-runtime window at `url` with a minimal SwiftUI
    /// toolbar overlay (back/forward/reload + address) on top of the full
    /// chrome runtime.
    func open(url: URL) {
        let model = ChromeWindowModel()
        let win = CefChromeWindow.open(
            url: url,
            initialBounds: CGRect(x: 200, y: 200, width: 1100, height: 760),
            delegate: model
        ) { window in
            window.setContentInsets(NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0))
            window.setOverlay { ChromeToolbar(model: model) }
        }
        model.window = win
        let key = ObjectIdentifier(win)
        windows[key] = win
        win.onClose = { [weak self] in self?.windows[key] = nil }
    }
}

/// Tiny per-window model that mirrors nav state and acts as the window's
/// delegate. Popups become new chrome windows (foreground/background honored).
@Observable
@MainActor
final class ChromeWindowModel: CefBrowserDelegate {
    weak var window: CefChromeWindow?
    var address: String = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false

    private var browser: CefBrowser? { window?.browser }

    func navigate() {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://\(text)" }
        if let url = URL(string: text) { browser?.load(url) }
    }

    func goBack() { browser?.goBack() }
    func goForward() { browser?.goForward() }
    func reload() { browser?.reload() }

    nonisolated init() {}

    func browser(_ b: CefBrowser, didChangeURL url: URL?) {
        if let url { address = url.absoluteString }
    }
    func browser(_ b: CefBrowser, didChangeLoading isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
    func browser(_ b: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        // Windowed/chrome browser: open the link as a fresh chrome window.
        if let url = request.targetURL {
            LauncherChromeController().open(url: url)  // detached window; closes independently
            return .handled
        }
        return .allowNativePopup
    }
}

/// A minimal omnibox-style toolbar composited over the chrome runtime.
private struct ChromeToolbar: View {
    @Bindable var model: ChromeWindowModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
            TextField("Search or enter address", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.navigate() }
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.regularMaterial)
        .buttonStyle(.borderless)
    }
}
