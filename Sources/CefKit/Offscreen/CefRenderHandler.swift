import AppKit
import CCef
import Foundation
import IOSurface

/// A frame painted by an offscreen browser.
///
/// A frame is only valid during
/// ``CefOffscreenHost/offscreenDidPaint(_:element:)``: Chromium reuses the
/// surface or buffer once the call returns, so display it there and do not
/// keep it.
public enum CefOffscreenFrame {
    /// A shared `IOSurface` Chromium rendered into; `size` is in pixels. Set
    /// it as a layer's `contents`.
    case accelerated(surface: IOSurfaceRef, size: CGSize)
    /// BGRA pixels, `width * height * 4` bytes with an upper-left origin.
    /// Used only when shared textures are unavailable.
    case cpu(buffer: UnsafeRawPointer, width: Int, height: Int, dirtyRects: [CGRect])
}

/// The surface an offscreen frame belongs to.
public enum CefOffscreenPaintElement: Sendable {
    /// The page itself.
    case view
    /// A widget Chromium draws separately above the page, such as an open
    /// `<select>` list.
    case popup
}

/// The geometry an offscreen host reports to Chromium.
///
/// Call ``CefBrowser/hostViewDidResize()`` after the size changes and
/// ``CefBrowser/hostViewDidChangeBackingProperties()`` after the scale or
/// screen changes.
public struct CefOffscreenViewInfo: Sendable {
    /// The view size in points.
    public var size: CGSize
    /// The backing scale factor, such as `2` on Retina displays.
    public var deviceScaleFactor: CGFloat
    /// The view's top-left corner in screen points (top-left origin), used
    /// to place popups and convert view coordinates to screen coordinates.
    public var screenOrigin: CGPoint
    /// The screen's frame in points, used to keep popups on screen.
    public var screenFrame: CGRect

    public init(
        size: CGSize = CGSize(width: 1, height: 1),
        deviceScaleFactor: CGFloat = 1,
        screenOrigin: CGPoint = .zero,
        screenFrame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        self.size = size
        self.deviceScaleFactor = deviceScaleFactor
        self.screenOrigin = screenOrigin
        self.screenFrame = screenFrame
    }
}

/// The view that displays an offscreen browser: it supplies geometry and
/// receives frames, cursor changes, popups, IME ranges, menus and drags.
///
/// CefSwiftUI's offscreen browser view implements this. Every method is
/// called on the main thread.
@MainActor
public protocol CefOffscreenHost: AnyObject {
    /// The geometry Chromium should render at.
    var offscreenViewInfo: CefOffscreenViewInfo { get }
    /// A frame for `element` is ready. It is valid only for this call.
    func offscreenDidPaint(_ frame: CefOffscreenFrame, element: CefOffscreenPaintElement)
    /// The page wants a different cursor.
    func offscreenDidChangeCursor(_ cursor: CefCursorType)
    /// The popup widget was shown or hidden.
    func offscreenPopupDidChangeVisibility(_ visible: Bool)
    /// The popup widget moved or resized to `rect`, in view points.
    func offscreenPopupDidResize(_ rect: CGRect)
    /// The range of an input-method composition changed. `characterBounds`
    /// are in view points and position the candidate window.
    func offscreenDidChangeCompositionRange(_ range: NSRange, characterBounds: [CGRect])
    /// The text selection changed.
    func offscreenDidChangeSelection(_ selectedText: String, selectedRange: NSRange)
    /// The page asks for a context menu at `point`, in view points. Present
    /// `menu`, then report the choice through `completion`.
    func offscreenShowContextMenu(_ menu: CefMenuModel, at point: CGPoint, completion: CefContextMenuCompletion)
    /// The page started dragging `data` from `point`, in view points. Begin
    /// a system drag session and, when it ends, call
    /// ``CefBrowser/draggingSessionEnded(at:operation:)``. Return `false` to
    /// cancel the drag. The default returns `false`.
    func offscreenBeginDraggingSession(_ data: CefDragData, allowedOperations: CefDragOperation, at point: CGPoint) -> Bool
    /// The drag cursor should show `operation`. The default does nothing.
    func offscreenDragOperationDidChange(_ operation: CefDragOperation)
    /// The browser's ``CefBrowser/accessibilityTree`` changed. Post the
    /// matching platform notifications. The default does nothing.
    func offscreenAccessibilityTreeDidChange(_ changes: CefAccessibilityChanges)
}

