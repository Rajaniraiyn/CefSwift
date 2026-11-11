import AppKit
import CCef
import Foundation

/// The operations a drag allows, mirroring `cef_drag_operations_mask_t`.
public struct CefDragOperation: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let none = CefDragOperation([])
    public static let copy = CefDragOperation(rawValue: 1)
    public static let link = CefDragOperation(rawValue: 2)
    public static let generic = CefDragOperation(rawValue: 4)
    public static let `private` = CefDragOperation(rawValue: 8)
    public static let move = CefDragOperation(rawValue: 16)
    public static let delete = CefDragOperation(rawValue: 32)
    public static let every = CefDragOperation(rawValue: UInt32.max)

    var cefValue: cef_drag_operations_mask_t {
        cef_drag_operations_mask_t(rawValue)
    }

    /// The equivalent `NSDragOperation`. ``every`` maps to copy, link, move
    /// and generic.
    public var nsOperation: NSDragOperation {
        if self == .every { return [.copy, .link, .move, .generic] }
        var op: NSDragOperation = []
        if contains(.copy) { op.insert(.copy) }
        if contains(.link) { op.insert(.link) }
        if contains(.move) { op.insert(.move) }
        if contains(.generic) { op.insert(.generic) }
        if contains(.delete) { op.insert(.delete) }
        if contains(.private) { op.insert(.private) }
        return op
    }

    /// Creates the mask equivalent to an `NSDragOperation`.
    public init(_ ns: NSDragOperation) {
        var raw: UInt32 = 0
        if ns.contains(.copy) { raw |= CefDragOperation.copy.rawValue }
        if ns.contains(.link) { raw |= CefDragOperation.link.rawValue }
        if ns.contains(.move) { raw |= CefDragOperation.move.rawValue }
        if ns.contains(.generic) { raw |= CefDragOperation.generic.rawValue }
        if ns.contains(.delete) { raw |= CefDragOperation.delete.rawValue }
        if ns.contains(.private) { raw |= CefDragOperation.private.rawValue }
        self.init(rawValue: raw)
    }
}

/// What the page is dragging when it starts a drag from an offscreen browser.
public struct CefDragData: Sendable, Equatable {
    /// Whether the drag is a hyperlink.
    public var isLink: Bool
    /// Whether the drag is a text or HTML fragment.
    public var isFragment: Bool
    /// The link URL, when ``isLink`` is `true`.
    public var linkURL: URL?
    /// The link title, when ``isLink`` is `true`.
    public var linkTitle: String
    /// The plain-text fragment being dragged.
    public var fragmentText: String
    /// The HTML fragment being dragged.
    public var fragmentHTML: String

    public init(
        isLink: Bool = false, isFragment: Bool = false,
        linkURL: URL? = nil, linkTitle: String = "",
        fragmentText: String = "", fragmentHTML: String = ""
    ) {
        self.isLink = isLink
        self.isFragment = isFragment
        self.linkURL = linkURL
        self.linkTitle = linkTitle
        self.fragmentText = fragmentText
        self.fragmentHTML = fragmentHTML
    }

    /// Reads a borrowed `cef_drag_data_t`.
    init(reading data: UnsafeMutablePointer<cef_drag_data_t>) {
        self.init(
            isLink: data.pointee.is_link(data) != 0,
            isFragment: data.pointee.is_fragment(data) != 0,
            linkURL: CefStringUtil.takingUserFree(data.pointee.get_link_url(data)).flatMap {
                $0.isEmpty ? nil : URL(string: $0)
            },
            linkTitle: CefStringUtil.takingUserFree(data.pointee.get_link_title(data)) ?? "",
            fragmentText: CefStringUtil.takingUserFree(data.pointee.get_fragment_text(data)) ?? "",
            fragmentHTML: CefStringUtil.takingUserFree(data.pointee.get_fragment_html(data)) ?? ""
        )
    }
}

// MARK: - Drag input

extension CefBrowser {

    // MARK: Dragging into the page

    /// Tells the page a drag entered the view, carrying the given content.
    public func dragTargetEnter(
        at point: CGPoint, modifiers: CefEventModifiers = [], allowedOperations: CefDragOperation,
        text: String? = nil, html: String? = nil, urls: [URL] = [], files: [String] = []
    ) {
        guard let data = cef_drag_data_create() else { return }
        data.pointee.reset_file_contents(data)
        if let text, !text.isEmpty {
            CefStringUtil.withCefString(text) { data.pointee.set_fragment_text(data, $0) }
        }
        if let html, !html.isEmpty {
            CefStringUtil.withCefString(html) { data.pointee.set_fragment_html(data, $0) }
        }
        if let first = urls.first {
            CefStringUtil.withCefString(first.absoluteString) { data.pointee.set_link_url(data, $0) }
        }
        for file in files {
            CefStringUtil.withCefString(file) { path in
                CefStringUtil.withCefString((file as NSString).lastPathComponent) { name in
                    data.pointee.add_file(data, path, name)
                }
            }
        }
        // drag_target_drag_enter consumes the reference cef_drag_data_create
        // returned; release it only if it was never handed over.
        let delivered: Void? = withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.drag_target_drag_enter(host, data, &event, allowedOperations.cefValue)
        }
        if delivered == nil { cefRelease(data) }
    }

    /// Tells the page the drag moved.
    public func dragTargetOver(at point: CGPoint, modifiers: CefEventModifiers = [], allowedOperations: CefDragOperation) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.drag_target_drag_over(host, &event, allowedOperations.cefValue)
        }
    }

    /// Tells the page the drag left the view.
    public func dragTargetLeave() {
        withHost { $0.pointee.drag_target_drag_leave($0) }
    }

    /// Tells the page the drag was dropped.
    public func dragTargetDrop(at point: CGPoint, modifiers: CefEventModifiers = []) {
        withHost { host in
            var event = cef_mouse_event_t(point, modifiers: modifiers)
            host.pointee.drag_target_drop(host, &event)
        }
    }

    // MARK: Dragging out of the page

    /// Tells the page a drag it started ended at `point`, in view points,
    /// with `operation`.
    public func dragSourceEnded(at point: CGPoint, operation: CefDragOperation) {
        withHost {
            $0.pointee.drag_source_ended_at(
                $0, Int32(point.x.rounded()), Int32(point.y.rounded()), operation.cefValue)
        }
    }

    /// Tells the page the system drag session it started has finished.
    public func dragSourceSystemDragEnded() {
        withHost { $0.pointee.drag_source_system_drag_ended($0) }
    }
}
