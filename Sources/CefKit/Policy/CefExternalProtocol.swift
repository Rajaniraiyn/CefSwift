import AppKit
import Foundation

/// A page's request to open a URL whose scheme Chromium does not load
/// itself (`mailto:`, `zoommtg:`, `slack:`), which another app on the Mac
/// may handle. Passed to
/// ``CefBrowserDelegate/browser(_:decideExternalProtocolFor:)``.
public struct CefExternalProtocolRequest: Sendable, Equatable {
    /// The URL to hand to another app.
    public var url: URL
    /// The address of the frame that asked, when CEF reports it.
    public var frameURL: URL?
    /// Whether the main frame asked, rather than an `iframe`.
    public var isMainFrame: Bool

    /// Creates a value of your own, for previews and tests.
    public init(url: URL, frameURL: URL? = nil, isMainFrame: Bool = true) {
        self.url = url
        self.frameURL = frameURL
        self.isMainFrame = isMainFrame
    }

    /// The app macOS would open ``url`` with; nil when none handles its
    /// scheme.
    @MainActor
    public var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }
}

/// What to do with a ``CefExternalProtocolRequest``.
public enum CefExternalProtocolDecision: Sendable, Equatable {
    /// Open the URL with the app macOS has for its scheme.
    case allow
    /// Do nothing.
    case deny
}

/// The sheet behind the default answer to
/// ``CefBrowserDelegate/browser(_:decideExternalProtocolFor:)``: "Open
/// “Zoom”?", naming the app and the site that asks, as Safari and Chrome
/// ask. Call it from your own delegate to keep it for some requests.
@MainActor
public enum CefExternalProtocolPresenter {
    /// Asks whether to open `request`'s URL, as a sheet on `window` when it
    /// is visible. Returns ``CefExternalProtocolDecision/deny`` without
    /// asking when no app opens such URLs. Cancelling the calling task
    /// dismisses the sheet as Cancel.
    public static func present(_ request: CefExternalProtocolRequest, in window: NSWindow?) async -> CefExternalProtocolDecision {
        guard let application = request.applicationURL else { return .deny }
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "Open “%@”?", bundle: .cefKit,
                           comment: "External protocol sheet: title. %@ is the app that would open the link."),
            FileManager.default.displayName(atPath: application.path))
        if let site = request.frameURL?.host() {
            alert.informativeText = String(
                format: String(localized: "%@ wants to open this app.", bundle: .cefKit,
                               comment: "External protocol sheet: message. %@ is the site that asks."),
                site)
        } else {
            alert.informativeText = String(
                localized: "A page wants to open this app.", bundle: .cefKit,
                comment: "External protocol sheet: message when the asking site is unknown.")
        }
        alert.icon = NSWorkspace.shared.icon(forFile: application.path)
        alert.addButton(withTitle: String(localized: "Open", bundle: .cefKit,
                                          comment: "External protocol sheet: the button that opens the app."))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .cefKit, comment: "A button that dismisses a sheet without answering it."))
        return await CefDialogPresenter.run(alert, in: window) == .alertFirstButtonReturn ? .allow : .deny
    }
}

extension CefBrowser {
    /// Opens a URL another app handles, once the delegate allowed it.
    /// SelfTest replaces it, so that no other app opens unattended.
    @_spi(Testing) public static var openExternalURL: @MainActor (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }

    /// Chromium found no handler of its own for `request`'s scheme: the
    /// delegate decides, while the page that asked is shown.
    func handleExternalProtocol(_ request: CefExternalProtocolRequest) {
        decide(.page, { [weak self] delegate -> CefExternalProtocolDecision in
            guard let self else { return .deny }
            return await delegate.browser(self, decideExternalProtocolFor: request)
        }, then: { (decision: CefExternalProtocolDecision) in
            if decision == .allow { CefBrowser.openExternalURL(request.url) }
        })
    }
}
