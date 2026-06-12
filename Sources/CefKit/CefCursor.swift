import AppKit
import CCef
import Foundation

/// The mouse cursor a page wants displayed, delivered to
/// ``CefBrowserDelegate/browser(_:didChangeCursor:)``. For windowed browsers
/// CEF already applies the cursor; this is informational (and lets OSR hosts
/// drive `NSCursor` themselves). Use ``nsCursor`` for a ready-made AppKit cursor.
public enum CefCursorType: Sendable, Equatable {
    case pointer
    case hand
    case iBeam
    case crosshair
    case wait
    case help
    case move
    case notAllowed
    case grab
    case grabbing
    case columnResize
    case rowResize
    case eastWestResize
    case northSouthResize
    case zoomIn
    case zoomOut
    case none
    /// A cursor type CefSwift does not map to a named case.
    case other

    init(cefValue: cef_cursor_type_t) {
        switch cefValue {
        case CT_POINTER: self = .pointer
        case CT_HAND: self = .hand
        case CT_IBEAM: self = .iBeam
        case CT_CROSS: self = .crosshair
        case CT_WAIT: self = .wait
        case CT_HELP: self = .help
        case CT_MOVE: self = .move
        case CT_NOTALLOWED, CT_NODROP: self = .notAllowed
        case CT_GRAB: self = .grab
        case CT_GRABBING: self = .grabbing
        case CT_COLUMNRESIZE: self = .columnResize
        case CT_ROWRESIZE: self = .rowResize
        case CT_EASTWESTRESIZE: self = .eastWestResize
        case CT_NORTHSOUTHRESIZE: self = .northSouthResize
        case CT_ZOOMIN: self = .zoomIn
        case CT_ZOOMOUT: self = .zoomOut
        case CT_NONE: self = .none
        default: self = .other
        }
    }

    /// The closest standard `NSCursor`, or `nil` when AppKit has no analogue
    /// (caller should fall back to the arrow cursor or hide it).
    @MainActor
    public var nsCursor: NSCursor? {
        switch self {
        case .pointer, .other: return .arrow
        case .hand, .grab: return .openHand
        case .grabbing: return .closedHand
        case .iBeam: return .iBeam
        case .crosshair: return .crosshair
        case .move: return .openHand
        case .notAllowed: return .operationNotAllowed
        case .columnResize: return .resizeLeftRight
        case .rowResize: return .resizeUpDown
        case .eastWestResize: return .resizeLeftRight
        case .northSouthResize: return .resizeUpDown
        case .help, .wait, .zoomIn, .zoomOut: return .arrow
        case .none: return nil
        }
    }
}
