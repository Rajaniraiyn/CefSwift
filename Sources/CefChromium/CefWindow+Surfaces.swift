import AppKit
import CCef
import CefKit
import Foundation
import Observation

// How a CefWindow follows Chromium's surfaces: CefSurfaceTracker
// reports each child window Chromium attaches; it is kept invisible until
// it is recognized, then shown and placed, replaced, or hidden according
// to the window's chromiumSurfacePolicy. A window's ChromiumSurfaceController holds
// all of it, made on first use (see ChromiumSurfaces.activate()).

extension CefWindow {
    /// How Chromium's own interface is presented in this window: its
    /// bubbles, dialogs, find bar and status bubble
    /// (``CefChromiumSurface/Kind``). Each kind is drawn by Chromium where
    /// Chromium puts it, anchored under your controls, replaced by your own
    /// interface, or hidden.
    ///
    /// ```swift
    /// window.chromiumSurfacePolicy.anchor = .view(addressField, alignment: .trailing)
    /// window.chromiumSurfacePolicy[.statusBubble] = .hidden
    /// window.setCustomPresentation(for: .qrCode) { surface in showMyQRCode(for: surface.url) }
    /// ```
    ///
    /// Surfaces follow their anchor as the window moves, resizes, enters
    /// full screen or changes screen, as an anchor view moves within the
    /// window, and when Chromium lays them out again. Changing the policy
    /// applies to the surfaces on screen: a kind turned
    /// ``CefChromiumSurface/Presentation/hidden`` closes, one turned
    /// ``CefChromiumSurface/Presentation/custom`` moves to your interface,
    /// and your interface for a kind turned back to
    /// ``CefChromiumSurface/Presentation/native`` is dismissed. The
    /// `chromiumSurfaceAnchor(_:alignment:)` modifier sets anchors from
    /// SwiftUI views in your toolbar.
    ///
    /// CefChromium starts following Chromium's surfaces, in every browser
    /// window, the first time any of its window API is used, this property
    /// and ``CefWindow/Configuration/chromiumSurfacePolicy`` included. Until
    /// then Chromium shows its interface as it does without CefChromium;
    /// surfaces already on screen then are taken up as they are. Set it
    /// before showing the window, so no surface shows before it applies.
    public var chromiumSurfacePolicy: CefChromiumSurface.Policy {
        get { surfaces.policy }
        set { surfaces.policy = newValue }
    }

    /// Decides a surface's presentation as it appears, taking precedence
    /// over ``chromiumSurfacePolicy``. Return `nil` to use ``chromiumSurfacePolicy``. The surface
    /// stays hidden while this runs.
    public var presentationForChromiumSurface: ((CefChromiumSurface) -> CefChromiumSurface.Presentation?)? {
        get { surfaces.presentationForChromiumSurface }
        set { surfaces.presentationForChromiumSurface = newValue }
    }

    /// Chromium's surfaces in this window, oldest first: those Chromium
    /// draws, and those you present yourself, until they are dismissed.
    public var chromiumSurfaces: [CefChromiumSurface] { surfaces.surfaces }

    /// Called as each surface appears, whatever its presentation: after a
    /// native one is placed, for a custom one after its presenter (or
    /// instead of one), and for a hidden one as it is closed, already
    /// ``CefChromiumSurface/State/dismissed(_:)``. Surfaces CefChromium has
    /// no kind for arrive as ``CefChromiumSurface/Kind/other(_:)``.
    public var onChromiumSurface: ((CefChromiumSurface) -> Void)? {
        get { surfaces.onSurface }
        set { surfaces.onSurface = newValue }
    }

