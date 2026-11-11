import Foundation

/// A built-in context-menu command, with its `MENU_ID_*` value from
/// `cef_types.h`.
///
/// Chromium performs these itself unless
/// ``CefBrowserDelegate/browser(_:contextMenuCommand:params:)`` returns
/// `true`. Hide them with ``CefContextMenuConfiguration/hiddenCommands``.
public enum CefContextMenuCommand: Int, Sendable, Hashable, CaseIterable {
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

    /// The built-in command with `commandID`, or `nil` for any other ID.
    public init?(commandID: Int) {
        self.init(rawValue: commandID)
    }

    /// Whether this is back, forward, reload or stop.
    public var isNavigation: Bool {
        switch self {
        case .back, .forward, .reload, .reloadNoCache, .stopLoad: return true
        default: return false
        }
    }

    /// Whether this command edits content, and so applies only to editable
    /// targets. ``copy`` is not one: it works on any selection.
    public var isEditing: Bool {
        switch self {
        case .undo, .redo, .cut, .paste, .pasteMatchStyle, .delete: return true
        default: return false
        }
    }
}
