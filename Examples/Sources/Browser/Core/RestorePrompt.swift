import AppKit
import CefChromium
import SwiftUI

/// After the browser quit unexpectedly: a small panel under the top bar
/// offering to reopen the windows it had (`CefTabStrip.previousSession`),
/// which goes away on its own once used, dismissed or the window closes.
/// It asks nothing modal: the new window works meanwhile.
@MainActor
enum RestorePrompt {
    static func show(in window: CefChromeWindow, session: CefTabStrip.PreviousSession, controller: BrowserController) {
        guard let parent = window.window else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        let close = { [weak panel, weak parent] in
            guard let panel else { return }
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        let tabs = session.windows.reduce(0) { $0 + $1.count }
        let hosting = NSHostingView(rootView: Prompt(windows: session.windows.count, tabs: tabs) {
            close()
            Task { try? await window.strip.restorePreviousSession(configuration: controller.tabConfiguration(for: window.profile), delegate: controller) }
        } dismiss: {
            close()
            window.strip.discardPreviousSession()
        })
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        parent.addChildWindow(panel, ordered: .above)
        // Under the top bar, at the trailing edge of the page.
        // contentFrame is from the content view's top left.
        let page = window.contentFrame
        let content = parent.contentView.map { parent.convertToScreen($0.frame) } ?? parent.frame
        let isRightToLeft = parent.contentView?.userInterfaceLayoutDirection == .rightToLeft
        let x = isRightToLeft ? content.minX + page.minX + 12 : content.minX + page.maxX - panel.frame.width - 12
        panel.setFrameTopLeftPoint(CGPoint(x: x, y: content.maxY - page.minY - 8))
        panel.orderFront(nil)
    }

    private struct Prompt: View {
        let windows: Int
        let tabs: Int
        let restore: () -> Void
        let dismiss: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Label("The browser quit unexpectedly.", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Reopen \(windows == 1 ? "its window" : "its \(windows) windows") (\(tabs) \(tabs == 1 ? "tab" : "tabs"))?")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Not Now", action: dismiss)
                    Button("Reopen", action: restore).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .frame(width: 300)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5) }
        }
    }
}
