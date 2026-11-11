import CCef
import Foundation

/// One of Chrome's own commands (`IDC_*`). Run it with
/// ``CefBrowser/execute(_:disposition:)``, intercept it in
/// ``CefBrowserDelegate/browser(_:handleChromeCommand:disposition:)``, or hide
/// it from Chrome's app menu with ``CefChromeUIConfiguration``.
///
/// The named constants cover the common commands; any other `IDC_*` value
/// from Chromium's `chrome/app/chrome_command_ids.h` works through
/// `init(rawValue:)`.
public struct CefChromeCommand: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let back = Self(rawValue: Int(IDC_BACK))
    public static let forward = Self(rawValue: Int(IDC_FORWARD))
    public static let reload = Self(rawValue: Int(IDC_RELOAD))
    public static let stop = Self(rawValue: Int(IDC_STOP))
    public static let home = Self(rawValue: Int(IDC_HOME))

    public static let newTab = Self(rawValue: Int(IDC_NEW_TAB))
    public static let closeTab = Self(rawValue: Int(IDC_CLOSE_TAB))
    public static let duplicateTab = Self(rawValue: Int(IDC_DUPLICATE_TAB))
    public static let restoreTab = Self(rawValue: Int(IDC_RESTORE_TAB))
    public static let selectNextTab = Self(rawValue: Int(IDC_SELECT_NEXT_TAB))
    public static let selectPreviousTab = Self(rawValue: Int(IDC_SELECT_PREVIOUS_TAB))
    public static let newWindow = Self(rawValue: Int(IDC_NEW_WINDOW))
    public static let newIncognitoWindow = Self(rawValue: Int(IDC_NEW_INCOGNITO_WINDOW))
    public static let closeWindow = Self(rawValue: Int(IDC_CLOSE_WINDOW))
    public static let toggleFullscreen = Self(rawValue: Int(IDC_FULLSCREEN))

    public static let find = Self(rawValue: Int(IDC_FIND))
    public static let print = Self(rawValue: Int(IDC_PRINT))
    public static let savePage = Self(rawValue: Int(IDC_SAVE_PAGE))
    public static let viewSource = Self(rawValue: Int(IDC_VIEW_SOURCE))
    public static let openFile = Self(rawValue: Int(IDC_OPEN_FILE))
    public static let focusLocation = Self(rawValue: Int(IDC_FOCUS_LOCATION))
    public static let bookmarkThisTab = Self(rawValue: Int(IDC_BOOKMARK_THIS_TAB))
    public static let toggleBookmarkBar = Self(rawValue: Int(IDC_SHOW_BOOKMARK_BAR))

    public static let copyURL = Self(rawValue: Int(IDC_COPY_URL))
    public static let createQRCode = Self(rawValue: Int(IDC_QRCODE_GENERATOR))
    public static let showSharingHub = Self(rawValue: Int(IDC_SHARING_HUB))
    public static let sendTabToSelf = Self(rawValue: Int(IDC_SEND_TAB_TO_SELF))
    public static let castMedia = Self(rawValue: Int(IDC_ROUTE_MEDIA))
    public static let showReadingMode = Self(rawValue: Int(IDC_SHOW_READING_MODE_SIDE_PANEL))
    public static let showPasswordManager = Self(rawValue: Int(IDC_SHOW_PASSWORD_MANAGER))
    public static let showPerformance = Self(rawValue: Int(IDC_PERFORMANCE))
    public static let installWebApp = Self(rawValue: Int(IDC_INSTALL_PWA))
    public static let pinTab = Self(rawValue: Int(IDC_WINDOW_PIN_TAB))

    public static let zoomIn = Self(rawValue: Int(IDC_ZOOM_PLUS))
    public static let zoomOut = Self(rawValue: Int(IDC_ZOOM_MINUS))
    public static let zoomReset = Self(rawValue: Int(IDC_ZOOM_NORMAL))

    public static let showHistory = Self(rawValue: Int(IDC_SHOW_HISTORY))
    public static let showDownloads = Self(rawValue: Int(IDC_SHOW_DOWNLOADS))
    public static let showSettings = Self(rawValue: Int(IDC_OPTIONS))
    public static let manageExtensions = Self(rawValue: Int(IDC_MANAGE_EXTENSIONS))
    public static let clearBrowsingData = Self(rawValue: Int(IDC_CLEAR_BROWSING_DATA))
    public static let taskManager = Self(rawValue: Int(IDC_TASK_MANAGER))
    public static let devTools = Self(rawValue: Int(IDC_DEV_TOOLS))
}

/// Trims Chrome's own UI in Chrome-style windows. Set on
/// ``CefConfiguration/chromeUI`` before initializing.
public struct CefChromeUIConfiguration: Sendable, Equatable {
    /// Commands removed from Chrome's app ("⋮") menu.
    public var hiddenAppMenuCommands: Set<CefChromeCommand> = []
    /// Commands shown but greyed out in Chrome's app menu.
    public var disabledAppMenuCommands: Set<CefChromeCommand> = []
    /// Whether Chrome's toolbar shows its optional buttons (extensions,
    /// downloads, side panel, cast, …).
    public var showsToolbarButtons = true
    /// Whether the omnibox shows page-action icons (bookmark star, zoom,
    /// translate, reader mode, …).
    public var showsPageActionIcons = true

    public init() {}
}

/// Identifies one of Chromium's built-in UI strings (`IDS_*`), for
/// ``CefConfiguration/stringOverrides``.
///
/// Identifiers are stable for a given CEF build but can change between CEF
/// versions; the named constants here are re-resolved against the vendored
/// headers on every build. Other identifiers are listed in the vendored
/// `cef_pack_strings.h`.
public struct CefStringID: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    /// The product name ("Chromium") as shown throughout settings, About,
    /// dialogs and internal pages.
    public static let productName = Self(rawValue: IDS_PRODUCT_NAME)
    /// The short product name, used where space is tight.
    public static let shortProductName = Self(rawValue: IDS_SHORT_PRODUCT_NAME)
    /// The company line on `chrome://version`.
    public static let companyName = Self(rawValue: IDS_ABOUT_VERSION_COMPANY_NAME)
}
