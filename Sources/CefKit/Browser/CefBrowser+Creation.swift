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
        client.isOffscreen = offscreenHost != nil
        self.client = client

        var settings = cef_browser_settings_t()
        settings.size = MemoryLayout<cef_browser_settings_t>.stride
        settings.windowless_frame_rate = Int32(frameRate)
        // Alpha 0 asks CEF for its default: white for a windowed browser,
        // but a transparent canvas for an offscreen one. So the color is
        // always opaque, unless an offscreen page is to be see-through.
        settings.background_color = offscreenHost != nil && !configuration.drawsBackground
            ? 0 : canvasColor.opaqueCefColor

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

    /// ``Configuration/backgroundColor`` as an opaque color, in the app's
    /// appearance.
    var canvasColor: CGColor {
        var color = configuration.backgroundColor.cgColor
        NSApp?.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = configuration.backgroundColor.cgColor
        }
        return color.copy(alpha: 1) ?? color
    }

    /// What the view behind the page shows: the canvas color, or nothing
    /// for a see-through offscreen page.
    var hostBackgroundColor: CGColor {
        !configuration.drawsBackground && configuration.rendering != .windowed ? .clear : canvasColor
    }

    /// Shows the browser as a native child view of `parentView`: creates it
    /// on first use, and afterwards moves its view there. `CefWebView` calls
    /// this; call it yourself to host a browser in AppKit.
    ///
    /// A browser shows in one host at a time. The host it showed in before
    /// lets go of it: a ``CefWindowedBrowserView`` that showed it sets its
    /// ``CefWindowedBrowserView/browser`` to nil. ``stopHosting(in:)``
    /// withdraws the browser without showing it elsewhere.
    public func host(windowedIn parentView: NSView) {
        guard state != .closed else { return }
        CefRuntime.shared.lifecycleCoordinator.setNeedsUpdate()
        if client == nil {
            // A browser discarded by closing it comes back when shown.
            guard state == .pending || isDiscarded else { return }
            guard profileAllowsCreation(for: parentView, { [weak parentView] browser in
                if let parentView, parentView.window != nil { browser.host(windowedIn: parentView) }
            }) else {
                hostView = parentView
                return
            }
            createWindowed(in: parentView)
        }
        guard let native = nativeView else { return }
        let previous = hostView
        if native.superview !== parentView {
            native.removeFromSuperview()
            parentView.addSubview(native)
        }
        native.frame = parentView.bounds
        native.autoresizingMask = [.width, .height]
        hostView = parentView
        if let previous, previous !== parentView {
            (previous as? CefWindowedBrowserView)?.browserDidStopHosting(self)
        }
    }

    /// Shows the browser through an offscreen host: creates it on first
    /// use, and afterwards redirects its frames and input to `host`.
    ///
    /// A browser shows in one host at a time. Moved to `host`, it repaints
    /// there in full, and the host it showed in before hears
    /// ``CefOffscreenHost/offscreenDidStopHosting(_:)`` and gets nothing
    /// more from it (a ``CefOffscreenBrowserView`` sets its
    /// ``CefOffscreenBrowserView/browser`` to nil). ``stopHosting(in:)``
    /// withdraws the browser without showing it elsewhere.
    public func host(offscreenIn host: CefOffscreenHost, size: CGSize) {
        guard state != .closed else { return }
        restoringOffscreenHost = host
        guard let client else {
            hostView = host as? NSView
            // A browser discarded by closing it comes back when shown.
            guard state == .pending || isDiscarded else { return }
            guard profileAllowsCreation(for: host, { browser in
                // The host it was last asked to show in, at its size then.
                guard let host = browser.restoringOffscreenHost else { return }
                browser.host(offscreenIn: host, size: host.offscreenViewInfo.size)
            }) else { return }
            createOffscreen(host: host, size: size)
            return
        }
        guard client.offscreenHost !== host else { return }
        let previous = client.offscreenHost
        client.offscreenHost = host
        client.detachedOffscreenViewInfo = nil
        hostView = host as? NSView
        // The new host may be at another scale or on another screen, and
        // has none of the page yet: everything is painted again.
        hostViewDidChangeBackingProperties()
        hostViewDidResize()
        setNeedsDisplay()
        previous?.offscreenDidStopHosting(self)
    }

    /// Withdraws the browser from `host`, a view given to
    /// ``host(windowedIn:)`` or a host given to ``host(offscreenIn:size:)``,
    /// without closing it: a creation deferred for `host` until the
    /// profile loads is dropped, a windowed browser's native view leaves
    /// `host`, and an offscreen browser stops painting and sends `host`
    /// nothing more (``CefOffscreenHost/offscreenDidStopHosting(_:)``). A
    /// browser discarded by closing it is no longer restored there.
    ///
    /// Nothing happens unless `host` is the browser's current host, so a
    /// host that was replaced never withdraws the browser from the newer
    /// one. The host views call this when their `browser` changes; call it
    /// yourself from a host of your own. Host the browser again to show it.
    public func stopHosting(in host: AnyObject) {
        cancelDeferredCreation(in: host)
        if restoringOffscreenHost === host { restoringOffscreenHost = nil }
        var stoppedOffscreen: CefOffscreenHost?
        if let client, let current = client.offscreenHost, current === host {
            client.detachedOffscreenViewInfo = current.offscreenViewInfo
            client.offscreenHost = nil
            stoppedOffscreen = current
            // Nothing shows it: Chromium stops painting.
            hostViewDidHide()
        }
        var stoppedWindowed: CefWindowedBrowserView?
        if hostView === host {
            if !isOffscreen, let native = nativeView, native.superview === host { native.removeFromSuperview() }
            hostView = nil
            stoppedWindowed = host as? CefWindowedBrowserView
        }
        // Told once the browser has let go, so their own clean-up finds
        // nothing to withdraw.
        stoppedOffscreen?.offscreenDidStopHosting(self)
        stoppedWindowed?.browserDidStopHosting(self)
        CefRuntime.shared.lifecycleCoordinator.setNeedsUpdate()
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

    /// Creates a Chrome-style browser view for a ``CefWindow``.
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
        guard profileAllowsCreation(for: nil, { $0.createInChromeUIWindow(frame: frame) }) else { return }
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

    /// Whether the browser's profile can take a new browser now. While
    /// Chromium is still loading the profile, `create` runs once it has
    /// (the last one given, if asked again meanwhile), unless meanwhile the
    /// browser closed or was created, `host` let go of it
    /// (``stopHosting(in:)``), or the app began to quit, which closes
    /// it. A browser on a profile Chromium could not load closes, and its
    /// ``ready()`` throws the profile's error. The default profile is
    /// always ready.
    ///
    /// Chromium creates a browser only on a loaded profile: synchronous
    /// creation and browser views fail on one it is still loading, and
    /// asynchronous creation would go ahead on the in-memory profile it
    /// gives when it cannot load one.
    func profileAllowsCreation(for host: AnyObject?, _ create: @escaping @MainActor (CefBrowser) -> Void) -> Bool {
        let profile = configuration.profile ?? .default
        _ = profile.requestContext()
        switch profile.readiness {
        case .ready, .pending:
            // Pending: Chromium is not running, which creation reports.
            return true
        case .failed(let reason):
            dropDeferredCreation()
            readyWaiters.completeAll(.failure(CefError.profileUnavailable(reason)))
            creationFailed()
            return false
        case .loading:
            // Quitting closes the browsers waiting for a profile; one
            // asked for now would be created after that.
            guard !CefRuntime.shared.isTerminating else {
                close()
                return false
            }
            let isWaiting = creationAwaitingProfile != nil
            creationAwaitingProfile = DeferredCreation(host: host, create: create)
            CefRuntime.shared.browserAwaitsProfile(self)
            guard !isWaiting else { return false }
            Task { [weak self] in
                // Loaded or failed, which `create` turns into a close; or
                // Chromium shut down meanwhile, which closed the browser.
                try? await profile.ready()
                guard let self, let deferred = self.creationAwaitingProfile else { return }
                self.dropDeferredCreation()
                guard CefRuntime.shared.isRunning, !CefRuntime.shared.isTerminating, self.client == nil,
                      self.state == .pending || self.isDiscarded
                else { return }
                deferred.create(self)
            }
            return false
        }
    }

    /// Forgets the creation waiting for the profile, if any.
    func dropDeferredCreation() {
        guard creationAwaitingProfile != nil else { return }
        creationAwaitingProfile = nil
        CefRuntime.shared.browserStoppedAwaitingProfile(self)
    }

    /// `host` cannot create the browser for now (it left its window): a
    /// creation deferred for it is dropped, and it asks again when it can.
    func cancelDeferredCreation(in host: AnyObject) {
        if creationAwaitingProfile?.host === host { dropDeferredCreation() }
    }

    func creationFailed() {
        dropDeferredCreation()
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
                // An attachment told after the close would never hear of it.
                for attachment in configuration.attachments where state == .live {
                    await attachment.browserDidCreate(self)
                }
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
            // An attachment told after the close would never hear of it.
            for attachment in configuration.attachments where state == .live {
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
            x: Int32(saturating: rect.origin.x), y: Int32(saturating: rect.origin.y),
            width: Int32(saturating: max(1, rect.width)), height: Int32(saturating: max(1, rect.height)))
    }

    /// An AppKit screen rectangle (bottom-left origin) in CEF's screen
    /// coordinates (top-left origin of the primary display).
    @MainActor
    init(screenRect: CGRect) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screenRect.maxY
        self.init(
            x: Int32(saturating: screenRect.origin.x), y: Int32(saturating: primaryHeight - screenRect.maxY),
            width: Int32(saturating: screenRect.width), height: Int32(saturating: screenRect.height))
    }
}
