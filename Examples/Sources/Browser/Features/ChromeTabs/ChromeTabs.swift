import CefSwiftUI

/// Tabs Chromium opens itself — following a link from `chrome://settings`
/// to the password manager, for instance — shown as the browser's own tabs
/// in the same profile (`CefRuntime.onChromeTab`) instead of in Chrome's
/// window.
struct ChromeTabs: BrowserFeature {
    func start(_ controller: BrowserController) {
        CefRuntime.shared.onChromeTab = { [weak controller] request in
            // A profile Chromium made itself, such as its own incognito
            // one, stays in Chromium's window.
            guard let controller, request.profile != nil else { return .showInChromeWindow }
            controller.openTab(
                url: request.url, inBackground: !request.disposition.prefersForeground,
                sharingProfileOf: request.opener ?? request.browser)
            return .close
        }
    }
}
