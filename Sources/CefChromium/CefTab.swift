import AppKit
import CefKit
import Foundation
import Observation

/// A tab in one of Chromium's windows: a browser's place in Chromium's tab
/// model (`TabStripModel`).
///
/// One object stands for one Chromium tab for as long as the tab exists,
/// across moves between windows, and its ``id`` is the tab's `chrome.tabs`
/// identifier, the one extensions see. What a tab shows (``title``,
/// ``favicon``, ``isLoading``) comes from its ``browser``, the page's
/// model; where it is (``window``, ``index``, ``isPinned``, ``group``,
/// ``isActive``) comes from Chromium's tab strip, read by the profile's
/// ``CefTabStrip``.
///
/// ```swift
/// for tab in window.tabs {
///     print(tab.title, tab.isPinned, tab.group?.title ?? "-")
/// }
/// try await tab.pin()
/// try await tab.move(to: 0, in: otherWindow)
/// ```
///
/// Each command asks Chromium to make the change; the tab's properties
/// change when Chromium reports it, a moment later, so a view drawing them
/// never disagrees with Chromium.
@MainActor
@Observable
public final class CefTab: Identifiable {
    /// The tab's `chrome.tabs` identifier: it stays the same across moves
    /// between windows, and is what extensions see.
    public struct ID: Hashable, Sendable, CustomStringConvertible, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public var description: String { String(rawValue) }
    }

    /// What a tab is doing that its tab shows, Chrome's tab alert states.
    public enum Alert: Hashable, Sendable {
        case playingAudio, muted, recording, capturing, bluetooth, usb, serial, hid, vr, pictureInPicture
        /// A state this version of CefChromium does not know.
        case other(String)
    }

    public nonisolated let id: ID
    /// The window the tab is in.
    public internal(set) var window: CefChromeWindow?
    /// The tab's position in its window, pinned tabs first.
    public internal(set) var index = 0
    /// The page's title as Chromium reports it.
    public internal(set) var title = ""
    /// The page's address.
    public internal(set) var url: URL?
    /// Whether the tab is its window's active tab, the one shown.
    public internal(set) var isActive = false
    /// Whether the tab is selected, alone or with others (Chromium's
    /// multiple selection: ⌘-click and ⇧-click on tabs).
    public internal(set) var isSelected = false
    public internal(set) var isPinned = false
    /// Whether Chromium discarded the page to save memory. It loads again
    /// when the tab is selected.
    public internal(set) var isDiscarded = false
    /// Whether the page plays sound, or did a moment ago.
    public internal(set) var isAudible = false
    /// Whether the tab's sound is muted.
    public internal(set) var isMuted = false
    /// Whether the page is loading.
    public internal(set) var isLoading = false
    /// The tab group the tab is in.
    public internal(set) var group: CefTabGroup?
    /// What the tab shows it is doing: playing sound, recording, sharing
    /// the screen.
    public internal(set) var alerts: [Alert] = []
    /// The tab the tab was opened from, while Chromium remembers it.
    public internal(set) var openerID: ID?
    /// The page's icon address as Chromium reports it; ``favicon`` is the
    /// image, once the tab's browser is known.
    public internal(set) var faviconURL: URL?

    /// The browser showing the tab's page. `nil` until CefChromium has
    /// matched the tab with its browser, which it does exactly (see
    /// ``CefTabStrip``), usually as the tab appears.
    public internal(set) var browser: CefBrowser?

    /// The page's icon.
    public var favicon: NSImage? { browser?.favicon }

    @ObservationIgnored weak var strip: CefTabStrip?

    init(id: ID, strip: CefTabStrip) {
        self.id = id
        self.strip = strip
    }

    // MARK: Commands

    /// Shows the tab in its window, and brings the window to the front.
    public func select() async throws {
        try await requireStrip().select(self)
    }

    /// Closes the tab as its close button would; its page's
    /// `beforeunload` handler may keep it open.
    public func close() {
        strip?.close([self])
    }

    /// Pins or unpins the tab. A pinned tab moves to the front of its
    /// window's strip.
    public func pin(_ isPinned: Bool = true) async throws {
        try await requireStrip().pin([self], isPinned)
    }

    /// Moves the tab to `index` in `window`, by default its own. A move to
    /// another window is Chromium's: the tab keeps its page, its history
    /// and its ``browser``.
    public func move(to index: Int, in window: CefChromeWindow? = nil) async throws {
        try await requireStrip().move([self], to: index, in: window ?? self.window)
    }

    /// Opens a copy of the tab beside it, with its history.
    @discardableResult
    public func duplicate() async throws -> CefTab {
        try await requireStrip().duplicate(self)
    }

    /// Moves the tab into a new window of its own, keeping its page.
    @discardableResult
    public func moveToNewWindow() async throws -> CefChromeWindow {
        try await requireStrip().moveToNewWindow([self])
    }

    /// Mutes or unmutes the tab's sound.
    public func setMuted(_ isMuted: Bool) {
        browser?.isAudioMuted = isMuted
        strip?.scheduleRead()
    }

    /// Discards the tab's page to free its memory, as Chromium's Memory
    /// Saver does; see ``CefBrowser/discard()``.
    public func discard() async throws {
        guard let browser else { throw CefTabStrip.Error.noBrowser }
        do { try await browser.discard() } catch { throw CefTabStrip.Error.chromium("\(error)") }
        strip?.scheduleRead()
    }

    private func requireStrip() throws -> CefTabStrip {
        guard let strip else { throw CefTabStrip.Error.tabClosed }
        return strip
    }
}

