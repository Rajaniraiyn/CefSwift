import AppKit
import CCef
import Foundation

/// How a link/popup the page wants to open should be routed — mirrors
/// `cef_window_open_disposition_t` (Chromium's `WindowOpenDisposition`). The
/// disposition encodes the user's intent as Chromium computed it from the
/// click + modifier keys (e.g. ⌘-click → ``newBackgroundTab``).
public enum CefWindowOpenDisposition: Sendable, Equatable {
    /// Unknown / unspecified.
    case unknown
    /// Replace the current tab's contents (the default for most clicks).
    case currentTab
    /// Only one tab with the URL should exist in the same window.
    case singletonTab
    /// Open a new foreground tab (Shift+middle-click, or ⌘/Ctrl+Shift+click).
    case newForegroundTab
    /// Open a new background tab (middle-click, or ⌘/Ctrl+click).
    case newBackgroundTab
    /// Open a new popup window (`window.open` with features, JS popup).
    case newPopup
    /// Open a new top-level window (Shift+click).
    case newWindow
    /// Save the link target to disk (Alt+click).
    case saveToDisk
    /// Open a new off-the-record (incognito) window.
    case offTheRecord
    /// Special error condition from the renderer.
    case ignoreAction
    /// Activate an existing tab containing the URL.
    case switchToTab
    /// New document picture-in-picture window.
    case newPictureInPicture
    /// Open in a split view alongside the current tab.
    case newSplitView

    /// Maps a raw `cef_window_open_disposition_t` value.
    public init(cefValue: cef_window_open_disposition_t) {
        switch cefValue {
        case CEF_WOD_CURRENT_TAB: self = .currentTab
        case CEF_WOD_SINGLETON_TAB: self = .singletonTab
        case CEF_WOD_NEW_FOREGROUND_TAB: self = .newForegroundTab
        case CEF_WOD_NEW_BACKGROUND_TAB: self = .newBackgroundTab
        case CEF_WOD_NEW_POPUP: self = .newPopup
        case CEF_WOD_NEW_WINDOW: self = .newWindow
        case CEF_WOD_SAVE_TO_DISK: self = .saveToDisk
        case CEF_WOD_OFF_THE_RECORD: self = .offTheRecord
        case CEF_WOD_IGNORE_ACTION: self = .ignoreAction
        case CEF_WOD_SWITCH_TO_TAB: self = .switchToTab
        case CEF_WOD_NEW_PICTURE_IN_PICTURE: self = .newPictureInPicture
        case CEF_WOD_NEW_SPLIT_VIEW: self = .newSplitView
        default: self = .unknown
        }
    }

    /// Whether this disposition expresses an intent to surface the new content
    /// in the foreground (vs. opening it in the background).
    public var prefersForeground: Bool {
        switch self {
        case .newBackgroundTab: return false
        default: return true
        }
    }
}

/// Optional window features the page requested for a popup (from
/// `window.open(url, name, "width=…,height=…")`). Mirrors
/// `cef_popup_features_t`.
public struct CefPopupFeatures: Sendable, Equatable {
    /// Requested origin X (screen coords), if specified.
    public var x: Int?
    /// Requested origin Y (screen coords), if specified.
    public var y: Int?
    /// Requested content width, if specified.
    public var width: Int?
    /// Requested content height, if specified.
    public var height: Int?
    /// Whether the page asked for a chromeless popup (toolbar hidden).
    public var isPopup: Bool

    public init(x: Int? = nil, y: Int? = nil, width: Int? = nil, height: Int? = nil, isPopup: Bool = false) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isPopup = isPopup
    }

    init(raw: cef_popup_features_t) {
        self.init(
            x: raw.xSet != 0 ? Int(raw.x) : nil,
            y: raw.ySet != 0 ? Int(raw.y) : nil,
            width: raw.widthSet != 0 ? Int(raw.width) : nil,
            height: raw.heightSet != 0 ? Int(raw.height) : nil,
            isPopup: raw.isPopup != 0
        )
    }
}

