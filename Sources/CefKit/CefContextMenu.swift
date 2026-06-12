import AppKit
import CCef
import Foundation

/// The kind of media element a context menu was invoked on.
public enum CefContextMenuMediaType: Sendable, Equatable {
    case none, image, video, audio, canvas, file, plugin

    init(cefValue: cef_context_menu_media_type_t) {
        switch cefValue {
        case CM_MEDIATYPE_IMAGE: self = .image
        case CM_MEDIATYPE_VIDEO: self = .video
        case CM_MEDIATYPE_AUDIO: self = .audio
        case CM_MEDIATYPE_CANVAS: self = .canvas
        case CM_MEDIATYPE_FILE: self = .file
        case CM_MEDIATYPE_PLUGIN: self = .plugin
        default: self = .none
        }
    }
}

/// Information about the node a context menu was invoked on. Mirrors
/// `cef_context_menu_params_t` (Electron's `context-menu` params).
public struct CefContextMenuParams: Sendable, Equatable {
    /// X coordinate of the invocation, relative to the view origin.
    public var x: Int
    /// Y coordinate of the invocation, relative to the view origin.
    public var y: Int
    /// URL of the enclosing link, if any.
    public var linkURL: URL?
    /// Source URL of the media element (img/audio/video), if any.
    public var sourceURL: URL?
    /// URL of the top-level page.
    public var pageURL: URL?
    /// Selected text, if any.
    public var selectionText: String
    /// The media element type the menu was invoked on.
    public var mediaType: CefContextMenuMediaType
    /// Whether the node is editable (text field, contentEditable, …).
    public var isEditable: Bool

    public init(
        x: Int = 0,
        y: Int = 0,
        linkURL: URL? = nil,
        sourceURL: URL? = nil,
        pageURL: URL? = nil,
        selectionText: String = "",
        mediaType: CefContextMenuMediaType = .none,
        isEditable: Bool = false
    ) {
        self.x = x
        self.y = y
        self.linkURL = linkURL
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.selectionText = selectionText
        self.mediaType = mediaType
        self.isEditable = isEditable
    }
}

extension CefContextMenuParams {
    /// Reads a snapshot out of a borrowed `cef_context_menu_params_t`.
    init(raw params: UnsafeMutablePointer<cef_context_menu_params_t>) {
        func url(_ s: String) -> URL? { s.isEmpty ? nil : URL(string: s) }
        let linkURLString = CefStringUtil.takingUserFree(params.pointee.get_link_url?(params)) ?? ""
        let sourceURLString = CefStringUtil.takingUserFree(params.pointee.get_source_url?(params)) ?? ""
        let pageURLString = CefStringUtil.takingUserFree(params.pointee.get_page_url?(params)) ?? ""
        let selection = CefStringUtil.takingUserFree(params.pointee.get_selection_text?(params)) ?? ""
        self.init(
            x: Int(params.pointee.get_xcoord?(params) ?? 0),
            y: Int(params.pointee.get_ycoord?(params) ?? 0),
            linkURL: url(linkURLString),
            sourceURL: url(sourceURLString),
            pageURL: url(pageURLString),
            selectionText: selection,
            mediaType: CefContextMenuMediaType(cefValue: params.pointee.get_media_type?(params) ?? CM_MEDIATYPE_NONE),
            isEditable: (params.pointee.is_editable?(params) ?? 0) != 0
        )
    }
}

/// A mutable wrapper around CEF's `cef_menu_model_t` exposing the common
/// add/remove/clear/insert operations needed to customize the page context
/// menu. Valid only inside ``CefBrowserDelegate/browser(_:configureContextMenu:params:)``;
/// do not retain it.
///
/// User-defined command IDs must be between ``userCommandIDFirst`` and
/// ``userCommandIDLast``; selecting one fires
/// ``CefBrowserDelegate/browser(_:contextMenuCommand:params:)``.
public final class CefMenuModel {
    /// Lower bound for app-defined command IDs (`MENU_ID_USER_FIRST`).
    public static let userCommandIDFirst = 26500
    /// Upper bound for app-defined command IDs (`MENU_ID_USER_LAST`).
    public static let userCommandIDLast = 28500

    private let raw: UnsafeMutablePointer<cef_menu_model_t>

    init(raw: UnsafeMutablePointer<cef_menu_model_t>) {
        self.raw = raw
    }

    /// Number of items currently in the menu.
    public var count: Int {
        Int(raw.pointee.get_count?(raw) ?? 0)
    }

    /// Removes every item (show no menu, or build a fully custom one).
    public func clear() {
        _ = raw.pointee.clear?(raw)
    }

    /// Appends a command item. `commandID` should be within the user range.
    public func addItem(commandID: Int, title: String) {
        CefStringUtil.withCefString(title) { label in
            _ = raw.pointee.add_item?(raw, Int32(commandID), label)
        }
    }

    /// Appends a separator.
    public func addSeparator() {
        _ = raw.pointee.add_separator?(raw)
    }

    /// Inserts a command item at `index`.
    public func insertItem(at index: Int, commandID: Int, title: String) {
        CefStringUtil.withCefString(title) { label in
            _ = raw.pointee.insert_item_at?(raw, index, Int32(commandID), label)
        }
    }

    /// Inserts a separator at `index`.
    public func insertSeparator(at index: Int) {
        _ = raw.pointee.insert_separator_at?(raw, index)
    }

    /// Removes the item with the given command ID. Returns whether it existed.
    @discardableResult
    public func remove(commandID: Int) -> Bool {
        (raw.pointee.remove?(raw, Int32(commandID)) ?? 0) != 0
    }

    /// Removes the item at `index`. Returns whether it existed.
    @discardableResult
    public func removeItem(at index: Int) -> Bool {
        (raw.pointee.remove_at?(raw, index) ?? 0) != 0
    }
}
