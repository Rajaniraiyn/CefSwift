import AppKit
import CCef
import CefBase
import CefKit
import Foundation
import Observation

/// A piece of Chromium's own interface over a ``CefWindow``: a
/// bubble such as the QR code generator or Cast, a dialog such as the HTTP
/// sign-in, the find bar, the link status bubble, and others.
///
/// Chromium draws these with its Views toolkit, each in a window of its
/// own attached to the ``CefWindow``. ``CefWindow/chromiumUI``
/// decides how each kind is presented: as Chromium draws it, anchored under
/// one of your controls, replaced by your own interface, or hidden. Every
/// surface that appears is listed in ``CefWindow/chromiumSurfaces``
/// and reported to ``CefWindow/onChromiumSurface``.
///
/// A surface you present yourself (``Presentation/custom``) carries what
/// your interface needs: the ``browser``, the ``url`` it is about, the
/// ``anchorRect`` to place it at, and ``dismiss()``.
@MainActor
@Observable
public final class CefChromiumSurface: Identifiable {

    /// What a surface is. Recognized from the class of Chromium's view
    /// inside the surface's window, which Chromium reports through
    /// accessibility, or else from its title in Chromium's localized
    /// strings.
    public enum Kind: Hashable, Sendable {
        /// The find bar (``CefChromeCommand/find``, ⌘F).
        case findBar
        /// "Scan QR Code" (``CefChromeCommand/createQRCode``).
        case qrCode
        /// Cast and media routing (``CefChromeCommand/castMedia``).
        case cast
        /// The share menu (``CefChromeCommand/showSharingHub``). Chromium
        /// shows it only from its own toolbar, so in a ``CefWindow``
        /// the command opens macOS's share menu unless you present your own.
        case share
        /// The sign-in dialog for HTTP authentication, with
        /// ``CefRuntime/AuthenticationPromptPolicy/chromium``.
        case signIn
        /// The status bubble showing a hovered link's address.
        case statusBubble
        /// The notice shown on entering fullscreen ("To exit full screen,
        /// press esc").
        case fullscreenNotice
        /// The downloads bubble.
        case downloads
        /// A permission prompt. CefSwift routes permission requests to
        /// ``CefBrowserDelegate/browser(_:decidePermissionFor:)``, so Chromium
        /// shows these only for requests that bypass the delegate.
        case permissionPrompt
        /// The translate bubble.
        case translate
        /// "Save password?" and "Update password?".
        case savePassword
        /// The bookmark bubble (``CefChromeCommand/bookmarkThisTab``).
        case bookmark
        /// Site information and permissions.
        case pageInfo
        /// The zoom bubble.
        case zoom
        /// Any other surface, identified by the class of Chromium's view
        /// inside it or, failing that, its title. Identifiers are Chromium's
        /// and can change between versions.
        case other(String)

        /// Whether Chromium would attach the surface to its toolbar, so that
        /// ``CefWindow/ChromiumUI/anchor`` applies to it.
        public var hangsFromToolbar: Bool {
            switch self {
            case .qrCode, .cast, .share, .downloads, .permissionPrompt, .translate, .savePassword, .bookmark,
                 .pageInfo, .zoom:
                true
            case .other(let identifier):
                // Bubble dialogs with a title; untitled widgets such as
                // autofill suggestions belong to the page.
                !identifier.isEmpty && !identifier.hasPrefix("view:")
            case .findBar, .signIn, .statusBubble, .fullscreenNotice:
                false
            }
        }
    }

    /// How a kind of surface is presented.
    public enum Presentation: Sendable {
        /// As Chromium draws it, under its anchor
        /// (``CefWindow/ChromiumUI/anchors``, or ``CefWindow/ChromiumUI/anchor`` for
        /// surfaces that hang from the toolbar), or where Chromium puts it
        /// when there is none.
        case native
        /// Not shown by Chromium: your own interface instead. The surface
        /// goes to the presenter set with
        /// ``CefWindow/setCustomPresentation(for:_:)``, or else to
        /// ``CefWindow/onChromiumSurface``.
        case custom
        /// Not shown at all. Dialogs that ask something are cancelled.
        case hidden
    }

