import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import PDFKit

/// PDF export with its options, read back with PDFKit.
extension SelfTest {
    static func pdfChecks() async {
        CefRuntime.shared.registerSchemeHandler(scheme: "https", domain: "cefswift.test", handler: CapabilityPages())
        let browser = CefBrowser(url: capabilityOrigin.appending(path: "print.html"))
        let view = CefWindowedBrowserView()
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        view.browser = browser
        guard await waitUntil({ browser.title == "print" && !browser.isLoading }) else {
            check("pdf: page loads", false, detail: browser.title)
            view.removeFromSuperview()
            return
        }
        let a4 = CGSize(width: 595.28, height: 841.89)
        func document(_ configure: (inout CefBrowser.PDFConfiguration) -> Void) async throws -> PDFDocument {
            var configuration = CefBrowser.PDFConfiguration(paperSize: a4)
            configure(&configuration)
            let data = try await browser.pdf(configuration: configuration)
            guard let document = PDFDocument(data: data) else { throw CefError.operationFailed("not a PDF") }
            return document
        }
        func size(_ document: PDFDocument) -> CGSize {
            document.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
        }
        func close(_ size: CGSize, _ expected: CGSize) -> Bool {
            abs(size.width - expected.width) < 2 && abs(size.height - expected.height) < 2
        }

        await expect("pdf: data in the paper size asked for, one page per break") {
            let pdf = try await document { _ in }
            return pdf.pageCount == 3 && close(size(pdf), a4)
        }
        // A page's @page size sets its orientation; this one has none.
        browser.load(capabilityOrigin.appending(path: "plain.html"))
        _ = await waitUntil { browser.title == "plain" && !browser.isLoading }
        do {
            let pdf = try await document { $0.isLandscape = true }
            let page = pdf.page(at: 0)
            check("pdf: landscape turns the paper", close(size(pdf), CGSize(width: a4.height, height: a4.width)),
                  detail: "\(size(pdf)), rotation \(page?.rotation ?? -1), \(pdf.pageCount) pages")
        } catch {
            check("pdf: landscape turns the paper", false, detail: "\(error)")
        }
        browser.load(capabilityOrigin.appending(path: "print.html"))
        _ = await waitUntil { browser.title == "print" && !browser.isLoading }
        await expect("pdf: page ranges select pages") {
            try await document { $0.pageRanges = [2...3] }.pageCount == 2
        }
        await expect("pdf: a range past the last page fails") {
            do {
                _ = try await document { $0.pageRanges = [7...9] }
                return false
            } catch { return true }
        }
        await expect("pdf: the CSS page size wins when preferred") {
            close(size(try await document { $0.prefersCSSPageSize = true }), CGSize(width: 419.53, height: 595.28))
        }
        await expect("pdf: tagged, with an outline from the headings") {
            let pdf = try await document { _ in }
            return Self.isTagged(pdf) && (pdf.outlineRoot?.numberOfChildren ?? 0) >= 3
        }
        await expect("pdf: untagged when asked") {
            let pdf = try await document { $0.isTagged = false }
            return !Self.isTagged(pdf) && pdf.outlineRoot == nil
        }
        await expect("pdf: header and footer templates are filled in") {
            let pdf = try await document {
                $0.headerTemplate = #"<div style="font-size: 10px">Header <span class=title></span></div>"#
                $0.footerTemplate = #"<div style="font-size: 10px">Page <span class=pageNumber></span> of <span class=totalPages></span></div>"#
                $0.margins = .uniform(72)
            }
            let text = pdf.page(at: 1)?.string ?? ""
            return text.contains("Header print") && text.contains("Page 2 of 3")
        }
        await expect("pdf: no margins and the default paper") {
            var configuration = CefBrowser.PDFConfiguration()
            configuration.margins = .none
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-selftest-margins.pdf")
            defer { try? FileManager.default.removeItem(at: file) }
            try await browser.printToPDF(at: file, configuration: configuration)
            return PDFDocument(url: file).map { close(size($0), NSPrintInfo.shared.paperSize) } ?? false
        }
        browser.close(force: true)
        _ = await waitUntil { browser.state == .closed }
        view.removeFromSuperview()
    }

    /// Whether the document has a structure tree, as tagged PDFs do.
    static func isTagged(_ document: PDFDocument) -> Bool {
        guard let pdf = document.documentRef, let catalog = pdf.catalog else { return false }
        var tree: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(catalog, "StructTreeRoot", &tree)
    }
}
