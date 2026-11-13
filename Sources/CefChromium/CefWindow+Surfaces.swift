import AppKit
import CCef
import CefKit
import Foundation
import Observation

// How a CefWindow follows Chromium's surfaces: CefSurfaceTracker
// reports each child window Chromium attaches; it is kept invisible until
// it is recognized, then shown and placed, replaced, or dismissed according
// to the window's chromiumUI. A window's ChromiumSurfaceController holds
// all of it, made on first use (see ChromiumSurfaces.activate()).

extension CefWindow {
    /// How Chromium's own interface is presented in this window: its
    /// bubbles, dialogs, find bar and status bubble
    /// (``CefChromiumSurface/Kind``). Each kind is drawn by Chromium where
    /// Chromium puts it, anchored under your controls, replaced by your own
    /// interface, or hidden.
    ///
    /// ```swift
    /// window.chromiumUI.anchor = .view(addressField, alignment: .trailing)
    /// window.chromiumUI[.statusBubble] = .hidden
    /// window.setCustomPresentation(for: .qrCode) { surface in showMyQRCode(for: surface.url) }
    /// ```
    ///
    /// Surfaces follow their anchor as the window moves or resizes, and when
    /// Chromium lays them out again. The `chromiumSurfaceAnchor(_:alignment:)`
    /// modifier sets anchors from SwiftUI views in your toolbar.
    ///
    /// CefChromium starts following Chromium's surfaces, in every browser
    /// window, the first time any of its window API is used, this property
    /// and ``CefWindow/Configuration/chromiumUI`` included. Until
    /// then Chromium shows its interface as it does without CefChromium;
    /// surfaces already on screen then are taken up as they are. Set it
    /// before showing the window, so no surface shows before it applies.
    public var chromiumUI: ChromiumUI {
        get { surfaces.ui }
        set { surfaces.ui = newValue }
    }

    /// Decides a surface's presentation as it appears, taking precedence
    /// over ``chromiumUI``. Return `nil` to use ``chromiumUI``. The surface
    /// stays hidden while this runs.
    public var presentationForSurface: ((CefChromiumSurface) -> CefChromiumSurface.Presentation?)? {
        get { surfaces.presentationForSurface }
        set { surfaces.presentationForSurface = newValue }
    }

    /// Chromium's surfaces in this window, oldest first: those Chromium
    /// draws, and those you present yourself until they are dismissed.
    public var chromiumSurfaces: [CefChromiumSurface] { surfaces.surfaces }

    /// Called as each surface appears: after a native one is placed, and for
    /// a custom one after its presenter (or instead of one).
    public var onChromiumSurface: ((CefChromiumSurface) -> Void)? {
        get { surfaces.onSurface }
        set { surfaces.onSurface = newValue }
    }

    /// Presents your own interface for a kind of surface, and sets the
    /// kind's presentation to ``CefChromiumSurface/Presentation/custom``.
    /// `present` receives the surface when Chromium would show it — from
    /// its command (``CefChromeCommand/find``, ``CefChromeCommand/createQRCode``,
    /// ``CefChromeCommand/castMedia``, ``CefChromeCommand/showSharingHub``),
    /// its shortcut, its menu item, or anything else — with Chromium's own
    /// interface kept off screen. Pass `nil` to go back to Chromium's.
    public func setCustomPresentation(
        for kind: CefChromiumSurface.Kind, _ present: (@MainActor (CefChromiumSurface) -> Void)?
    ) {
        let surfaces = surfaces
        surfaces.customPresenters[kind] = present
        surfaces.ui[kind] = present == nil ? .native : .custom
    }

    /// The window's surface state, made on first use.
    var surfaces: ChromiumSurfaceController {
        if let surfaces = existingModuleState(ChromiumSurfaceController.self) { return surfaces }
        ChromiumSurfaces.activate()
        let surfaces = moduleState { ChromiumSurfaceController(window: self) }
        surfaces.start()
        return surfaces
    }
}

