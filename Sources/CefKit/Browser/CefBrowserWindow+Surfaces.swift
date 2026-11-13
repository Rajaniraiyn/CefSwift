import AppKit
import CCef
import Foundation

// How a CefBrowserWindow follows Chromium's surfaces: CefSurfaceTracker
// reports each child window Chromium attaches; it is kept invisible until
// it is recognized, then shown and placed, replaced, or dismissed according
// to the window's chromiumUI.
extension CefBrowserWindow {

    // MARK: Native surfaces

    /// Chromium is about to attach `child` to this window.
    func childWindowWillAttach(_ child: NSWindow) {
        guard CefChromiumSurface.isSurfaceWindow(child),
              !chromiumSurfaces.contains(where: { $0.window === child }),
              pendingSurfaces[ObjectIdentifier(child)] == nil
        else { return }
        // A window Chromium reuses may have been hidden before; it is
        // decided afresh.
        CefSurfaceTracker.setHidden(child, false)
        pendingSurfaces[ObjectIdentifier(child)] = (child, child.alphaValue)
        child.alphaValue = 0
    }

    /// Chromium has attached `child`; decide how it is presented.
    func childWindowDidAttach(_ child: NSWindow) {
        guard let pending = pendingSurfaces.removeValue(forKey: ObjectIdentifier(child)) else { return }
        let recognized = CefChromiumSurface.recognize(child)
        guard let kind = recognized.kind else {
            // No view tree yet: show it as Chromium does.
            child.alphaValue = pending.alpha
            return
        }
        let url = kind == .qrCode ? recognized.text.flatMap(URL.init(string:)) ?? browser.url : browser.url
        let surface = CefChromiumSurface(
            kind: kind, title: recognized.title, browser: browser, url: url,
            window: child, browserWindow: self)
        let presentation = presentationForSurface?(surface) ?? chromiumUI[kind]
        surface.presentation = presentation
        switch presentation {
        case .native:
            child.alphaValue = pending.alpha
            track(surface, window: child)
            place(surface)
            onChromiumSurface?(surface)
        case .hidden:
            hide(surface, window: child)
        case .custom:
            hide(surface, window: child)
            presentCustom(kind: kind, url: url, title: recognized.title)
        }
    }

    /// Chromium has detached `child`, as it does when hiding a surface.
    func childWindowDidDetach(_ child: NSWindow) {
        pendingSurfaces.removeValue(forKey: ObjectIdentifier(child))
        guard let surface = chromiumSurfaces.first(where: { $0.window === child }) else { return }
        surface.isPresented = false
        stopTracking(surface)
        chromiumSurfaces.removeAll { $0 === surface }
    }

