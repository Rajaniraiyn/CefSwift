import SwiftUI

/// One example in the gallery: a small view that shows one capability of
/// CefSwift.
///
/// To add one, write a type that conforms to `Demo` in
/// `Demos/<TypeName>.swift` and list it in ``Demos/all``.
@MainActor
protocol Demo {
    associatedtype Content: View

    var title: String { get }
    /// One or two sentences: what the demo shows.
    var summary: String { get }
    /// An SF Symbol.
    var symbol: String { get }
    var category: DemoCategory { get }

    @ViewBuilder func makeView() -> Content
}

extension Demo {
    var id: String { String(describing: Self.self) }

    /// Each demo lives in a file named after its type.
    var sourceFile: String { "Demos/\(id).swift" }
}

enum DemoCategory: String, CaseIterable {
    case webViews = "Web Views"
    case page = "Page"
    case javaScript = "JavaScript"
    case network = "Content and Network"
    case windows = "Chrome-Style Windows"
    case runtime = "Runtime"
    case chromiumData = "Chromium Data"
    case passkeys = "Passkeys"
}

@MainActor
enum Demos {
    static let all: [any Demo] = [
        ObservableStateDemo(),
        OffscreenOverlayDemo(),
        AnimationDemo(),
        SwipeNavigationDemo(),
        AppKitHostingDemo(),

        FindInPageDemo(),
        ContextMenuDemo(),
        PDFDemo(),
        DevToolsDemo(),

        EvaluateJavaScriptDemo(),
        BridgeDemo(),
        UserScriptsDemo(),
        FramesDemo(),

        CustomSchemeDemo(),
        RequestsDemo(),
        ProfilesDemo(),
        PermissionsDemo(),
        DownloadsDemo(),

        ChromeWindowDemo(),
        ChromiumSurfacesDemo(),
        TabStripDemo(),
        AppShellDemo(),

        TaskManagerDemo(),
        DiscardDemo(),
        MediaRouterDemo(),

        BookmarksDemo(),
        HistoryDemo(),
        SuggestionsDemo(),
        ExtensionsDemo(),

        PasskeysDemo(),
    ]
}
