import AppKit
import CCef
import Foundation

/// A bubble or dialog that Chromium shows over a ``CefBrowserWindow``: the
/// QR code generator, Cast, the HTTP sign-in dialog, the find bar, and the
/// like.
///
/// Chromium draws these in windows of its own, child windows of the browser
/// window. Without Chrome's toolbar it places them where that toolbar's
/// buttons would be; ``CefBrowserWindow/bubbleAnchor`` moves them under your
/// own controls instead. ``CefBrowserWindow/chromiumBubbles`` lists the ones
/// on screen, and ``CefBrowserWindow/onChromiumBubble`` hears about each as
/// it appears.
@MainActor
public final class CefChromiumBubble: Identifiable {

    /// What a bubble is, recognized from its title in Chromium's own
    /// localized strings, so it works in every UI language.
    public enum Kind: Hashable, Sendable, CaseIterable {
        /// "Scan QR Code" (``CefChromeCommand/createQRCode``).
        case qrCode
        /// Cast and media routing (``CefChromeCommand/castMedia``).
        case cast
        /// The share menu (``CefChromeCommand/showSharingHub``).
        case share
        /// The sign-in dialog for HTTP authentication. It belongs to the
        /// page, so only an anchor set for this kind in
        /// ``CefBrowserWindow/bubbleAnchors`` moves it.
        case signIn
        /// Chrome's find bar (``CefChromeCommand/find``). Only an anchor set
        /// for this kind in ``CefBrowserWindow/bubbleAnchors`` moves it.
        case findBar
        /// A permission prompt. CefSwift routes permission requests to
        /// ``CefBrowserDelegate/browser(_:decidePermissionFor:)``, so
        /// Chromium shows these only for requests that bypass the delegate.
        case permission
        /// The translate bubble.
        case translate
        /// "Save password?" and "Update password?".
        case savePassword
        /// The bookmark editor bubble (``CefChromeCommand/bookmarkThisTab``).
        case bookmark
        /// A titled bubble of another kind (page info, zoom, downloads,
        /// extensions, …), or an untitled one Chromium attaches to the
        /// browser window. Untitled bubbles, such as autofill suggestions,
        /// are attached to the page and are never moved.
        case other
    }

    public private(set) var kind: Kind
    /// The bubble's title as Chromium sets it, in the UI language: its
    /// window's title, or for the find bar its accessible name. Empty for
    /// untitled bubbles.
    public private(set) var title: String
    /// Chromium's window for the bubble. Chromium owns it; move it, but do
    /// not close it directly — call ``dismiss()``.
    public private(set) weak var window: NSWindow?
    /// The browser window the bubble belongs to.
    public private(set) weak var browserWindow: CefBrowserWindow?

    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// Whether the bubble is on screen.
    public var isVisible: Bool { window?.isVisible ?? false }

    init(window: NSWindow, kind: Kind, title: String, browserWindow: CefBrowserWindow) {
        self.window = window
        self.kind = kind
        self.title = title
        self.browserWindow = browserWindow
    }

    /// Reads the title again if there was none: an untitled bubble's
    /// accessible name exists only once Chromium has shown it.
    func refreshKind() {
        guard title.isEmpty, let window else { return }
        title = Self.title(of: window)
        kind = Self.kind(forTitle: title)
    }

    /// Whether ``CefBrowserWindow/bubbleAnchor`` applies: bubbles Chromium
    /// would attach to its toolbar. Page-attached ones, the sign-in dialog
    /// and the find bar move only for an anchor of their own kind.
    var followsWindowAnchor: Bool {
        switch kind {
        case .signIn, .findBar: false
        case .other: !title.isEmpty
        default: true
        }
    }

