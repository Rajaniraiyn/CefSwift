import CefSwiftUI
import SwiftUI

/// Private tabs: File › New Private Tab (⇧⌘N) opens a tab on a new
/// incognito profile, which keeps no history, cookies or site data once it
/// closes. Tabs it opens share its profile, and its address field carries
/// a "Private" badge.
struct PrivateTabs: BrowserFeature {
    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(after: .newItem) {
            Button("New Private Tab") { controller.openTab(isPrivate: true) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    @ViewBuilder func toolbarItems(_ placement: ToolbarPlacement, for browser: CefBrowser) -> some View {
        if placement == .addressFieldLeading, browser.isPrivate {
            Label("Private", systemImage: "hand.raised.fill")
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.2), in: .capsule)
        }
    }
}
