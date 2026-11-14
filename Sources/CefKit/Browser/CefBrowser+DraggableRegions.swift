import AppKit
import CCef
import CefBase
import Foundation

extension CefBrowser {
    /// A part of the page that moves its window when dragged, or that is
    /// exempt from one that does: what the page declares with the CSS
    /// property `-webkit-app-region: drag` (or `no-drag`).
    public struct DraggableRegion: Sendable, Equatable {
        /// Where the region is, in the page's view points, top-left origin.
        public var frame: CGRect
        /// Whether dragging there moves the window: `false` for a `no-drag`
        /// region, such as a button inside a draggable title bar.
        public var isDraggable: Bool

        /// Creates a value of your own, for previews and tests.
        public init(frame: CGRect, isDraggable: Bool) {
            self.frame = frame
            self.isDraggable = isDraggable
        }
    }

    /// Whether dragging at `point` (view points, top-left origin) moves the
    /// window: the last of ``draggableRegions`` that contains it decides,
    /// as Chromium orders them (a `no-drag` region inside a `drag` one
    /// comes after it).
    public func isDraggable(at point: CGPoint) -> Bool {
        Self.isDraggable(at: point, in: draggableRegions)
    }

    static func isDraggable(at point: CGPoint, in regions: [DraggableRegion]) -> Bool {
        regions.last { $0.frame.contains(point) }?.isDraggable ?? false
    }

    /// Moves the host's window with the mouse, as its title bar would, when
    /// `event` is a left mouse-down at `point` (view points, top-left
    /// origin) in a draggable region; a double click there zooms or
    /// minimizes the window, as the user's "Double-click a window's title
    /// bar" setting says. Returns whether the page's region took the event,
    /// which then does not reach the page. The host views call this.
    func handleWindowDrag(_ event: NSEvent, at point: CGPoint) -> Bool {
        guard event.type == .leftMouseDown, !draggableRegions.isEmpty, isDraggable(at: point),
              let window = event.window
        else { return false }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
            return true
        }
        window.performDrag(with: event)
        return true
    }
}

extension CefBrowserClient {
    func makeDragHandler() -> UnsafeMutablePointer<cef_drag_handler_t> {
        let h = cefAllocate(cef_drag_handler_t.self, owner: self)
        // Drags into the page keep Chromium's handling.
        h.pointee.on_drag_enter = { _, browser, dragData, _ in
            cefRelease(browser)
            cefRelease(dragData)
            return 0
        }
        h.pointee.on_draggable_regions_changed = { s, browser, frame, count, regions in
            let isMain = frame.map { $0.pointee.is_main($0) != 0 } ?? true
            cefRelease(frame)
            var value: [CefBrowser.DraggableRegion] = []
            if let regions, isMain {
                for region in UnsafeBufferPointer(start: regions, count: count) {
                    value.append(CefBrowser.DraggableRegion(
                        frame: CGRect(
                            x: CGFloat(region.bounds.x), y: CGFloat(region.bounds.y),
                            width: CGFloat(region.bounds.width), height: CGFloat(region.bounds.height)),
                        isDraggable: region.draggable != 0))
                }
            }
            CefBrowserClient.run(s, browser, default: ()) { _, b in
                guard isMain, b.draggableRegions != value else { return }
                b.draggableRegions = value
            }
        }
        return h
    }
}
