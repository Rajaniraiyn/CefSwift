import CCef
import CefBase
import Foundation

extension CefBrowser.Configuration {
    /// What a page may run and load, and how its text is set: Chromium's
    /// per-browser web preferences (`cef_browser_settings_t`), fixed when
    /// the browser is created. A popup Chromium opens gets its opener's.
    ///
    /// ```swift
    /// var configuration = CefBrowser.Configuration()
    /// configuration.content.javaScript = .disabled
    /// configuration.content.fonts.standardFamily = "Helvetica Neue"
    /// ```
    public struct Content: Sendable, Equatable {
        /// What a page's scripts may do with the clipboard beyond the
        /// asynchronous Clipboard API, which asks for permission.
        public enum ClipboardAccess: Sendable, Equatable {
            /// Chromium's default: `document.execCommand('copy')` and
            /// `'cut'` only during a user gesture, and no
            /// `document.execCommand('paste')`.
            case automatic
            /// Copying and cutting at any time, without a gesture.
            case copy
            /// Copying, cutting and pasting at any time: the page can read
            /// what the user copied elsewhere. For your own content only.
            case copyAndPaste
        }

        /// The fonts a page gets where it names none, by CSS generic
        /// family. `nil` keeps Chromium's (or the profile's
        /// `webkit.webprefs.fonts` preferences). Sizes are the profile's
        /// `webkit.webprefs.default_font_size` and `minimum_font_size`
        /// preferences, which win over a browser's own in CEF 156.
        public struct Fonts: Sendable, Equatable {
            public var standardFamily: String?
            public var fixedFamily: String?
            public var serifFamily: String?
            public var sansSerifFamily: String?
            public var cursiveFamily: String?
            public var fantasyFamily: String?

            public init() {}
        }

        /// Whether pages run JavaScript. ``CefRuntime/Setting/disabled``
        /// turns off the page's own scripts; bridges and user scripts,
        /// which CefKit runs through V8's API, are not page scripts, but a
        /// page without JavaScript has no context for them either.
        public var javaScript: CefRuntime.Setting = .automatic
        /// Whether pages load images.
        public var images: CefRuntime.Setting = .automatic
        /// Whether pages get WebGL contexts.
        public var webGL: CefRuntime.Setting = .automatic
        /// Whether pages get `localStorage` and `sessionStorage`.
        public var localStorage: CefRuntime.Setting = .automatic
        /// Whether pages load web fonts (`@font-face`).
        public var webFonts: CefRuntime.Setting = .automatic
        public var clipboardAccess: ClipboardAccess = .automatic
        public var fonts = Fonts()
        /// The text encoding of a document that declares none, such as
        /// `"ISO-8859-1"`; `nil` keeps Chromium's.
        public var defaultEncoding: String?

        public init() {}

        /// Writes the choices into `settings`. Strings are set with
        /// CefStringUtil and freed by ``clearStrings(of:)``.
        func apply(to settings: inout cef_browser_settings_t) {
            func state(_ setting: CefRuntime.Setting) -> cef_state_t {
                setting == .disabled ? STATE_DISABLED : STATE_DEFAULT
            }
            settings.javascript = state(javaScript)
            settings.image_loading = state(images)
            settings.webgl = state(webGL)
            settings.local_storage = state(localStorage)
            settings.remote_fonts = state(webFonts)
            switch clipboardAccess {
            case .automatic: break
            case .copy:
                settings.javascript_access_clipboard = STATE_ENABLED
            case .copyAndPaste:
                settings.javascript_access_clipboard = STATE_ENABLED
                settings.javascript_dom_paste = STATE_ENABLED
            }
            if let family = fonts.standardFamily { CefStringUtil.set(family, into: &settings.standard_font_family) }
            if let family = fonts.fixedFamily { CefStringUtil.set(family, into: &settings.fixed_font_family) }
            if let family = fonts.serifFamily { CefStringUtil.set(family, into: &settings.serif_font_family) }
            if let family = fonts.sansSerifFamily { CefStringUtil.set(family, into: &settings.sans_serif_font_family) }
            if let family = fonts.cursiveFamily { CefStringUtil.set(family, into: &settings.cursive_font_family) }
            if let family = fonts.fantasyFamily { CefStringUtil.set(family, into: &settings.fantasy_font_family) }
            if let defaultEncoding { CefStringUtil.set(defaultEncoding, into: &settings.default_encoding) }
        }

        /// Frees the strings ``apply(to:)`` set, once CEF has copied them.
        static func clearStrings(of settings: inout cef_browser_settings_t) {
            ccef_string_clear(&settings.standard_font_family)
            ccef_string_clear(&settings.fixed_font_family)
            ccef_string_clear(&settings.serif_font_family)
            ccef_string_clear(&settings.sans_serif_font_family)
            ccef_string_clear(&settings.cursive_font_family)
            ccef_string_clear(&settings.fantasy_font_family)
            ccef_string_clear(&settings.default_encoding)
        }
    }
}
