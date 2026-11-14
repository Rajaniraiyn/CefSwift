import CCef
import Foundation

/// One of Chromium's context-menu commands: what an item of the menu
/// Chromium builds does.
///
/// The raw value is Chrome's command ID (`IDC_*`, from Chromium's
/// `chrome_command_ids.h`). Alloy-style browsers (views) number the
/// items CEF builds with CEF's `MENU_ID_*` values, and Chrome-style ones
/// (``CefWindow``) number macOS's Speech and Writing Direction items with
/// values that overlap those; CefKit reads either as the constant here,
/// so ``copy`` or ``back`` is the same in every browser. The named
/// constants cover the commands Chromium puts in context menus today.
/// Any other value, such as one a later Chromium adds, is kept as it is
/// (`init(rawValue:)`), so an item of that kind still shows and still
/// runs.
public struct CefContextMenuCommand: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    private init(_ value: Int32) { rawValue = Int(value) }

    // MARK: Page

    public static let back = Self(IDC_BACK)
    public static let forward = Self(IDC_FORWARD)
    public static let reload = Self(IDC_RELOAD)
    public static let reloadIgnoringCache = Self(IDC_RELOAD_BYPASSING_CACHE)
    public static let stopLoading = Self(IDC_STOP)
    public static let find = Self(IDC_FIND)
    public static let print = Self(IDC_PRINT)
    public static let viewSource = Self(IDC_VIEW_SOURCE)
    /// Save As…: the page.
    public static let savePage = Self(IDC_SAVE_PAGE)
    /// Cast…
    public static let cast = Self(IDC_ROUTE_MEDIA)
    /// Create QR Code for This Page.
    public static let createQRCode = Self(IDC_CONTENT_CONTEXT_GENERATE_QR_CODE)
    /// Translate to…
    public static let translate = Self(IDC_CONTENT_CONTEXT_TRANSLATE)
    public static let openInReadingMode = Self(IDC_CONTENT_CONTEXT_OPEN_IN_READING_MODE)
    public static let exitFullscreen = Self(IDC_CONTENT_CONTEXT_EXIT_FULLSCREEN)
    /// Inspect: DevTools on the element under the pointer.
    public static let inspectElement = Self(IDC_CONTENT_CONTEXT_INSPECTELEMENT)
    /// Send to your devices, as one item or a submenu of them.
    public static let sendTabToSelf = Self(IDC_SEND_TAB_TO_SELF)
    /// The Share submenu (`IDC_CONTENT_CONTEXT_SHARING_SUBMENU`).
    public static let shareMenu = Self(IDC_CONTENT_CONTEXT_SHARING_SUBMENU)

    // MARK: Frame

    public static let reloadFrame = Self(IDC_CONTENT_CONTEXT_RELOADFRAME)
    public static let viewFrameSource = Self(IDC_CONTENT_CONTEXT_VIEWFRAMESOURCE)

    // MARK: Link

    public static let openLinkInNewTab = Self(IDC_CONTENT_CONTEXT_OPENLINKNEWTAB)
    public static let openLinkInNewWindow = Self(IDC_CONTENT_CONTEXT_OPENLINKNEWWINDOW)
    /// Open Link in Incognito Window.
    public static let openLinkInIncognitoWindow = Self(IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD)
    /// Open Link as another of the user's profiles.
    public static let openLinkInProfile = Self(IDC_CONTENT_CONTEXT_OPENLINKINPROFILE)
    public static let openLinkInSplitView = Self(IDC_CONTENT_CONTEXT_OPENLINKSPLITVIEW)
    public static let openLinkWith = Self(IDC_CONTENT_CONTEXT_OPENLINKWITH)
    public static let addLinkToReadingList = Self(IDC_CONTENT_CONTEXT_ADD_LINK_TO_READING_LIST)
    public static let saveLinkAs = Self(IDC_CONTENT_CONTEXT_SAVELINKAS)
    public static let copyLinkAddress = Self(IDC_CONTENT_CONTEXT_COPYLINKLOCATION)
    public static let copyLinkText = Self(IDC_CONTENT_CONTEXT_COPYLINKTEXT)
    /// Copy Link to Highlight: a link that scrolls to the selected text.
    public static let copyLinkToHighlight = Self(IDC_CONTENT_CONTEXT_COPYLINKTOTEXT)
    public static let reshareLinkToHighlight = Self(IDC_CONTENT_CONTEXT_RESHARELINKTOTEXT)
    public static let removeHighlight = Self(IDC_CONTENT_CONTEXT_REMOVELINKTOTEXT)

    // MARK: Image, audio and video

    public static let openImageInNewTab = Self(IDC_CONTENT_CONTEXT_OPENIMAGENEWTAB)
    public static let openOriginalImageInNewTab = Self(IDC_CONTENT_CONTEXT_OPEN_ORIGINAL_IMAGE_NEW_TAB)
    public static let loadImage = Self(IDC_CONTENT_CONTEXT_LOAD_IMAGE)
    public static let saveImageAs = Self(IDC_CONTENT_CONTEXT_SAVEIMAGEAS)
    public static let copyImage = Self(IDC_CONTENT_CONTEXT_COPYIMAGE)
    public static let copyImageAddress = Self(IDC_CONTENT_CONTEXT_COPYIMAGELOCATION)
    /// Search for the image with the profile's search engine.
    public static let searchWebForImage = Self(IDC_CONTENT_CONTEXT_SEARCHWEBFORIMAGE)
    public static let searchLensForImage = Self(IDC_CONTENT_CONTEXT_SEARCHLENSFORIMAGE)
    /// Save Video As… or Save Audio As…
    public static let saveMediaAs = Self(IDC_CONTENT_CONTEXT_SAVEAVAS)
    /// Copy Video Address or Copy Audio Address.
    public static let copyMediaAddress = Self(IDC_CONTENT_CONTEXT_COPYAVLOCATION)
    /// Open Video in New Tab or Open Audio in New Tab.
    public static let openMediaInNewTab = Self(IDC_CONTENT_CONTEXT_OPENAVNEWTAB)
    public static let copyVideoFrame = Self(IDC_CONTENT_CONTEXT_COPYVIDEOFRAME)
    public static let saveVideoFrameAs = Self(IDC_CONTENT_CONTEXT_SAVEVIDEOFRAMEAS)
    public static let searchLensForVideoFrame = Self(IDC_CONTENT_CONTEXT_SEARCHLENSFORVIDEOFRAME)
    public static let searchWebForVideoFrame = Self(IDC_CONTENT_CONTEXT_SEARCHWEBFORVIDEOFRAME)
    public static let pictureInPicture = Self(IDC_CONTENT_CONTEXT_PICTUREINPICTURE)
    /// Loop: a checked item.
    public static let loop = Self(IDC_CONTENT_CONTEXT_LOOP)
    /// Show Controls: a checked item.
    public static let showControls = Self(IDC_CONTENT_CONTEXT_CONTROLS)
    public static let rotateClockwise = Self(IDC_CONTENT_CONTEXT_ROTATECW)
    public static let rotateCounterclockwise = Self(IDC_CONTENT_CONTEXT_ROTATECCW)
    /// Save As… for a plugin's content, such as a PDF.
    public static let savePluginAs = Self(IDC_CONTENT_CONTEXT_SAVEPLUGINAS)

    // MARK: Selection

    /// Search the profile's search engine for "…".
    public static let searchWebFor = Self(IDC_CONTENT_CONTEXT_SEARCHWEBFOR)
    public static let searchWebForInNewTab = Self(IDC_CONTENT_CONTEXT_SEARCHWEBFORNEWTAB)
    /// Go to the selected address.
    public static let goToURL = Self(IDC_CONTENT_CONTEXT_GOTOURL)
    /// Look Up "…", in the system dictionary.
    public static let lookUp = Self(IDC_CONTENT_CONTEXT_LOOK_UP)
    public static let lensRegionSearch = Self(IDC_CONTENT_CONTEXT_LENS_REGION_SEARCH)
    public static let webRegionSearch = Self(IDC_CONTENT_CONTEXT_WEB_REGION_SEARCH)
    public static let partialTranslate = Self(IDC_CONTENT_CONTEXT_PARTIAL_TRANSLATE)

    // MARK: Editing

    public static let undo = Self(IDC_CONTENT_CONTEXT_UNDO)
    public static let redo = Self(IDC_CONTENT_CONTEXT_REDO)
    public static let cut = Self(IDC_CONTENT_CONTEXT_CUT)
    public static let copy = Self(IDC_CONTENT_CONTEXT_COPY)
    public static let paste = Self(IDC_CONTENT_CONTEXT_PASTE)
    public static let pasteAndMatchStyle = Self(IDC_CONTENT_CONTEXT_PASTE_AND_MATCH_STYLE)
    public static let delete = Self(IDC_CONTENT_CONTEXT_DELETE)
    public static let selectAll = Self(IDC_CONTENT_CONTEXT_SELECTALL)
    /// Emoji & Symbols: the system character viewer.
    public static let emojiAndSymbols = Self(IDC_CONTENT_CONTEXT_EMOJI)
    public static let generatePassword = Self(IDC_CONTENT_CONTEXT_GENERATEPASSWORD)
    public static let showAllSavedPasswords = Self(IDC_CONTENT_CONTEXT_SHOWALLSAVEDPASSWORDS)
    /// The Passwords and Autofill submenu of a form field.
    public static let passwordsAndAutofillMenu = Self(IDC_PASSWORDS_AND_AUTOFILL_MENU)
    /// The Writing Direction submenu and its items.
    public static let writingDirectionMenu = Self(IDC_WRITING_DIRECTION_MENU)
    public static let writingDirectionDefault = Self(IDC_WRITING_DIRECTION_DEFAULT)
    public static let writingDirectionLeftToRight = Self(IDC_WRITING_DIRECTION_LTR)
    public static let writingDirectionRightToLeft = Self(IDC_WRITING_DIRECTION_RTL)

    /// The Speech submenu, and its items.
    public static let speechMenu = Self(rawValue: 100)
    public static let startSpeaking = Self(rawValue: 101)
    public static let stopSpeaking = Self(rawValue: 102)

    // MARK: Spelling

    /// The `index`th spelling suggestion, from 0.
    public static func spellingSuggestion(_ index: Int) -> Self {
        Self(rawValue: Int(IDC_SPELLCHECK_SUGGESTION_0) + index)
    }
    /// The suggestion of Chrome's spelling service, when it has one.
    public static let spellingServiceSuggestion = Self(IDC_CONTENT_CONTEXT_SPELLING_SUGGESTION)
    public static let noSpellingSuggestions = Self(IDC_CONTENT_CONTEXT_NO_SPELLING_SUGGESTIONS)
    public static let addToDictionary = Self(IDC_SPELLCHECK_ADD_TO_DICTIONARY)
    public static let removeFromDictionary = Self(IDC_SPELLCHECK_REMOVE_FROM_DICTIONARY)
    /// The Spelling and Grammar submenu (`IDC_SPELLCHECK_MENU`).
    public static let spellingMenu = Self(IDC_SPELLCHECK_MENU)
    public static let checkSpellingWhileTyping = Self(IDC_CHECK_SPELLING_WHILE_TYPING)
    public static let languageSettings = Self(IDC_CONTENT_CONTEXT_LANGUAGE_SETTINGS)

    // MARK: Equivalents

    /// CEF's `MENU_ID_*` values, which number the items of Alloy-style
    /// menus, mapped to Chrome's.
    private static let alloyEquivalents: [Int: Self] = {
        var map: [Int: Self] = [
            Int(MENU_ID_BACK.rawValue): .back, Int(MENU_ID_FORWARD.rawValue): .forward,
            Int(MENU_ID_RELOAD.rawValue): .reload, Int(MENU_ID_RELOAD_NOCACHE.rawValue): .reloadIgnoringCache,
            Int(MENU_ID_STOPLOAD.rawValue): .stopLoading,
            Int(MENU_ID_UNDO.rawValue): .undo, Int(MENU_ID_REDO.rawValue): .redo, Int(MENU_ID_CUT.rawValue): .cut,
            Int(MENU_ID_COPY.rawValue): .copy, Int(MENU_ID_PASTE.rawValue): .paste,
            Int(MENU_ID_PASTE_MATCH_STYLE.rawValue): .pasteAndMatchStyle, Int(MENU_ID_DELETE.rawValue): .delete,
            Int(MENU_ID_SELECT_ALL.rawValue): .selectAll,
            Int(MENU_ID_FIND.rawValue): .find, Int(MENU_ID_PRINT.rawValue): .print,
            Int(MENU_ID_VIEW_SOURCE.rawValue): .viewSource,
            Int(MENU_ID_NO_SPELLING_SUGGESTIONS.rawValue): .noSpellingSuggestions,
            Int(MENU_ID_ADD_TO_DICTIONARY.rawValue): .addToDictionary,
        ]
        let first = Int(MENU_ID_SPELLCHECK_SUGGESTION_0.rawValue)
        for index in 0...(Int(MENU_ID_SPELLCHECK_SUGGESTION_LAST.rawValue) - first) {
            map[first + index] = .spellingSuggestion(index)
        }
        return map
    }()

    /// The values macOS's text services give their items in Chrome-style
    /// menus (`ui::TextServicesContextMenu`), mapped to the constants here.
    private static let chromeTextServices: [Int: Self] = [
        100: .speechMenu, 101: .startSpeaking, 102: .stopSpeaking,
        103: .writingDirectionMenu, 104: .writingDirectionDefault,
        105: .writingDirectionLeftToRight, 106: .writingDirectionRightToLeft,
    ]

    /// The command an item Chromium numbered `commandID` runs, in a menu of
    /// a Chrome-style browser or an Alloy-style one.
    init(chromiumID commandID: Int, isChromeStyle: Bool) {
        let map = isChromeStyle ? Self.chromeTextServices : Self.alloyEquivalents
        self = map[commandID] ?? Self(rawValue: commandID)
    }

    // MARK: Names

    /// The constant's name, such as `copyLinkAddress`, or the raw value
    /// for a command without one.
    public var description: String {
        if let name = Self.names[self] { return name }
        if let index = spellingSuggestionIndex { return "spellingSuggestion(\(index))" }
        return "CefContextMenuCommand(rawValue: \(rawValue))"
    }

    /// Whether Chromium names this command: one of the constants above.
    public var isKnown: Bool {
        Self.names[self] != nil || spellingSuggestionIndex != nil
    }

    /// Which spelling suggestion this is, from 0, if it is one.
    public var spellingSuggestionIndex: Int? {
        let index = rawValue - Int(IDC_SPELLCHECK_SUGGESTION_0)
        return (0..<Int(IDC_SPELLCHECK_LANGUAGES_FIRST - IDC_SPELLCHECK_SUGGESTION_0)).contains(index) ? index : nil
    }

    private static let names: [Self: String] = {
        let all: [(Self, String)] = [
            (.back, "back"), (.forward, "forward"), (.reload, "reload"), (.reloadIgnoringCache, "reloadIgnoringCache"),
            (.stopLoading, "stopLoading"), (.find, "find"), (.print, "print"), (.viewSource, "viewSource"),
            (.savePage, "savePage"), (.cast, "cast"), (.createQRCode, "createQRCode"), (.translate, "translate"),
            (.openInReadingMode, "openInReadingMode"), (.exitFullscreen, "exitFullscreen"),
            (.inspectElement, "inspectElement"), (.sendTabToSelf, "sendTabToSelf"), (.shareMenu, "shareMenu"),
            (.reloadFrame, "reloadFrame"), (.viewFrameSource, "viewFrameSource"),
            (.openLinkInNewTab, "openLinkInNewTab"), (.openLinkInNewWindow, "openLinkInNewWindow"),
            (.openLinkInIncognitoWindow, "openLinkInIncognitoWindow"), (.openLinkInProfile, "openLinkInProfile"),
            (.openLinkInSplitView, "openLinkInSplitView"), (.openLinkWith, "openLinkWith"),
            (.addLinkToReadingList, "addLinkToReadingList"), (.saveLinkAs, "saveLinkAs"),
            (.copyLinkAddress, "copyLinkAddress"), (.copyLinkText, "copyLinkText"),
            (.copyLinkToHighlight, "copyLinkToHighlight"), (.reshareLinkToHighlight, "reshareLinkToHighlight"),
            (.removeHighlight, "removeHighlight"),
            (.openImageInNewTab, "openImageInNewTab"), (.openOriginalImageInNewTab, "openOriginalImageInNewTab"),
            (.loadImage, "loadImage"), (.saveImageAs, "saveImageAs"), (.copyImage, "copyImage"),
            (.copyImageAddress, "copyImageAddress"), (.searchWebForImage, "searchWebForImage"),
            (.searchLensForImage, "searchLensForImage"), (.saveMediaAs, "saveMediaAs"),
            (.copyMediaAddress, "copyMediaAddress"), (.openMediaInNewTab, "openMediaInNewTab"),
            (.copyVideoFrame, "copyVideoFrame"), (.saveVideoFrameAs, "saveVideoFrameAs"),
            (.searchLensForVideoFrame, "searchLensForVideoFrame"), (.searchWebForVideoFrame, "searchWebForVideoFrame"),
            (.pictureInPicture, "pictureInPicture"), (.loop, "loop"), (.showControls, "showControls"),
            (.rotateClockwise, "rotateClockwise"), (.rotateCounterclockwise, "rotateCounterclockwise"),
            (.savePluginAs, "savePluginAs"),
            (.searchWebFor, "searchWebFor"), (.searchWebForInNewTab, "searchWebForInNewTab"), (.goToURL, "goToURL"),
            (.lookUp, "lookUp"), (.lensRegionSearch, "lensRegionSearch"), (.webRegionSearch, "webRegionSearch"),
            (.partialTranslate, "partialTranslate"),
            (.undo, "undo"), (.redo, "redo"), (.cut, "cut"), (.copy, "copy"), (.paste, "paste"),
            (.pasteAndMatchStyle, "pasteAndMatchStyle"), (.delete, "delete"), (.selectAll, "selectAll"),
            (.emojiAndSymbols, "emojiAndSymbols"), (.generatePassword, "generatePassword"),
            (.showAllSavedPasswords, "showAllSavedPasswords"), (.passwordsAndAutofillMenu, "passwordsAndAutofillMenu"),
            (.writingDirectionMenu, "writingDirectionMenu"), (.writingDirectionDefault, "writingDirectionDefault"),
            (.writingDirectionLeftToRight, "writingDirectionLeftToRight"),
            (.writingDirectionRightToLeft, "writingDirectionRightToLeft"),
            (.speechMenu, "speechMenu"), (.startSpeaking, "startSpeaking"), (.stopSpeaking, "stopSpeaking"),
            (.spellingServiceSuggestion, "spellingServiceSuggestion"), (.noSpellingSuggestions, "noSpellingSuggestions"),
            (.addToDictionary, "addToDictionary"), (.removeFromDictionary, "removeFromDictionary"),
            (.spellingMenu, "spellingMenu"), (.checkSpellingWhileTyping, "checkSpellingWhileTyping"),
            (.languageSettings, "languageSettings"),
        ]
        return Dictionary(all, uniquingKeysWith: { first, _ in first })
    }()
}
