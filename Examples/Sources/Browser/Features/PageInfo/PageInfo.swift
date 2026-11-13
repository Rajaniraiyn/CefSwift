import AppKit
import CefSwiftUI
import SwiftUI

/// The site's security at the start of the address field; clicking it shows
/// the page info (`PageInfoView`): who the site is, how it is connected,
/// and its permissions (`CefSiteSettings`). Pages asking for the camera,
/// location and the like are asked about in a sheet, which can remember
/// the answer for the site.
struct PageInfo: BrowserFeature {
    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for browser: CefBrowser) -> some View {
        if placement == .addressFieldLeading { PageInfoButton(browser: browser) }
    }

    func decidePermission(for request: CefPermissionRequest, in browser: CefBrowser) async -> CefPermissionDecision? {
        let alert = NSAlert()
        alert.messageText = "Allow \(request.origin) to use \(request.kinds.summary)?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        // Screen capture is decided per request, never remembered.
        alert.showsSuppressionButton = request.kinds.isDisjoint(with: [.screenCapture, .systemAudioCapture])
        alert.suppressionButton?.title = "Remember for this website"
        guard let window = browser.hostWindow else { return .deny }
        let allowed = await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        let remembers = alert.suppressionButton?.state == .on
        switch (allowed, remembers) {
        case (true, true): return .alwaysAllow
        case (true, false): return .allow
        case (false, true): return .alwaysDeny
        case (false, false): return .deny
        }
    }
}

/// The badge at the start of the address field; clicking it shows the
/// site's page info.
private struct PageInfoButton: View {
    let browser: CefBrowser
    @Environment(BrowserController.self) private var controller
    @Environment(\.isEditingAddress) private var isEditingAddress
    @State private var isShowing = false

    var body: some View {
        if !isEditingAddress, !controller.isStartPage(browser.url), let security = SiteSecurity(browser: browser) {
            Button { isShowing.toggle() } label: { security.badge }
                .buttonStyle(.borderless)
                .help("Show page info")
                .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                    PageInfoView(browser: browser)
                }
                .task {
                    // -showPageInfo YES, for screenshots.
                    guard UserDefaults.standard.bool(forKey: "showPageInfo") else { return }
                    try? await Task.sleep(for: .seconds(2))
                    isShowing = true
                }
        }
    }
}

/// The connection's security, as the address field shows it.
enum SiteSecurity {
    case secure, notSecure, app

    @MainActor init?(browser: CefBrowser) {
        let url = browser.url
        switch browser.connectionSecurity?.level {
        case .secure: self = .secure
        case .partiallySecure, .notSecure: self = .notSecure
        case .local: if BrowserPages.isInternal(url) { self = .app } else { return nil }
        case nil:
            switch url?.scheme {
            case "https": self = .secure
            case "http": self = .notSecure
            case _ where BrowserPages.isInternal(url): self = .app
            default: return nil
            }
        }
    }

    @MainActor @ViewBuilder var badge: some View {
        switch self {
        case .secure:
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("Secure connection")
        case .notSecure:
            Label("Not Secure", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize()
        case .app:
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

extension CefPermissionRequest.Kinds {
    /// What a permission prompt asks for, such as “the camera and the
    /// microphone”.
    var summary: String {
        let names: [(CefPermissionRequest.Kinds, String)] = [
            (.camera, "the camera"), (.microphone, "the microphone"),
            (.cameraPanTiltZoom, "camera movement"), (.screenCapture, "your screen"),
            (.systemAudioCapture, "your Mac’s audio"), (.geolocation, "your location"),
            (.notifications, "notifications"), (.clipboard, "the clipboard"),
        ]
        let matched = names.filter { contains($0.0) }.map(\.1)
        return matched.isEmpty ? "additional features" : matched.formatted(.list(type: .and))
    }
}