/// A tab group in one of Chromium's windows.
@MainActor
@Observable
public final class CefTabGroup: Identifiable {
    /// The group's `chrome.tabGroups` identifier.
    public struct ID: Hashable, Sendable, CustomStringConvertible, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public var description: String { String(rawValue) }
    }

    /// Chrome's tab group colours.
    public enum Color: Int, CaseIterable, Sendable, Codable {
        case grey, blue, red, yellow, green, pink, purple, cyan, orange
    }

    public nonisolated let id: ID
    public internal(set) var window: CefChromeWindow?
    /// The group's name; empty for a group without one.
    public internal(set) var title = ""
    public internal(set) var color = Color.grey
    /// Whether the group shows only its header.
    public internal(set) var isCollapsed = false
    /// The group's tabs, in order.
    public internal(set) var tabs: [CefTab] = []

    @ObservationIgnored weak var strip: CefTabStrip?
    /// The tabs being collected while the strip is read.
    @ObservationIgnored var pendingTabs: [CefTab] = []

    init(id: ID, strip: CefTabStrip) {
        self.id = id
        self.strip = strip
    }

    /// Adds `tabs` to the group.
    public func add(_ tabs: [CefTab]) async throws {
        guard let strip else { throw CefTabStrip.Error.tabClosed }
        try await strip.group(tabs, into: self)
    }

    /// Takes every tab out of the group, which then ends.
    public func ungroup() async throws {
        guard let strip else { throw CefTabStrip.Error.tabClosed }
        try await strip.ungroup(tabs)
    }

    /// Closes every tab of the group.
    public func close() {
        strip?.close(tabs)
    }

    /// Moves the group's tabs, in order, to `index` of `window`.
    public func move(to index: Int, in window: CefChromeWindow? = nil) async throws {
        guard let strip else { throw CefTabStrip.Error.tabClosed }
        try await strip.move(tabs, to: index, in: window ?? self.window)
    }

    /// Moves the group into a new window of its own.
    ///
    /// Chromium regroups the tabs there; the group's name and colour are
    /// carried over through Chromium's group editor (see ``setTitle(_:)``)
    /// where it can, which is not guaranteed.
    @discardableResult
    public func moveToNewWindow() async throws -> CefChromeWindow {
        guard let strip else { throw CefTabStrip.Error.tabClosed }
        return try await strip.moveGroupToNewWindow(self)
    }

    /// Collapses or expands the group.
    ///
    /// Not available on CEF 156: Chromium grants `chrome.tabGroups` to
    /// extensions only, no WebUI page or Chrome command collapses a group,
    /// and Chromium's own group header, beneath the app's views, takes no
    /// accessibility action, synthesized click or key press for it. Throws
    /// ``CefTabStrip/Error/unsupported(_:)``; ``isCollapsed`` still follows
    /// collapsing done by an extension. An app can collapse a group in its
    /// own view meanwhile.
    public func setCollapsed(_ isCollapsed: Bool) async throws {
        guard isCollapsed != self.isCollapsed else { return }
        throw CefTabStrip.Error.unsupported(
            "Chromium offers no way to collapse a tab group outside chrome.tabGroups, which only extensions have.")
    }

    /// Renames the group, through Chromium's own group editor.
    ///
    /// The editor bubble Chromium opens for it is kept off screen while
    /// CefChromium types the name into it. Throws
    /// ``CefTabStrip/Error/unsupported(_:)`` when the editor cannot be
    /// found, which a Chromium update can cause.
    public func setTitle(_ title: String) async throws {
        guard let strip else { throw CefTabStrip.Error.tabClosed }
        try await strip.editGroup(self, title: title, color: nil)
    }

    /// Recolours the group, through Chromium's own group editor; see
    /// ``setTitle(_:)``.
    public func setColor(_ color: Color) async throws {
        guard let strip else { throw CefTabStrip.Error.tabClosed }
        try await strip.editGroup(self, title: nil, color: color)
    }
}

extension CefTab.Alert {
    /// From `tabs.mojom.TabAlertState`'s names.
    init(name: String) {
        switch name {
        case "kAudioPlaying": self = .playingAudio
        case "kAudioMuting": self = .muted
        case "kMediaRecording", "kAudioRecording", "kVideoRecording": self = .recording
        case "kTabCapturing", "kDesktopCapturing": self = .capturing
        case "kBluetoothConnected", "kBluetoothScanActive": self = .bluetooth
        case "kUsbConnected": self = .usb
        case "kSerialConnected": self = .serial
        case "kHidConnected": self = .hid
        case "kVrPresentingInHeadset": self = .vr
        case "kPipPlaying": self = .pictureInPicture
        default: self = .other(name)
        }
    }
}
