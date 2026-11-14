import CCef
import CefBase
import CoreGraphics
import Foundation

/// What a context menu was opened on: the point, and the link, media,
/// selection or field under it.
public struct CefContextMenuTarget: Sendable, Equatable {
    /// Where the click was, in view points with a top-left origin.
    public var location: CGPoint
    /// URL of the enclosing link, if any.
    public var linkURL: URL?
    /// Source URL of the media element (img/audio/video), if any.
    public var sourceURL: URL?
    /// URL of the top-level page.
    public var pageURL: URL?
    /// URL of the frame the click was in, when that is a subframe's.
    public var frameURL: URL?
    /// The element's title or alt text, such as an image's.
    public var titleText: String
    /// The selected text, or an empty string when nothing is selected.
    public var selectedText: String
    /// The media element type the menu was invoked on.
    public var mediaType: CefContextMenuTarget.MediaType
    /// The state of the media element.
    public var mediaState: CefContextMenuTarget.MediaState
    /// Whether the node is editable, such as a text field.
    public var isEditable: Bool
    /// What the editable node, or the selection, allows.
    public var editing: CefContextMenuTarget.Editing
    /// The misspelled word under the pointer, or an empty string.
    public var misspelledWord: String
    /// Chromium's corrections for ``misspelledWord``.
    public var spellingSuggestions: [String]

    public init(
        location: CGPoint = .zero,
        linkURL: URL? = nil,
        sourceURL: URL? = nil,
        pageURL: URL? = nil,
        frameURL: URL? = nil,
        titleText: String = "",
        selectedText: String = "",
        mediaType: CefContextMenuTarget.MediaType = .none,
        mediaState: CefContextMenuTarget.MediaState = [],
        isEditable: Bool = false,
        editing: CefContextMenuTarget.Editing = [],
        misspelledWord: String = "",
        spellingSuggestions: [String] = []
    ) {
        self.location = location
        self.linkURL = linkURL
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.frameURL = frameURL
        self.titleText = titleText
        self.selectedText = selectedText
        self.mediaType = mediaType
        self.mediaState = mediaState
        self.isEditable = isEditable
        self.editing = editing
        self.misspelledWord = misspelledWord
        self.spellingSuggestions = spellingSuggestions
    }
}

extension CefContextMenuTarget {
    /// The kind of media element a context menu was invoked on.
    public enum MediaType: Sendable, Equatable {
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

    /// The state of the audio, video or plugin element under the pointer
    /// (`cef_context_menu_media_state_flags_t`).
    public struct MediaState: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        private init(_ flag: cef_context_menu_media_state_flags_t) { rawValue = flag.rawValue }

        public static let isInError = Self(CM_MEDIAFLAG_IN_ERROR)
        public static let isPaused = Self(CM_MEDIAFLAG_PAUSED)
        public static let isMuted = Self(CM_MEDIAFLAG_MUTED)
        public static let loops = Self(CM_MEDIAFLAG_LOOP)
        public static let canSave = Self(CM_MEDIAFLAG_CAN_SAVE)
        public static let hasAudio = Self(CM_MEDIAFLAG_HAS_AUDIO)
        public static let canToggleControls = Self(CM_MEDIAFLAG_CAN_TOGGLE_CONTROLS)
        public static let showsControls = Self(CM_MEDIAFLAG_CONTROLS)
        public static let canPrint = Self(CM_MEDIAFLAG_CAN_PRINT)
        public static let canRotate = Self(CM_MEDIAFLAG_CAN_ROTATE)
        public static let canPictureInPicture = Self(CM_MEDIAFLAG_CAN_PICTURE_IN_PICTURE)
        public static let isInPictureInPicture = Self(CM_MEDIAFLAG_PICTURE_IN_PICTURE)
        public static let canLoop = Self(CM_MEDIAFLAG_CAN_LOOP)
    }

    /// What the editable node or selection allows
    /// (`cef_context_menu_edit_state_flags_t`).
    public struct Editing: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        private init(_ flag: cef_context_menu_edit_state_flags_t) { rawValue = flag.rawValue }

        public static let canUndo = Self(CM_EDITFLAG_CAN_UNDO)
        public static let canRedo = Self(CM_EDITFLAG_CAN_REDO)
        public static let canCut = Self(CM_EDITFLAG_CAN_CUT)
        public static let canCopy = Self(CM_EDITFLAG_CAN_COPY)
        public static let canPaste = Self(CM_EDITFLAG_CAN_PASTE)
        public static let canDelete = Self(CM_EDITFLAG_CAN_DELETE)
        public static let canSelectAll = Self(CM_EDITFLAG_CAN_SELECT_ALL)
        public static let canTranslate = Self(CM_EDITFLAG_CAN_TRANSLATE)
        public static let canEditRichly = Self(CM_EDITFLAG_CAN_EDIT_RICHLY)
    }
}

extension CefContextMenuTarget {
    /// Reads a borrowed `cef_context_menu_params_t`.
    init(raw params: UnsafeMutablePointer<cef_context_menu_params_t>) {
        func url(_ value: cef_string_userfree_t?) -> URL? {
            CefStringUtil.takingUserFree(value).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        }
        func text(_ value: cef_string_userfree_t?) -> String {
            CefStringUtil.takingUserFree(value) ?? ""
        }
        var suggestions: [String] = []
        if let list = cef_string_list_alloc() {
            if params.pointee.get_dictionary_suggestions(params, list) != 0 {
                suggestions = cefStrings(from: list)
            }
            cef_string_list_free(list)
        }
        let pageURL = url(params.pointee.get_page_url(params))
        let frameURL = url(params.pointee.get_frame_url(params))
        self.init(
            location: CGPoint(x: Int(params.pointee.get_xcoord(params)), y: Int(params.pointee.get_ycoord(params))),
            linkURL: url(params.pointee.get_link_url(params)),
            sourceURL: url(params.pointee.get_source_url(params)),
            pageURL: pageURL,
            frameURL: frameURL == pageURL ? nil : frameURL,
            titleText: text(params.pointee.get_title_text(params)),
            selectedText: text(params.pointee.get_selection_text(params)),
            mediaType: CefContextMenuTarget.MediaType(cefValue: params.pointee.get_media_type(params)),
            mediaState: MediaState(rawValue: params.pointee.get_media_state_flags(params).rawValue),
            isEditable: params.pointee.is_editable(params) != 0,
            editing: Editing(rawValue: params.pointee.get_edit_state_flags(params).rawValue),
            misspelledWord: text(params.pointee.get_misspelled_word(params)),
            spellingSuggestions: suggestions
        )
    }
}