    public let kind: Kind
    /// The surface's title, as Chromium sets it, in the UI language. Empty
    /// for untitled surfaces such as the find bar.
    public let title: String
    /// The browser the surface belongs to.
    public let browser: CefBrowser
    /// What the surface is about: the address a QR code encodes, the page to
    /// share or cast. For most surfaces, the page's address.
    public let url: URL?
    /// The anchor for this kind in screen coordinates, where your interface
    /// for a custom surface goes; `nil` when there is none. ``position(_:)``
    /// places a window there.
    public var anchorRect: CGRect? {
        guard let window = parentWindow?.window else { return nil }
        return parentWindow?.chromiumUI.anchor(for: kind)?.screenRect(in: window)
    }
    /// How the surface is presented.
    public internal(set) var presentation: Presentation = .native
    /// Whether the surface is on screen — Chromium's, or yours while you
    /// present it. Becomes `false` once it is dismissed.
    public internal(set) var isPresented = true

    /// Chromium's window for a surface it draws; `nil` for one presented
    /// with your own interface from the start. Chromium owns it: move it,
    /// but dismiss it with ``dismiss()``.
    @ObservationIgnored public private(set) weak var window: NSWindow?
    /// The window the surface belongs to. Chromium attaches the surface's ``window`` to it as a child window.
    @ObservationIgnored public private(set) weak var parentWindow: CefWindow?

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// Called once when the surface is dismissed.
    @ObservationIgnored var onDismiss: (() -> Void)?

    init(
        kind: Kind, title: String, browser: CefBrowser, url: URL?,
        window: NSWindow?, parentWindow: CefWindow
    ) {
        self.kind = kind
        self.title = title
        self.browser = browser
        self.url = url
        self.window = window
        self.parentWindow = parentWindow
    }

    /// Ends the surface. Chromium's surfaces close as pressing Esc in them
    /// would, which cancels what they ask (a sign-in dialog cancels the
    /// sign-in); a find bar ends the browser's ``CefBrowser/findSession``;
    /// your own interface for a custom surface should close when
    /// ``isPresented`` turns `false`.
    public func dismiss() {
        guard isPresented else { return }
        isPresented = false
        if kind == .findBar {
            browser.findSession.end()
        }
        if let window, window.isVisible {
            Self.closeNatively(window, kind: kind, browser: browser)
        }
        let onDismiss = self.onDismiss
        self.onDismiss = nil
        onDismiss?()
    }