/// Describes a page's request to open a link/popup/new window — the input to
/// ``CefBrowserDelegate/browser(_:decideWindowOpenFor:)``, modeled on
/// Electron's `setWindowOpenHandler` details.
public struct CefWindowOpenRequest: Sendable, Equatable {
    /// The URL the page wants to open (may be `nil` for `about:blank` popups).
    public var targetURL: URL?
    /// The target frame name (`window.open`'s second argument / `target=`).
    public var frameName: String
    /// How Chromium classified the open intent (from click + modifiers).
    public var disposition: CefWindowOpenDisposition
    /// Whether the open was triggered by a genuine user gesture (vs. script).
    public var userGesture: Bool
    /// Window features the page requested for a popup, if any.
    public var features: CefPopupFeatures
    /// Whether the source browser is offscreen-rendered (OSR). Native popups
    /// are unsafe for OSR browsers, so the delegate should prefer
    /// ``CefWindowOpenAction/openInCurrentBrowser`` or
    /// ``CefWindowOpenAction/handled`` here.
    public var isSourceOffscreen: Bool

    public init(
        targetURL: URL?,
        frameName: String = "",
        disposition: CefWindowOpenDisposition = .unknown,
        userGesture: Bool = false,
        features: CefPopupFeatures = .init(),
        isSourceOffscreen: Bool = false
    ) {
        self.targetURL = targetURL
        self.frameName = frameName
        self.disposition = disposition
        self.userGesture = userGesture
        self.features = features
        self.isSourceOffscreen = isSourceOffscreen
    }
}

/// What CefSwift should do with a ``CefWindowOpenRequest`` — the return of
/// ``CefBrowserDelegate/browser(_:decideWindowOpenFor:)``, modeled on the
/// allow/deny outcomes of Electron's `setWindowOpenHandler`.
public enum CefWindowOpenAction: Sendable, Equatable {
    /// Suppress the open entirely (Electron `{ action: 'deny' }`).
    case deny
    /// Load the target URL in the *same* browser (no new window/tab). The
    /// safe default for OSR browsers. If the request has no URL, this is a
    /// no-op (treated as ``deny``).
    case openInCurrentBrowser
    /// Let CEF create a native popup browser/window (Electron
    /// `{ action: 'allow' }`). **Only safe for windowed/chrome browsers** —
    /// for OSR browsers a native popup would be created with no render handler.
    /// CefSwift downgrades this to ``openInCurrentBrowser`` for OSR browsers.
    case allowNativePopup
    /// The app will open its own tab/window for this URL (e.g. a new
    /// `CefWebView`/`CefChromeWindow`). CEF's native popup is blocked.
    case handled
}

/// The policy CefSwift applies when no delegate is present, or when bridging
/// the legacy ``CefPopupDecision`` API. Pure logic, unit-tested.
public enum CefWindowOpenPolicy {
    /// The safe default action for a request when the delegate does not
    /// override ``CefBrowserDelegate/browser(_:decideWindowOpenFor:)``.
    ///
    /// - OSR browsers: never a native popup. Route to the current browser so
    ///   the target loads in-place (no orphaned, unhandled popup browser).
    /// - Windowed/chrome browsers: also default to the current browser, which
    ///   is safe everywhere; apps that want native popups or tabs opt in via
    ///   the delegate.
    public static func defaultAction(for request: CefWindowOpenRequest) -> CefWindowOpenAction {
        if request.targetURL != nil {
            return .openInCurrentBrowser
        }
        // No URL to load in place (about:blank popup). For windowed/chrome it's
        // safe to let CEF make the popup; for OSR we must not.
        return request.isSourceOffscreen ? .deny : .allowNativePopup
    }

    /// Resolves an action against the source browser's hosting mode, applying
    /// the OSR safety downgrade: a native popup requested for an OSR browser
    /// becomes ``CefWindowOpenAction/openInCurrentBrowser`` (or ``deny`` if
    /// there is no URL).
    public static func resolve(_ action: CefWindowOpenAction, for request: CefWindowOpenRequest) -> CefWindowOpenAction {
        guard action == .allowNativePopup, request.isSourceOffscreen else { return action }
        return request.targetURL != nil ? .openInCurrentBrowser : .deny
    }

    /// Bridges a legacy ``CefPopupDecision`` into a ``CefWindowOpenAction`` so
    /// the old `requestsPopupFor` delegate method keeps working.
    public static func action(for legacy: CefPopupDecision, request: CefWindowOpenRequest) -> CefWindowOpenAction {
        switch legacy {
        case .allow: return resolve(.allowNativePopup, for: request)
        case .block: return .deny
        case .openInSameBrowser: return .openInCurrentBrowser
        }
    }
}