extension CefOffscreenHost {
    public func offscreenBeginDraggingSession(_ data: CefDragData, allowedOperations: CefDragOperation, at point: CGPoint) -> Bool { false }
    public func offscreenDragOperationDidChange(_ operation: CefDragOperation) {}
    public func offscreenAccessibilityTreeDidChange(_ changes: CefAccessibilityChanges) {}
}

extension CefBrowserClient {
    /// Builds the `cef_render_handler_t` installed for offscreen browsers.
    func makeRenderHandler() -> UnsafeMutablePointer<cef_render_handler_t> {
        let handler = cefAllocate(cef_render_handler_t.self, owner: self)

        handler.pointee.get_accessibility_handler = { s in
            cefOwner(CefBrowserClient.self, s)?.handlers.retained(cef_accessibility_handler_t.self)
        }

        handler.pointee.get_view_rect = { s, browser, rect in
            cefRelease(browser)
            guard let rect else { return }
            let info = CefBrowserClient.offscreenViewInfo(s)
            rect.pointee = cef_rect_t(CGRect(origin: .zero, size: info.size))
        }

        handler.pointee.get_screen_info = { s, browser, screenInfo in
            cefRelease(browser)
            guard let screenInfo else { return 0 }
            let info = CefBrowserClient.offscreenViewInfo(s)
            let screen = cef_rect_t(info.screenFrame)
            screenInfo.pointee.device_scale_factor = Float(info.deviceScaleFactor)
            screenInfo.pointee.depth = 24
            screenInfo.pointee.depth_per_component = 8
            screenInfo.pointee.is_monochrome = 0
            screenInfo.pointee.rect = screen
            screenInfo.pointee.available_rect = screen
            return 1
        }

        handler.pointee.get_screen_point = { s, browser, viewX, viewY, screenX, screenY in
            cefRelease(browser)
            guard let screenX, let screenY else { return 0 }
            let origin = CefBrowserClient.offscreenViewInfo(s).screenOrigin
            screenX.pointee = Int32((origin.x + CGFloat(viewX)).rounded())
            screenY.pointee = Int32((origin.y + CGFloat(viewY)).rounded())
            return 1
        }

        handler.pointee.on_paint = { s, browser, type, dirtyCount, dirtyRects, buffer, width, height in
            cefRelease(browser)
            guard let buffer else { return }
            let element = CefOffscreenPaintElement(cefValue: type)
            let rects = CGRect.array(dirtyRects, count: dirtyCount)
            let frame = CefOffscreenFrame.cpu(buffer: buffer, width: Int(width), height: Int(height), dirtyRects: rects)
            CefBrowserClient.withOffscreenHost(s) { $0.offscreenDidPaint(frame, element: element) }
        }

        handler.pointee.on_accelerated_paint = { s, browser, type, _, _, info in
            cefRelease(browser)
            guard let opaque = info?.pointee.shared_texture_io_surface else { return }
            let element = CefOffscreenPaintElement(cefValue: type)
            let surface = Unmanaged<IOSurfaceRef>.fromOpaque(opaque).takeUnretainedValue()
            let size = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
            CefBrowserClient.withOffscreenHost(s) {
                $0.offscreenDidPaint(.accelerated(surface: surface, size: size), element: element)
            }
        }

        handler.pointee.on_scroll_offset_changed = { s, browser, x, y in
            cefRelease(browser)
            guard let client = cefOwner(CefBrowserClient.self, s) else { return }
            MainActor.assumeIsolated {
                client.primary?.accessibilityScrollOffsetDidChange(CGPoint(x: x, y: y))
            }
        }

        handler.pointee.start_dragging = { s, browser, dragData, allowedOps, x, y in
            cefRelease(browser)
            guard let dragData else { return 0 }
            let data = CefDragData(reading: dragData)
            cefRelease(dragData)
            let operations = CefDragOperation(rawValue: UInt32(allowedOps.rawValue))
            let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
            guard let client = cefOwner(CefBrowserClient.self, s) else { return 0 }
            return MainActor.assumeIsolated {
                guard let host = client.offscreenHost else { return 0 }
                return host.offscreenBeginDraggingSession(data, allowedOperations: operations, at: point) ? 1 : 0
            }
        }

        handler.pointee.update_drag_cursor = { s, browser, operation in
            cefRelease(browser)
            let operation = CefDragOperation(rawValue: UInt32(operation.rawValue))
            CefBrowserClient.withOffscreenHost(s) { $0.offscreenDragOperationDidChange(operation) }
        }

        handler.pointee.on_popup_show = { s, browser, show in
            cefRelease(browser)
            let visible = show != 0
            CefBrowserClient.withOffscreenHost(s) { $0.offscreenPopupDidChangeVisibility(visible) }
        }

        handler.pointee.on_popup_size = { s, browser, rect in
            cefRelease(browser)
            guard let rect else { return }
            let bounds = CGRect(rect.pointee)
            CefBrowserClient.withOffscreenHost(s) { $0.offscreenPopupDidResize(bounds) }
        }

        handler.pointee.on_ime_composition_range_changed = { s, browser, selectedRange, boundsCount, characterBounds in
            cefRelease(browser)
            let range = selectedRange.map { NSRange($0.pointee) } ?? NSRange(location: 0, length: 0)
            let rects = CGRect.array(characterBounds, count: boundsCount)
            CefBrowserClient.withOffscreenHost(s) {
                $0.offscreenDidChangeCompositionRange(range, characterBounds: rects)
            }
        }

        handler.pointee.on_text_selection_changed = { s, browser, selectedText, selectedRange in
            cefRelease(browser)
            let text = CefStringUtil.string(from: selectedText)
            let range = selectedRange.map { NSRange($0.pointee) } ?? NSRange(location: 0, length: 0)
            CefBrowserClient.withOffscreenHost(s) {
                $0.offscreenDidChangeSelection(text, selectedRange: range)
            }
        }

        return handler
    }

