import AppKit
import CCef
import CefBase
import UniformTypeIdentifiers

/// A file chooser a page asked for: an `<input type="file">`, or
/// `showOpenFilePicker()` and its relatives.
///
/// ``CefBrowserDelegate/browser(_:runFileDialog:)`` answers it; by default
/// ``CefFileDialogPresenter`` shows an `NSOpenPanel` or `NSSavePanel`.
public struct CefFileDialog: Sendable, Equatable {
    /// What the page asks the user to choose.
    public enum Mode: Sendable, Equatable {
        /// One existing file.
        case open
        /// One or more existing files (`<input type="file" multiple>`).
        case openMultiple
        /// A folder (`<input type="file" webkitdirectory>`,
        /// `showDirectoryPicker()`).
        case openFolder
        /// A file to write, which may not exist yet (`showSaveFilePicker()`).
        case save
    }

    /// A kind of file the page accepts.
    public struct AcceptedType: Sendable, Equatable {
        /// As the page wrote it: a lower-case MIME type such as `image/*`,
        /// or an extension such as `.png`.
        public var filter: String
        /// The extensions the filter stands for, without dots, when
        /// Chromium knows them: `["png", "jpg", …]` for `image/*`.
        public var extensions: [String]
        /// A description for the filter, such as "Image Files"; empty when
        /// Chromium has none.
        public var description: String

        public init(filter: String, extensions: [String] = [], description: String = "") {
            self.filter = filter
            self.extensions = extensions
            self.description = description
        }

        /// The uniform types the filter stands for; empty when none is
        /// known.
        public var contentTypes: [UTType] {
            var extensions = extensions
            if filter.hasPrefix(".") { extensions.append(String(filter.dropFirst())) }
            var types = extensions.compactMap { UTType(filenameExtension: $0) }
            if types.isEmpty, filter.contains("/") {
                if filter.hasSuffix("/*") {
                    switch filter.dropLast(2) {
                    case "image": types = [.image]
                    case "audio": types = [.audio]
                    case "video": types = [.movie]
                    case "text": types = [.text]
                    default: break
                    }
                } else if let type = UTType(mimeType: filter) {
                    types = [type]
                }
            }
            // A dynamic type stands for nothing the system knows.
            var seen = Set<UTType>()
            return types.filter { !$0.isDynamic && seen.insert($0).inserted }
        }
    }

    public var mode: Mode
    /// The title the page asked for; empty for the default ("Open" or
    /// "Save").
    public var title: String
    /// The file or folder to start in, and for ``Mode/save`` the suggested
    /// name; `nil` when the page suggests none.
    public var defaultURL: URL?
    /// The kinds of file the page accepts; empty for any file.
    public var acceptedTypes: [AcceptedType]

    public init(mode: Mode, title: String = "", defaultURL: URL? = nil, acceptedTypes: [AcceptedType] = []) {
        self.mode = mode
        self.title = title
        self.defaultURL = defaultURL
        self.acceptedTypes = acceptedTypes
    }
}

extension CefFileDialog.Mode {
    init(cefValue: cef_file_dialog_mode_t) {
        switch cefValue {
        case FILE_DIALOG_OPEN_MULTIPLE: self = .openMultiple
        case FILE_DIALOG_OPEN_FOLDER: self = .openFolder
        case FILE_DIALOG_SAVE: self = .save
        default: self = .open
        }
    }
}

extension CefFileDialog {
    /// Reads `on_file_dialog`'s arguments. The three lists are parallel;
    /// extensions arrive semicolon-separated with dots.
    init(
        mode: cef_file_dialog_mode_t, title: UnsafePointer<cef_string_t>?, defaultFilePath: UnsafePointer<cef_string_t>?,
        filters: cef_string_list_t?, extensions: cef_string_list_t?, descriptions: cef_string_list_t?
    ) {
        let filters = cefStrings(from: filters)
        let extensions = cefStrings(from: extensions)
        let descriptions = cefStrings(from: descriptions)
        let path = CefStringUtil.string(from: defaultFilePath)
        self.init(
            mode: Mode(cefValue: mode),
            title: CefStringUtil.string(from: title),
            defaultURL: path.isEmpty ? nil : URL(fileURLWithPath: path),
            acceptedTypes: filters.indices.map { index in
                AcceptedType(
                    filter: filters[index],
                    extensions: index < extensions.count
                        ? extensions[index].split(separator: ";").map { $0.hasPrefix(".") ? String($0.dropFirst()) : String($0) }
                        : [],
                    description: index < descriptions.count ? descriptions[index] : "")
            })
    }

