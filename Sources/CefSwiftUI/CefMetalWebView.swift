import AppKit
import CefKit
import SwiftUI

/// A SwiftUI web view that renders Chromium **offscreen** into a shared
/// `IOSurface` composited in a `CALayer`-backed `NSView` — a genuine in-tree
/// subview that native SwiftUI/AppKit content can composite over and around
/// (unlike the windowed ``CefWebView``, whose CEF-owned surface always sits on
/// top). This is CefSwift's "indistinguishable embedded web view" primitive.
///
/// Mirrors ``CefWebView``'s API so it is a drop-in:
///
/// ```swift
/// CefMetalWebView(url: URL(string: "https://example.com")!)
///
/// // with an overlay composited ON TOP of the web pixels:
/// ZStack {
///     CefMetalWebView(model: model)
///     Badge().padding()          // native SwiftUI, over the page
/// }
/// ```
///
/// - Important: Requires `configuration.windowlessRenderingEnabled = true`
///   before `CefRuntime.initialize` (the factory traps otherwise). Offscreen
///   browsers always use Alloy style (no `chrome://` UI) — a macOS constraint.
public struct CefMetalWebView: NSViewRepresentable {

    private let externalModel: CefWebViewModel?
    private let initialURL: URL?

    /// Creates an offscreen web view driven by the given model.
    public init(model: CefWebViewModel) {
        self.externalModel = model
        self.initialURL = nil
    }

    /// Creates a self-contained offscreen web view loading `url`.
    public init(url: URL) {
        self.externalModel = nil
        self.initialURL = url
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(model: externalModel ?? CefWebViewModel(url: initialURL))
    }

    public func makeNSView(context: Context) -> CefMetalHostView {
        let view = CefMetalHostView()
        view.model = context.coordinator.model
        return view
    }

    public func updateNSView(_ nsView: CefMetalHostView, context: Context) {
        if let externalModel, externalModel !== context.coordinator.model {
            context.coordinator.model = externalModel
        }
        nsView.model = context.coordinator.model
    }

    public static func dismantleNSView(_ nsView: CefMetalHostView, coordinator: Coordinator) {
        nsView.tearDown()
    }

    @MainActor public final class Coordinator {
        var model: CefWebViewModel
        init(model: CefWebViewModel) { self.model = model }
    }
}
