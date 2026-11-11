import AppKit
import CefKit
import CCef
import Foundation

// Drag and drop in both directions: drags from other apps are passed to the
// page as drag-target events, and drags the page starts become AppKit
// dragging sessions whose outcome is reported back to it.
extension CefOffscreenBrowserView: NSDraggingSource {

    func registerDragTypes() {
        registerForDraggedTypes([.string, .html, .fileURL, .URL])
    }

    /// Modifiers for drag events, which always have the left button down.
    private var dragModifiers: UInt32 {
        Self.cefModifiers(NSEvent.modifierFlags, pressedButtons: 1 << 0)
    }

    private func dipPoint(for info: NSDraggingInfo) -> CGPoint {
        convert(info.draggingLocation, from: nil)
    }

    // MARK: Drags into the page

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let browser else { return [] }
        let pasteboard = sender.draggingPasteboard
        var urls: [URL] = []
        var files: [String] = []
        for url in pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [] {
            if url.isFileURL { files.append(url.path) } else { urls.append(url) }
        }
        let allowed = CefDragOperation(sender.draggingSourceOperationMask)
        browser.dragTargetEnter(
            at: dipPoint(for: sender), modifiers: dragModifiers, allowedOps: allowed,
            text: pasteboard.string(forType: .string), html: pasteboard.string(forType: .html),
            urls: urls, files: files)
        browser.dragTargetOver(at: dipPoint(for: sender), modifiers: dragModifiers, allowedOps: allowed)
        return sender.draggingSourceOperationMask
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let browser else { return [] }
        browser.dragTargetOver(
            at: dipPoint(for: sender), modifiers: dragModifiers,
            allowedOps: CefDragOperation(sender.draggingSourceOperationMask))
        return sender.draggingSourceOperationMask
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        browser?.dragTargetLeave()
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let browser else { return false }
        browser.dragTargetOver(
            at: dipPoint(for: sender), modifiers: dragModifiers,
            allowedOps: CefDragOperation(sender.draggingSourceOperationMask))
        browser.dragTargetDrop(at: dipPoint(for: sender), modifiers: dragModifiers)
        return true
    }

    // MARK: Drags out of the page

    public func offscreenStartDragging(_ data: CefDragData, allowedOps: CefDragOperation, at viewPoint: CGPoint) -> Bool {
        guard let event = NSApp.currentEvent ?? syntheticDragEvent(at: viewPoint) else { return false }
        let item = NSDraggingItem(pasteboardWriter: data.pasteboardItem)
        item.setDraggingFrame(NSRect(x: viewPoint.x - 16, y: viewPoint.y - 16, width: 32, height: 32), contents: nil)
        currentDragAllowedOps = allowedOps
        beginDraggingSession(with: [item], event: event, source: self)
        return true
    }

    public func offscreenUpdateDragCursor(_ operation: CefDragOperation) {
        // AppKit draws the drag cursor; keep the page's operation for the
        // session's operation mask.
        if operation != .none {
            currentDragAllowedOps = operation
        }
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        currentDragAllowedOps.nsOperation
    }

    public func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        currentDragAllowedOps = .none
        guard let browser else { return }
        let inWindow = window?.convertPoint(fromScreen: screenPoint) ?? screenPoint
        browser.dragSourceEndedAt(viewPoint: convert(inWindow, from: nil), operation: CefDragOperation(operation))
        browser.dragSourceSystemDragEnded()
    }

    private func syntheticDragEvent(at viewPoint: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .leftMouseDragged, location: convert(viewPoint, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }
}

extension CefDragData {
    /// A pasteboard item carrying the dragged link, text and HTML.
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
