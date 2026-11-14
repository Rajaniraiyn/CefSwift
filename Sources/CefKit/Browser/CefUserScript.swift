import AppKit
import CCef
import Foundation
import Observation
import CefBase

/// A script injected into every document a browser loads, before the page's
/// own scripts run.
///
/// Scripts run on every page the browser shows, Chromium's own `chrome://`
/// pages included, which makes them the tool for customizing those pages:
///
/// ```swift
/// configuration.userScripts = [
///     // Hide Chromium's update status on the settings About page.
///     .styleSheet("settings-about-page #updateStatusContainer { display: none }",
///                 matching: ["chrome://settings/*"]),
/// ]
/// ```
///
/// The helper's renderer code runs each script in the document's own
/// JavaScript context (the page's main world) as the context is created,
/// in every frame and process of the browser. Stack traces taken inside a
/// script show it as an anonymous script; nothing else about it is
/// visible to the page, other than what the script itself does. CEF's API
/// has no isolated worlds, so scripts share the page's globals.
public struct CefUserScript: Sendable, Equatable {
    /// When the script runs.
    public enum InjectionTime: Sendable, Equatable {
        /// Before any of the document's own scripts.
        case documentStart
        /// When the document has been parsed (`DOMContentLoaded`), before
        /// the page's own listeners for it.
        case documentEnd
    }

    /// Which frames the script runs in.
    public enum Frames: Sendable, Equatable {
        /// Every frame, cross-site frames included.
        case all
        /// Only top-level documents.
        case mainFrame
    }

    public var source: String
    /// The documents the script runs in, by address, where `*` stands for
    /// any run of characters: `"chrome://settings/*"`,
    /// `"https://*.example.com/*"`. Empty runs it in every document.
    public var matches: [String]
    /// Addresses the script does not run in, though ``matches`` lists
    /// them: `"https://example.com/login*"`.
    ///
    /// A script with either list runs inside a function, so its top-level
    /// declarations are not global.
    public var excludeMatches: [String]
    public var injectionTime: InjectionTime
    public var frames: Frames

    public init(
        source: String, matching matches: [String] = [], excluding excludeMatches: [String] = [],
        injectionTime: InjectionTime = .documentStart, frames: Frames = .all
    ) {
        self.source = source
        self.matches = matches
        self.excludeMatches = excludeMatches
        self.injectionTime = injectionTime
        self.frames = frames
    }

    /// A script that adds `css` to matching pages.
    ///
    /// Pages built from web components — every `chrome://` page — keep their
    /// markup inside shadow roots that ordinary stylesheets cannot reach.
    /// With `includingShadowRoots` the rules are applied inside each shadow
    /// root as well — including roots whose component later sets its own
    /// `adoptedStyleSheets` — so a selector written for a component's
    /// internals matches there. Selectors still cannot cross a shadow
    /// boundary: `settings-section #row` matches nothing when `#row` lives in
    /// the section's shadow root; write `#row`.
    ///
    /// Removing the script (``CefProfile/userScripts``,
    /// ``CefBrowser/removeUserScript(_:)``) keeps the sheet out of documents
    /// loaded afterwards; a loaded document keeps it until it reloads.
    public static func styleSheet(
        _ css: String, matching matches: [String] = [], excluding excludeMatches: [String] = [],
        includingShadowRoots: Bool = true
    ) -> CefUserScript {
        // Covers shadow roots that already exist and those created later.
        // Components commonly assign their own `adoptedStyleSheets` after
        // attaching a shadow root (Lit does), which would drop the sheet, so
        // such assignments keep it.
        let shadowRoots = """
              const visit = root => {
                for (const element of root.querySelectorAll('*')) {
                  if (element.shadowRoot) { adopt(element.shadowRoot); visit(element.shadowRoot); }
                }
              };
              const sheets = Object.getOwnPropertyDescriptor(ShadowRoot.prototype, 'adoptedStyleSheets');
              if (sheets?.set) {
                Object.defineProperty(ShadowRoot.prototype, 'adoptedStyleSheets', {
                  ...sheets,
                  set(value) { sheets.set.call(this, [...value].includes(sheet) ? value : [...value, sheet]); },
                });
              }
              visit(document);
              const attachShadow = Element.prototype.attachShadow;
              Element.prototype.attachShadow = function (options) {
                const root = attachShadow.call(this, options);
                adopt(root);
                return root;
              };
            """
        return CefUserScript(
            source: """
                (() => {
                  const sheet = new CSSStyleSheet();
                  sheet.replaceSync(\(CefJSON.string(css).text));
                  const adopt = root => { root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet]; };
                  adopt(document);
                \(includingShadowRoots ? shadowRoots : "")
                })();
                """,
            matching: matches, excluding: excludeMatches)
    }
}