    /// Closes Chromium's window for a surface the way its own controls do.
    static func closeNatively(_ window: NSWindow, kind: Kind, browser: CefBrowser) {
        switch kind {
        case .findBar:
            browser.execute(CefChromeCommand(rawValue: Int(IDC_CLOSE_FIND_OR_STOP)))
        case .statusBubble, .fullscreenNotice:
            // Chromium shows and hides these itself and reuses their windows.
            break
        default:
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
                if let event { window.sendEvent(event) }
            }
            // Untitled widgets belong to the page; leave them be.
            guard kind.hangsFromToolbar || kind == .signIn else { return }
            Task { @MainActor [weak window] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let window, window.isVisible else { return }
                window.close()
            }
        }
    }

    /// Places a window of yours for this surface as Chromium's would be:
    /// beneath the kind's anchor, or else at the top right of the page.
    public func position(_ panel: NSWindow) {
        guard let parent = parentWindow?.window else { return }
        let size = panel.frame.size
        if let anchor = parentWindow?.chromiumUI.anchor(for: kind), let origin = anchor.origin(for: size, in: parent) {
            panel.setFrameOrigin(origin)
            return
        }
        let page = parent.convertToScreen(parent.contentLayoutRect)
        panel.setFrameOrigin(CGPoint(x: page.maxX - size.width - 12, y: page.maxY - size.height - 8))
    }

    /// Shows macOS's share menu for ``url`` at ``anchorRect``, or at the top
    /// right of the window. What ``Kind/share`` does by default.
    public func showSharingServicePicker() {
        guard let url, let host = parentWindow?.window?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        let rect: CGRect
        if let anchorRect, let window = host.window {
            rect = host.convert(window.convertFromScreen(anchorRect), from: nil)
        } else {
            rect = CGRect(x: host.bounds.maxX - 40, y: host.bounds.maxY - 8, width: 1, height: 1)
        }
        picker.show(relativeTo: rect, of: host, preferredEdge: .minY)
    }

    // MARK: Recognizing surfaces

    /// Chromium's view classes, by kind. The view is the one inside the
    /// surface's frame that Chromium names in the surface's accessibility
    /// tree; a prefix matches subclasses Chromium names after it.
    private static let viewClasses: [(String, Kind)] = [
        ("FindBarView", .findBar),
        ("QRCodeGeneratorBubble", .qrCode),
        ("CastDialogView", .cast),
        ("MediaDialogView", .cast),
        ("SharingHubBubble", .share),
        ("LoginView", .signIn),
        ("StatusView", .statusBubble),
        ("SubtleNotificationView", .fullscreenNotice),
        ("DownloadBubble", .downloads),
        ("PermissionPrompt", .permissionPrompt),
        ("TranslateBubble", .translate),
        ("PartialTranslateBubble", .translate),
        ("PasswordSaveUpdate", .savePassword),
        ("PasswordBubble", .savePassword),
        ("BookmarkBubble", .bookmark),
        ("PageInfoBubble", .pageInfo),
        ("ZoomBubble", .zoom),
    ]

    /// Views every surface has, which say nothing about its kind.
    private static let frameClasses: Set<String> = [
        "RootView", "NonClientView", "BubbleFrameView", "ClientView", "DialogClientView", "View",
        "BoxLayoutView", "FlexLayoutView", "TableLayoutView", "Label", "ImageView", "ImageButton",
        "LabelButton", "MdTextButton", "Textfield", "ScrollView", "ScrollView::Viewport", "Separator",
        "BubbleDialogModelHostContentsView", "DialogClientView::ButtonRowContainer",
    ]

    /// Chromium's titles, by kind, when the view class says nothing. `$1`
    /// stands for any text.
    private static let titleIdentifiers: [(Int32, Kind)] = [
        (IDS_BROWSER_SHARING_QR_CODE_DIALOG_TITLE, .qrCode),
        (IDS_MEDIA_ROUTER_TAB_MIRROR_CAST_MODE, .cast),
        (IDS_MEDIA_ROUTER_PRESENTATION_CAST_MODE, .cast),
        (IDS_MEDIA_ROUTER_DESKTOP_MIRROR_CAST_MODE, .cast),
        (IDS_SHARING_HUB_TITLE, .share),
        (IDS_LOGIN_DIALOG_TITLE, .signIn),
        (IDS_PERMISSIONS_BUBBLE_PROMPT, .permissionPrompt),
        (IDS_TRANSLATE_BUBBLE_BEFORE_TRANSLATE_TITLE, .translate),
        (IDS_TRANSLATE_BUBBLE_TRANSLATED_TITLE, .translate),
        (IDS_SAVE_PASSWORD, .savePassword),
        (IDS_UPDATE_PASSWORD, .savePassword),
        (IDS_BOOKMARK_BUBBLE_PAGE_BOOKMARKED, .bookmark),
        (IDS_BOOKMARK_BUBBLE_PAGE_BOOKMARK, .bookmark),
        (IDS_DOWNLOAD_BUBBLE_HEADER_LABEL, .downloads),
        (IDS_FIND_IN_PAGE_ACCESSIBLE_TITLE, .findBar),
    ]

    private static var titlePatterns: [(NSRegularExpression, Kind)]?

    /// What `window` shows: its kind, title, and its accessibility tree's
    /// first editable text, which is the address in a QR code bubble.
    /// `kind` is `nil` while Chromium has not yet built the view tree.
    static func recognize(_ window: NSWindow) -> (kind: Kind?, title: String, text: String?) {
        let root = window.contentView?.accessibilityChildren()?.first as? NSObject
        var classes: [String] = []
        var text: String?
        if let root { collect(root, depth: 0, classes: &classes, text: &text) }
        let rootTitle = (root as? NSAccessibilityProtocol)?.accessibilityTitle() ?? ""
        let title = window.title.isEmpty ? rootTitle : window.title
        if let match = classes.lazy.compactMap({ name in
            viewClasses.first { name.hasPrefix($0.0) }?.1
        }).first {
            return (match, title, text)
        }
        if let kind = kind(forTitle: title) { return (kind, title, text) }
        guard root != nil else { return (nil, title, text) }
        let specific = classes.first { !frameClasses.contains($0) }
        if !title.isEmpty { return (.other(title), title, text) }
        return (.other(specific.map { "view:\($0)" } ?? ""), title, text)
    }

    /// Gathers view class names, breadth first and a few levels deep, and
    /// the first text field's value.
    private static func collect(_ element: NSObject, depth: Int, classes: inout [String], text: inout String?) {
        guard depth < 8 else { return }
        classes.append(contentsOf: classList(of: element))
        let accessible = element as? NSAccessibilityProtocol
        if text == nil, accessible?.accessibilityRole() == .textField,
           let value = accessible?.accessibilityValue() as? String, !value.isEmpty {
            text = value
        }
        for child in (accessible?.accessibilityChildren() ?? []).prefix(16) {
            if let child = child as? NSObject { collect(child, depth: depth + 1, classes: &classes, text: &text) }
        }
    }

    /// Chromium's Views name each view's class in `AXDOMClassList`.
    private static func classList(of element: NSObject) -> [String] {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard element.responds(to: selector),
              let value = element.perform(selector, with: "AXDOMClassList")?.takeUnretainedValue()
        else { return [] }
        return (value as? [String]) ?? (value as? NSArray)?.compactMap { $0 as? String } ?? []
    }

    /// The kind a title names, if any.
    static func kind(forTitle title: String) -> Kind? {
        let text = normalized(title)
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return patterns().first { $0.0.firstMatch(in: text, range: range) != nil }?.1
    }

    private static func patterns() -> [(NSRegularExpression, Kind)] {
        if let titlePatterns { return titlePatterns }
        guard let bundle = cef_resource_bundle_get_global() else { return [] }
        defer { cefRelease(bundle) }
        let patterns = titleIdentifiers.compactMap { identifier, kind -> (NSRegularExpression, Kind)? in
            guard let template = CefStringUtil.takingUserFree(bundle.pointee.get_localized_string(bundle, identifier)),
                  !template.isEmpty
            else { return nil }
            let parts = normalized(template).split(separator: /\$[1-9]/, omittingEmptySubsequences: false)
            let pattern = "^" + parts.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
            return (try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])).map { ($0, kind) }
        }
        titlePatterns = patterns
        return patterns
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether a child window of a ``CefWindow`` is one of Chromium's
    /// surfaces: a Views widget window, not a Chrome-style browser window
    /// such as a popup the app layers over its opener.
    static func isSurfaceWindow(_ window: NSWindow) -> Bool {
        guard let widgetClass = NSClassFromString("NativeWidgetMacNSWindow"), window.isKind(of: widgetClass) else {
            return false
        }
        if let browserWindowClass = NSClassFromString("CefNSWindow"), window.isKind(of: browserWindowClass) {
            return false
        }
        return true
    }
}

