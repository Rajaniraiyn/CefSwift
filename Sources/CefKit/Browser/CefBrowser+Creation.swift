import AppKit
import CCef
import Foundation
import Observation
import CefBase

// MARK: - Creation

extension CefBrowser {
    private struct Blueprint {
        var client: UnsafeMutablePointer<cef_client_t>
        var settings: cef_browser_settings_t
        var url: String
        var requestContext: UnsafeMutablePointer<cef_request_context_t>?
        /// Bridges and user scripts, for the renderer.
        var extraInfo: UnsafeMutablePointer<cef_dictionary_value_t>?
    }

    /// Builds everything browser creation needs. Each returned reference is
    /// consumed by the CEF creation call it is passed to.
    private func makeBlueprint(offscreenHost: CefOffscreenHost? = nil, frameRate: Int = 0) -> Blueprint {
        precondition(CefRuntime.shared.isRunning, "Create browsers after CefRuntime.shared.initialize().")
        precondition(
            (state == .pending || isDiscarded) && client == nil, "This CefBrowser has already been created.")

        let client = CefBrowserClient(
            browser: self,
            requestFilter: configuration.requestFilter,
            chromeToolbar: CefRuntime.shared.configuration?.chromeToolbar ?? .init())
        client.offscreenHost = offscreenHost
        self.client = client

        var settings = cef_browser_settings_t()
        settings.size = MemoryLayout<cef_browser_settings_t>.stride
        settings.windowless_frame_rate = Int32(frameRate)
        if let color = configuration.backgroundColor {
            settings.background_color = cefColor(color.cgColor)
        }

        // Bridges and user scripts reach the renderer with the browser
        // itself (extra_info). Attachments that must prepare before any
        // page runs do so before the first real document, so such
        // browsers start blank and navigate once set up, as does every
        // browser created again after a discard.
        configuration.bridges.forEach { $0.attach(to: self) }
        isBootstrapping = attachmentsPrepareBeforeFirstDocument || isDiscarded
        let url = isBootstrapping ? "about:blank" : (initialURL?.absoluteString ?? "about:blank")

        return Blueprint(
            client: client.makeClient(),
            settings: settings,
            url: url,
            requestContext: (configuration.profile ?? .default).makeRequestContext(),
            extraInfo: pageScripting.makeExtraInfo())
    }

    /// Shows the browser as a native child view of `parentView`: creates it
    /// on first use, and afterwards moves its view there. `CefWebView` calls
    /// this; call it yourself to host a browser in AppKit.
    public func host(windowedIn parentView: NSView) {
        guard state != .closed else { return }
        CefRuntime.shared.lifecycleCoordinator.setNeedsUpdate()
        if client == nil {
            // A browser discarded by closing it comes back when shown.
            guard state == .pending || isDiscarded else { return }
            createWindowed(in: parentView)
        }
        guard let native = nativeView else { return }
        if native.superview !== parentView {
            native.removeFromSuperview()
            parentView.addSubview(native)
        }
        native.frame = parentView.bounds
        native.autoresizingMask = [.width, .height]
        hostView = parentView
    }

    /// Shows the browser through an offscreen host: creates it on first
    /// use, and afterwards redirects its frames and input to `host`.
    public func host(offscreenIn host: CefOffscreenHost, size: CGSize) {
        guard state != .closed else { return }
        restoringOffscreenHost = host
        guard let client else {
            hostView = host as? NSView
            // A browser discarded by closing it comes back when shown.
            guard state == .pending || isDiscarded else { return }
            createOffscreen(host: host, size: size)
            return
        }
        guard client.offscreenHost !== host else { return }
        client.offscreenHost = host
        hostView = host as? NSView
        hostViewDidResize()
        setNeedsDisplay()
    }

    private func createWindowed(in parentView: NSView) {
        var blueprint = makeBlueprint()
        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.stride
        windowInfo.bounds = cef_rect_t(parentView.bounds)
        windowInfo.parent_view = Unmanaged.passUnretained(parentView).toOpaque()
        // CEF always gives a browser in a parent view Alloy style.
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_DEFAULT
        hostView = parentView
        isEmbeddedView = true

        // on_after_created adopts the browser before this returns.
        let created = CefStringUtil.withCefString(blueprint.url) {
            cef_browser_host_create_browser_sync(
                &windowInfo, blueprint.client, $0, &blueprint.settings, blueprint.extraInfo, blueprint.requestContext)
        }
        cefRelease(created)
        if created == nil { creationFailed() }
    }

    private func createOffscreen(host: CefOffscreenHost, size: CGSize) {
        precondition(
            CefRuntime.shared.configuration?.isOffscreenRenderingEnabled == true,
            "Offscreen browsers need CefRuntime.Configuration.isOffscreenRenderingEnabled = true at initialize().")
        var frameRate = 60
        if case .offscreen(let requested) = configuration.rendering { frameRate = requested }
        var blueprint = makeBlueprint(offscreenHost: host, frameRate: frameRate)

        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.stride
        windowInfo.windowless_rendering_enabled = 1
        windowInfo.shared_texture_enabled = 1
        // Chromium times frames itself, at the browser's frame rate. Frames
        // requested from a display link (external begin frames) reach the
        // same rate only with a frame rate at least the display's, and a
        // mouse move then takes longer to reach a frame; see the
        // architecture guide's "Frame timing".
        windowInfo.external_begin_frame_enabled = Self.usesExternalBeginFrames ? 1 : 0
        windowInfo.bounds = cef_rect_t(CGRect(origin: .zero, size: size))
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        hostView = host as? NSView

        let started = CefStringUtil.withCefString(blueprint.url) {
            cef_browser_host_create_browser(
                &windowInfo, blueprint.client, $0, &blueprint.settings, blueprint.extraInfo, blueprint.requestContext)
        }
        if started == 0 { creationFailed() }
    }

