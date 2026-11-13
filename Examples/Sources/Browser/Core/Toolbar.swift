import CefSwiftUI
import SwiftUI

/// Back and forward, beside the window buttons.
struct NavigationButtons: View {
    let browser: CefBrowser

    var body: some View {
        HStack(spacing: 2) {
            Button("Back", systemImage: "chevron.left", action: browser.goBack)
                .disabled(!browser.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: browser.goForward)
                .disabled(!browser.canGoForward)
        }
        .buttonStyle(ToolbarIconButtonStyle())
    }
}

/// An icon button sized and highlighted like AppKit's toolbar buttons. The
/// toolbar's trailing items have it.
struct ToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: 30, height: 28)
                .background(
                    .quaternary.opacity(configuration.isPressed ? 1 : isHovered && isEnabled ? 0.6 : 0),
                    in: .rect(cornerRadius: 7))
                .contentShape(.rect)
                .onHover { isHovered = $0 }
        }
    }
}

/// A favicon, or a spinner while the page loads, shown in the tab itself.
/// A tab that has been discarded to save memory shows its icon faded.
struct TabIcon: View {
    let browser: CefBrowser
    @Environment(BrowserController.self) private var controller

    var body: some View {
        Group {
            if browser.isLoading {
                ProgressView().controlSize(.mini)
            } else if let favicon = browser.favicon {
                Image(nsImage: favicon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(browser.isDiscarded ? 0.4 : 1)
        .help(browser.isDiscarded ? "Asleep to save memory" : "")
    }

    /// The symbol standing in for a page without a favicon.
    private var symbol: String {
        controller.isStartPage(browser.url) ? "square.grid.2x2" : BrowserPages.isInternal(browser.url) ? "gearshape" : "globe"
    }
}
