import AppKit
import CefSwiftUI
import SwiftUI

/// Owns the browser's tabs. Each tab is one ``CefBrowserWindow``; macOS
/// groups them into a native tab bar.
@MainActor
@Observable
final class BrowserController: CefBrowserDelegate {
    static let defaultHomePage = "https://duckduckgo.com"

    private(set) var windows: [CefBrowserWindow] = []
    /// Incremented to ask the frontmost address bar to take focus.
    private(set) var addressBarFocusRequest = 0

    /// The browser in the frontmost tab.
    var current: CefBrowser? {
        windows.first { $0.nsWindow?.isKeyWindow == true }?.browser ?? windows.last?.browser
    }

    private var homePage: URL {
        URL(string: UserDefaults.standard.string(forKey: "homePage") ?? Self.defaultHomePage)
            ?? URL(string: Self.defaultHomePage)!
    }

    @discardableResult
    func openTab(url: URL? = nil, isPrivate: Bool = false, inBackground: Bool = false) -> CefBrowser {
        var options = CefBrowserOptions()
        options.profile = isPrivate ? .incognito() : .default
        options.contextMenu.showsInspectElement = true
        options.contextMenu.hiddenCommands = [.viewSource]
        options.contextMenu.items = [
            CefContextMenuItem("Open Link in New Tab", isVisible: { $0.linkURL != nil }) { [weak self] _, target in
                self?.openTab(url: target.linkURL, inBackground: true)
            },
            CefContextMenuItem("Create QR Code for This Page", isVisible: { $0.linkURL == nil && !$0.isEditable }) { browser, _ in
                browser.execute(.createQRCode)
            },
        ]
        let browser = CefBrowser(url: url ?? homePage, options: options, delegate: self)

        var configuration = CefBrowserWindow.Configuration()
        configuration.tabbingIdentifier = "browser"
        configuration.frame = windows.last?.nsWindow?.frame
        let window = CefBrowserWindow(browser: browser, configuration: configuration)
        window.setToolbar { BrowserToolbar(browser: browser, controller: self, isPrivate: isPrivate) }
        window.onClose = { [weak self, weak window] in
            self?.windows.removeAll { $0 === window }
        }
        windows.append(window)

        if let key = NSApp.keyWindow, let new = window.nsWindow, key.tabbingIdentifier == "browser" {
            key.addTabbedWindow(new, ordered: .above)
            if !inBackground { new.makeKeyAndOrderFront(nil) }
        } else {
            window.show()
        }
        return browser
    }

    /// Chromium sometimes opens a window of its own — following a link from
    /// `chrome://settings` to the password manager, for instance. Those
    /// arrive with Chrome's tab strip and toolbar; reopen them as tabs here.
    func adoptWindowsOpenedByChromium() {
        CefRuntime.shared.onBrowserCreated = { [weak self] browser in
            // Popups and DevTools have an opener and keep their own windows.
            guard browser.opener == nil else { return }
            Task {
                for _ in 0..<80 where browser.url == nil {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                let url = browser.url
                browser.close(force: true)
                self?.openTab(url: url)
            }
        }
    }

    func focusAddressBar() {
        addressBarFocusRequest += 1
    }

    // MARK: CefBrowserDelegate

    func browser(_ browser: CefBrowser, decideWindowOpenFor request: CefWindowOpenRequest) -> CefWindowOpenAction {
        // Real popups (sign-in windows and the like) keep Chromium's handling.
        guard request.disposition != .newPopup, let url = request.targetURL else { return .allowNativePopup }
        openTab(url: url, inBackground: request.disposition == .newBackgroundTab)
        return .handled
    }

    func browser(_ browser: CefBrowser, handleChromeCommand command: CefChromeCommand, disposition: CefWindowOpenDisposition) -> Bool {
        switch command {
        case .newTab:
            openTab()
            return true
        case .focusLocation:
            focusAddressBar()
            return true
        default:
            return false
        }
    }

    func browser(_ browser: CefBrowser, decidePermission request: CefPermissionRequest) async -> CefPermissionDecision {
        let alert = NSAlert()
        alert.messageText = "Allow \(request.origin) to use \(request.kinds.summary)?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        guard let window = browser.hostWindow else { return .deny }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? .allow : .deny
    }
}

extension CefPermissionKind {
    var summary: String {
        let names: [(CefPermissionKind, String)] = [
            (.camera, "the camera"), (.microphone, "the microphone"), (.geolocation, "your location"),
            (.notifications, "notifications"), (.clipboard, "the clipboard"),
        ]
        let matched = names.filter { contains($0.0) }.map(\.1)
        return matched.isEmpty ? "additional features" : matched.formatted(.list(type: .and))
    }
}
