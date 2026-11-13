import CefSwiftUI
import PDFKit
import SwiftUI

/// `pdf(configuration:)` renders the page as PDF data, tagged and with an
/// outline from its headings; `printToPDF(at:configuration:)` writes it to a
/// file and `print()` opens the print panel. A `PDFConfiguration` starts
/// from the user's Page Setup.
struct PDFDemo: Demo {
    let title = "PDF and Printing"
    let summary = "The page rendered as PDF beside it, in portrait or landscape with a page-number footer, saved to a file or printed."
    let symbol = "doc.richtext"
    let category = DemoCategory.page

    func makeView() -> some View { PDFDemoView() }
}

private struct PDFDemoView: View {
    @State private var browser = CefBrowser(url: SamplePage.article.url)
    @State private var isLandscape = false
    @State private var document: PDFDocument?

    var body: some View {
        HSplitView {
            CefWebView(browser).frame(minWidth: 320)
            PDFPreview(document: document).frame(minWidth: 280)
        }
        .toolbar {
            Toggle("Landscape", systemImage: "rectangle.landscape.rotate", isOn: $isLandscape)
            Button("Save as PDF…", systemImage: "square.and.arrow.down", action: save)
            Button("Print…", systemImage: "printer") { browser.print() }
        }
        .reportReady {
            try await browser.waitUntilLoaded(timeout: .seconds(30))
            try await render()
        }
        .onChange(of: isLandscape) { Task { try? await render() } }
        .onDisappear { browser.close(force: true) }
    }

    private var configuration: CefBrowser.PDFConfiguration {
        var configuration = CefBrowser.PDFConfiguration()
        configuration.isLandscape = isLandscape
        configuration.margins = .uniform(36)
        configuration.footerTemplate = """
            <div style="font-size: 9px; margin: auto"><span class=pageNumber></span> / <span class=totalPages></span></div>
            """
        return configuration
    }

    private func render() async throws {
        document = PDFDocument(data: try await browser.pdf(configuration: configuration))
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(browser.title).pdf"
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { try? await browser.printToPDF(at: url, configuration: configuration) }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