    /// Closes the bubble as pressing Esc in it would, which cancels what it
    /// asks (a sign-in dialog cancels the sign-in). Closes its window if the
    /// bubble does not handle Esc.
    public func dismiss() {
        if kind == .findBar {
            browserWindow?.browser.stopFinding()
        }
        guard let window, window.isVisible else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
            if let event { window.sendEvent(event) }
        }
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let window, window.isVisible else { return }
            window.close()
        }
    }

    // MARK: Recognizing bubbles

    /// Chromium's titles for each kind, by string identifier. `$1` stands
    /// for any text.
    private static let titleIdentifiers: [(Int32, Kind)] = [
        (IDS_BROWSER_SHARING_QR_CODE_DIALOG_TITLE, .qrCode),
        (IDS_MEDIA_ROUTER_TAB_MIRROR_CAST_MODE, .cast),
        (IDS_MEDIA_ROUTER_PRESENTATION_CAST_MODE, .cast),
        (IDS_MEDIA_ROUTER_DESKTOP_MIRROR_CAST_MODE, .cast),
        (IDS_SHARING_HUB_TITLE, .share),
        (IDS_LOGIN_DIALOG_TITLE, .signIn),
        (IDS_PERMISSIONS_BUBBLE_PROMPT, .permission),
        (IDS_TRANSLATE_BUBBLE_BEFORE_TRANSLATE_TITLE, .translate),
        (IDS_TRANSLATE_BUBBLE_TRANSLATED_TITLE, .translate),
        (IDS_TRANSLATE_BUBBLE_COULD_NOT_TRANSLATE_TITLE, .translate),
        (IDS_SAVE_PASSWORD, .savePassword),
        (IDS_UPDATE_PASSWORD, .savePassword),
        (IDS_SAVE_PASSWORD_DIFFERENT_DOMAINS_TITLE, .savePassword),
        (IDS_BOOKMARK_BUBBLE_PAGE_BOOKMARKED, .bookmark),
        (IDS_BOOKMARK_BUBBLE_PAGE_BOOKMARK, .bookmark),
        (IDS_FIND_IN_PAGE_ACCESSIBLE_TITLE, .findBar),
    ]

    private static var titlePatterns: [(NSRegularExpression, Kind)]?

    /// The patterns, read from Chromium's resource bundle on first use.
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

    /// The kind a title names, or ``Kind/other``.
    static func kind(forTitle title: String) -> Kind {
        let text = normalized(title)
        guard !text.isEmpty else { return .other }
        let range = NSRange(text.startIndex..., in: text)
        return patterns().first { $0.0.firstMatch(in: text, range: range) != nil }?.1 ?? .other
    }

    /// A bubble window's title: the window's own, or for untitled windows
    /// the accessible name of its root view, which is how the find bar
    /// names itself.
    static func title(of window: NSWindow) -> String {
        if !window.title.isEmpty { return window.title }
        let root = window.contentView?.accessibilityChildren()?.first as? NSAccessibilityProtocol
        return root?.accessibilityTitle() ?? root?.accessibilityLabel() ?? ""
    }

    /// Whether a child window of a browser window is one of Chromium's
    /// bubbles: a Views widget window, not a Chrome-style browser window
    /// such as a popup the app layers over its opener.
    static func isBubbleWindow(_ window: NSWindow) -> Bool {
        guard let widgetClass = NSClassFromString("NativeWidgetMacNSWindow"), window.isKind(of: widgetClass) else {
            return false
        }
        if let browserWindowClass = NSClassFromString("CefNSWindow"), window.isKind(of: browserWindowClass) {
            return false
        }
        return true
    }
}

/// Where Chromium's bubbles appear in a ``CefBrowserWindow``: beneath a view
/// or a rectangle of yours, aligned with its leading or trailing edge or
/// centered on it.
///
/// ```swift
/// window.bubbleAnchor = .view(addressField, alignment: .trailing)
/// window.bubbleAnchors[.findBar] = .rect(CGRect(x: 0, y: 700, width: 300, height: 0))
/// ```
@MainActor
public struct CefBubbleAnchor {
    /// How the bubble lines up with its anchor.
    public enum Alignment: Sendable {
        /// The bubble's left edge at the anchor's left edge.
        case leading
        /// Centered under the anchor.
        case center
        /// The bubble's right edge at the anchor's right edge.
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
    /// The gap between the anchor's bottom edge and the bubble.
    public var spacing: CGFloat

    /// Beneath `view`, which must be in the browser window, its title bar
    /// and toolbar included. The view is held weakly; once it is gone or
    /// out of the window, bubbles stay where Chromium puts them.
    public static func view(_ view: NSView, alignment: Alignment = .center, spacing: CGFloat = 4) -> CefBubbleAnchor {
        CefBubbleAnchor(target: .view(WeakView(view)), alignment: alignment, spacing: spacing)
    }

    /// Beneath `rect`, in the window's coordinate space (points from its
    /// bottom-left corner, as `NSView.convert(_:to: nil)` gives).
    public static func rect(_ rect: CGRect, alignment: Alignment = .center, spacing: CGFloat = 4) -> CefBubbleAnchor {
        CefBubbleAnchor(target: .rect(rect), alignment: alignment, spacing: spacing)
    }

    /// Whether this anchor is beneath `view`.
    package func isAnchored(to view: NSView) -> Bool {
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

    /// Where a bubble of `size` goes for this anchor in `window`, kept
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

// MARK: - Tracking

/// Notices Chromium's bubbles as Chromium attaches them to a browser
/// window, by overriding `-addChildWindow:ordered:` and
/// `-removeChildWindow:` in `CefNSWindow`, the class of every window CEF
/// Views creates.
@MainActor
enum CefBubbleTracker {
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
                // Placed before it is ordered in, so it never shows elsewhere.
                CefBrowserWindow.owning(parent)?.childWindowWillAttach(child)
            }
            addOriginal?(parent, addSelector, child, order)
            MainActor.assumeIsolated {
                CefBrowserWindow.owning(parent)?.childWindowDidAttach(child)
            }
        }
        if let imp = CefObjCHook.override("CefNSWindow", addSelector, expectedTypes: "v@:@q", with: add) {
            addOriginal = unsafeBitCast(imp, to: AddChild.self)
        }

        let removeSelector = #selector(NSWindow.removeChildWindow(_:))
        var removeOriginal: RemoveChild?
        let remove: @convention(block) (NSWindow, NSWindow) -> Void = { parent, child in
            removeOriginal?(parent, removeSelector, child)
            MainActor.assumeIsolated {
                CefBrowserWindow.owning(parent)?.childWindowDidDetach(child)
            }
        }
        if let imp = CefObjCHook.override("CefNSWindow", removeSelector, expectedTypes: "v@:@", with: remove) {
            removeOriginal = unsafeBitCast(imp, to: RemoveChild.self)
        }
        CefObjCHook.require("NativeWidgetMacNSWindow", #selector(NSWindow.sendEvent(_:)))
    }
}
