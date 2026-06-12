import AppKit
import CefKit
import Foundation

/// Presents CEF's context menu as a native `NSMenu` for the offscreen browser,
/// so right-click feels identical to a native control.
extension CefMetalHostView {

    public func osrRunContextMenu(_ menu: CefMenuModel, at viewPoint: CGPoint, callback: CefRunContextMenuCallback) {
        // IMPORTANT: CEF forbids running an OS modal message loop *inside* this
        // callback (only start_dragging may). So we snapshot the menu items
        // synchronously, then present the NSMenu on the next runloop tick and
        // resolve the callback then. We return having retained the callback.
        struct Item { let label: String; let commandID: Int; let isSeparator: Bool }
        var items: [Item] = []
        for i in 0..<menu.count {
            if menu.isSeparator(at: i) {
                items.append(Item(label: "", commandID: -1, isSeparator: true))
            } else {
                let label = menu.label(at: i).replacingOccurrences(of: "&", with: "")
                guard !label.isEmpty else { continue }
                items.append(Item(label: label, commandID: menu.commandID(at: i), isSeparator: false))
            }
        }
        guard !items.isEmpty else {
            callback.cancel()
            return
        }

        pendingContextMenuCallback = callback
        let location = NSPoint(x: viewPoint.x, y: viewPoint.y)

        DispatchQueue.main.async { [weak self] in
            guard let self else { callback.cancel(); return }
            let nsMenu = NSMenu()
            nsMenu.autoenablesItems = false
            for item in items {
                if item.isSeparator {
                    nsMenu.addItem(.separator())
                    continue
                }
                let mi = NSMenuItem(title: item.label, action: #selector(self.contextMenuItemSelected(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = item.commandID
                nsMenu.addItem(mi)
            }
            nsMenu.popUp(positioning: nil, at: location, in: self)
            // popUp is modal; the action selector resolved the callback if an
            // item was chosen. Otherwise cancel.
            if let cb = self.pendingContextMenuCallback {
                cb.cancel()
                self.pendingContextMenuCallback = nil
            }
        }
    }

    @objc private func contextMenuItemSelected(_ sender: NSMenuItem) {
        guard let cb = pendingContextMenuCallback else { return }
        cb.select(commandID: sender.tag)
        pendingContextMenuCallback = nil
    }
}
