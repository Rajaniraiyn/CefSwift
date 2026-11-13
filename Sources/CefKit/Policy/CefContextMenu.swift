import AppKit
import CCef
import Foundation
import CefBase

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

/// What a context menu was invoked on.
public struct CefContextMenuTarget: Sendable, Equatable {
    /// Where the click was, in view points with a top-left origin.
    public var location: CGPoint
    /// URL of the enclosing link, if any.
    public var linkURL: URL?
    /// Source URL of the media element (img/audio/video), if any.
    public var sourceURL: URL?
    /// URL of the top-level page.
    public var pageURL: URL?
    /// The selected text, or an empty string when nothing is selected.
    public var selectedText: String
    /// The media element type the menu was invoked on.
    public var mediaType: CefContextMenuMediaType
    /// Whether the node is editable, such as a text field.
    public var isEditable: Bool

    public init(
        location: CGPoint = .zero,
        linkURL: URL? = nil,
        sourceURL: URL? = nil,
        pageURL: URL? = nil,
        selectedText: String = "",
        mediaType: CefContextMenuMediaType = .none,
        isEditable: Bool = false
    ) {
        self.location = location
        self.linkURL = linkURL
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.selectedText = selectedText
        self.mediaType = mediaType
        self.isEditable = isEditable
    }
}

extension CefContextMenuTarget {
    /// Reads a borrowed `cef_context_menu_params_t`.
    init(raw params: UnsafeMutablePointer<cef_context_menu_params_t>) {
        func url(_ value: cef_string_userfree_t?) -> URL? {
            CefStringUtil.takingUserFree(value).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        }
        self.init(
            location: CGPoint(x: Int(params.pointee.get_xcoord(params)), y: Int(params.pointee.get_ycoord(params))),
            linkURL: url(params.pointee.get_link_url(params)),
            sourceURL: url(params.pointee.get_source_url(params)),
            pageURL: url(params.pointee.get_page_url(params)),
            selectedText: CefStringUtil.takingUserFree(params.pointee.get_selection_text(params)) ?? "",
            mediaType: CefContextMenuMediaType(cefValue: params.pointee.get_media_type(params)),
            isEditable: params.pointee.is_editable(params) != 0
        )
    }
}

/// A context menu about to be shown.
///
/// A menu model is valid only during the call that provides it, such as
/// ``CefBrowserDelegate/browser(_:configureContextMenu:for:)``: CefKit
/// invalidates it when the call returns, and using it afterwards stops
/// the program.
///
/// Give your own items command IDs from ``userCommandIDs``. Choosing one
/// calls ``CefBrowserDelegate/browser(_:handleContextMenuCommand:for:)``.
@MainActor
public final class CefMenuModel {
    /// The command IDs available to your items (`MENU_ID_USER_FIRST`
    /// through `MENU_ID_USER_LAST`).
    public nonisolated static let userCommandIDs = Int(MENU_ID_USER_FIRST.rawValue)...Int(MENU_ID_USER_LAST.rawValue)

    /// Chromium's model; `nil` once the callback has returned.
    private var borrowed: UnsafeMutablePointer<cef_menu_model_t>?

    init(raw: UnsafeMutablePointer<cef_menu_model_t>) {
        borrowed = raw
    }

    /// Runs `body` with a wrapper of the borrowed `raw`, which is
    /// invalidated when `body` returns.
    static func borrowing<R>(_ raw: UnsafeMutablePointer<cef_menu_model_t>, _ body: (CefMenuModel) -> R) -> R {
        let menu = CefMenuModel(raw: raw)
        defer { menu.invalidate() }
        return body(menu)
    }

    /// Ends the wrapper's use: the callback that provided it returned.
    func invalidate() { borrowed = nil }

    /// Whether the callback that provided it is still running.
    var isValid: Bool { borrowed != nil }

    private var raw: UnsafeMutablePointer<cef_menu_model_t> {
        guard let borrowed else {
            preconditionFailure("CefMenuModel used after the callback that provided it returned")
        }
        return borrowed
    }

    /// The number of items, separators included.
    public var count: Int {
        Int(raw.pointee.get_count(raw))
    }

    /// Removes every item. A menu left empty is not shown.
    public func clear() {
        _ = raw.pointee.clear(raw)
    }

    /// Appends an item.
    public func addItem(commandID: Int, title: String) {
        CefStringUtil.withCefString(title) { label in
            _ = raw.pointee.add_item(raw, Int32(commandID), label)
        }
    }

    /// Appends a separator.
    public func addSeparator() {
        _ = raw.pointee.add_separator(raw)
    }

    /// Inserts an item at `index`.
    public func insertItem(at index: Int, commandID: Int, title: String) {
        CefStringUtil.withCefString(title) { label in
            _ = raw.pointee.insert_item_at(raw, index, Int32(commandID), label)
        }
    }

    /// Inserts a separator at `index`.
    public func insertSeparator(at index: Int) {
        _ = raw.pointee.insert_separator_at(raw, index)
    }

    /// Removes the item with `commandID`. Returns whether it was found.
    @discardableResult
    public func removeItem(commandID: Int) -> Bool {
        raw.pointee.remove(raw, Int32(commandID)) != 0
    }

    /// Removes the item at `index`. Returns whether it was found.
    @discardableResult
    public func removeItem(at index: Int) -> Bool {
        raw.pointee.remove_at(raw, index) != 0
    }

    /// The title of the item at `index`. Chromium marks mnemonics with `&`
    /// and writes a literal ampersand as `&&`.
    public func title(at index: Int) -> String {
        CefStringUtil.takingUserFree(raw.pointee.get_label_at(raw, index)) ?? ""
    }

