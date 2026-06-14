import AppKit
import CefKit
import CefSwiftUI
import Observation
import SwiftUI

// MARK: - App

/// CefSwift Launcher — a single SwiftUI app you open once, then launch each
/// hosting mode / configuration demo one at a time to try them out.
///
/// Each catalog entry opens its own window (repeatable, closable); the
/// Chrome-runtime entry opens a full CEF-owned chrome window via
/// ``LauncherChromeController``.
@main
struct LauncherApp: CefSwiftApp {

    static var cefConfiguration: CefConfiguration {
        var config = CefConfiguration()
        config.cachePath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.rajaniraiyn.cefswift.launcher/Cache", isDirectory: true)
        config.persistSessionCookies = true
        // The OSR / Metal, Incognito, Persistent, and Popups demos use
        // CefMetalWebView (offscreen rendering), which requires this.
        config.windowlessRenderingEnabled = true
        config.customSchemes = [CefCustomScheme(name: "launcher")]
        return config
    }

    @State private var chrome = LauncherChromeController()

    var body: some Scene {
        // The launcher catalog window.
        WindowGroup("CefSwift Launcher", id: "launcher") {
            LauncherView()
                .environment(chrome)
                .frame(minWidth: 720, minHeight: 480)
                .task { LauncherDemoPage.registerSchemeHandler() }
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 880, height: 560)
        .defaultPosition(.center)

        // A reusable embedded-demo window opened per catalog entry. SwiftUI
        // can open multiple instances (one per distinct demo id), each closable.
        WindowGroup("CefSwift Demo", id: "demo", for: LauncherDemo.ID.self) { $demoID in
            if let demoID, let demo = LauncherDemo.catalog.first(where: { $0.id == demoID }) {
                DemoWindow(demo: demo)
                    .navigationTitle(demo.title)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 980, height: 720)
    }
}

// MARK: - Catalog

/// One launchable demo in the catalog. The `kind` selects which hosting mode /
/// configuration the demo window builds.
struct LauncherDemo: Identifiable, Hashable {
    typealias ID = String

    let id: ID
    let title: String
    let subtitle: String
    let symbol: String
    let kind: Kind

    /// How the demo window hosts CEF + which configuration it exercises.
    enum Kind: Hashable {
        /// Windowed Alloy `CefWebView` (CEF renders into a child NSView).
        case windowedAlloy(url: URL)
        /// OSR / Metal `CefMetalWebView` (offscreen → IOSurface → CALayer).
        case osrMetal(url: URL)
        /// Full Chrome-runtime window (`CefChromeWindow`, inverted ownership).
        /// Handled specially (opens a CEF-owned window, not a SwiftUI scene).
        case chromeRuntime(url: URL)
        /// OSR view backed by an incognito profile.
        case incognitoProfile(url: URL)
        /// OSR view backed by a named persistent profile.
        case persistentProfile(url: URL, profileName: String)
        /// A custom-scheme page exercising the `window.cefswift` JS bridge.
        case jsBridge
        /// A page that triggers permission + JS-dialog prompts.
        case dialogsAndPermissions
        /// A page with a download link.
        case downloads
        /// A page with various link/popup types — drives the window-open
        /// disposition handler (Part B), OSR-safe.
        case popups
    }

