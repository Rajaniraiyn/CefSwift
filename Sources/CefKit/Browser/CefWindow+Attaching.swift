import AppKit
import ObjectiveC

extension CefWindow {
    /// Shows the page inside a window of your own, over `view`: a tabbed
    /// browser keeps one ``CefWindow`` per tab and attaches them all to the
    /// page area of one app window, showing the selected tab and hiding the
    /// others.
    ///
    /// Chromium gives each Chrome-style browser a window of its own (CEF
    /// refuses a second Chrome-style browser view in one), so the page stays
    /// in this window; attaching makes it a borderless child window of
    /// `view`'s window that follows `view`'s frame as it moves and resizes,
    /// enters and leaves full screen, and changes displays.
    /// Your window stays the main window while the page has the keyboard,
    /// so its title bar and toolbar look active; the attached window has no
    /// shadow, stays out of the Window menu and window cycling, and is
    /// minimized and taken to other Spaces with yours.
    ///
    /// ``show()`` orders the window in over `view`, ``hide()`` orders it
    /// out. Create the window with ``Configuration/isFrameless``, and attach
    /// it before showing it. Attach it to another view, in another window
    /// if you like, to move the tab: the browser, its history and its
    /// Chromium window stay the same.
    ///
    /// ```swift
    /// var configuration = CefWindow.Configuration()
    /// configuration.isFrameless = true
    /// let tab = CefWindow(browser: browser, configuration: configuration)
    /// tab.attach(to: pageArea)   // an NSView in your window
    /// tab.show()
    /// ```
    public func attach(to view: NSView) {
        placement?.stop()
        let placement = Placement(window: self, view: view)
        self.placement = placement
        withWindow { [weak self] nsWindow in
            guard let self, self.placement === placement else { return }
            placement.configure(nsWindow)
            if nsWindow.isVisible {
                placement.place()
                placement.order()
            }
        }
    }

    /// Stops following the view the window was attached to; the window
    /// is hidden.
    public func detach() {
        guard let placement else { return }
        hide()
        placement.stop()
        self.placement = nil
    }

    /// The view the window is attached to (``attach(to:)``).
    public var attachedView: NSView? { placement?.view }

    /// Keeps an attached window over its view.
    @MainActor
    final class Placement {
        private weak var owner: CefWindow?
        private(set) weak var view: NSView?
        private weak var parent: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(window: CefWindow, view: NSView) {
            owner = window
            self.view = view
            view.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.followView() } })
            // The view's window can change; every window's geometry is
            // watched, and changes to other windows ignored.
            for name in [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didDeminiaturizeNotification,
            ] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let window = note.object as? NSWindow
                    MainActor.assumeIsolated {
                        guard let self, window != nil, window === self.view?.window else { return }
                        self.followView()
                    }
                })
            }
        }

        /// Makes Chromium's window a borderless, shadowless child.
        func configure(_ window: NSWindow) {
            AttachedWindows.install()
            AttachedWindows.windows.insert(ObjectIdentifier(window))
            window.hasShadow = false
            window.isExcludedFromWindowsMenu = true
            window.tabbingMode = .disallowed
            window.collectionBehavior.formUnion([.fullScreenAuxiliary, .ignoresCycle])
            window.collectionBehavior.remove(.fullScreenPrimary)
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
        }

        /// Gives the window the view's frame on screen.
        func place() {
            guard let window = owner?.window, let view, let host = view.window else { return }
            let frame = host.convertToScreen(view.convert(view.bounds, to: nil))
            guard frame.width > 0, frame.height > 0, window.frame != frame else { return }
            window.setFrame(frame, display: window.isVisible)
        }

        /// Puts the shown window above the view's window, as its child.
        func order() {
            guard let window = owner?.window, window.isVisible, let host = view?.window else { return }
            if window.parent !== host {
                parent?.removeChildWindow(window)
                host.addChildWindow(window, ordered: .above)
                parent = host
            }
        }

        private func followView() {
            guard let window = owner?.window, window.isVisible else { return }
            place()
            order()
        }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window = owner?.window {
                parent?.removeChildWindow(window)
                AttachedWindows.windows.remove(ObjectIdentifier(window))
            }
            parent = nil
        }
    }
}

/// Keeps Chromium's attached windows from becoming the main window, so the
/// app's window they are attached to stays main, and looks active, while
/// the page has the keyboard. Chromium's window class answers
/// `canBecomeMainWindow` itself; it is overridden for attached windows only.
@MainActor
enum AttachedWindows {
    static var windows: Set<ObjectIdentifier> = []

    private typealias BoolGetter = @convention(c) (NSObject, Selector) -> Bool
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let selector = #selector(getter: NSWindow.canBecomeMain)
        var original: BoolGetter?
        let canBecomeMain: @convention(block) (NSObject) -> Bool = { window in
            let attached = MainActor.assumeIsolated { windows.contains(ObjectIdentifier(window)) }
            return attached ? false : original?(window, selector) ?? true
        }
        CefObjCHook.installFeature("attached windows", overrides: [
            .init(method: .init("CefNSWindow", selector, types: "B@:"), block: canBecomeMain) {
                original = unsafeBitCast($0, to: BoolGetter.self)
            },
        ])
    }
}
