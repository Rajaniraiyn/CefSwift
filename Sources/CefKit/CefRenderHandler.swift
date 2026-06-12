import AppKit
import CCef
import Foundation
import IOSurface

/// A single offscreen-rendered frame delivered by CEF's render handler.
///
/// The accelerated path (``accelerated``) carries a shared `IOSurface` that the
/// host should set as a layer's `contents` (or blit via Metal) within the
/// callback's lifetime — CEF returns the surface to its pool after the sink
/// returns, so do not retain it past the call. The CPU path (``cpu``) carries a
/// BGRA byte buffer (upper-left origin) only used when shared textures are
/// unavailable.
@MainActor
public enum CefOSRFrame {
    /// A GPU frame: a shared `IOSurface` Chromium rendered into. `size` is in
    /// device pixels. Set it as `CALayer.contents` inside the sink.
    case accelerated(surface: IOSurfaceRef, size: CGSize)
    /// A CPU frame: BGRA8 pixels (`width`*`height`*4 bytes, upper-left origin).
    case cpu(buffer: UnsafeRawPointer, width: Int, height: Int, dirtyRects: [CGRect])
}

/// Which compositing surface an OSR frame targets. Alloy OSR renders form
/// widgets (the `<select>` dropdown, autofill) as a *separate* paint element
/// (``popup``) so the host can composite it above the page content.
public enum CefOSRPaintElement: Sendable {
    /// The main page content (`PET_VIEW`).
    case view
    /// The popup widget such as a `<select>` dropdown (`PET_POPUP`).
    case popup
}

/// The geometry an OSR host advertises to CEF: the logical (DIP) view size and
/// the backing scale factor for retina. The host updates this on layout/scale
/// changes and calls ``CefBrowser/wasResized()`` /
/// ``CefBrowser/notifyScreenInfoChanged()``.
public struct CefOSRViewInfo: Sendable {
    /// Logical view size in DIP (points).
    public var sizeDIP: CGSize
    /// Device scale factor (e.g. 2.0 on retina).
    public var deviceScaleFactor: CGFloat
    /// Origin of the view in screen DIP coordinates (top-left). Used by CEF to
    /// place popups (e.g. `<select>` dropdowns) and for screen-point queries.
    public var screenOriginDIP: CGPoint
    /// Full screen rectangle in DIP, used for popup clamping.
    public var screenRectDIP: CGRect

    public init(
        sizeDIP: CGSize = CGSize(width: 1, height: 1),
        deviceScaleFactor: CGFloat = 1,
        screenOriginDIP: CGPoint = .zero,
        screenRectDIP: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        self.sizeDIP = sizeDIP
        self.deviceScaleFactor = deviceScaleFactor
        self.screenOriginDIP = screenOriginDIP
        self.screenRectDIP = screenRectDIP
    }
}

/// The host's contract for an offscreen browser: supplies geometry to CEF and
/// receives painted frames, cursor changes, popup geometry, and IME ranges.
///
/// Implemented by ``CefMetalHostView`` in CefSwiftUI; CEF invokes the
/// callbacks on the UI thread (== main thread under the external pump).
@MainActor
public protocol CefOSRHost: AnyObject {
    /// Current view geometry CEF should render at.
    var osrViewInfo: CefOSRViewInfo { get }
    /// A new frame is ready for `element`. The frame is only valid for the
    /// duration of this call (accelerated path returns the surface to CEF's
    /// pool afterwards). `.view` frames go to the content layer; `.popup`
    /// frames go to the popup overlay layer.
    func osrDidPaint(_ frame: CefOSRFrame, element: CefOSRPaintElement)
    /// The page requested a cursor change.
    func osrDidChangeCursor(_ cursor: CefCursorType)
    /// The popup widget (e.g. `<select>` dropdown) should show/hide.
    func osrPopupDidChangeVisibility(_ visible: Bool)
    /// The popup widget moved/resized to `rect` (view DIP coordinates).
    func osrPopupDidResize(_ rect: CGRect)
    /// The IME composition range changed; `bounds` are character rects in view
    /// DIP coordinates (used to position the candidate window).
    func osrImeCompositionRangeChanged(selectedRange: NSRange, characterBounds: [CGRect])
    /// Text selection changed (used by NSTextInputClient for `selectedRange`).
    func osrTextSelectionChanged(selectedText: String, selectedRange: NSRange)
    /// The page requested a context menu. The host should present a native
    /// `NSMenu` built from `menu` at `viewPoint` (view DIP) and report the
    /// chosen command (or cancellation) through `callback`.
    func osrRunContextMenu(_ menu: CefMenuModel, at viewPoint: CGPoint, callback: CefRunContextMenuCallback)

