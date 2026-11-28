import CefSwiftUI
import SwiftUI

/// `page.frames` lists the page's frames, main frame first, and follows
/// them as iframes attach, navigate and go. `evaluateJavaScript(_:in:)`
/// runs a script in one of them, a cross-site frame in another renderer
/// process included.
struct FramesDemo: Demo {
    let title = "Frames"
    let summary = "The page's frame tree as Chromium reports it, and a script evaluated in the frame you choose, a cross-site one included."
    let symbol = "rectangle.split.2x2"
    let category = DemoCategory.javaScript

    func makeView() -> some View { FramesView() }
}

private struct FramesView: View {
    @ViewState private var page = CefPage(url: FramesPages.top.url)
    @ViewState private var selection: CefFrame.ID?
    @ViewState private var result = ""

    var body: some View {
        HSplitView {
            CefWebView(page).frame(minWidth: 360)
            VStack(alignment: .leading, spacing: 0) {
                List(page.frames, selection: $selection) { frame in
                    VStack(alignment: .leading) {
                        Text(frame.isMain ? "Main frame" : frame.name.isEmpty ? "Unnamed frame" : frame.name)
                        Text(frame.url?.absoluteString ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, depth(of: frame) * 14)
                }
                Divider()
                Text(result.isEmpty ? "Select a frame to read its title and background color." : result)
                    .font(.callout.monospaced())
                    .padding(10)
            }
            .frame(minWidth: 240, maxWidth: 340)
        }
        .task(id: selection) { await evaluateInSelectedFrame() }
        .reportReady {
            try await page.waitUntilLoaded(timeout: .seconds(30))
            // The cross-site frame comes from the local server, in a renderer of its own.
            while page.frames.count < 3 { try await Task.sleep(for: .milliseconds(100)) }
        }
        .onDisappear { page.close(force: true) }
    }

    private func depth(of frame: CefFrame) -> CGFloat {
        var depth = 0.0
        var parent = frame.parentID
        while let id = parent, let next = page.frames.first(where: { $0.id == id }) {
            depth += 1
            parent = next.parentID
        }
        return depth
    }

    private func evaluateInSelectedFrame() async {
        guard let frame = page.frames.first(where: { $0.id == selection }) else { return }
        do {
            let value = try await page.evaluateJavaScript(
                "document.title + ' · ' + getComputedStyle(document.body).backgroundColor", in: frame)
            result = value.stringValue ?? "\(value)"
        } catch {
            result = "\(error)"
        }
    }
}

private enum FramesPages {
    static let top = SamplePage("frames.html", title: "Top", body: """
        <h1>Frames</h1>
        <iframe name=same-site src="\(child.url.absoluteString)" width=300 height=120></iframe>
        <iframe name=cross-site src="\(crossSite.localURL.absoluteString)" width=300 height=120></iframe>
        """)
    static let child = SamplePage("frames-child.html", title: "Child", body: """
        <style>body { background: #e8f4ff; padding: 12px }</style><p>A frame from the gallery scheme.</p>
        """)
    static let crossSite = SamplePage("frames-cross-site.html", title: "Cross-site", body: """
        <style>body { background: #fff2e0; padding: 12px }</style><p>A frame from http://localhost.</p>
        """)
}
