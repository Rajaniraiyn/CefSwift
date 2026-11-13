import CefSwiftUI
import SwiftUI

/// Chromium's own pages, fitted to this browser: `chrome://settings`
/// without what does nothing in an embedded Chromium, an About page of the
/// browser's own (`browser://about/`) in place of Chromium's, and a Browser
/// menu of Chromium's pages.
struct ChromiumPages: BrowserFeature {
    static let about = URL(string: "browser://about/")!

    func start(_ controller: BrowserController) {
        BrowserPages.register(host: "about", AboutPage())
    }

    func configure(_ configuration: inout CefBrowser.Configuration) {
        configuration.userScripts.append(Self.settingsStyle)
    }

    func decidePolicy(for navigation: CefNavigationAction, in browser: CefBrowser) -> CefNavigationDecision? {
        guard let replacement = Self.replacement(for: navigation.url) else { return nil }
        browser.load(replacement)
        return .cancel
    }

    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About CefSwift Browser") { controller.openTab(url: Self.about) }
        }
        CommandMenu("Browser") {
            Button("Extensions") { controller.openTab(url: URL(string: "chrome://extensions")!) }
            Button("Passwords") { controller.openTab(url: URL(string: "chrome://password-manager")!) }
            Button("Chromium Settings") { controller.openTab(url: URL(string: "chrome://settings")!) }
            Button("Flags") { controller.openTab(url: URL(string: "chrome://flags")!) }
            Divider()
            Button("Version Details") { controller.openTab(url: URL(string: "chrome://version")!) }
        }
    }

    /// The page to show instead of one of Chromium's: the browser's About
    /// page for Chromium's, which reports on an updater this browser doesn't
    /// use; and for the settings pages ``settingsStyle`` hides (Chromium's
    /// settings open on "You and Google"), Appearance.
    static func replacement(for url: URL?) -> URL? {
        guard let url, url.scheme == "chrome" else { return nil }
        switch (url.host(), url.path) {
        case ("help", _), ("settings", "/help"):
            return about
        case ("settings", ""), ("settings", "/"), ("settings", "/people"), ("settings", "/syncSetup"),
             ("settings", "/defaultBrowser"):
            return URL(string: "chrome://settings/appearance")
        default:
            return nil
        }
    }

    /// Trims Chromium's settings to what this browser supports. Its About
    /// entry is replaced by the browser's own page; sign-in, sync, "default
    /// browser" and the updater do not exist in an embedded Chromium; and
    /// the Appearance options for Chrome's own toolbar, tab strip, bookmarks
    /// bar and side panel have nothing to act on under the SwiftUI toolbar.
    /// The rules apply inside each settings component's shadow root, so a
    /// selector cannot reach from a component into another's (write
    /// `#themeRow`, not `settings-appearance-page #themeRow`). Rows are
    /// matched by their id or by the preference they edit (`pref-key`),
    /// which are stabler than their position.
    static let settingsStyle = CefUserScript.styleSheet(
        """
        /* Sidebar: About (replaced by browser://about), You and Google, Default browser. */
        #about-menu, a[href="/people"], a[href="/syncSetup"], a[href="/defaultBrowser"],
        /* Their pages: Google sign-in and sync; making this the default browser. */
        settings-people-page-index, settings-default-browser-page,
        /* About page leftovers, should it be reached directly. */
        settings-about-page #updateStatusMessage, settings-about-page #relaunch,
        /* Appearance: Chrome themes and toolbar customization. */
        #themeRow, #toolbarRow,
        /* Home button, bookmarks bar, tab position, and their separators. */
        settings-toggle-button[pref-key="browser.show_home_button"],
        div.hr:has(+ settings-toggle-button[pref-key="browser.show_home_button"]),
        div.hr:has(+ .cr-row > #bookmarksBarVisibilityDropdown),
        .cr-row:has(> #bookmarksBarVisibilityDropdown), .cr-row:has(> #tabStripPosition),
        /* Tab strip buttons and tab groups. */
        #showEverythingMenuButton, #showTabSearchButton, #showSavedTabGroups, #autoPinNewTabGroups,
        /* Side panel position: its heading row and its list. */
        .cr-row:has(+ .list-frame #sidePanelPosition), .list-frame:has(#sidePanelPosition),
        /* Tab hover cards and split view belong to Chrome's tab strip. */
        div.hr:has(+ #hoverCardMemoryUsageToggle), #hoverCardMemoryUsageToggle, #splitViewDragAndDrop,
        /* The browser turns the ⌘Q warning off at every launch. */
        settings-toggle-button[pref-key="browser.confirm_to_quit"]
        { display: none !important }
        """,
        matching: "chrome://settings/*")

    private struct AboutPage: CefSchemeHandler {
        func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
            BrowserPages.html("""
                <title>About CefSwift Browser</title>
                <style>
                  body { min-height: calc(100vh - 80px); display: grid; place-items: center; }
                  main { text-align: center; }
                  .icon { font-size: 64px; }
                </style>
                <main>
                  <div class="icon">🧭</div>
                  <h1>CefSwift Browser</h1>
                  <p id="engine"></p>
                  <p>Built with CefSwift on the Chromium Embedded Framework.</p>
                </main>
                <script>
                  const version = navigator.userAgent.match(/Chrome\\/([\\d.]+)/);
                  document.getElementById('engine').textContent = version ? 'Chromium ' + version[1] : '';
                </script>
                """)
        }
    }
}