extension CefWindow.Configuration {
    /// How Chromium's interface is presented at first:
    /// ``CefWindow/chromiumUI`` starts as this, or with every
    /// surface ``CefChromiumSurface/Presentation/native`` when `nil`.
    /// A status bubble or zoom bubble hidden here is never created, as the
    /// browser starts with Chromium's own switched off
    /// (`cef_browser_settings_t`); hiding one later keeps Chromium's window
    /// invisible instead. Popups start with every surface native.
    @MainActor
    public var chromiumUI: CefWindow.ChromiumUI? {
        get { moduleValues[ObjectIdentifier(CefWindow.ChromiumUI.self)] as? CefWindow.ChromiumUI }
        set {
            ChromiumSurfaces.activate()
            moduleValues[ObjectIdentifier(CefWindow.ChromiumUI.self)] = newValue
            showsChromiumStatusBubble = newValue?[.statusBubble] != .hidden
            showsChromiumZoomBubble = newValue?[.zoom] != .hidden
        }
    }
}

/// Hooks for CefSwift's own end-to-end tests (the SelfTest example). Not
/// for apps.
@_spi(Testing)
@MainActor
public enum CefChromiumTesting {
    /// Installs CefChromium's overrides of Chromium's AppKit classes, as
    /// its first use does, so `CefTesting.runtimeHookFeatures` lists them.
    public static func activate() { ChromiumSurfaces.activate() }
}

/// Starts CefChromium's surface handling, once: the overrides that report
/// the child windows Chromium attaches, and the Chrome-command interceptor
/// that opens or hides the surfaces commands would show.
@MainActor
enum ChromiumSurfaces {
    private static var isActive = false

    static func activate() {
        guard !isActive else { return }
        isActive = true
        CefSurfaceTracker.install()
        CefWindow.addChromeCommandInterceptor { window, command in
            window.surfaces.handleSurfaceCommand(command)
        }
    }
}

/// What CefChromium keeps for one ``CefWindow``.
@MainActor
@Observable
final class ChromiumSurfaceController: CefWindowParticipant {
    @ObservationIgnored private weak var window: CefWindow?
    private let browser: CefBrowser

    var ui: CefWindow.ChromiumUI {
        didSet { applyChromiumUI() }
    }

    var surfaces: [CefChromiumSurface] = []
    @ObservationIgnored var presentationForSurface: ((CefChromiumSurface) -> CefChromiumSurface.Presentation?)?
    @ObservationIgnored var onSurface: ((CefChromiumSurface) -> Void)?
    @ObservationIgnored var customPresenters: [CefChromiumSurface.Kind: @MainActor (CefChromiumSurface) -> Void] = [:]
    @ObservationIgnored private var surfaceObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var frameObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var isPlacingSurface = false
    @ObservationIgnored private var pendingSurfaces: [ObjectIdentifier: (window: NSWindow, alpha: CGFloat)] = [:]

    init(window: CefWindow) {
        self.window = window
        browser = window.browser
        ui = window.configuration.chromiumUI ?? CefWindow.ChromiumUI()
    }

    /// Follows the window's frame, and takes up the surfaces Chromium
    /// attached before CefChromium was first used.
    func start() {
        guard let window, !window.isClosed else { return }
        window.withWindow { [weak self] nsWindow in
            guard let self else { return }
            self.observeFrame(of: nsWindow)
            for child in nsWindow.childWindows ?? [] {
                self.childWindowWillAttach(child)
                self.childWindowDidAttach(child)
            }
        }
    }

    func windowDidClose(_ window: CefWindow) {
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = []
        surfaces.forEach(stopTracking)
        surfaces = []
    }

    // MARK: Native surfaces

