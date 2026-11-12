import AppKit
import CefKit
import Foundation

// Drag and drop in both directions: drags from other apps are passed to the
// page as drag-target events, and drags the page starts become AppKit
// dragging sessions whose outcome is reported back to it.
extension CefOffscreenBrowserView: NSDraggingSource {

    func registerDragTypes() {
        registerForDraggedTypes([.string, .html, .fileURL, .URL])
    }

    /// Modifiers for drag events, which always have the left button down.
    private var dragModifiers: CefEventModifiers {
        Self.eventModifiers(NSEvent.modifierFlags, pressedButtons: 1 << 0)
    }

    private func viewPoint(for info: NSDraggingInfo) -> CGPoint {
        convert(info.draggingLocation, from: nil)
    }

    // MARK: Drags into the page

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let browser else { return [] }
        let pasteboard = sender.draggingPasteboard
        var urls: [URL] = []
        var fileURLs: [URL] = []
        for url in pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [] {
            if url.isFileURL { fileURLs.append(url) } else { urls.append(url) }
        }
        let allowed = CefDragOperation(sender.draggingSourceOperationMask)
        browser.draggingEntered(
            at: viewPoint(for: sender), modifiers: dragModifiers, allowedOperations: allowed,
            text: pasteboard.string(forType: .string), html: pasteboard.string(forType: .html),
            urls: urls, fileURLs: fileURLs)
        browser.draggingUpdated(at: viewPoint(for: sender), modifiers: dragModifiers, allowedOperations: allowed)
        return sender.draggingSourceOperationMask
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let browser else { return [] }
        browser.draggingUpdated(
            at: viewPoint(for: sender), modifiers: dragModifiers,
            allowedOperations: CefDragOperation(sender.draggingSourceOperationMask))
        return sender.draggingSourceOperationMask
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        browser?.draggingExited()
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let browser else { return false }
        browser.draggingUpdated(
            at: viewPoint(for: sender), modifiers: dragModifiers,
            allowedOperations: CefDragOperation(sender.draggingSourceOperationMask))
        browser.performDrop(at: viewPoint(for: sender), modifiers: dragModifiers)
        return true
    }

    // MARK: Drags out of the page

    public func offscreenBeginDraggingSession(_ data: CefDragData, allowedOperations: CefDragOperation, at point: CGPoint) -> Bool {
        guard let event = NSApp.currentEvent ?? syntheticDragEvent(at: point) else { return false }
        let item = NSDraggingItem(pasteboardWriter: data.pasteboardItem)
        item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: nil)
        currentDragAllowedOperations = allowedOperations
        beginDraggingSession(with: [item], event: event, source: self)
        return true
    }

    public func offscreenDragOperationDidChange(_ operation: CefDragOperation) {
        // AppKit draws the drag cursor; keep the page's operation for the
        // session's operation mask.
        if operation != .none {
            currentDragAllowedOperations = operation
        }
    }

    public func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        NSDragOperation(currentDragAllowedOperations)
    }

    public func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        currentDragAllowedOperations = .none
        guard let browser else { return }
        let inWindow = window?.convertPoint(fromScreen: screenPoint) ?? screenPoint
        browser.draggingSessionEnded(at: convert(inWindow, from: nil), operation: CefDragOperation(operation))
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
        if isLink, let linkURL {
            item.setString(linkURL.absoluteString, forType: .URL)
            item.setString(linkURL.absoluteString, forType: .string)
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