    /// Creates a Chrome-style browser view for a ``CefBrowserWindow``.
    /// Returns a +1 `cef_browser_view_t`.
    func createBrowserView(
        delegate: UnsafeMutablePointer<cef_browser_view_delegate_t>, showsStatusBubble: Bool, showsZoomBubble: Bool
    ) -> UnsafeMutablePointer<cef_browser_view_t>? {
        var blueprint = makeBlueprint()
        isChromeStyle = true
        if !showsStatusBubble { blueprint.settings.chrome_status_bubble = STATE_DISABLED }
        if !showsZoomBubble { blueprint.settings.chrome_zoom_bubble = STATE_DISABLED }
        return CefStringUtil.withCefString(blueprint.url) {
            cef_browser_view_create(blueprint.client, $0, &blueprint.settings, blueprint.extraInfo, blueprint.requestContext, delegate)
        }
    }

    /// Creates the browser in a window owned and drawn entirely by Chrome:
    /// tab strip, omnibox, menus, extensions toolbar.
    func createInChromeUIWindow(frame: CGRect?) {
        var blueprint = makeBlueprint()
        isChromeStyle = true
        var windowInfo = cef_window_info_t()
        windowInfo.size = MemoryLayout<cef_window_info_t>.stride
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME
        if let frame {
            windowInfo.bounds = cef_rect_t(screenRect: frame)
        }
        let started = CefStringUtil.withCefString(blueprint.url) {
            cef_browser_host_create_browser(
                &windowInfo, blueprint.client, $0, &blueprint.settings, blueprint.extraInfo, blueprint.requestContext)
        }
        if started == 0 { creationFailed() }
    }

    func creationFailed() {
        client?.cancelCreation()
        client = nil
        discardPhase = .none
        handleClosed()
    }

    /// Takes over the live `cef_browser_t` once Chromium has created it.
    func adopt(_ raw: CefRef<cef_browser_t>) {
        self.raw = raw
        appliedOffscreenFrameRate = nil
        identifier = raw.pointer.pointee.get_identifier(raw.pointer)
        let isRestoring = isDiscarded
        state = .live
        CefRuntime.shared.register(self)
        if !isBootstrapping { readyWaiters.completeAll(.success(())) }
        refreshZoomLevel()
        refreshAudioMuted()
        applyInitialAccessibilityState()
        // A host that could not be seen when it asked for the browser told
        // nobody: Chromium creates offscreen browsers visible.
        if isOffscreen, isHostViewHidden {
            withHost { $0.pointee.was_hidden($0, 1) }
        }
        if isRestoring {
            discardPhase = .restoring
        } else {
            delegate?.browserDidCreate(self)
        }
        if isBootstrapping {
            Task { await bootstrap() }
        } else if !configuration.attachments.isEmpty {
            // Nothing waits for these. A browser Chromium created by itself
            // with attachments that prepare first is not a page's popup,
            // which `route(_:)` opens bootstrapped instead, but a popup
            // that never reached `route(_:)`; its first document may run
            // before this.
            Task {
                for attachment in configuration.attachments { await attachment.browserDidCreate(self) }
            }
        }
    }

    /// Whether an attachment needs the browser set up before its first
    /// document; see ``CefBrowserAttachment/preparesBeforeFirstDocument``.
    var attachmentsPrepareBeforeFirstDocument: Bool {
        configuration.attachments.contains { $0.preparesBeforeFirstDocument }
    }

    /// Sets up what needs the DevTools protocol before the first real
    /// document, then performs the real first load.
    ///
    /// A browser created again after a discard always comes through here,
    /// so everything a page relies on is in place before its document
    /// starts: the DevTools domains enabled before the discard, the
    /// accessibility state and the attachments. Bridges and user scripts
    /// travel with the browser's creation instead.
    private func bootstrap() async {
        await Self.$settingUp.withValue(id) {
            let isRestoring = isDiscarded
            if isRestoring {
                await devTools.enableDomainsAgain()
                reassertAccessibilityState()
            }
            for attachment in configuration.attachments {
                if isRestoring {
                    await attachment.browserDidRestore(self)
                } else {
                    await attachment.browserDidCreate(self)
                }
            }
        }
        isBootstrapping = false
        guard state == .live else { return }
        if let initialURL { startLoad(initialURL) }
        readyWaiters.completeAll(.success(()))
    }
}

extension cef_rect_t {
    /// A view-local rectangle, rounded to whole points and at least 1×1.
    init(_ rect: CGRect) {
        self.init(
            x: Int32(rect.origin.x.rounded()), y: Int32(rect.origin.y.rounded()),
            width: Int32(max(1, rect.width.rounded())), height: Int32(max(1, rect.height.rounded())))
    }

    /// An AppKit screen rectangle (bottom-left origin) in CEF's screen
    /// coordinates (top-left origin of the primary display).
    @MainActor
    init(screenRect: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenRect.maxY
        self.init(
            x: Int32(screenRect.origin.x.rounded()), y: Int32((primaryHeight - screenRect.maxY).rounded()),
            width: Int32(screenRect.width.rounded()), height: Int32(screenRect.height.rounded()))
    }
}
