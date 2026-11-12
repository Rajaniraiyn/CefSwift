import AppKit
import CCef
import CefBase
import Foundation
import Testing

@testable import CefKit

/// What a PDF configuration hands Chromium.
@MainActor
struct PDFConfigurationTests {
    @Test func defaultsFollowPageSetup() {
        let configuration = CefBrowser.PDFConfiguration()
        #expect(configuration.paperSize == NSPrintInfo.shared.paperSize)
        #expect(configuration.printsBackgrounds && configuration.isTagged && configuration.includesOutline)
        var settings = configuration.makeSettings()
        defer { ccef_string_clear(&settings.page_ranges) }
        #expect(settings.margin_type == PDF_PRINT_MARGIN_DEFAULT)
        #expect(settings.display_header_footer == 0)
        #expect(abs(settings.paper_width - NSPrintInfo.shared.paperSize.width / 72) < 0.001)
    }

    @Test func pointsBecomeInches() {
        var configuration = CefBrowser.PDFConfiguration(paperSize: CGSize(width: 595, height: 842))
        configuration.margins = .custom(top: 72, left: 36, bottom: 18, right: 0)
        configuration.scale = 5
        configuration.isTagged = false
        var settings = configuration.makeSettings()
        defer { ccef_string_clear(&settings.page_ranges) }
        #expect(abs(settings.paper_width - 595.0 / 72) < 0.001 && abs(settings.paper_height - 842.0 / 72) < 0.001)
        #expect(settings.margin_type == PDF_PRINT_MARGIN_CUSTOM)
        #expect(settings.margin_top == 1 && settings.margin_left == 0.5 && settings.margin_bottom == 0.25)
        #expect(settings.scale == 2)
        // An outline needs a tagged PDF.
        #expect(settings.generate_tagged_pdf == 0 && settings.generate_document_outline == 0)
    }

    @Test func landscapeTurnsThePaper() {
        var configuration = CefBrowser.PDFConfiguration(paperSize: CGSize(width: 612, height: 792))
        configuration.isLandscape = true
        var settings = configuration.makeSettings()
        defer { ccef_string_clear(&settings.page_ranges) }
        #expect(settings.paper_width == 11 && settings.paper_height == 8.5 && settings.landscape == 0)
    }

    @Test func pageRangesAreSpelledAsChromiumReadsThem() {
        var configuration = CefBrowser.PDFConfiguration(paperSize: CGSize(width: 612, height: 792))
        configuration.pageRanges = [1...3, 5...5, 8...9]
        #expect(configuration.pageRangeText == "1-3, 5, 8-9")
    }

    @Test func aFooterAloneStillGetsAnEmptyHeader() {
        var configuration = CefBrowser.PDFConfiguration(paperSize: CGSize(width: 612, height: 792))
        configuration.footerTemplate = "<span class=pageNumber></span>"
        var settings = configuration.makeSettings()
        defer {
            ccef_string_clear(&settings.page_ranges)
            ccef_string_clear(&settings.header_template)
            ccef_string_clear(&settings.footer_template)
        }
        #expect(settings.display_header_footer == 1)
        #expect(CefStringUtil.string(from: settings.header_template) == "<span></span>")
    }
}
