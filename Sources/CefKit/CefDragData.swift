import AppKit
import CCef
import Foundation

/// A drag operation bitmask, mirroring `cef_drag_operations_mask_t`. Maps to
/// `NSDragOperation` for bridging native AppKit drag sessions.
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

    /// The CEF enum value to hand back to host drag methods.
    var cefValue: cef_drag_operations_mask_t {
        cef_drag_operations_mask_t(UInt32(truncatingIfNeeded: rawValue))
    }

    /// Maps to `NSDragOperation`. `.every`/`.generic` widen to `.generic`.
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

    /// Builds from an `NSDragOperation`.
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

/// A decoded snapshot of a page-initiated drag (page → system), captured in the
/// render handler's `start_dragging`. The borrowed `cef_drag_data_t` is only
/// valid during the callback, so all fields are eagerly read.
public struct CefDragData: Sendable, Equatable {
    /// Whether the drag is a hyperlink.
    public var isLink: Bool
    /// Whether the drag is a text/html fragment.
    public var isFragment: Bool
    /// The link URL (when `isLink`).
    public var linkURL: String
    /// The link title (when `isLink`).
    public var linkTitle: String
    /// The plain-text fragment being dragged.
    public var fragmentText: String
    /// The text/html fragment being dragged.
    public var fragmentHTML: String

    public init(
        isLink: Bool = false, isFragment: Bool = false,
        linkURL: String = "", linkTitle: String = "",
        fragmentText: String = "", fragmentHTML: String = ""
    ) {
        self.isLink = isLink
        self.isFragment = isFragment
        self.linkURL = linkURL
        self.linkTitle = linkTitle
        self.fragmentText = fragmentText
        self.fragmentHTML = fragmentHTML
    }

    /// Reads a snapshot out of a borrowed `cef_drag_data_t`.
    init(reading data: UnsafeMutablePointer<cef_drag_data_t>) {
        self.init(
            isLink: (data.pointee.is_link?(data) ?? 0) != 0,
            isFragment: (data.pointee.is_fragment?(data) ?? 0) != 0,
            linkURL: CefStringUtil.takingUserFree(data.pointee.get_link_url?(data)) ?? "",
            linkTitle: CefStringUtil.takingUserFree(data.pointee.get_link_title?(data)) ?? "",
            fragmentText: CefStringUtil.takingUserFree(data.pointee.get_fragment_text?(data)) ?? "",
            fragmentHTML: CefStringUtil.takingUserFree(data.pointee.get_fragment_html?(data)) ?? ""
        )
    }
}

// MARK: - Host-side drag/touch forwarding

extension CefBrowser {

    // MARK: Drag target (system → page)

    /// Notifies the page a drag entered the view. Builds a `cef_drag_data_t`
    /// from `text`/`html`/`urls`/`files` and forwards to the host.
    public func dragTargetEnter(
        at point: CGPoint, modifiers: UInt32, allowedOps: CefDragOperation,
        text: String? = nil, html: String? = nil, urls: [URL] = [], files: [String] = []
    ) {
        guard let data = cef_drag_data_create() else { return }
        defer { cefRelease(UnsafeMutableRawPointer(data)) }
        // The web view rejects file contents on drag-in; reset to be safe.
        data.pointee.reset_file_contents?(data)
        if let text, !text.isEmpty {
            CefStringUtil.withCefString(text) { data.pointee.set_fragment_text?(data, $0) }
        }
        if let html, !html.isEmpty {
            CefStringUtil.withCefString(html) { data.pointee.set_fragment_html?(data, $0) }
        }
        if let first = urls.first {
            CefStringUtil.withCefString(first.absoluteString) { data.pointee.set_link_url?(data, $0) }
        }
        for file in files {
            CefStringUtil.withCefString(file) { path in
                CefStringUtil.withCefString((file as NSString).lastPathComponent) { name in
                    data.pointee.add_file?(data, path, name)
                }
            }
        }
        withHostInternal { host in
            var event = cef_mouse_event_t(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), modifiers: modifiers)
            host.pointee.drag_target_drag_enter?(host, data, &event, allowedOps.cefValue)
        }
    }

    /// Forwards a drag-over (call repeatedly as the mouse moves during a drag).
    public func dragTargetOver(at point: CGPoint, modifiers: UInt32, allowedOps: CefDragOperation) {
        withHostInternal { host in
            var event = cef_mouse_event_t(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), modifiers: modifiers)
            host.pointee.drag_target_drag_over?(host, &event, allowedOps.cefValue)
        }
    }

    /// Forwards a drag-leave.
    public func dragTargetLeave() {
        withHostInternal { $0.pointee.drag_target_drag_leave?($0) }
    }

    /// Forwards a drop.
    public func dragTargetDrop(at point: CGPoint, modifiers: UInt32) {
        withHostInternal { host in
            var event = cef_mouse_event_t(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), modifiers: modifiers)
            host.pointee.drag_target_drop?(host, &event)
        }
    }

    // MARK: Drag source (page → system)

    /// Tells the page a page-initiated system drag ended at `viewPoint`.
    public func dragSourceEndedAt(viewPoint: CGPoint, operation: CefDragOperation) {
        withHostInternal { $0.pointee.drag_source_ended_at?($0, Int32(viewPoint.x.rounded()), Int32(viewPoint.y.rounded()), operation.cefValue) }
    }

    /// Tells the page the page-initiated system drag fully completed.
    public func dragSourceSystemDragEnded() {
        withHostInternal { $0.pointee.drag_source_system_drag_ended?($0) }
    }

    // MARK: Touch

    /// Forwards a raw touch event to Chromium's gesture/scroll recognizers
    /// (windowless only). `point` is in view DIP (top-left origin).
    public func sendTouchEvent(
        id: Int32, point: CGPoint, type: cef_touch_event_type_t,
        modifiers: UInt32 = 0, pressure: Float = 0,
        pointerType: cef_pointer_type_t = CEF_POINTER_TYPE_TOUCH
    ) {
        withHostInternal { host in
            var event = cef_touch_event_t()
            event.id = id
            event.x = Float(point.x)
            event.y = Float(point.y)
            event.radius_x = 0
            event.radius_y = 0
            event.rotation_angle = 0
            event.pressure = pressure
            event.type = type
            event.modifiers = modifiers
            event.pointer_type = pointerType
            host.pointee.send_touch_event?(host, &event)
        }
    }
}
