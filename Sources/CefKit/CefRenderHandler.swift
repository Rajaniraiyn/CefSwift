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
    /// A new frame is ready. The frame is only valid for the duration of this
    /// call (accelerated path returns the surface to CEF's pool afterwards).
    func osrDidPaint(_ frame: CefOSRFrame)
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
}

extension BrowserClient {
    /// Allocates and wires the `cef_render_handler_t` used by OSR browsers.
    /// Only called for browsers created via the OSR factory path; windowed
    /// browsers never set `renderPointer`, so `get_render_handler` returns NULL
    /// and CEF uses its native compositor.
    func makeRenderHandler() {
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
            // Popups (type 1) on the CPU path are composited by the host's own
            // overlay; we forward the view frame (type 0) only for simplicity.
            guard type == PET_VIEW, let buffer else { return }
            var rects: [CGRect] = []
            if let dirtyRects, dirtyCount > 0 {
                for i in 0..<Int(dirtyCount) {
                    let r = dirtyRects[i]
                    rects.append(CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.width), height: CGFloat(r.height)))
                }
            }
            let w = Int(width), h = Int(height)
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrDidPaint(.cpu(buffer: buffer, width: w, height: h, dirtyRects: rects))
            }
        }

        handler.pointee.on_accelerated_paint = { handlerSelf, browser, type, _, _, info in
            cefRelease(browser.map(UnsafeMutableRawPointer.init))
            guard type == PET_VIEW, let info else { return }
            let ioSurfacePtr = info.pointee.shared_texture_io_surface
            guard let ioSurfacePtr else { return }
            let surface = Unmanaged<IOSurfaceRef>.fromOpaque(ioSurfacePtr).takeUnretainedValue()
            let size = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
            BrowserClient.withOSRHost(handlerSelf) { host in
                host.osrDidPaint(.accelerated(surface: surface, size: size))
            }
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