    /// Chromium is about to attach `child` to this window.
    func childWindowWillAttach(_ child: NSWindow) {
        guard CefChromiumSurface.isSurfaceWindow(child),
              !surfaces.contains(where: { $0.window === child }),
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
        guard let window else {
            child.alphaValue = pending.alpha
            return
        }
        let recognized = CefChromiumSurface.recognize(child)
        guard let kind = recognized.kind else {
            // No view tree yet: show it as Chromium does.
            child.alphaValue = pending.alpha
            return
        }
        let url = kind == .qrCode ? recognized.text.flatMap(URL.init(string:)) ?? browser.url : browser.url
        let surface = CefChromiumSurface(
            kind: kind, title: recognized.title, browser: browser, url: url,
            window: child, parentWindow: window)
        let presentation = presentationForSurface?(surface) ?? ui[kind]
        surface.presentation = presentation
        switch presentation {
        case .native:
            child.alphaValue = pending.alpha
            track(surface, window: child)
            place(surface)
            onSurface?(surface)
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
        guard let surface = surfaces.first(where: { $0.window === child }) else { return }
        surface.isPresented = false
        forget(surface)
    }

    /// Stops listing and placing a native surface.
    private func forget(_ surface: CefChromiumSurface) {
        stopTracking(surface)
        surfaces.removeAll { $0 === surface }
    }

    /// Keeps a native surface listed and placed until it closes.
    private func track(_ surface: CefChromiumSurface, window child: NSWindow) {
        surfaces.append(surface)
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
                    self.forget(surface)
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
    private func applyChromiumUI() {
        for surface in surfaces {
            guard let child = surface.window else { continue }
            if case .hidden = ui[surface.kind] {
                hide(surface, window: child)
                forget(surface)
            } else {
                place(surface)
            }
        }
    }

    private func stopTracking(_ surface: CefChromiumSurface) {
        surfaceObservers.removeValue(forKey: surface.id)?.forEach(NotificationCenter.default.removeObserver)
    }

    /// Moves a native surface under its anchor.
    private func place(_ surface: CefChromiumSurface) {
        guard surface.isPresented, let child = surface.window, let parent = window?.window,
              let anchor = ui.anchor(for: surface.kind),
              let origin = anchor.origin(for: child.frame.size, in: parent)
        else { return }
        let current = child.frame.origin
        guard abs(current.x - origin.x) > 0.5 || abs(current.y - origin.y) > 0.5 else { return }
        isPlacingSurface = true
        child.setFrameOrigin(origin)
        isPlacingSurface = false
    }

    /// Keeps surfaces under their anchors as the window changes.
    private func observeFrame(of nsWindow: NSWindow) {
        guard frameObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.surfaces.forEach { self?.place($0) } }
        }
        frameObservers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: nsWindow, queue: nil, using: update),
            center.addObserver(forName: NSWindow.didMoveNotification, object: nsWindow, queue: nil, using: update),
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nsWindow, queue: nil, using: update),
        ]
    }

    // MARK: Custom surfaces

    /// Hands a surface to the app's presenter, or to `onChromiumSurface`.
    private func presentCustom(kind: CefChromiumSurface.Kind, url: URL?, title: String) {
        guard let window else { return }
        // One custom surface of a kind at a time.
        surfaces.filter { $0.kind == kind && $0.window == nil }.forEach { $0.dismiss() }
        let surface = CefChromiumSurface(
            kind: kind, title: title, browser: browser, url: url,
            window: nil, parentWindow: window)
        surface.presentation = .custom
        surface.onDismiss = { [weak self, weak surface] in
            self?.surfaces.removeAll { $0 === surface }
        }
        surfaces.append(surface)
        if kind == .findBar { browser.findSession.begin() }
        if let present = customPresenters[kind] {
            present(surface)
        } else if kind == .share {
            surface.showSharingServicePicker()
            surface.dismiss()
        }
        onSurface?(surface)
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
        if case .custom = ui[.findBar], browser.findSession.isActive {
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
        switch ui[kind] {
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
}