    /// The uniform types of every accepted type; empty for any file.
    var contentTypes: [UTType] {
        var seen = Set<UTType>()
        return acceptedTypes.flatMap(\.contentTypes).filter { seen.insert($0).inserted }
    }
}

/// The native panels behind ``CefBrowserDelegate/browser(_:runFileDialog:)``:
/// `NSOpenPanel` for opening files and folders, `NSSavePanel` for saving.
/// Call it from your own delegate to keep the stock panel for some pages.
@MainActor
public enum CefFileDialogPresenter {
    /// Shows the panel `dialog` asks for, as a sheet on `window` when it is
    /// visible, and returns the chosen files, or `nil` when the user
    /// cancels. Cancelling the calling task closes the panel as Cancel.
    public static func present(_ dialog: CefFileDialog, in window: NSWindow?) async -> [URL]? {
        guard !Task.isCancelled else { return nil }
        let panel = makePanel(for: dialog)
        let response = await withTaskCancellationHandler {
            if let window, window.isVisible {
                return await panel.beginSheetModal(for: window)
            }
            return panel.runModal()
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
        guard response == .OK else { return nil }
        if let open = panel as? NSOpenPanel { return open.urls }
        return panel.url.map { [$0] }
    }

    /// The configured panel for `dialog`.
    public static func makePanel(for dialog: CefFileDialog) -> NSSavePanel {
        let panel: NSSavePanel
        if dialog.mode == .save {
            panel = NSSavePanel()
            if let url = dialog.defaultURL {
                if url.hasDirectoryPath {
                    panel.directoryURL = url
                } else {
                    panel.directoryURL = url.deletingLastPathComponent()
                    panel.nameFieldStringValue = url.lastPathComponent
                }
            }
        } else {
            let open = NSOpenPanel()
            open.canChooseFiles = dialog.mode != .openFolder
            open.canChooseDirectories = dialog.mode == .openFolder
            open.allowsMultipleSelection = dialog.mode == .openMultiple
            open.directoryURL = dialog.defaultURL
            panel = open
        }
        if !dialog.title.isEmpty { panel.title = dialog.title; panel.message = dialog.title }
        let types = dialog.contentTypes
        if !types.isEmpty, dialog.mode != .openFolder { panel.allowedContentTypes = types }
        return panel
    }
}

// MARK: - Dialog handler

extension CefBrowserClient {
    func makeDialogHandler() -> UnsafeMutablePointer<cef_dialog_handler_t> {
        let h = cefAllocate(cef_dialog_handler_t.self, owner: self)
        h.pointee.on_file_dialog = { s, browser, mode, title, defaultPath, filters, extensions, descriptions, callback in
            let dialog = CefFileDialog(
                mode: mode, title: title, defaultFilePath: defaultPath,
                filters: filters, extensions: extensions, descriptions: descriptions)
            guard let callback = CefRef(adopting: callback) else {
                cefRelease(browser)
                return 0
            }
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.decide(.page) { await $0.browser(b, runFileDialog: dialog) } then: { urls in
                    guard let urls, !urls.isEmpty, let list = cef_string_list_alloc() else {
                        callback.pointer.pointee.cancel(callback.pointer)
                        return
                    }
                    defer { cef_string_list_free(list) }
                    for url in urls {
                        CefStringUtil.withCefString(url.path) { cef_string_list_append(list, $0) }
                    }
                    callback.pointer.pointee.cont(callback.pointer, list)
                }
                return 1
            }
        }
        return h
    }
}