    /// The page started a drag (page → system). The host should begin an
    /// `NSDraggingSession` carrying `data`, and on completion call back through
    /// ``CefBrowser/dragSourceEndedAt(viewPoint:operation:)`` +
    /// ``CefBrowser/dragSourceSystemDragEnded()``. Return `false` to abort.
    func osrStartDragging(_ data: CefDragData, allowedOps: CefDragOperation, at viewPoint: CGPoint) -> Bool

    /// The drag cursor should reflect `operation` during an in-progress drag.
    func osrUpdateDragCursor(_ operation: CefDragOperation)

    /// The accessibility tree changed. `value` is CEF's serialized AX tree
    /// (a nested dictionary/list snapshot). Delivered only when accessibility
    /// has been enabled via ``CefBrowser/setAccessibilityEnabled(_:)``.
    func osrAccessibilityTreeDidChange(_ value: CefAXValue)

    /// An accessibility node's location changed.
    func osrAccessibilityLocationDidChange(_ value: CefAXValue)
}

// Default no-ops so existing hosts (and tests) need not implement every method.
extension CefOSRHost {
    public func osrStartDragging(_ data: CefDragData, allowedOps: CefDragOperation, at viewPoint: CGPoint) -> Bool { false }
    public func osrUpdateDragCursor(_ operation: CefDragOperation) {}
    public func osrAccessibilityTreeDidChange(_ value: CefAXValue) {}
    public func osrAccessibilityLocationDidChange(_ value: CefAXValue) {}
}