extension CefWindow {
    /// How a ``CefWindow`` presents Chromium's own interface: for each
    /// kind of surface, whether Chromium draws it, you replace it, or it is
    /// hidden, and where it goes.
    ///
    /// ```swift
    /// window.chromiumUI.anchor = .view(addressField, alignment: .trailing)
    /// window.chromiumUI.anchors[.qrCode] = .view(qrButton, alignment: .trailing)
    /// window.chromiumUI[.statusBubble] = .hidden
    /// ```
    @MainActor
    public struct ChromiumUI {
        /// Where surfaces that hang from Chrome's toolbar go
        /// (``CefChromiumSurface/Kind/hangsFromToolbar``) when their kind has no
        /// anchor in ``anchors``. `nil` leaves them where Chromium puts them,
        /// which without Chrome's toolbar is the top right of the page.
        public var anchor: CefChromiumSurface.Anchor?

        /// Anchors by kind, for Chromium's surfaces and for your own interface
        /// in their place. The only way to move surfaces that belong to the
        /// page, such as the find bar and the sign-in dialog.
        public var anchors: [CefChromiumSurface.Kind: CefChromiumSurface.Anchor] = [:]

        /// Presentations by kind. A kind not listed is
        /// ``CefChromiumSurface/Presentation/native``.
        public var presentations: [CefChromiumSurface.Kind: CefChromiumSurface.Presentation] = [:]

