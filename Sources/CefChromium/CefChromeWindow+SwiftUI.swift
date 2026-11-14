import AppKit
import CefKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension CefChromeWindow {
    /// Sets ``topBar`` to a SwiftUI view: the app's tab strip and toolbar,
    /// over Chrome's. It is as tall as Chrome's (``topBarHeight``); the
    /// window buttons sit at its leading edge, so leave them room.
    ///
    /// `content` runs once; the view updates with the observable state it
    /// reads, such as this window's ``tabs``.
    public func setTopBar(@ViewBuilder _ content: () -> some View) {
        topBar = NSHostingView(rootView: content())
    }

    /// Sets ``sidebar`` to a SwiftUI view, over Chrome's vertical tab
    /// strip.
    public func setSidebar(@ViewBuilder _ content: () -> some View) {
        sidebar = NSHostingView(rootView: content())
    }

    /// Sets ``pageOverlay`` to a SwiftUI view: sized to the page, and
    /// passing every event through to it.
    public func setPageOverlay(@ViewBuilder _ content: () -> some View) {
        let hosting = NSHostingView(rootView: content().allowsHitTesting(false))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        let container = PassthroughView()
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        pageOverlay = container
    }
}

// MARK: - Dragging tabs

/// A tab on the move: what a dragged ``CefTab`` carries, between the app's
/// windows and out of the app.
///
/// Inside the app it names the tab, so a drop lands it with
/// ``CefTab/move(to:in:)`` or ``CefTabGroup/add(_:)``; in Finder, a text
/// field or another browser it is the tab's address.
///
/// ```swift
/// TabView(tab)
///     .draggable(CefTab.Transfer(tab))
/// TabRow()
///     .dropDestination(for: CefTab.Transfer.self) { items, _ in
///         Task { for item in items { try await item.tab(in: strip)?.move(to: index, in: window) } }
///         return true
///     }
/// ```
extension CefTab {
    public struct Transfer: Codable, Hashable, Sendable, Transferable {
        /// The tab's identifier.
        public var id: CefTab.ID
        /// Its address when the drag began.
        public var url: URL?
        public var title: String

        @MainActor public init(_ tab: CefTab) {
            id = tab.id
            url = tab.url
            title = tab.title
        }

        /// The tab, if it is still open in `strip`.
        @MainActor public func tab(in strip: CefTabStrip) -> CefTab? {
            strip.tab(id)
        }

        /// A tab of a CefSwift app.
        public static let contentType = UTType(exportedAs: "dev.cefswift.tab", conformingTo: .data)

        public static var transferRepresentation: some TransferRepresentation {
            CodableRepresentation(contentType: contentType)
            ProxyRepresentation { (transfer: Transfer) in transfer.url ?? URL(string: "about:blank")! }
        }
    }

    /// The tab on the pasteboard, for AppKit dragging: its address for
    /// other apps, and the tab itself for the app.
    public var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        if let url { item.setString(url.absoluteString, forType: .URL) }
        item.setString(url?.absoluteString ?? title, forType: .string)
        if let data = try? JSONEncoder().encode(Transfer(self)) {
            item.setData(data, forType: NSPasteboard.PasteboardType(Transfer.contentType.identifier))
        }
        return item
    }
}