extension BrowserClient {
    /// Allocates and wires the `cef_render_handler_t` used by OSR browsers.
    /// Only called for browsers created via the OSR factory path; windowed
    /// browsers never set `renderPointer`, so `get_render_handler` returns NULL
    /// and CEF uses its native compositor.
    func makeRenderHandler() {
        makeAccessibilityHandler()
        let handler = cefAllocate(cef_render_handler_t.self, owner: self)

        handler.pointee.get_view_rect = { handlerSelf, browser, rect in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let rect else { return }
            let info = BrowserClient.osrHostInfo(handlerSelf)
            // CEF requires a non-empty rect; clamp to >= 1.
            rect.pointee = cef_rect_t(
                x: 0, y: 0,
                width: Int32(max(1, info.sizeDIP.width.rounded())),
                height: Int32(max(1, info.sizeDIP.height.rounded()))
            )
        }

        handler.pointee.get_screen_info = { handlerSelf, browser, screenInfo in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let screenInfo else { return 0 }
            let info = BrowserClient.osrHostInfo(handlerSelf)
            screenInfo.pointee.device_scale_factor = Float(info.deviceScaleFactor)
            screenInfo.pointee.depth = 24
            screenInfo.pointee.depth_per_component = 8
            screenInfo.pointee.is_monochrome = 0
            let screen = cef_rect_t(
                x: Int32(info.screenRectDIP.origin.x.rounded()),
                y: Int32(info.screenRectDIP.origin.y.rounded()),
                width: Int32(max(1, info.screenRectDIP.size.width.rounded())),
                height: Int32(max(1, info.screenRectDIP.size.height.rounded()))
            )
            screenInfo.pointee.rect = screen
            screenInfo.pointee.available_rect = screen
            return 1
        }

        handler.pointee.get_screen_point = { handlerSelf, browser, viewX, viewY, screenX, screenY in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let screenX, let screenY else { return 0 }
            let info = BrowserClient.osrHostInfo(handlerSelf)
            // macOS expects screen DIP coordinates.
            screenX.pointee = Int32((info.screenOriginDIP.x + CGFloat(viewX)).rounded())
            screenY.pointee = Int32((info.screenOriginDIP.y + CGFloat(viewY)).rounded())
            return 1
        }

        handler.pointee.on_paint = { handlerSelf, browser, type, dirtyCount, dirtyRects, buffer, width, height in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            // Both PET_VIEW (page) and PET_POPUP (e.g. <select> dropdown) frames
            // are forwarded; the host routes each to the right CALayer.
            guard let buffer else { return }
            let element: CefOSRPaintElement = (type == PET_POPUP) ? .popup : .view
            var rects: [CGRect] = []
            if let dirtyRects, dirtyCount > 0 {
                for i in 0..<Int(dirtyCount) {
                    let r = dirtyRects[i]
                    rects.append(CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.width), height: CGFloat(r.height)))
                }
            }
            let w = Int(width), h = Int(height)
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrDidPaint(.cpu(buffer: buffer, width: w, height: h, dirtyRects: rects), element: element)
            }
        }

        handler.pointee.on_accelerated_paint = { handlerSelf, browser, type, _, _, info in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let info else { return }
            let element: CefOSRPaintElement = (type == PET_POPUP) ? .popup : .view
            let ioSurfacePtr = info.pointee.shared_texture_io_surface
            guard let ioSurfacePtr else { return }
            let surface = Unmanaged<IOSurfaceRef>.fromOpaque(ioSurfacePtr).takeUnretainedValue()
            let size = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrDidPaint(.accelerated(surface: surface, size: size), element: element)
            }
        }

        handler.pointee.start_dragging = { handlerSelf, browser, dragData, allowedOps, x, y in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let dragData else { return 0 }
            // start_dragging hands us a +1 drag_data ref; snapshot then release.
            let snapshot = CefDragData(reading: dragData)
            cefRelease(UnsafeMutableRawPointer(dragData))
            let ops = CefDragOperation(rawValue: UInt32(allowedOps.rawValue))
            let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
            guard let client = cefOwner(BrowserClient.self, handlerSelf.map(UnsafeMutableRawPointer.init)) else { return 0 }
            return MainActor.assumeIsolated {
                guard let host = client.osrHost else { return 0 }
                return host.osrStartDragging(snapshot, allowedOps: ops, at: point) ? 1 : 0
            }
        }

        handler.pointee.update_drag_cursor = { handlerSelf, browser, operation in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            let op = CefDragOperation(rawValue: UInt32(operation.rawValue))
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrUpdateDragCursor(op)
            }
        }

        handler.pointee.get_accessibility_handler = { handlerSelf in
            guard let client = cefOwner(BrowserClient.self, handlerSelf.map(UnsafeMutableRawPointer.init)),
                  let ax = client.accessibilityPointer else { return nil }
            cefAddRef(UnsafeMutableRawPointer(ax))
            return ax
        }

        handler.pointee.on_popup_show = { handlerSelf, browser, show in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            let visible = show != 0
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrPopupDidChangeVisibility(visible)
            }
        }

        handler.pointee.on_popup_size = { handlerSelf, browser, rect in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard let rect else { return }
            let cg = CGRect(x: CGFloat(rect.pointee.x), y: CGFloat(rect.pointee.y),
                            width: CGFloat(rect.pointee.width), height: CGFloat(rect.pointee.height))
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrPopupDidResize(cg)
            }
        }

        handler.pointee.on_ime_composition_range_changed = { handlerSelf, browser, selectedRange, boundsCount, charBounds in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            let range = selectedRange.map { NSRange(location: Int($0.pointee.from), length: Int($0.pointee.to) - Int($0.pointee.from)) } ?? NSRange(location: 0, length: 0)
            var rects: [CGRect] = []
            if let charBounds, boundsCount > 0 {
                for i in 0..<Int(boundsCount) {
                    let r = charBounds[i]
                    rects.append(CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.width), height: CGFloat(r.height)))
                }
            }
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrImeCompositionRangeChanged(selectedRange: range, characterBounds: rects)
            }
        }

        handler.pointee.on_text_selection_changed = { handlerSelf, browser, selectedText, selectedRange in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            let text = CefStringUtil.string(from: selectedText)
            let range = selectedRange.map { NSRange(location: Int($0.pointee.from), length: Int($0.pointee.to) - Int($0.pointee.from)) } ?? NSRange(location: 0, length: 0)
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrTextSelectionChanged(selectedText: text, selectedRange: range)
            }
        }

        // on_cursor_change lives on the display handler (set up in makeClient);
        // the existing handler already routes to the delegate, and the OSR host
        // is also the delegate, so cursor changes arrive there.

        renderPointer = handler
    }

    /// Reads the host's current geometry, or a 1x1 fallback if the host is gone
    /// (CEF may call get_view_rect from non-main contexts during teardown).
    nonisolated static func osrHostInfo(_ handlerSelf: UnsafeMutableRawPointer?) -> CefOSRViewInfo {
        guard let client = cefOwner(BrowserClient.self, handlerSelf) else { return CefOSRViewInfo() }
        return MainActor.assumeIsolated { client.osrHost?.osrViewInfo ?? CefOSRViewInfo() }
    }

    /// Runs `body` with the OSR host on the main actor when both client and
    /// host are alive.
    nonisolated static func withOSRHost(_ handlerSelf: UnsafeMutableRawPointer?, _ body: @MainActor (CefOSRHost) -> Void) {
        guard let client = cefOwner(BrowserClient.self, handlerSelf) else { return }
        MainActor.assumeIsolated {
            guard let host = client.osrHost else { return }
            body(host)
        }
    }
}