        public init() {}

        /// The presentation of `kind`.
        public subscript(kind: CefChromiumSurface.Kind) -> CefChromiumSurface.Presentation {
            get { presentations[kind] ?? .native }
            set { presentations[kind] = newValue }
        }

        /// The anchor that applies to a surface of `kind`.
        func anchor(for kind: CefChromiumSurface.Kind) -> CefChromiumSurface.Anchor? {
            anchors[kind] ?? (kind.hangsFromToolbar ? anchor : nil)
        }
    }
}
extension CefChromiumSurface {
    /// Where a surface of Chromium's goes in a ``CefWindow``: beneath a
    /// view or a rectangle of yours, aligned with its leading or trailing edge
    /// or centered on it.
    ///
    /// ```swift
    /// window.chromiumUI.anchor = .view(addressField, alignment: .trailing)
    /// window.chromiumUI.anchors[.findBar] = .rect(CGRect(x: 0, y: 700, width: 300, height: 0))
    /// ```
    @MainActor
    public struct Anchor {
        /// How the surface lines up with its anchor.
        public enum Alignment: Sendable {
            /// The surface's left edge at the anchor's left edge.
            case leading
            /// Centered under the anchor.
            case center
            /// The surface's right edge at the anchor's right edge.
            case trailing
        }

        private enum Target {
            case view(WeakView)
            case rect(CGRect)
        }

        private final class WeakView {
            weak var view: NSView?
            init(_ view: NSView) { self.view = view }
        }

        private let target: Target
        public var alignment: Alignment
        /// The gap between the anchor's bottom edge and the surface.
        public var spacing: CGFloat

        /// Beneath `view`, which must be in the window, its title bar
        /// and toolbar included. The view is held weakly; once it is gone or
        /// out of the window, surfaces stay where Chromium puts them.
        public static func view(_ view: NSView, alignment: Alignment = .center, spacing: CGFloat = 4) -> CefChromiumSurface.Anchor {
            CefChromiumSurface.Anchor(target: .view(WeakView(view)), alignment: alignment, spacing: spacing)
        }

        /// Beneath `rect`, in the window's coordinate space (points from its
        /// bottom-left corner, as `NSView.convert(_:to: nil)` gives).
        public static func rect(_ rect: CGRect, alignment: Alignment = .center, spacing: CGFloat = 4) -> CefChromiumSurface.Anchor {
            CefChromiumSurface.Anchor(target: .rect(rect), alignment: alignment, spacing: spacing)
        }

        /// Whether this anchor is beneath `view`.
        func isAnchored(to view: NSView) -> Bool {
            if case .view(let box) = target { return box.view === view }
            return false
        }

        /// The anchor in screen coordinates, or `nil` when its view is gone or
        /// not in `window`.
        func screenRect(in window: NSWindow) -> CGRect? {
            switch target {
            case .rect(let rect):
                return window.convertToScreen(rect)
            case .view(let box):
                guard let view = box.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
                return window.convertToScreen(view.convert(view.bounds, to: nil))
            }
        }

        /// Where a surface of `size` goes for this anchor in `window`, kept
        /// inside the window horizontally and on screen.
        func origin(for size: CGSize, in window: NSWindow) -> CGPoint? {
            guard let anchor = screenRect(in: window) else { return nil }
            var x: CGFloat = switch alignment {
            case .leading: anchor.minX
            case .center: anchor.midX - size.width / 2
            case .trailing: anchor.maxX - size.width
            }
            var y = anchor.minY - spacing - size.height
            let margin: CGFloat = 4
            let bounds = window.frame.insetBy(dx: margin, dy: 0)
            if size.width <= bounds.width {
                x = min(max(x, bounds.minX), bounds.maxX - size.width)
            }
            if let screen = window.screen?.visibleFrame {
                x = min(max(x, screen.minX), screen.maxX - size.width)
                y = max(y, screen.minY)
            }
            return CGPoint(x: x.rounded(), y: y.rounded())
        }
    }
}

