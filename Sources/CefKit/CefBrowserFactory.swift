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

    /// Creates an **offscreen-rendered** (OSR) browser with no CEF-owned
    /// window: Chromium paints into a shared `IOSurface` delivered to `host`
    /// via the render handler, so the host can composite the pixels into a
    /// genuine in-tree `CALayer`/`CAMetalLayer`. This is the "indistinguishable
    /// embedded web view" mode.
    ///
    /// Requires ``CefConfiguration/windowlessRenderingEnabled`` to have been
    /// `true` when the runtime was initialized — otherwise this traps with an
    /// actionable message.
    ///
    /// Creation is asynchronous (CEF calls back into `on_after_created`); the
    /// returned ``CefBrowser`` has `id == -1` until then but is safe to retain
    /// and to forward input to once frames begin arriving.
    ///
    /// - Parameters:
    ///   - initialSize: Logical (DIP) size of the view.
    ///   - scale: Backing scale factor (e.g. 2.0 on retina).
    ///   - url: Initial URL.
    ///   - options: Background color etc. (runtime style is forced to Alloy).
    ///   - host: The view that supplies geometry and receives frames.
    ///   - delegate: Navigation/state observer (typically the same model).
    public static func createOSRBrowser(
        initialSize: CGSize,
        scale: CGFloat,
        url: URL,
        options: CefBrowserOptions = .init(),
        host: CefOSRHost,
        delegate: CefBrowserDelegate?
    ) -> CefBrowser {
        precondition(
            CefRuntime.shared.isInitialized,
            "CefBrowserFactory.createOSRBrowser requires CefRuntime.shared.initialize() to have succeeded first."
        )
        precondition(
            CefRuntime.shared.configuration?.windowlessRenderingEnabled == true,
            """
            CefBrowserFactory.createOSRBrowser requires windowless rendering. Set \
            `configuration.windowlessRenderingEnabled = true` before \
            CefRuntime.shared.initialize(configuration:).
            """
        )

        let client = BrowserClient()
        client.osrHost = host
        let clientPointer = client.makeClient()

        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.stride
        windowInfo.windowless_rendering_enabled = 1
        windowInfo.shared_texture_enabled = 1
        windowInfo.external_begin_frame_enabled = 0
        windowInfo.bounds = cef_rect_t(
            x: 0, y: 0,
            width: Int32(max(1, initialSize.width.rounded())),
            height: Int32(max(1, initialSize.height.rounded()))
        )
        // Windowless rendering forces Alloy style on macOS regardless of the
        // requested option.
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY

        var browserSettings = cef_browser_settings_t()
        browserSettings.size = MemoryLayout<cef_browser_settings_t>.stride
        browserSettings.windowless_frame_rate = 60
        if let color = options.backgroundColor?.usingColorSpace(.sRGB) {
            browserSettings.background_color = cefColor(color)
        }

        let requestContext = options.profile?.makeRequestContext()

        // Async creation: the browser arrives via on_after_created; adopt it
        // through the life-span handler. create_browser consumes our +1 client
        // ref. We build the wrapper first and let the client attach it; the raw
        // browser is adopted in on_after_created via the registry.
        let browser = CefBrowser(raw: nil, client: client, delegate: delegate)
        client.attach(browser)
        client.pendingOSRBrowser = browser

        _ = CefStringUtil.withCefString(url.absoluteString) { cefURL in
            cef_browser_host_create_browser(&windowInfo, clientPointer, cefURL, &browserSettings, nil, requestContext)
        }
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
