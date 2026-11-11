import CCef
import Foundation

/// Where Chromium intends new content to open, derived from the click and
/// its modifier keys (⌘-click gives ``newBackgroundTab``). Mirrors
/// `cef_window_open_disposition_t`.
public enum CefWindowOpenDisposition: Sendable, Equatable {
    /// No disposition was given.
    case unknown
    /// Replace the current page; most clicks.
    case currentTab
    /// Reuse a tab already showing the URL, or open one.
    case singletonTab
    /// Open a tab in front (⇧⌘-click or Shift-middle-click).
    case newForegroundTab
    /// Open a tab behind the current one (⌘-click or middle-click).
    case newBackgroundTab
    /// Open a popup window, such as `window.open` with window features.
    case newPopup
    /// Open a new window (Shift-click).
    case newWindow
    /// Download the link target (Option-click).
    case saveToDisk
    /// Open an incognito window.
    case offTheRecord
    /// Do nothing; the renderer reported an error.
    case ignoreAction
    /// Switch to a tab already showing the URL.
    case switchToTab
    /// Open a document picture-in-picture window.
    case newPictureInPicture
    /// Open in a split view beside the current tab.
    case newSplitView

    init(cefValue: cef_window_open_disposition_t) {
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

    var cefValue: cef_window_open_disposition_t {
        switch self {
        case .unknown: return CEF_WOD_UNKNOWN
        case .currentTab: return CEF_WOD_CURRENT_TAB
        case .singletonTab: return CEF_WOD_SINGLETON_TAB
        case .newForegroundTab: return CEF_WOD_NEW_FOREGROUND_TAB
        case .newBackgroundTab: return CEF_WOD_NEW_BACKGROUND_TAB
        case .newPopup: return CEF_WOD_NEW_POPUP
        case .newWindow: return CEF_WOD_NEW_WINDOW
        case .saveToDisk: return CEF_WOD_SAVE_TO_DISK
        case .offTheRecord: return CEF_WOD_OFF_THE_RECORD
        case .ignoreAction: return CEF_WOD_IGNORE_ACTION
        case .switchToTab: return CEF_WOD_SWITCH_TO_TAB
        case .newPictureInPicture: return CEF_WOD_NEW_PICTURE_IN_PICTURE
        case .newSplitView: return CEF_WOD_NEW_SPLIT_VIEW
        }
    }

    /// Whether the new content should come to the front. Only
    /// ``newBackgroundTab`` opens behind.
    public var prefersForeground: Bool {
        switch self {
        case .newBackgroundTab: return false
        default: return true
        }
    }
}

/// The window features a page requested for a popup, as in
/// `window.open(url, name, "width=400,height=300")`.
public struct CefPopupFeatures: Sendable, Equatable {
    /// The requested horizontal position on screen.
    public var x: Int?
    /// The requested vertical position on screen.
    public var y: Int?
    /// The requested content width.
    public var width: Int?
    /// The requested content height.
    public var height: Int?
    /// Whether the page asked for a popup without browser controls.
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

/// A page's request to open a link, popup or window, passed to
/// ``CefBrowserDelegate/browser(_:decideWindowOpenFor:)``.
public struct CefWindowOpenRequest: Sendable, Equatable {
    /// The URL to open; `nil` for a blank popup.
    public var targetURL: URL?
    /// The target name: `window.open`'s second argument or a link's `target`.
    public var frameName: String
    /// Where Chromium intends the content to open.
    public var disposition: CefWindowOpenDisposition
    /// Whether a user gesture, rather than script alone, caused the request.
    public var hasUserGesture: Bool
    /// The window features the page requested.
    public var features: CefPopupFeatures
    /// Whether the requesting browser renders offscreen. Offscreen browsers
    /// cannot host native popups; see
    /// ``CefWindowOpenAction/allowNativePopup``.
    public var isSourceOffscreen: Bool
    /// Whether the requesting browser uses Chrome style, where Chromium can
    /// open tabs and windows itself.
    public var isSourceChromeStyle: Bool

    public init(
        targetURL: URL?,
        frameName: String = "",
        disposition: CefWindowOpenDisposition = .unknown,
        hasUserGesture: Bool = false,
        features: CefPopupFeatures = .init(),
        isSourceOffscreen: Bool = false,
        isSourceChromeStyle: Bool = false
    ) {
        self.targetURL = targetURL
        self.frameName = frameName
        self.disposition = disposition
        self.hasUserGesture = hasUserGesture
        self.features = features
        self.isSourceOffscreen = isSourceOffscreen
        self.isSourceChromeStyle = isSourceChromeStyle
    }
}

/// What to do with a ``CefWindowOpenRequest``, returned from
/// ``CefBrowserDelegate/browser(_:decideWindowOpenFor:)``.
public enum CefWindowOpenAction: Sendable, Equatable {
    /// Ignore the request.
    case deny
    /// Load the URL in the requesting browser. Does nothing when the request
    /// has no URL.
    case openInCurrentBrowser
    /// Let Chromium open the popup, tab or window itself. For offscreen
    /// browsers, which cannot host a native popup, this acts as
    /// ``openInCurrentBrowser``, or ``deny`` when there is no URL.
    case allowNativePopup
    /// You opened the content yourself, for example in a new
    /// ``CefBrowserWindow``; Chromium does nothing more.
    case handled

    /// The action taken when the delegate does not implement
    /// ``CefBrowserDelegate/browser(_:decideWindowOpenFor:)``: Chrome-style
    /// browsers open tabs and windows natively; other browsers load the URL
    /// in place, and allow a blank popup only when not offscreen. Return it
    /// from your own implementation for requests you don't handle.
    public static func `default`(for request: CefWindowOpenRequest) -> CefWindowOpenAction {
        if request.isSourceChromeStyle {
            return .allowNativePopup
        }
        if request.targetURL != nil {
            return .openInCurrentBrowser
        }
        return request.isSourceOffscreen ? .deny : .allowNativePopup
    }
}

/// The window-open behavior CefSwift applies.
enum CefWindowOpenPolicy {
    /// The action actually taken for `action`: for offscreen browsers,
    /// ``CefWindowOpenAction/allowNativePopup`` becomes
    /// ``CefWindowOpenAction/openInCurrentBrowser``, or
    /// ``CefWindowOpenAction/deny`` when there is no URL.
    static func resolve(_ action: CefWindowOpenAction, for request: CefWindowOpenRequest) -> CefWindowOpenAction {
        guard action == .allowNativePopup, request.isSourceOffscreen else { return action }
        return request.targetURL != nil ? .openInCurrentBrowser : .deny
    }
}
