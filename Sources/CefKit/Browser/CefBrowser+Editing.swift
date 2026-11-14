import CCef
import CefBase
import Foundation

// MARK: - Spelling

extension CefBrowser {
    /// Replaces the misspelled word selected in an editable field with
    /// `word`, as choosing one of a context menu's
    /// ``CefContextMenuTarget/spellingSuggestions`` does. Does nothing when
    /// no misspelled word is selected.
    public func replaceMisspelling(with word: String) {
        withHost { host in CefStringUtil.withCefString(word) { host.pointee.replace_misspelling(host, $0) } }
    }

    /// Adds `word` to the spelling dictionary, so that it is no longer
    /// marked misspelled, as the context menu's Learn Spelling does.
    public func learnSpelling(_ word: String) {
        withHost { host in CefStringUtil.withCefString(word) { host.pointee.add_word_to_dictionary(host, $0) } }
    }
}

// MARK: - Zoom steps

extension CefBrowser {
    /// A zoom step, as Chrome's View menu takes them.
    public enum ZoomCommand: Sendable, Hashable {
        /// The next larger of Chrome's preset zoom factors (110%, 125%,
        /// 150%, …).
        case zoomIn
        /// The next smaller preset factor.
        case zoomOut
        /// The profile's default zoom (``defaultZoomLevel``).
        case reset

        var cefValue: cef_zoom_command_t {
            switch self {
            case .zoomIn: CEF_ZOOM_COMMAND_IN
            case .zoomOut: CEF_ZOOM_COMMAND_OUT
            case .reset: CEF_ZOOM_COMMAND_RESET
            }
        }
    }

    /// Whether ``zoom(_:)`` can take `command` now: false at the largest
    /// or smallest preset, at the default for ``ZoomCommand/reset``, and
    /// while the browser has nothing in Chromium.
    public func canZoom(_ command: ZoomCommand) -> Bool {
        withHost { $0.pointee.can_zoom($0, command.cefValue) != 0 } ?? false
    }

    /// Steps the zoom to the next of Chrome's preset factors, or back to
    /// the default; ``zoomLevel`` follows. To set any level, set
    /// ``zoomLevel``.
    public func zoom(_ command: ZoomCommand) {
        guard !isDiscarded else {
            whenRestored { [weak self] in self?.zoom(command) }
            return
        }
        withHost { $0.pointee.zoom($0, command.cefValue) }
        CefBrowser.refreshZoomLevels()
    }

    /// The zoom level pages open at when no site-specific level applies:
    /// 0 unless the profile's preferences set another.
    public var defaultZoomLevel: Double {
        withHost { $0.pointee.get_default_zoom_level($0) } ?? 0
    }
}

// MARK: - Fullscreen and capture

extension CefBrowser {
    /// Asks the page to leave fullscreen (`document.exitFullscreen()`),
    /// for an app's own Exit Full Screen command or button. A Chrome-style
    /// browser leaves on Escape and the window's green button by itself;
    /// an Alloy-style one in a `CefWebView` needs this.
    public func exitFullscreen() {
        withHost { $0.pointee.exit_fullscreen($0, 1) }
    }

    /// Tells an offscreen browser that its host lost the mouse capture,
    /// for example when a menu or another window takes the pointer during
    /// a drag: the page ends the drag or selection it was making.
    /// ``CefOffscreenBrowserView`` calls it when its window resigns key
    /// with a mouse button down.
    public func sendCaptureLostEvent() {
        withHost { $0.pointee.send_capture_lost_event($0) }
    }
}
