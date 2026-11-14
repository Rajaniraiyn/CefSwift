import AppKit
import Foundation

/// The native menu behind ``CefBrowserDelegate/browser(_:runContextMenu:for:)``:
/// an `NSMenu` of the ``CefContextMenu``, opened as a context menu at the
/// click, with the system's additions such as Services. Call it from your
/// own delegate to keep the stock menu for some clicks.
@MainActor
public enum CefContextMenuPresenter {
    /// Shows `menu` at `target`'s location in `browser`'s view and returns
    /// the item the user chose, or `nil` when the menu closes without a
    /// choice. Cancelling the calling task closes the menu.
    public static func present(
        _ menu: CefContextMenu, for target: CefContextMenuTarget, in browser: CefBrowser
    ) async -> CefContextMenu.Item? {
        guard !Task.isCancelled, let view = contentView(of: browser), let window = view.window else { return nil }
        let nsMenu = makeMenu(for: menu)
        guard !nsMenu.items.isEmpty else { return nil }
        // An offscreen page's points follow the frame as the view shows it.
        let offscreen = view as? CefOffscreenBrowserView
        let point = offscreen.map { $0.windowPoint(fromView: $0.viewPoint(fromPage: target.location)) }
            ?? view.convert(viewPoint(of: target.location, in: view), to: nil)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        // Callers run in a task, after Chromium's callback has returned:
        // Chromium allows no nested run loop inside it, and the menu's
        // tracking is one. Choosing an item sends its action before the
        // menu returns.
        let choice = MenuChoice()
        for item in nsMenu.allItems where item.action != nil { item.target = choice }
        let presented = PresentedMenu(menu: nsMenu)
        await withTaskCancellationHandler {
            if let event {
                NSMenu.popUpContextMenu(nsMenu, with: event, for: view)
            } else {
                nsMenu.popUp(positioning: nil, at: view.convert(point, from: nil), in: view)
            }
        } onCancel: {
            CefDialogPresenter.dismissOnMain { presented.menu.cancelTrackingWithoutAnimation() }
        }
        let chosen = choice.path
        return chosen.flatMap { menu.normalized.item(at: $0) }
    }

    /// An `NSMenu` of `menu`, tidied. Each item's `representedObject` is
    /// its index path in the tidied menu, as an `[Int]`.
    static func makeMenu(for menu: CefContextMenu) -> NSMenu {
        makeMenu(for: menu.normalized, path: [])
    }

    private static func makeMenu(for menu: CefContextMenu, path: [Int]) -> NSMenu {
        let nsMenu = NSMenu()
        nsMenu.autoenablesItems = false
        for (index, item) in menu.items.enumerated() {
            if item.isSeparator {
                nsMenu.addItem(.separator())
                continue
            }
            let nsItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            nsItem.isEnabled = item.isEnabled
            nsItem.state = item.isChecked ? .on : .off
            nsItem.representedObject = path + [index]
            if let submenu = item.submenu {
                nsItem.submenu = makeMenu(for: submenu, path: path + [index])
                nsItem.submenu?.title = item.title
            } else {
                nsItem.action = #selector(MenuChoice.menuItemChosen(_:))
            }
            nsMenu.addItem(nsItem)
        }
        return nsMenu
    }

    /// The view Chromium's page is drawn in, which the menu's point is
    /// relative to: the offscreen host, or Chromium's own view under the
    /// browser's, which takes first responder when clicked.
    static func contentView(of browser: CefBrowser) -> NSView? {
        if browser.isOffscreen { return browser.hostView }
        guard let native = browser.nativeView else { return browser.hostView }
        if let responder = native.window?.firstResponder as? NSView, responder.isDescendant(of: native) {
            return responder
        }
        return native
    }

    /// `location`, in points from the top left of `view`, in `view`'s
    /// coordinates.
    static func viewPoint(of location: CGPoint, in view: NSView) -> NSPoint {
        view.isFlipped ? location : NSPoint(x: location.x, y: view.bounds.height - location.y)
    }
}

/// A menu being shown, for closing it from a cancellation handler.
private struct PresentedMenu: @unchecked Sendable {
    let menu: NSMenu
}

/// Records the item chosen from a presented menu.
@MainActor
private final class MenuChoice: NSObject {
    var path: [Int]?

    @objc func menuItemChosen(_ sender: NSMenuItem) {
        path = sender.representedObject as? [Int]
    }
}

extension NSMenu {
    /// The items of this menu and its submenus.
    fileprivate var allItems: [NSMenuItem] {
        items.flatMap { [$0] + ($0.submenu?.allItems ?? []) }
    }
}