    static let catalog: [LauncherDemo] = [
        LauncherDemo(
            id: "alloy",
            title: "Windowed Alloy",
            subtitle: "CefWebView — CEF renders into a child NSView. Max compatibility.",
            symbol: "rectangle.inset.filled",
            kind: .windowedAlloy(url: URL(string: "https://example.com")!)),
        LauncherDemo(
            id: "chrome",
            title: "Chrome Runtime Window",
            subtitle: "CefChromeWindow — full Chrome runtime + SwiftUI overlay (chrome:// works).",
            symbol: "macwindow.on.rectangle",
            kind: .chromeRuntime(url: URL(string: "https://duckduckgo.com")!)),
        LauncherDemo(
            id: "osr",
            title: "OSR / Metal",
            subtitle: "CefMetalWebView — offscreen → IOSurface → CALayer. Native UI composites over it.",
            symbol: "square.stack.3d.up.fill",
            kind: .osrMetal(url: URL(string: "https://animejs.com")!)),
        LauncherDemo(
            id: "incognito",
            title: "Incognito Profile",
            subtitle: "An OSR view in a private (off-the-record) profile — no cookies persist.",
            symbol: "eyeglasses",
            kind: .incognitoProfile(url: URL(string: "https://example.com")!)),
        LauncherDemo(
            id: "persistent",
            title: "Persistent Profile",
            subtitle: "An OSR view in a named on-disk profile — cookies/storage survive relaunch.",
            symbol: "externaldrive.fill",
            kind: .persistentProfile(url: URL(string: "https://example.com")!, profileName: "demo")),
        LauncherDemo(
            id: "bridge",
            title: "Custom Scheme + JS Bridge",
            subtitle: "A launcher:// page calling window.cefswift — native ↔ JS round-trips.",
            symbol: "point.3.connected.trianglepath.dotted",
            kind: .jsBridge),
        LauncherDemo(
            id: "dialogs",
            title: "Permissions & JS Dialogs",
            subtitle: "alert / confirm / prompt and a geolocation permission request.",
            symbol: "exclamationmark.bubble.fill",
            kind: .dialogsAndPermissions),
        LauncherDemo(
            id: "downloads",
            title: "Downloads",
            subtitle: "A download link — saved to ~/Downloads via the download delegate.",
            symbol: "arrow.down.circle.fill",
            kind: .downloads),
        LauncherDemo(
            id: "popups",
            title: "Popups & New Tabs",
            subtitle: "target=_blank, window.open, ⌘/middle-click — routed by the window-open handler.",
            symbol: "arrow.up.forward.app.fill",
            kind: .popups),
    ]
}

// MARK: - Demo page scheme handler

/// Serves the launcher:// demo pages and registers a bridge function. The
/// pages are intentionally tiny, self-contained HTML so the demos work fully
/// offline.
enum LauncherDemoPage {
    @MainActor private static var didRegister = false

    /// Registers the launcher:// scheme handler + a `ping` bridge function.
    /// Idempotent; call once after CEF init.
    @MainActor static func registerSchemeHandler() {
        guard !didRegister else { return }
        didRegister = true
        CefRuntime.shared.registerSchemeHandler(scheme: "launcher", handler: Handler())
        CefRuntime.shared.bridge.register("ping") { (message: String) -> String in
            "Swift received: \"\(message.prefix(120))\" @ "
                + Date.now.formatted(date: .omitted, time: .standard)
        }
    }

    /// URL for a given page path (e.g. `popups`, `dialogs`, `downloads`, `bridge`).
    static func url(_ path: String) -> URL { URL(string: "launcher://app/\(path)")! }

    private struct Handler: CefSchemeHandler {
        func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
            let path = request.url?.lastPathComponent ?? ""
            let html: String
            switch path {
            case "popups": html = popupsHTML
            case "dialogs": html = dialogsHTML
            case "downloads": html = downloadsHTML
            case "bridge": html = bridgeHTML
            default: html = "<h1>launcher demo</h1>"
            }
            return CefSchemeResponse(status: 200, mimeType: "text/html", body: Data(html.utf8))
        }
    }

    private static let head = """
        <meta charset="utf-8">
        <style>
          body { font: 15px -apple-system, system-ui, sans-serif; margin: 32px; color: #1d1d1f;
                 line-height: 1.5; }
          h1 { font-size: 22px; } h2 { font-size: 17px; margin-top: 28px; }
          a, button { font-size: 15px; }
          button { padding: 8px 16px; border-radius: 8px; border: none;
                   background: #0071e3; color: #fff; cursor: pointer; margin: 4px 0; }
          .row { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; margin: 8px 0; }
          .hint { color: #6e6e73; font-size: 13px; }
          #out { margin-top: 16px; padding: 12px; background: #f5f5f7; border-radius: 8px;
                 min-height: 2em; white-space: pre-wrap; }
        </style>
        """

