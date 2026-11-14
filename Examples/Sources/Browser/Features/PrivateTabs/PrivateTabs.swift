import CefSwiftUI
import SwiftUI

/// Private windows: File › New Private Window (⇧⌘N) opens a window of
/// Chromium's own on the browser's incognito profile, which keeps no
/// history, cookies or site data once the app quits. Its tabs share that
/// profile, its tabs carry a small badge in the rail, and its address field
/// a "Private" badge.
struct PrivateTabs: BrowserFeature {
    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(after: .newItem) {
            Button("New Private Window") { Task { await controller.openWindow(isPrivate: true) } }
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