    /// Presents your own interface for a kind of surface, and sets the
    /// kind's presentation to ``CefChromiumSurface/Presentation/custom``.
    /// `present` receives the surface when Chromium would show it — from
    /// its command (``CefChromeCommand/find``, ``CefChromeCommand/createQRCode``,
    /// ``CefChromeCommand/castMedia``, ``CefChromeCommand/showSharingHub``,
    /// ``CefChromeCommand/zoomIn``, …), its shortcut, its menu item, or
    /// anything else — with Chromium's own interface kept off screen. Pass
    /// `nil` to go back to Chromium's.
    ///
    /// Only kinds whose ``CefChromiumSurface/Kind/capabilities`` include
    /// ``CefChromiumSurface/Capabilities/replace`` can be replaced: the app
    /// cannot get what the others show, so for them this does nothing.
    public func setCustomPresentation(
        for kind: CefChromiumSurface.Kind, _ present: (@MainActor (CefChromiumSurface) -> Void)?
    ) {
        guard kind.capabilities.contains(.replace) else { return }
        let surfaces = surfaces
        surfaces.customPresenters[kind] = present
        surfaces.policy[kind] = present == nil ? .native : .custom
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
    /// ``CefWindow/chromiumSurfacePolicy`` starts as this, or with every
    /// surface ``CefChromiumSurface/Presentation/native`` when `nil`.
    /// A status bubble or zoom bubble hidden or custom here is never
    /// created, as the browser starts with Chromium's own switched off
    /// (`cef_browser_settings_t`); hiding one later keeps Chromium's window
    /// invisible instead. Popups start with every surface native.
    @MainActor
    public var chromiumSurfacePolicy: CefChromiumSurface.Policy? {
        get { moduleValues[ObjectIdentifier(CefChromiumSurface.Policy.self)] as? CefChromiumSurface.Policy }
        set {
            ChromiumSurfaces.activate()
            moduleValues[ObjectIdentifier(CefChromiumSurface.Policy.self)] = newValue
            showsChromiumStatusBubble = (newValue?[.statusBubble] ?? .native) == .native
            showsChromiumZoomBubble = (newValue?[.zoom] ?? .native) == .native
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

    /// What CefChromium reads from a window Chromium attached: whether it is
    /// a surface window, the kind it is recognized as (`nil` while it has
    /// no view tree), its title, and the view classes it names.
    public static func describe(_ window: NSWindow) -> (isSurface: Bool, kind: String?, title: String, classes: [String]) {
        let recognized = CefChromiumSurface.recognize(window)
        return (CefChromiumSurface.isSurfaceWindow(window), recognized.kind.map { "\($0)" }, recognized.title,
                CefChromiumSurface.viewClasses(in: window).classes)
    }

    /// The phase of each of Chromium's windows the window follows.
    public static func widgetPhases(of window: CefWindow) -> [String] {
        window.existingModuleState(ChromiumSurfaceController.self)?.widgetPhaseDescriptions ?? []
    }
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
///
/// Two state machines live here. Each of Chromium's windows (a widget) goes
/// through ``WidgetPhase``: attaching → recognizing → shown or suppressed,
/// and leaves when Chromium detaches or closes it. Each surface the app sees
/// goes through ``CefChromiumSurface/State``: presented → dismissed, once,
/// in ``end(_:_:)``.
@MainActor
@Observable
final class ChromiumSurfaceController: CefWindowParticipant {
    /// Where one of Chromium's windows is.
    enum WidgetPhase {
        /// Being attached: transparent; `alpha` is what Chromium gave it.
        case attaching(alpha: CGFloat)
        /// Attached, its view tree not built yet: transparent, looked at
        /// again shortly.
        case recognizing(alpha: CGFloat, attempt: Int)
        /// Shown as Chromium draws it, as `surface`, under its anchor.
        case shown(CefChromiumSurface)
        /// Kept transparent and closed natively: hidden, or replaced by the
        /// app's interface. Chromium may attach it again (it reuses some
        /// windows), which decides afresh.
        case suppressed(CefChromiumSurface.Kind)
    }

    private struct Widget {
        weak var window: NSWindow?
        var phase: WidgetPhase
    }

    @ObservationIgnored private weak var window: CefWindow?
    private let browser: CefBrowser

    var policy: CefChromiumSurface.Policy {
        didSet { applyPolicy() }
    }

    var surfaces: [CefChromiumSurface] = []
    @ObservationIgnored var presentationForChromiumSurface: ((CefChromiumSurface) -> CefChromiumSurface.Presentation?)?
    @ObservationIgnored var onSurface: ((CefChromiumSurface) -> Void)?
    @ObservationIgnored var customPresenters: [CefChromiumSurface.Kind: @MainActor (CefChromiumSurface) -> Void] = [:]
    @ObservationIgnored private var widgets: [ObjectIdentifier: Widget] = [:]
    @ObservationIgnored private var surfaceObservers: [ObjectIdentifier: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var frameObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var anchorObserver: NSObjectProtocol?
    @ObservationIgnored private var isPlacingSurface = false
    @ObservationIgnored private var isClosed = false

    init(window: CefWindow) {
        self.window = window
        browser = window.browser
        policy = window.configuration.chromiumSurfacePolicy ?? CefChromiumSurface.Policy()
    }

    /// Follows the window's frame and the browser's status text, and takes
    /// up the surfaces Chromium attached before CefChromium was first used.
    func start() {
        guard let window, !window.isClosed else { return }
        window.withWindow { [weak self] nsWindow in
            guard let self, !self.isClosed else { return }
            self.observeFrame(of: nsWindow)
            for child in nsWindow.childWindows ?? [] {
                self.childWindowWillAttach(child)
                self.childWindowDidAttach(child)
            }
        }
        followStatusText()
    }

    /// The window has closed: every surface ends, and nothing of the app's
    /// is called afterwards.
    func windowDidClose(_ window: CefWindow) {
        guard !isClosed else { return }
        isClosed = true
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = []
        for surface in surfaces { end(surface, .window) }
        stopFollowingAnchors()
        widgets = [:]
        onSurface = nil
        presentationForChromiumSurface = nil
        customPresenters = [:]
    }

    var widgetPhaseDescriptions: [String] {
        widgets.values.map { widget in
            switch widget.phase {
            case .attaching: "attaching"
            case .recognizing(_, let attempt): "recognizing \(attempt)"
            case .shown(let surface): "shown \(surface.kind)"
            case .suppressed(let kind): "suppressed \(kind)"
            }
        }
    }

    // MARK: Chromium's windows

    /// Chromium is about to attach `child` to this window.
    func childWindowWillAttach(_ child: NSWindow) {
        guard !isClosed, CefChromiumSurface.isSurfaceWindow(child) else { return }
        let id = ObjectIdentifier(child)
        switch widgets[id]?.phase {
        case .attaching?, .recognizing?, .shown?:
            // Already followed; Chromium orders it again.
            return
        case .suppressed?, nil:
            // A window Chromium reuses was hidden before; it is decided
            // afresh, at the alpha Chromium last asked for.
            CefSurfaceTracker.setHidden(child, false)
            let alpha = CefSurfaceTracker.requestedAlpha(of: child) ?? child.alphaValue
            widgets[id] = Widget(window: child, phase: .attaching(alpha: alpha))
            child.alphaValue = 0
        }
    }

    /// Chromium has attached `child`; decide how it is presented.
    func childWindowDidAttach(_ child: NSWindow) {
        guard case .attaching(let alpha)? = widgets[ObjectIdentifier(child)]?.phase else { return }
        recognize(child, alpha: alpha, attempt: 0)
    }

    /// Chromium has detached `child`, as it does when hiding a surface.
    func childWindowDidDetach(_ child: NSWindow) {
        guard let widget = widgets.removeValue(forKey: ObjectIdentifier(child)) else { return }
        switch widget.phase {
        case .attaching(let alpha), .recognizing(let alpha, _):
            child.alphaValue = alpha
        case .shown(let surface):
            // Chromium detaches every surface as the window closes.
            let closing = window?.isClosed != false || window?.window?.isVisible != true
            end(surface, closing ? .window : .chromium)
        case .suppressed:
            break
        }
    }

    /// How many times a window without a view tree is looked at again, 50 ms
    /// apart, before it is shown as an unknown surface.
    private static let recognitionAttempts = 6

    private func recognize(_ child: NSWindow, alpha: CGFloat, attempt: Int) {
        let id = ObjectIdentifier(child)
        guard let window, !isClosed else {
            child.alphaValue = alpha
            widgets[id] = nil
            return
        }
        let recognized = CefChromiumSurface.recognize(child)
        guard let kind = recognized.kind ?? (attempt >= Self.recognitionAttempts ? .other("") : nil) else {
            // No view tree yet: stay transparent and look again.
            widgets[id]?.phase = .recognizing(alpha: alpha, attempt: attempt + 1)
            Task { @MainActor [weak self, weak child] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let child, case .recognizing? = self.widgets[id]?.phase else { return }
                self.recognize(child, alpha: alpha, attempt: attempt + 1)
            }
            return
        }
        let url = kind == .qrCode ? recognized.text.flatMap(URL.init(string:)) ?? browser.url : browser.url
        let surface = CefChromiumSurface(
            kind: kind, title: recognized.title, browser: browser, url: url,
            window: child, parentWindow: window)
        let presentation = presentation(for: surface)
        surface.presentation = presentation
        switch presentation {
        case .native:
            child.alphaValue = alpha
            widgets[id]?.phase = .shown(surface)
            track(surface, window: child)
            place(surface)
            followAnchors()
            onSurface?(surface)
        case .hidden:
            suppress(child, kind: kind)
            surface.state = .dismissed(.presentation)
            onSurface?(surface)
        case .custom:
            suppress(child, kind: kind)
            // The command that opened it may have presented the app's
            // interface already; the status bubble follows statusText.
            let presented = surfaces.contains { $0.kind == kind && $0.window == nil }
            if !presented, kind != .statusBubble {
                presentCustom(kind: kind, url: url, title: recognized.title)
            }
        }
    }

    /// The presentation a surface gets now: what the app asks, within what
    /// its kind allows.
    private func presentation(for surface: CefChromiumSurface) -> CefChromiumSurface.Presentation {
        let presentation = presentationForChromiumSurface?(surface) ?? policy[surface.kind]
        switch presentation {
        case .custom where !surface.kind.capabilities.contains(.replace),
             .hidden where !surface.kind.capabilities.contains(.hide):
            return .native
        default:
            return presentation
        }
    }

    /// Keeps Chromium's window for a surface off screen and ends what it
    /// asks. Status bubbles and fullscreen notices stay invisible, as
    /// Chromium reuses their windows.
    private func suppress(_ child: NSWindow, kind: CefChromiumSurface.Kind) {
        widgets[ObjectIdentifier(child)]?.phase = .suppressed(kind)
        CefSurfaceTracker.setHidden(child, true)
        child.ignoresMouseEvents = true
        CefChromiumSurface.closeNatively(child, kind: kind, browser: browser)
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
        let id = ObjectIdentifier(child)
        surfaceObservers[surface.id] = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: child, queue: nil, using: follow),
            center.addObserver(forName: NSWindow.didResizeNotification, object: child, queue: nil, using: follow),
            center.addObserver(forName: NSWindow.willCloseNotification, object: child, queue: nil) { [weak self, weak surface] _ in
                MainActor.assumeIsolated {
                    guard let self, let surface else { return }
                    self.widgets[id] = nil
                    self.end(surface, .chromium)
                }
            },
        ]
    }

    /// Ends a surface: the one transition out of
    /// ``CefChromiumSurface/State/presented``.
    func end(_ surface: CefChromiumSurface, _ reason: CefChromiumSurface.Dismissal) {
        guard surface.state == .presented else { return }
        surface.state = .dismissed(reason)
        surfaceObservers.removeValue(forKey: surface.id)?.forEach(NotificationCenter.default.removeObserver)
        surfaces.removeAll { $0 === surface }
        if surface.window == nil, surface.kind == .findBar, browser.findSession.isActive {
            browser.findSession.end()
        }
        if !surfaces.contains(where: { $0.window != nil }) { stopFollowingAnchors() }
    }

    /// Applies a changed `chromiumSurfacePolicy` to the surfaces on screen:
    /// each moves to its kind's presentation, and native ones go under their
    /// anchors.
    private func applyPolicy() {
        guard !isClosed else { return }
        for surface in surfaces {
            let presentation = presentation(for: surface)
            guard presentation != surface.presentation else {
                place(surface)
                continue
            }
            if let child = surface.window {
                // Chromium's: hidden, or handed to the app.
                suppress(child, kind: surface.kind)
                end(surface, .presentation)
                if presentation == .custom, surface.kind != .statusBubble {
                    presentCustom(kind: surface.kind, url: surface.url, title: surface.title)
                }
            } else {
                // The app's: Chromium shows the next one, or none.
                end(surface, .presentation)
            }
        }
        followStatusText()
        followAnchors()
    }

    /// Moves a native surface under its anchor.
    private func place(_ surface: CefChromiumSurface) {
        guard surface.state == .presented, let child = surface.window, let parent = window?.window,
              let anchor = policy.anchor(for: surface.kind),
              let origin = anchor.origin(for: child.frame.size, in: parent)
        else { return }
        let current = child.frame.origin
        guard abs(current.x - origin.x) > 0.5 || abs(current.y - origin.y) > 0.5 else { return }
        isPlacingSurface = true
        child.setFrameOrigin(origin)
        isPlacingSurface = false
    }

    private func placeAll() {
        surfaces.forEach(place)
    }

    /// Keeps surfaces under their anchors as the window changes.
    private func observeFrame(of nsWindow: NSWindow) {
        guard frameObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.placeAll() }
        }
        frameObservers = [
            NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
        ].map { center.addObserver(forName: $0, object: nsWindow, queue: nil, using: update) }
    }

    /// An anchor view can move within the window without the window
    /// changing (a toolbar shown or hidden, a split view resized): while a
    /// native surface hangs from a view, it is placed again after each
    /// update of the window, which costs a comparison when nothing moved.
    private func followAnchors() {
        let anchored = surfaces.contains { $0.window != nil && policy.anchor(for: $0.kind)?.isViewAnchor == true }
        guard anchored else { return stopFollowingAnchors() }
        guard anchorObserver == nil, let nsWindow = window?.window else { return }
        anchorObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nsWindow, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeAll() }
        }
    }

    private func stopFollowingAnchors() {
        if let anchorObserver { NotificationCenter.default.removeObserver(anchorObserver) }
        anchorObserver = nil
    }

    // MARK: Custom surfaces

    /// Hands a surface to the app's presenter, or to `onChromiumSurface`.
    private func presentCustom(kind: CefChromiumSurface.Kind, url: URL?, title: String) {
        guard let window, !isClosed else { return }
        let current = surfaces.filter { $0.kind == kind && $0.window == nil }
        if kind == .findBar, !current.isEmpty {
            // ⌘F again: the find bar stays, with its search.
            return
        }
        // One custom surface of a kind at a time: a second replaces the first.
        current.forEach { end($0, .replaced) }
        let surface = CefChromiumSurface(
            kind: kind, title: title, browser: browser, url: url,
            window: nil, parentWindow: window)
        surface.presentation = .custom
        surfaces.append(surface)
        if kind == .findBar {
            browser.findSession.begin()
            followFindSession(of: surface)
        } else if kind != .statusBubble {
            followNavigation(of: surface, from: browser.url)
        }
        if let present = customPresenters[kind] {
            present(surface)
        } else if kind == .share {
            surface.showSharingServicePicker()
            surface.dismiss()
        }
        onSurface?(surface)
    }

    /// A custom find bar ends with the browser's find session.
    private func followFindSession(of surface: CefChromiumSurface) {
        guard surface.state == .presented else { return }
        let session = browser.findSession
        let isActive = withObservationTracking {
            session.isActive
        } onChange: { [weak self, weak surface] in
            Task { @MainActor in
                guard let self, let surface else { return }
                self.followFindSession(of: surface)
            }
        }
        if !isActive { end(surface, .app) }
    }

    /// A custom surface about the page ends when the page goes elsewhere,
    /// as Chromium's bubbles do.
    private func followNavigation(of surface: CefChromiumSurface, from start: URL?) {
        guard surface.state == .presented else { return }
        let url = withObservationTracking {
            browser.url
        } onChange: { [weak self, weak surface] in
            Task { @MainActor in
                guard let self, let surface else { return }
                self.followNavigation(of: surface, from: start)
            }
        }
        if let start, let url, !Self.isSameDocument(start, url) { end(surface, .chromium) }
    }

    private static func isSameDocument(_ a: URL, _ b: URL) -> Bool {
        var a = URLComponents(url: a, resolvingAgainstBaseURL: false)
        var b = URLComponents(url: b, resolvingAgainstBaseURL: false)
        a?.fragment = nil
        b?.fragment = nil
        return a == b
    }

    /// With the status bubble ``CefChromiumSurface/Presentation/custom``, a
    /// custom surface is presented while ``CefBrowser/statusText`` is not
    /// empty.
    private func followStatusText() {
        guard !isClosed, policy[.statusBubble] == .custom, !isFollowingStatusText else { return }
        isFollowingStatusText = true
        let text = withObservationTracking {
            browser.statusText
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.isFollowingStatusText = false
                self?.followStatusText()
            }
        }
        let current = surfaces.first { $0.kind == .statusBubble && $0.window == nil }
        if text.isEmpty {
            if let current { end(current, .chromium) }
        } else if current == nil {
            presentCustom(kind: .statusBubble, url: browser.url, title: text)
        }
    }

    @ObservationIgnored private var isFollowingStatusText = false
    @ObservationIgnored private var passingOn: Int?

    /// The surface a Chrome command opens.
    private static func surfaceKind(for command: CefChromeCommand) -> CefChromiumSurface.Kind? {
        switch command {
        case .find: .findBar
        case .createQRCode: .qrCode
        case .castMedia: .cast
        case .showSharingHub: .share
        case .bookmarkThisTab: .bookmark
        case .zoomIn, .zoomOut, .resetZoom: .zoom
        default: nil
        }
    }

    /// Runs a command that opens a surface the app replaces or hides,
    /// without Chromium showing its own. Returns whether it was handled.
    func handleSurfaceCommand(_ command: CefChromeCommand) -> Bool {
        guard !isClosed else { return false }
        // ⌘G and ⇧⌘G move through a custom find bar's matches.
        if case .custom = policy[.findBar], browser.findSession.isActive {
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
        // A zoom command passed on to Chromium comes back through its
        // command handler in the same turn: it was handled already.
        if kind == .zoom, passingOn == command.rawValue { return false }
        switch policy[kind] {
        case .hidden:
            // Zooming still zooms; only its bubble is hidden.
            return kind != .zoom
        case .custom:
            presentCustom(kind: kind, url: browser.url, title: browser.title)
            guard kind == .zoom else { return true }
            // Chromium still zooms, its bubble off or suppressed.
            passingOn = command.rawValue
            DispatchQueue.main.async { [weak self] in self?.passingOn = nil }
            return false
        case .native:
            // Chromium has no share menu without its toolbar: macOS's.
            guard kind == .share else { return false }
            presentCustom(kind: kind, url: browser.url, title: browser.title)
            return true
        }
    }
}