// MARK: - Tracking

/// Notices Chromium's surfaces as Chromium attaches them to a browser
/// window, by overriding `-addChildWindow:ordered:` and
/// `-removeChildWindow:` in `CefNSWindow`, the class of every window CEF
/// Views creates.
@MainActor
enum CefSurfaceTracker {
    private typealias AddChild = @convention(c) (NSWindow, Selector, NSWindow, NSWindow.OrderingMode) -> Void
    private typealias RemoveChild = @convention(c) (NSWindow, Selector, NSWindow) -> Void

    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let addSelector = #selector(NSWindow.addChildWindow(_:ordered:))
        var addOriginal: AddChild?
        let add: @convention(block) (NSWindow, NSWindow, NSWindow.OrderingMode) -> Void = { parent, child, order in
            MainActor.assumeIsolated {
                // Hidden until it is recognized, so a surface the app
                // replaces or hides never shows.
                CefWindow.owning(parent)?.surfaces.childWindowWillAttach(child)
            }
            addOriginal?(parent, addSelector, child, order)
            MainActor.assumeIsolated {
                CefWindow.owning(parent)?.surfaces.childWindowDidAttach(child)
            }
        }

        let removeSelector = #selector(NSWindow.removeChildWindow(_:))
        var removeOriginal: RemoveChild?
        let remove: @convention(block) (NSWindow, NSWindow) -> Void = { parent, child in
            removeOriginal?(parent, removeSelector, child)
            MainActor.assumeIsolated {
                CefWindow.owning(parent)?.surfaces.childWindowDidDetach(child)
            }
        }

        // Chromium fades some widgets in by setting their window's alpha
        // (the status bubble does on every hover), which would undo hiding
        // them. A hidden surface's window keeps an alpha of 0.
        let alphaSelector = #selector(setter: NSWindow.alphaValue)
        var alphaOriginal: SetAlpha?
        let setAlpha: @convention(block) (NSWindow, CGFloat) -> Void = { window, alpha in
            let hidden = objc_getAssociatedObject(window, &hiddenKey) != nil
            alphaOriginal?(window, alphaSelector, hidden ? 0 : alpha)
        }

        // Recognizing surfaces as they attach, and keeping hidden ones
        // transparent, work together: all of them or none.
        CefObjCHook.installFeature(
            "Chromium surfaces",
            requires: [.init("NativeWidgetMacNSWindow", #selector(NSWindow.sendEvent(_:)), types: "v@:@")],
            overrides: [
                .init(method: .init("CefNSWindow", addSelector, types: "v@:@q"), block: add) {
                    addOriginal = unsafeBitCast($0, to: AddChild.self)
                },
                .init(method: .init("CefNSWindow", removeSelector, types: "v@:@"), block: remove) {
                    removeOriginal = unsafeBitCast($0, to: RemoveChild.self)
                },
                .init(method: .init("NativeWidgetMacNSWindow", alphaSelector, types: "v@:d"), block: setAlpha) {
                    alphaOriginal = unsafeBitCast($0, to: SetAlpha.self)
                },
            ])
    }

    private typealias SetAlpha = @convention(c) (NSWindow, Selector, CGFloat) -> Void
    private nonisolated(unsafe) static var hiddenKey = 0

    /// Keeps `window` transparent, whatever alpha Chromium gives it, or lets
    /// it be shown again.
    static func setHidden(_ window: NSWindow, _ hidden: Bool) {
        objc_setAssociatedObject(window, &hiddenKey, hidden ? NSNumber(value: true) : nil, .OBJC_ASSOCIATION_RETAIN)
        if hidden { window.alphaValue = 0 }
    }
}