    static let popupsHTML = """
        <!DOCTYPE html><html><head><title>Popups & New Tabs</title>\(head)</head><body>
        <h1>Popups &amp; New Tabs</h1>
        <p class="hint">These exercise the Electron-style window-open handler. In the OSR
        hosting mode the target loads in-place (no native popup is ever created);
        in the Chrome Browser shell they open as foreground/background tabs.</p>

        <h2>Links</h2>
        <div class="row">
          <a href="https://example.com" target="_blank">target=_blank link</a>
          <span class="hint">— ⌘-click or middle-click for a background tab</span>
        </div>
        <div class="row"><a href="https://www.wikipedia.org" target="_blank">another _blank link</a></div>

        <h2>window.open</h2>
        <div class="row">
          <button onclick="window.open('https://example.com', '_blank')">window.open(url)</button>
          <button onclick="window.open('https://example.com', 'named', 'width=640,height=480')">
            window.open with features</button>
        </div>

        <h2>Download</h2>
        <div class="row">
          <a href="data:text/plain;charset=utf-8,Hello%20from%20CefSwift%20Launcher!"
             download="cefswift-launcher.txt">download a text file</a>
        </div>
        </body></html>
        """

    static let dialogsHTML = """
        <!DOCTYPE html><html><head><title>Permissions & JS Dialogs</title>\(head)</head><body>
        <h1>Permissions &amp; JS Dialogs</h1>
        <h2>JavaScript dialogs</h2>
        <div class="row">
          <button onclick="alert('This is a native NSAlert presented by CefSwift.')">alert()</button>
          <button onclick="document.getElementById('out').textContent =
            'confirm() → ' + confirm('Proceed?')">confirm()</button>
          <button onclick="document.getElementById('out').textContent =
            'prompt() → ' + prompt('Your name?', 'Ada')">prompt()</button>
        </div>
        <h2>Permission request</h2>
        <div class="row">
          <button onclick="navigator.geolocation.getCurrentPosition(
            p => document.getElementById('out').textContent = 'granted: ' + p.coords.latitude,
            e => document.getElementById('out').textContent = 'denied/error: ' + e.message)">
            Request geolocation</button>
          <span class="hint">— routed through the permission delegate (denied by default)</span>
        </div>
        <div id="out">results appear here</div>
        </body></html>
        """

    static let downloadsHTML = """
        <!DOCTYPE html><html><head><title>Downloads</title>\(head)</head><body>
        <h1>Downloads</h1>
        <p class="hint">Clicking a download link triggers the download delegate, which
        saves to ~/Downloads by default.</p>
        <div class="row">
          <a href="data:application/octet-stream;base64,Q2VmU3dpZnQgTGF1bmNoZXIgZG93bmxvYWQgZGVtbyE="
             download="cefswift-download-demo.bin">download a binary file</a>
        </div>
        <div class="row">
          <a href="data:text/csv;charset=utf-8,a,b,c%0A1,2,3%0A4,5,6" download="data.csv">download a CSV</a>
        </div>
        </body></html>
        """

    static let bridgeHTML = """
        <!DOCTYPE html><html><head><title>Custom Scheme + JS Bridge</title>
        <script>\(CefBridge.javascriptShim)</script>\(head)</head><body>
        <h1>Custom Scheme + JS Bridge</h1>
        <p class="hint">This page is served over the <code>launcher://</code> custom scheme and
        calls a Swift function via <code>window.cefSwift.invoke</code>.</p>
        <div class="row"><button onclick="ping()">Call Swift ping()</button></div>
        <div id="out">waiting for first round-trip…</div>
        <script>
          let n = 0;
          async function ping() {
            n += 1;
            try {
              const reply = await window.cefSwift.invoke('ping', 'hello #' + n);
              document.getElementById('out').textContent = reply;
            } catch (e) { document.getElementById('out').textContent = 'bridge error: ' + e.message; }
          }
          ping();
        </script>
        </body></html>
        """
}

// MARK: - Chrome controller

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
            // Titlebar accessory auto-sizes; no manual inset needed — CEF's
            // BoxLayout still keeps the browser view below the standard titlebar.
            window.setContentInsets(NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
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

    func goBack()      { browser?.goBack() }
    func goForward()   { browser?.goForward() }
    func reload()      { browser?.reload() }
    func stopLoading() { browser?.stopLoading() }

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
        // Lives in the window's titlebar via NSTitlebarAccessoryViewController —
        // fully outside CEF's content view, so text fields get proper focus.
        HStack(spacing: 8) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
            Button {
                model.isLoading ? model.stopLoading() : model.reload()
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }
            TextField("Search or enter address", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.navigate() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .buttonStyle(.borderless)
    }
}
