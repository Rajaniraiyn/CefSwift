import os
import AppKit
import CCef
import Foundation
import CefBase

extension CefBrowserClient {
    // MARK: Context menu

    func makeContextMenuHandler() -> UnsafeMutablePointer<cef_context_menu_handler_t> {
        let h = cefAllocate(cef_context_menu_handler_t.self, owner: self)
        h.pointee.on_before_context_menu = { s, browser, frame, params, model in
            cefRelease(frame)
            defer {
                cefRelease(params)
                cefRelease(model)
            }
            guard let params, let model else {
                cefRelease(browser)
                return
            }
            let target = CefContextMenuTarget(raw: params)
            nonisolated(unsafe) let borrowedModel = model
            CefBrowserClient.run(s, browser, default: ()) { client, b in
                client.contextMenuTarget = target
                CefMenuModel.borrowing(borrowedModel) { menu in
                    b.configuration.contextMenu.apply(to: menu, for: target)
                    b.delegate?.browser(b, configureContextMenu: menu, for: target)
                }
            }
        }
        h.pointee.run_context_menu = { s, browser, frame, params, model, callback in
            cefRelease(frame)
            let point = params.map { CGPoint(x: CGFloat($0.pointee.get_xcoord($0)), y: CGFloat($0.pointee.get_ycoord($0))) }
            cefRelease(params)
            defer { cefRelease(model) }
            guard let model, let callback else {
                cefRelease(browser)
                cefRelease(callback)
                return 0
            }
            // Windowed browsers show Chromium's own menu (return 0 and leave
            // the callback untouched — cancelling it would suppress the menu).
            // Offscreen browsers have no window to show it in, so the host
            // presents a native menu from a snapshot of the model.
            nonisolated(unsafe) let borrowedModel = model
            let handled = CefBrowserClient.run(s, browser, default: false) { client, _ in
                guard let host = client.offscreenHost else { return false }
                // The host reads the model before it returns.
                CefMenuModel.borrowing(borrowedModel) { menu in
                    host.offscreenShowContextMenu(
                        menu, at: point ?? .zero, completion: CefContextMenuCompletion(raw: callback))
                }
                return true
            }
            if !handled { cefRelease(callback) }
            return handled ? 1 : 0
        }
        h.pointee.on_context_menu_command = { s, browser, frame, params, commandID, _ in
            cefRelease(frame)
            let snapshot = params.map { CefContextMenuTarget(raw: $0) }
            cefRelease(params)
            return CefBrowserClient.run(s, browser, default: 0) { client, b in
                let target = snapshot ?? client.contextMenuTarget
                if b.configuration.contextMenu.perform(commandID: Int(commandID), in: b, for: target) { return 1 }
                return (b.delegate?.browser(b, handleContextMenuCommand: Int(commandID), for: target) ?? false) ? 1 : 0
            }
        }
        return h
    }
}

extension CefBrowserClient {
    // MARK: Chrome commands and UI

    func makeCommandHandler() -> UnsafeMutablePointer<cef_command_handler_t> {
        let h = cefAllocate(cef_command_handler_t.self, owner: self)
        h.pointee.on_chrome_command = { s, browser, commandID, disposition in
            let command = CefChromeCommand(rawValue: Int(commandID))
            let disposition = CefWindowOpenDisposition(cefValue: disposition)
            return CefBrowserClient.run(s, browser, default: 0) { _, b in
                b.handleChromeCommand(command, disposition: disposition) ? 1 : 0
            }
        }
        h.pointee.is_chrome_app_menu_item_visible = { s, browser, commandID in
            CefBrowserClient.run(s, browser, default: 1) { client, _ in
                client.chromeToolbar.hiddenAppMenuCommands.contains(CefChromeCommand(rawValue: Int(commandID))) ? 0 : 1
            }
        }
        h.pointee.is_chrome_app_menu_item_enabled = { s, browser, commandID in
            CefBrowserClient.run(s, browser, default: 1) { client, _ in
                client.chromeToolbar.disabledAppMenuCommands.contains(CefChromeCommand(rawValue: Int(commandID))) ? 0 : 1
            }
        }
        h.pointee.is_chrome_page_action_icon_visible = { s, _ in
            guard let client = cefOwner(CefBrowserClient.self, s) else { return 1 }
            return MainActor.assumeIsolated { client.chromeToolbar.showsPageActionIcons ? 1 : 0 }
        }
        h.pointee.is_chrome_toolbar_button_visible = { s, _ in
            guard let client = cefOwner(CefBrowserClient.self, s) else { return 1 }
            return MainActor.assumeIsolated { client.chromeToolbar.showsToolbarButtons ? 1 : 0 }
        }
        return h
    }
}
