import CCef
import Foundation

/// The standard context-menu commands CEF can build into the default page menu
/// (a Swift mirror of the relevant `MENU_ID_*` values in `cef_types.h`).
///
/// CEF builds and *executes* these itself: leaving them in the menu and
/// returning `false` from
/// ``CefBrowserDelegate/browser(_:contextMenuCommand:params:)`` runs the
/// built-in behavior (navigate, clipboard, view-source, …). This enum lets
/// apps reason about which standard items are present, gate them, or perform
/// them explicitly.
public enum CefContextMenuCommand: Int, Sendable, CaseIterable {
    case back = 100
    case forward = 101
    case reload = 102
    case reloadNoCache = 103
    case stopLoad = 104

    case undo = 110
    case redo = 111
    case cut = 112
    case copy = 113
    case paste = 114
    case pasteMatchStyle = 115
    case delete = 116
    case selectAll = 117

    case find = 130
    case print = 131
    case viewSource = 132

    /// Maps a raw command id reported by CEF. Returns `nil` for command ids
    /// outside the standard range (custom/app commands, spellcheck, …).
    public init?(commandID: Int) {
        self.init(rawValue: commandID)
    }

    /// Whether this command is a navigation command (back/forward/reload/stop).
    public var isNavigation: Bool {
        switch self {
        case .back, .forward, .reload, .reloadNoCache, .stopLoad: return true
        default: return false
        }
    }

    /// Whether this command is an editing/clipboard command (only meaningful
    /// when the click target is editable, except `.copy` on a selection).
    public var isEditing: Bool {
        switch self {
        case .undo, .redo, .cut, .paste, .pasteMatchStyle, .delete: return true
        default: return false
        }
    }
}

/// CEF's reserved command-id ranges, exposed so apps can place custom items
/// safely and recognize built-in ranges.
public enum CefMenuCommandRange {
    /// `MENU_ID_USER_FIRST` — start of the app-defined command-id range.
    public static let userFirst = 26500
    /// `MENU_ID_USER_LAST` — end of the app-defined command-id range.
    public static let userLast = 28500

    /// Whether `commandID` falls in the app-defined (user) range.
    public static func isUserCommand(_ commandID: Int) -> Bool {
        (userFirst...userLast).contains(commandID)
    }

    /// Whether `commandID` is one of CEF's standard built-in commands.
    public static func isStandardCommand(_ commandID: Int) -> Bool {
        CefContextMenuCommand(commandID: commandID) != nil
    }
}
