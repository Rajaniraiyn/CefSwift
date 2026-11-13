import AppKit
import Foundation

extension CefOffscreenBrowserView {

    public func offscreenShowContextMenu(_ menu: CefMenuModel, at point: CGPoint, completion: CefContextMenuCompletion) {
        // Chromium does not allow a nested run loop inside this callback, so
        // the menu is read now and shown on the next turn of the run loop.
        let menuItems: [NSMenuItem] = (0..<menu.count).compactMap { index in
            if menu.isSeparator(at: index) { return .separator() }
            let title = Self.menuTitle(fromCefTitle: menu.title(at: index))
            guard !title.isEmpty else { return nil }
            let item = NSMenuItem(title: title, action: #selector(contextMenuItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = menu.commandID(at: index)
            return item
        }
        guard !menuItems.isEmpty else {
            completion.cancel()
            return
        }

        pendingContextMenuCompletion = completion
        DispatchQueue.main.async { [weak self] in
            guard let self else { return completion.cancel() }
            let nsMenu = NSMenu()
            nsMenu.autoenablesItems = false
            nsMenu.items = menuItems
            nsMenu.popUp(positioning: nil, at: point, in: self)
            // `popUp` returns once the menu closes; an unanswered completion
            // means nothing was chosen.
            self.pendingContextMenuCompletion?.cancel()
            self.pendingContextMenuCompletion = nil
        }
    }

    /// Chromium marks mnemonics with `&` and writes a literal ampersand as `&&`.
    static func menuTitle(fromCefTitle title: String) -> String {
        title.components(separatedBy: "&&")
            .map { $0.replacingOccurrences(of: "&", with: "") }
            .joined(separator: "&")
    }

    @objc private func contextMenuItemSelected(_ sender: NSMenuItem) {
        pendingContextMenuCompletion?.select(commandID: sender.tag)
        pendingContextMenuCompletion = nil
    }
}
