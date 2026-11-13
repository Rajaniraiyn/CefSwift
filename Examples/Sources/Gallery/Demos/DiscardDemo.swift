import CefSwiftUI
import SwiftUI

/// A browser that is off screen can give back its page's memory with
/// `discard()`: its renderer ends, the browser keeps its address, title
/// and a snapshot, and the page loads again when it is shown. When to
/// discard is the app's choice; `discardBlockers()` says what keeps a
/// browser loaded.
struct DiscardDemo: Demo {
    let title = "Discard and Restore"
    let summary = "Two tabs: discard the hidden one to free its memory, then show it again to restore its page."
    let symbol = "moon.zzz"
    let category = DemoCategory.runtime

    func makeView() -> some View { DiscardView() }
}

private struct DiscardView: View {
    @State private var tabs = [CefBrowser(url: SamplePage.tour[0].url), CefBrowser(url: SamplePage.article.url)]
    @State private var selected = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                ForEach(tabs.indices, id: \.self) { index in
                    TabCard(browser: tabs[index], isSelected: index == selected) { selected = index }
                }
            }
            .padding(10)
            Divider()
            // Only the selected tab is in the window; the other is hidden.
            CefWebView(tabs[selected]).id(selected)
        }
        .reportReady {
            try await tabs[0].waitUntilLoaded(timeout: .seconds(30))
            selected = 1
            try await tabs[1].waitUntilLoaded(timeout: .seconds(30))
        }
        .onDisappear { tabs.forEach { $0.close(force: true) } }
    }
}

private struct TabCard: View {
    let browser: CefBrowser
    let isSelected: Bool
    let select: () -> Void
    @State private var blockers = ""

    var body: some View {
        HStack {
            Group {
                if let snapshot = browser.discardSnapshot, browser.isDiscarded {
                    Image(nsImage: snapshot).resizable().scaledToFill()
                } else {
                    Image(systemName: browser.isDiscarded ? "moon.zzz" : "doc.richtext").font(.title)
                }
            }
            .frame(width: 64, height: 44)
            .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(browser.title.isEmpty ? "Tab" : browser.title).lineLimit(1)
                Text("\(String(describing: browser.lifecycle))\(blockers)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show", action: select).disabled(isSelected)
            Button("Discard") {
                Task {
                    do {
                        try await browser.discard()
                        blockers = ""
                    } catch {
                        blockers = " · \(error)"
                    }
                }
            }
            .disabled(isSelected || browser.isDiscarded)
        }
        .padding(8)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 10))
        .opacity(browser.isDiscarded ? 0.6 : 1)
    }
}
