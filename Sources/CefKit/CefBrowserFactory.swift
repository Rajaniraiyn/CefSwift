import AppKit
import CCef
import Foundation

/// Creates CEF browsers embedded in AppKit view hierarchies.
@MainActor
public enum CefBrowserFactory {
    /// Creates a windowed browser as a child of `parentView` filling
    /// `bounds` (parent-view coordinates).
    ///
    /// Requires an initialized runtime (``CefRuntime/initialize(configuration:)``)
    /// and a `parentView` that is part of a window. Creation is synchronous;
    /// the returned browser is live (its ``CefBrowser/nativeView`` exists)
    /// unless creation failed, in which case `id == -1`.
    ///
    /// - Note: CEF always uses Alloy runtime style for browsers embedded via
    ///   a parent view, regardless of ``CefBrowserOptions/runtimeStyle``.
    public static func createBrowser(
        parentView: NSView,
        bounds: CGRect,
        url: URL,
        options: CefBrowserOptions = .init(),
        delegate: CefBrowserDelegate?
    ) -> CefBrowser {
        precondition(
            CefRuntime.shared.isInitialized,
            "CefBrowserFactory.createBrowser requires CefRuntime.shared.initialize() to have succeeded first."
        )

        let client = BrowserClient()
        let clientPointer = client.makeClient()

        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.stride
        windowInfo.bounds = cef_rect_t(
            x: Int32(bounds.origin.x.rounded()),
            y: Int32(bounds.origin.y.rounded()),
            width: Int32(bounds.size.width.rounded()),
            height: Int32(bounds.size.height.rounded())
        )
        windowInfo.parent_view = Unmanaged.passUnretained(parentView).toOpaque()
        // Fall back to the runtime-wide default style when the per-browser
        // option is .default.
        var style = options.runtimeStyle
        if case .default = style,
            let configured = CefRuntime.shared.configuration?.defaultRuntimeStyle
        {
            style = configured
        }
        windowInfo.runtime_style = style.cefValue

        var browserSettings = cef_browser_settings_t()
        browserSettings.size = MemoryLayout<cef_browser_settings_t>.stride
        if let color = options.backgroundColor?.usingColorSpace(.sRGB) {
            browserSettings.background_color = cefColor(color)
        }

        // Resolve the request context from the profile (nil = global).
        // The profile hands us a +1 reference that the create call consumes.
        let requestContext = options.profile?.makeRequestContext()

        // cef_browser_host_create_browser_sync consumes our +1 client ref and
        // returns a +1 browser ref that CefBrowser owns.
        let rawBrowser = CefStringUtil.withCefString(url.absoluteString) { cefURL in
            cef_browser_host_create_browser_sync(&windowInfo, clientPointer, cefURL, &browserSettings, nil, requestContext)
        }

        let browser = CefBrowser(raw: rawBrowser, client: client, delegate: delegate)
        client.attach(browser)
        CefRuntime.shared.registerBrowser(browser)
        return browser
    }

    /// Converts an sRGB NSColor to CEF's ARGB `cef_color_t`.
    private static func cefColor(_ color: NSColor) -> cef_color_t {
        let a = UInt32((color.alphaComponent * 255).rounded()) & 0xFF
        let r = UInt32((color.redComponent * 255).rounded()) & 0xFF
        let g = UInt32((color.greenComponent * 255).rounded()) & 0xFF
        let b = UInt32((color.blueComponent * 255).rounded()) & 0xFF
        return (a << 24) | (r << 16) | (g << 8) | b
    }
}