    /// Keeps a native surface listed and placed until it closes.
    private func track(_ surface: CefChromiumSurface, window child: NSWindow) {
        chromiumSurfaces.append(surface)
        let center = NotificationCenter.default
        let follow: @Sendable (Notification) -> Void = { [weak self, weak surface] _ in
            MainActor.assumeIsolated {
                guard let self, let surface, !self.isPlacingSurface else { return }
                self.place(surface)
            }
        }
        surfaceObservers[surface.id] = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: child, queue: nil, using: follow),
            center.addObserver(forName: NSWindow.didResizeNotification, object: child, queue: nil, using: follow),
            center.addObserver(forName: NSWindow.willCloseNotification, object: child, queue: nil) { [weak self, weak surface] _ in
                MainActor.assumeIsolated {
                    guard let self, let surface else { return }
                    surface.isPresented = false
                    self.stopTracking(surface)
                    self.chromiumSurfaces.removeAll { $0 === surface }
                }
            },
        ]
    }

    /// Keeps Chromium's window for a surface off screen and ends what it
    /// asks. Status bubbles and fullscreen notices stay invisible, as
    /// Chromium reuses their windows.
    private func hide(_ surface: CefChromiumSurface, window child: NSWindow) {
        CefSurfaceTracker.setHidden(child, true)
        child.ignoresMouseEvents = true
        surface.isPresented = false
        CefChromiumSurface.closeNatively(child, kind: surface.kind, browser: browser)
    }

    /// Applies a changed `chromiumUI` to the surfaces on screen: places them
    /// under their anchors, and hides those whose kind is now hidden.
    func applyChromiumUI() {
        for surface in chromiumSurfaces {
            guard let child = surface.window else { continue }
            if case .hidden = chromiumUI[surface.kind] {
                hide(surface, window: child)
                stopTracking(surface)
                chromiumSurfaces.removeAll { $0 === surface }
            } else {
                place(surface)
            }
        }
    }

    func stopTracking(_ surface: CefChromiumSurface) {
        surfaceObservers.removeValue(forKey: surface.id)?.forEach(NotificationCenter.default.removeObserver)
    }

    /// Moves a native surface under its anchor.
    func place(_ surface: CefChromiumSurface) {
        guard surface.isPresented, let child = surface.window, let parent = window,
              let anchor = chromiumUI.anchor(for: surface.kind),
              let origin = anchor.origin(for: child.frame.size, in: parent)
        else { return }
        let current = child.frame.origin
        guard abs(current.x - origin.x) > 0.5 || abs(current.y - origin.y) > 0.5 else { return }
        isPlacingSurface = true
        child.setFrameOrigin(origin)
        isPlacingSurface = false
    }

    /// Keeps surfaces under their anchors as the window changes.
    func observeFrame(of nsWindow: NSWindow) {
        guard frameObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.chromiumSurfaces.forEach { self?.place($0) } }
        }
        frameObservers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: nsWindow, queue: nil, using: update),
            center.addObserver(forName: NSWindow.didMoveNotification, object: nsWindow, queue: nil, using: update),
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nsWindow, queue: nil, using: update),
        ]
    }

    // MARK: Custom surfaces

    /// Hands a surface to the app's presenter, or to `onChromiumSurface`.
    /// Returns the surface.
    @discardableResult
    private func presentCustom(kind: CefChromiumSurface.Kind, url: URL?, title: String = "") -> CefChromiumSurface {
        // One custom surface of a kind at a time.
        chromiumSurfaces.filter { $0.kind == kind && $0.window == nil }.forEach { $0.dismiss() }
        let surface = CefChromiumSurface(
            kind: kind, title: title, browser: browser, url: url,
            window: nil, browserWindow: self)
        surface.presentation = .custom
        surface.onDismiss = { [weak self, weak surface] in
            self?.chromiumSurfaces.removeAll { $0 === surface }
        }
        chromiumSurfaces.append(surface)
        if kind == .findBar { browser.findSession.begin() }
        if let present = customPresenters[kind] {
            present(surface)
        } else if kind == .share {
            surface.showSharingServicePicker()
            surface.dismiss()
        }
        onChromiumSurface?(surface)
        return surface
    }

    /// The surface a Chrome command opens.
    private static func surfaceKind(for command: CefChromeCommand) -> CefChromiumSurface.Kind? {
        switch command {
        case .find: .findBar
        case .createQRCode: .qrCode
        case .castMedia: .cast
        case .showSharingHub: .share
        case .bookmarkThisTab: .bookmark
        default: nil
        }
    }

    /// Runs a command that opens a surface the app replaces or hides,
    /// without Chromium showing its own. Returns whether it was handled.
    func handleSurfaceCommand(_ command: CefChromeCommand) -> Bool {
        // ⌘G and ⇧⌘G move through a custom find bar's matches.
        if case .custom = chromiumUI[.findBar], browser.findSession.isActive {
            switch command.rawValue {
            case Int(IDC_FIND_NEXT):
                browser.findSession.next()
                return true
            case Int(IDC_FIND_PREVIOUS):
                browser.findSession.previous()
                return true
            default:
                break
            }
        }
        guard let kind = Self.surfaceKind(for: command) else { return false }
        switch chromiumUI[kind] {
        case .hidden:
            return true
        case .custom:
            presentCustom(kind: kind, url: browser.url, title: browser.title)
            return true
        case .native:
            // Chromium has no share menu without its toolbar: macOS's.
            guard kind == .share else { return false }
            presentCustom(kind: kind, url: browser.url, title: browser.title)
            return true
        }
    }

    /// The window showing `browser`, if it is a browser window.
    static func hosting(_ browser: CefBrowser) -> CefBrowserWindow? {
        all.first { $0.browser === browser }
    }
}
