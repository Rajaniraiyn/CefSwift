import Foundation

/// A built-in context-menu command, with its `MENU_ID_*` value from
/// `cef_types.h` as its raw value.
///
/// Chromium performs these itself unless
/// ``CefBrowserDelegate/browser(_:handleContextMenuCommand:for:)`` returns
/// `true`. Hide them with ``CefBrowser/Configuration/ContextMenu/hiddenCommands``.
public enum CefContextMenuCommand: Int, Sendable, Hashable, CaseIterable {
    case back = 100
    case forward = 101
    case reload = 102
    case reloadIgnoringCache = 103
    case stopLoading = 104

    case undo = 110
    case redo = 111
    case cut = 112
    case copy = 113
    case paste = 114
    case pasteAndMatchStyle = 115
    case delete = 116
    case selectAll = 117

    case find = 130
    case print = 131
    case viewSource = 132

    /// Whether this is back, forward, reload or stop.
    public var isNavigation: Bool {
        switch self {
        case .back, .forward, .reload, .reloadIgnoringCache, .stopLoading: return true
        default: return false
        }
    }

    /// Whether this command edits content, and so applies only to editable
    /// targets. ``copy`` is not one: it works on any selection.
    public var isEditing: Bool {
        switch self {
        case .undo, .redo, .cut, .paste, .pasteAndMatchStyle, .delete: return true
        default: return false
        }
    }
}
