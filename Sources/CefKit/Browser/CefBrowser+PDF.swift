import AppKit
import CCef
import CefBase
import Foundation

extension CefBrowser {
    /// How ``CefBrowser/pdf(configuration:)`` lays out the page.
    ///
    /// The defaults follow the user's Page Setup: the paper size of
    /// `NSPrintInfo.shared`, portrait, Chromium's default margins, with
    /// backgrounds, and a tagged PDF with an outline from the page's
    /// headings.
    public struct PDFConfiguration: Sendable, Equatable {
        /// Page margins.
        public enum Margins: Sendable, Equatable {
            /// Chromium's default margins, about 0.4 inch.
            case `default`
            /// No margins.
            case none
            /// These margins, in points.
            case custom(top: Double, left: Double, bottom: Double, right: Double)

            /// The same margin, in points, on every side.
            public static func uniform(_ points: Double) -> Margins {
                .custom(top: points, left: points, bottom: points, right: points)
            }
        }

        /// The paper size in points, portrait. Defaults to the paper of
        /// `NSPrintInfo.shared`, US Letter or A4 for most users.
        public var paperSize: CGSize
        /// Lays the paper out landscape. A page whose CSS `@page` rule
        /// gives a size keeps that size's orientation.
        public var isLandscape = false
        public var margins = Margins.default
        /// How much to scale the page, from 0.1 to 2.
        public var scale = 1.0
        /// The pages to include, numbered from 1, in document order; empty
        /// for every page. Ranges past the last page are ignored.
        public var pageRanges: [ClosedRange<Int>] = []
        /// Uses the page size a page's CSS `@page` rule asks for instead of
        /// ``paperSize``.
        public var prefersCSSPageSize = false
        /// Prints background colors and images.
        public var printsBackgrounds = true
        /// HTML for a header on each page. Elements with the classes
        /// `date`, `title`, `url`, `pageNumber` and `totalPages` are filled
        /// in, as in `<span class=pageNumber></span>`. Pages set no font
        /// size for it; set one, such as `font-size: 10px`.
        public var headerTemplate: String?
        /// HTML for a footer on each page, as ``headerTemplate``.
        public var footerTemplate: String?
        /// Writes a tagged PDF, which VoiceOver and other assistive apps
        /// can read in order.
        public var isTagged = true
        /// Adds an outline (bookmarks) made from the page's headings.
        /// Needs ``isTagged``.
        public var includesOutline = true

        /// A configuration with the defaults.
        @MainActor
        public init() {
            paperSize = NSPrintInfo.shared.paperSize
        }

        /// A configuration for `paperSize`, in points, portrait.
        public init(paperSize: CGSize) {
            self.paperSize = paperSize
        }

        /// `pageRanges` as Chromium spells them: `"1-5, 8"`.
        var pageRangeText: String {
            pageRanges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
                .joined(separator: ", ")
        }

        /// The settings struct, with its strings owned by the caller, who
        /// clears them.
        func makeSettings() -> cef_pdf_print_settings_t {
            var settings = cef_pdf_print_settings_t()
            settings.size = MemoryLayout<cef_pdf_print_settings_t>.stride
            settings.print_background = printsBackgrounds ? 1 : 0
            settings.scale = min(2, max(0.1, scale))
            // Chromium takes inches. Its `landscape` flag does not turn a
            // paper size given with it, so the size is turned here instead
            // and the flag left off.
            let width = max(1, paperSize.width) / 72, height = max(1, paperSize.height) / 72
            settings.paper_width = isLandscape ? max(width, height) : width
            settings.paper_height = isLandscape ? min(width, height) : height
            settings.prefer_css_page_size = prefersCSSPageSize ? 1 : 0
            switch margins {
            case .default:
                settings.margin_type = PDF_PRINT_MARGIN_DEFAULT
            case .none:
                settings.margin_type = PDF_PRINT_MARGIN_NONE
            case .custom(let top, let left, let bottom, let right):
                settings.margin_type = PDF_PRINT_MARGIN_CUSTOM
                settings.margin_top = max(0, top) / 72
                settings.margin_left = max(0, left) / 72
                settings.margin_bottom = max(0, bottom) / 72
                settings.margin_right = max(0, right) / 72
            }
            CefStringUtil.set(pageRangeText, into: &settings.page_ranges)
            if headerTemplate != nil || footerTemplate != nil {
                settings.display_header_footer = 1
                // An empty template would get Chromium's default one.
                CefStringUtil.set(headerTemplate ?? "<span></span>", into: &settings.header_template)
                CefStringUtil.set(footerTemplate ?? "<span></span>", into: &settings.footer_template)
            }
            settings.generate_tagged_pdf = isTagged ? 1 : 0
            settings.generate_document_outline = isTagged && includesOutline ? 1 : 0
            return settings
        }
    }

    /// Renders the page as PDF data.
    ///
    /// ```swift
    /// var configuration = CefBrowser.PDFConfiguration()
    /// configuration.isLandscape = true
    /// configuration.footerTemplate = #"<div style="font-size: 9px; margin: auto"><span class=pageNumber></span></div>"#
    /// let data = try await browser.pdf(configuration: configuration)
    /// ```
    public func pdf(configuration: PDFConfiguration? = nil) async throws -> Data {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cefswift-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        try await printToPDF(at: file, configuration: configuration)
        return try Data(contentsOf: file)
    }

    /// Renders the page to a PDF file at `destination`, replacing it.
    public func printToPDF(at destination: URL, configuration: PDFConfiguration? = nil) async throws {
        try await ready()
        let configuration = configuration ?? PDFConfiguration()
        let succeeded: Bool = await withCheckedContinuation { continuation in
            let callback = PDFPrintCallback(continuation: continuation).makeCallback()
            var settings = configuration.makeSettings()
            defer {
                ccef_string_clear(&settings.page_ranges)
                ccef_string_clear(&settings.header_template)
                ccef_string_clear(&settings.footer_template)
            }
            let started: Void? = withHost { host in
                CefStringUtil.withCefString(destination.path) {
                    host.pointee.print_to_pdf(host, $0, &settings, callback)
                }
            }
            if started == nil {
                cefRelease(callback)
            }
        }
        guard succeeded else {
            throw CefError.operationFailed("print_to_pdf did not produce \(destination.path); check the page ranges")
        }
    }
}