    /// The command ID of the item at `index`, or `-1` for a separator.
    public func commandID(at index: Int) -> Int {
        Int(raw.pointee.get_command_id_at(raw, index))
    }

    /// Whether the item at `index` is a separator.
    public func isSeparator(at index: Int) -> Bool {
        raw.pointee.get_type_at(raw, index) == MENUITEMTYPE_SEPARATOR
    }

    /// Removes leading, trailing and doubled separators, such as those left
    /// after removing items.
    public func trimSeparators() {
        var index = count - 1
        while index >= 0 {
            let isEdge = index == 0 || index == count - 1
            if isSeparator(at: index), isEdge || isSeparator(at: index - 1) {
                removeItem(at: index)
            }
            index -= 1
        }
    }
}

/// Reports the outcome of a context menu an offscreen host presented.
///
/// Call ``select(commandID:)`` or ``cancel()`` once; later calls do nothing.
/// A completion released without either cancels the menu.
@MainActor
public final class CefContextMenuCompletion {
    /// The reference CEF passed to `run_context_menu`, released exactly once:
    /// by ``select(commandID:)``, ``cancel()`` or `deinit`, whichever runs
    /// first.
    private nonisolated(unsafe) var raw: UnsafeMutablePointer<cef_run_context_menu_callback_t>?

    init(raw: UnsafeMutablePointer<cef_run_context_menu_callback_t>) {
        self.raw = raw
    }

    deinit {
        guard let raw else { return }
        raw.pointee.cancel(raw)
        cefRelease(raw)
    }

    /// Reports that the user chose the item with `commandID`.
    public func select(commandID: Int) {
        guard let raw else { return }
        raw.pointee.cont(raw, Int32(commandID), cef_event_flags_t(rawValue: 0))
        cefRelease(raw)
        self.raw = nil
    }

    /// Reports that the menu closed without a choice.
    public func cancel() {
        guard let raw else { return }
        raw.pointee.cancel(raw)
        cefRelease(raw)
        self.raw = nil
    }
}

// MARK: - Declarative configuration

/// An item you add to a browser's context menu.
@MainActor
public struct CefContextMenuItem {
    public var title: String
    /// Decides for each menu whether the item appears, for example only on
    /// links. `nil` always shows it.
    public var isVisible: ((CefContextMenuTarget) -> Bool)?
    /// Runs when the item is chosen.
    public var action: (CefBrowser, CefContextMenuTarget) -> Void

    public init(
        _ title: String,
        isVisible: ((CefContextMenuTarget) -> Bool)? = nil,
        action: @escaping (CefBrowser, CefContextMenuTarget) -> Void
    ) {
        self.title = title
        self.isVisible = isVisible
        self.action = action
    }
}

extension CefBrowser.Configuration {
    /// Shapes a browser's context menu without a delegate: hide Chromium's
    /// items, add your own, and optionally add Inspect Element.
    ///
    /// ```swift
    /// configuration.contextMenu.hiddenCommands = [.viewSource, .print]
    /// configuration.contextMenu.showsInspectElement = true
    /// configuration.contextMenu.items = [
    ///     CefContextMenuItem("Copy Link as Markdown", isVisible: { $0.linkURL != nil }) { browser, target in
    ///         copyMarkdownLink(target.linkURL!, title: browser.title)
    ///     },
    /// ]
    /// ```
    ///
    /// For menus that depend on more than the click target, implement
    /// ``CefBrowserDelegate/browser(_:configureContextMenu:for:)``, which
    /// runs after this configuration is applied.
    @MainActor
    public struct ContextMenu {
        /// `false` suppresses the context menu entirely.
        public var isEnabled = true
        /// Chromium items to remove.
        public var hiddenCommands: Set<CefContextMenuCommand> = []
        /// Adds "Inspect Element", opening DevTools on the clicked node.
        public var showsInspectElement = false
        /// Your items, added below Chromium's.
        public var items: [CefContextMenuItem] = []

        public init() {}

        /// Inspect Element takes the last user ID; ``items`` count up from the first.
        static let inspectCommandID = CefMenuModel.userCommandIDs.upperBound

        /// Applies the configuration to a menu about to be shown.
        func apply(to menu: CefMenuModel, for target: CefContextMenuTarget) {
            guard isEnabled else {
                menu.clear()
                return
            }
            for command in hiddenCommands {
                menu.removeItem(commandID: command.rawValue)
            }
            let visible = items.enumerated().filter { $0.element.isVisible?(target) ?? true }
            if !visible.isEmpty || showsInspectElement {
                menu.trimSeparators()
                if menu.count > 0 { menu.addSeparator() }
            }
            for (index, item) in visible {
                menu.addItem(commandID: CefMenuModel.userCommandIDs.lowerBound + index, title: item.title)
            }
            if showsInspectElement {
                if !visible.isEmpty { menu.addSeparator() }
                menu.addItem(commandID: Self.inspectCommandID, title: "Inspect Element")
            }
        }

        /// Runs the item for `commandID`. Returns whether the ID was one of ours.
        func perform(commandID: Int, in browser: CefBrowser, for target: CefContextMenuTarget) -> Bool {
            if showsInspectElement, commandID == Self.inspectCommandID {
                browser.showDevTools(inspecting: target.location)
                return true
            }
            let index = commandID - CefMenuModel.userCommandIDs.lowerBound
            guard items.indices.contains(index) else { return false }
            items[index].action(browser, target)
            return true
        }
    }
}
