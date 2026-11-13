import CefChromium
import CefSwiftUI
import SwiftUI

/// Find in page, Safari style: Edit › Find (⌘F) shows a bar under the
/// toolbar in place of Chromium's (`CefWindow.setFindBar`), driven by the
/// browser's `CefFindSession`.
struct FindBar: BrowserFeature {
    func windowDidOpen(_ window: CefWindow) {
        window.setFindBar { session in Bar(session: session) }
    }

    func commands(for controller: BrowserController) -> some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { controller.current?.execute(.find) }.keyboardShortcut("f")
        }
    }

    private struct Bar: View {
        @Bindable var session: CefFindSession

        var body: some View {
            HStack(spacing: 8) {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find on Page", text: $session.text)
                        .textFieldStyle(.plain)
                        .onSubmit(session.next)
                        .onExitCommand(perform: session.end)
                    if !session.text.isEmpty {
                        Text(session.matchCount == 0 ? "Not found" : "\(session.activeMatch) of \(session.matchCount)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 280, height: 24)
                .background(.quaternary.opacity(0.8), in: .rect(cornerRadius: 6))
                Button("Previous", systemImage: "chevron.left", action: session.previous)
                    .disabled(session.matchCount == 0)
                Button("Next", systemImage: "chevron.right", action: session.next)
                    .disabled(session.matchCount == 0)
                Button("Done", action: session.end)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
