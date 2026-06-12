import AppKit
import CefKit
import CCef
import Foundation
import UniformTypeIdentifiers

/// Bidirectional drag and drop for the OSR web view.
///
/// - **In (system → page):** the host view is an `NSDraggingDestination`
///   (`registerForDraggedTypes`); drag enter/over/exit/drop build a CEF drag
///   data from the pasteboard and call the host `drag_target_*` methods.
/// - **Out (page → system):** the render handler's `start_dragging` routes to
///   ``osrStartDragging(_:allowedOps:at:)``, which begins an `NSDraggingSession`
///   from the view; session end reports back via `drag_source_ended_at` +
///   `drag_source_system_drag_ended`.
extension CefMetalHostView: NSDraggingSource {

    // MARK: Registration

    func registerDragTypes() {
        registerForDraggedTypes([.string, .html, .fileURL, .URL])
    }

    private func cefMods(_ info: NSDraggingInfo) -> UInt32 {
        CefMetalHostView.cefModifiers(NSEvent.modifierFlags, pressedButtons: 1 << 0)
    }

    private func dipPoint(_ info: NSDraggingInfo) -> CGPoint {
        convert(info.draggingLocation, from: nil)
    }

    // MARK: NSDraggingDestination (system → page)

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let browser = osrBrowser else { return [] }
        let pb = sender.draggingPasteboard
        let text = pb.string(forType: .string)
        let html = pb.string(forType: .html)
        var urls: [URL] = []
        var files: [String] = []
        if let items = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for u in items {
                if u.isFileURL { files.append(u.path) } else { urls.append(u) }
            }
        }
        let allowed = CefDragOperation(sender.draggingSourceOperationMask)
        browser.dragTargetEnter(at: dipPoint(sender), modifiers: cefMods(sender),
                                allowedOps: allowed, text: text, html: html,
                                urls: urls, files: files)
        browser.dragTargetOver(at: dipPoint(sender), modifiers: cefMods(sender), allowedOps: allowed)
        return sender.draggingSourceOperationMask
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let browser = osrBrowser else { return [] }
        let allowed = CefDragOperation(sender.draggingSourceOperationMask)
        browser.dragTargetOver(at: dipPoint(sender), modifiers: cefMods(sender), allowedOps: allowed)
        return sender.draggingSourceOperationMask
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        osrBrowser?.dragTargetLeave()
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let browser = osrBrowser else { return false }
        let allowed = CefDragOperation(sender.draggingSourceOperationMask)
        browser.dragTargetOver(at: dipPoint(sender), modifiers: cefMods(sender), allowedOps: allowed)
        browser.dragTargetDrop(at: dipPoint(sender), modifiers: cefMods(sender))
        return true
    }

    // MARK: CefOSRHost drag callbacks

    public func osrStartDragging(_ data: CefDragData, allowedOps: CefDragOperation, at viewPoint: CGPoint) -> Bool {
        beginPageDrag(data, allowedOps: allowedOps, at: viewPoint)
    }

    public func osrUpdateDragCursor(_ operation: CefDragOperation) {
        // The drag cursor during a page-initiated session is managed by AppKit's
        // dragging session; we keep the page-requested operation for the source
        // mask callback. (Hook left intentionally light — AppKit drives the
        // visible cursor.)
        currentDragAllowedOps = operation == .none ? currentDragAllowedOps : operation
    }

    // MARK: NSDraggingSource (page → system)

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        currentDragAllowedOps.nsOperation
    }

    public func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        guard let browser = osrBrowser else { return }
        // Convert the screen end-point back into view DIP (top-left origin).
        let inWindow = window?.convertPoint(fromScreen: screenPoint) ?? screenPoint
        let viewPoint = convert(inWindow, from: nil)
        browser.dragSourceEndedAt(viewPoint: viewPoint, operation: CefDragOperation(operation))
        browser.dragSourceSystemDragEnded()
        currentDragAllowedOps = .none
    }

    /// Begins a system drag for a page-initiated drag (`start_dragging`).
    func beginPageDrag(_ data: CefDragData, allowedOps: CefDragOperation, at viewPoint: CGPoint) -> Bool {
        let item = NSDraggingItem(pasteboardWriter: data.pasteboardItem)
        // Give the drag a small placeholder image at the start point.
        let frame = NSRect(x: viewPoint.x - 16, y: viewPoint.y - 16, width: 32, height: 32)
        item.setDraggingFrame(frame, contents: nil)
        currentDragAllowedOps = allowedOps
        guard let event = NSApp.currentEvent ?? syntheticDragEvent(at: viewPoint) else { return false }
        beginDraggingSession(with: [item], event: event, source: self)
        return true
    }

    private func syntheticDragEvent(at viewPoint: CGPoint) -> NSEvent? {
        let inWindow = convert(viewPoint, to: nil)
        return NSEvent.mouseEvent(
            with: .leftMouseDragged, location: inWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0)
    }
}

extension CefDragData {
    /// Builds an `NSPasteboardItem` carrying this drag's text/html/url.
    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        if isLink, !linkURL.isEmpty {
            item.setString(linkURL, forType: .URL)
            item.setString(linkURL, forType: .string)
        }
        if !fragmentText.isEmpty {
            item.setString(fragmentText, forType: .string)
        }
        if !fragmentHTML.isEmpty {
            item.setString(fragmentHTML, forType: .html)
        }
        return item
    }
}
