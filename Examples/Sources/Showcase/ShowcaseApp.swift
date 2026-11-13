import CefSwiftUI
import SwiftUI

/// Embedding web content in a SwiftUI app: the lean `.embedded`
/// configuration, both rendering modes, and a typed JavaScript bridge to a
/// page served from a custom scheme.
@main
struct ShowcaseApp: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.embedded
        configuration.isOffscreenRenderingEnabled = true
        configuration.customSchemes = [CefCustomScheme(name: "showcase")]
        return configuration
    }

    init() {
        // Chromium is running by now; register before any view loads a page.
        CefRuntime.shared.registerSchemeHandler(scheme: "showcase", handler: ShowcasePages())
    }

    var body: some Scene {
        WindowGroup {
            ShowcaseView()
        }
        .defaultSize(width: 1100, height: 720)
    }
}

struct ShowcaseView: View {
    enum Demo: String, CaseIterable, Identifiable {
        case webView = "Web View"
        case overlay = "Native Overlay"
        case bridge = "JavaScript Bridge"

        var id: Self { self }
        var symbol: String {
            switch self {
            case .webView: "globe"
            case .overlay: "square.2.layers.3d"
            case .bridge: "arrow.left.arrow.right"
            }
        }
    }

    /// Launch with `-demo "JavaScript Bridge"` to open a specific demo.
    @State private var selection: Demo? = Demo(rawValue: UserDefaults.standard.string(forKey: "demo") ?? "") ?? .webView

    var body: some View {
        NavigationSplitView {
            List(Demo.allCases, selection: $selection) { demo in
                Label(demo.rawValue, systemImage: demo.symbol)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            switch selection {
            case .webView, nil: WebViewDemo()
            case .overlay: OverlayDemo()
            case .bridge: BridgeDemo()
            }
        }
    }
}

// MARK: - Web view bound to browser state

struct WebViewDemo: View {
    @State private var browser = CefBrowser(url: URL(string: "https://www.swift.org")!)

    var body: some View {
        CefWebView(browser)
            .navigationTitle(browser.title.isEmpty ? "Web View" : browser.title)
            .toolbar {
                ToolbarItem {
                    Button("Developer Tools", systemImage: "wrench.and.screwdriver") { browser.showDevTools() }
                }
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left", action: browser.goBack).disabled(!browser.canGoBack)
                    Button("Forward", systemImage: "chevron.right", action: browser.goForward).disabled(!browser.canGoForward)
                }
                ToolbarItem {
                    if browser.isLoading { ProgressView(value: browser.estimatedProgress).frame(width: 80) }
                }
            }
            .onDisappear { browser.close(force: true) }
    }
}

// MARK: - Offscreen rendering under SwiftUI content

struct OverlayDemo: View {
    @State private var browser: CefBrowser = {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        configuration.allowsBackForwardNavigationGestures = true
        return CefBrowser(url: URL(string: "https://developer.apple.com/swiftui/")!, configuration: configuration)
    }()

    var body: some View {
        CefWebView(browser)
            // A swipe indicator drawn from the browser's swipe progress.
            .overlay {
                let value = browser.navigationGestureProgress
                let progress = min(1, abs(value))
                Image(systemName: value < 0 ? "chevron.left" : "chevron.right")
                    .font(.title2.weight(.semibold))
                    .padding(12)
                    .background(.regularMaterial, in: .circle)
                    .scaleEffect(0.6 + 0.4 * progress)
                    .opacity(progress)
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: value < 0 ? .leading : .trailing)
                    .allowsHitTesting(false)
            }
            .clipShape(.rect(cornerRadius: 16))
            .padding()
            .overlay(alignment: .bottom) {
                // Native SwiftUI, composited over live web pixels.
                Label(browser.url?.host() ?? "Loading…", systemImage: "lock.fill")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: .capsule)
                    .padding(32)
            }
            .navigationTitle("Native Overlay")
            .onDisappear { browser.close(force: true) }
    }
}

// MARK: - Typed Swift ↔ JavaScript calls

@MainActor
@Observable
final class Counter {
    var value = 0
    let bridge = CefBridge(name: "app")
    let browser: CefBrowser

    init() {
        var configuration = CefBrowser.Configuration()
        configuration.bridges = [bridge]
        browser = CefBrowser(url: URL(string: "showcase://app/bridge.html")!, configuration: configuration)
        bridge.handle("increment") { [unowned self] (amount: Int) -> Int in
            value += amount
            return value
        }
    }
}

struct BridgeDemo: View {
    @State private var counter = Counter()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Swift counter: \(counter.value)").monospacedDigit()
                Spacer()
                Button("Send Event to Page") { counter.bridge.emit("shake", ["at": Date.now.formatted(date: .omitted, time: .standard)]) }
            }
            .padding()
            Divider()
            CefWebView(counter.browser)
        }
        .navigationTitle("JavaScript Bridge")
        .onDisappear { counter.browser.close(force: true) }
    }
}
