import os
import AppKit
import CCef
import Foundation
import CefBase

extension CefBrowserClient {
    // MARK: Chrome commands and UI

    func makeCommandHandler() -> UnsafeMutablePointer<cef_command_handler_t> {
        let h = cefAllocate(cef_command_handler_t.self, owner: self)
        h.pointee.on_chrome_command = { s, browser, commandID, disposition in
            let command = CefChromeCommand(rawValue: Int(commandID))
            let disposition = CefWindowOpenDisposition(cefValue: disposition)
            // Handled, so that Chromium does not run it and end the browser process.
            if CefChromeCommand.endingTheBrowserProcess.contains(command.rawValue) {
                cefRelease(browser)
                return 1
            }
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
