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