    /// The host's geometry, or a 1×1 placeholder once the host is gone.
    private nonisolated static func offscreenViewInfo(
        _ handler: UnsafeMutablePointer<cef_render_handler_t>?
    ) -> CefOffscreenViewInfo {
        guard let client = cefOwner(CefBrowserClient.self, handler) else { return CefOffscreenViewInfo() }
        return MainActor.assumeIsolated { client.offscreenHost?.offscreenViewInfo ?? CefOffscreenViewInfo() }
    }

    /// Runs `body` with the offscreen host, if the client and host still exist.
    private nonisolated static func withOffscreenHost(
        _ handler: UnsafeMutablePointer<cef_render_handler_t>?,
        _ body: @MainActor (CefOffscreenHost) -> Void
    ) {
        guard let client = cefOwner(CefBrowserClient.self, handler) else { return }
        MainActor.assumeIsolated {
            guard let host = client.offscreenHost else { return }
            body(host)
        }
    }
}

extension CefOffscreenPaintElement {
    init(cefValue: cef_paint_element_type_t) {
        self = cefValue == PET_POPUP ? .popup : .view
    }
}

// MARK: - Geometry conversions

extension CGRect {
    init(_ rect: cef_rect_t) {
        self.init(x: CGFloat(rect.x), y: CGFloat(rect.y), width: CGFloat(rect.width), height: CGFloat(rect.height))
    }

    /// Converts a C array of `cef_rect_t`.
    static func array(_ rects: UnsafePointer<cef_rect_t>?, count: Int) -> [CGRect] {
        guard let rects else { return [] }
        return UnsafeBufferPointer(start: rects, count: count).map(CGRect.init)
    }
}

extension NSRange {
    init(_ range: cef_range_t) {
        self.init(location: Int(range.from), length: Int(range.to) - Int(range.from))
    }
}

extension cef_range_t {
    init(_ range: NSRange) {
        self.init(from: UInt32(clamping: range.location), to: UInt32(clamping: range.location + range.length))
    }
}

extension cef_mouse_event_t {
    /// A mouse event at `point`, in view points.
    init(_ point: CGPoint, modifiers: CefEventModifiers) {
        self.init(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), modifiers: modifiers.rawValue)
    }
}
