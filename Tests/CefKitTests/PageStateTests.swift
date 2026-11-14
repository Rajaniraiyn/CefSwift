import CCef
import Foundation
import Testing

@testable import CefKit
import CefBase

/// Page-level values that need no Chromium: draggable regions, navigation
/// transitions, content switches and profile page defaults.
@MainActor
@Suite struct PageStateTests {
    @Test func theLastRegionContainingAPointDecides() {
        let bar = CefBrowser.DraggableRegion(frame: CGRect(x: 0, y: 0, width: 300, height: 40), isDraggable: true)
        let button = CefBrowser.DraggableRegion(frame: CGRect(x: 200, y: 5, width: 60, height: 30), isDraggable: false)
        #expect(CefBrowser.isDraggable(at: CGPoint(x: 10, y: 10), in: [bar, button]))
        #expect(!CefBrowser.isDraggable(at: CGPoint(x: 210, y: 10), in: [bar, button]))
        #expect(!CefBrowser.isDraggable(at: CGPoint(x: 10, y: 100), in: [bar, button]))
        // A drag region after a no-drag one wins again.
        #expect(CefBrowser.isDraggable(at: CGPoint(x: 210, y: 10), in: [bar, button, bar]))
        #expect(!CefBrowser.isDraggable(at: .zero, in: []))
    }

    @Test func transitionsReadChromiumsSourceAndQualifiers() {
        let back = CefNavigationTransition(cefValue: TT_LINK.rawValue | TT_FORWARD_BACK_FLAG.rawValue)
        #expect(back.source == .link && back.isBackForward && !back.isRedirect)
        let form = CefNavigationTransition(cefValue: TT_FORM_SUBMIT.rawValue | TT_SERVER_REDIRECT_FLAG.rawValue)
        #expect(form.source == .formSubmit && form.isRedirect)
        #expect(CefNavigationTransition(cefValue: TT_AUTO_SUBFRAME.rawValue).source == .autoSubframe)
        let action = CefNavigationAction(url: URL(string: "https://a.example"),
                                         frame: CefFrame(id: "1-A", url: nil, isMain: false, parentID: "1-B"))
        #expect(!action.isMainFrame)
    }

    @Test func contentSwitchesFillBrowserSettings() {
        var content = CefBrowser.Configuration.Content()
        var settings = cef_browser_settings_t()
        content.apply(to: &settings)
        #expect(settings.javascript == STATE_DEFAULT && settings.javascript_access_clipboard == STATE_DEFAULT)
        content.javaScript = .disabled
        content.images = .disabled
        content.webGL = .disabled
        content.localStorage = .disabled
        content.webFonts = .disabled
        content.clipboardAccess = .copyAndPaste
        content.fonts.standardFamily = "Helvetica"
        content.defaultEncoding = "ISO-8859-1"
        content.apply(to: &settings)
        defer { CefBrowser.Configuration.Content.clearStrings(of: &settings) }
        #expect(settings.javascript == STATE_DISABLED && settings.image_loading == STATE_DISABLED
                    && settings.webgl == STATE_DISABLED && settings.local_storage == STATE_DISABLED
                    && settings.remote_fonts == STATE_DISABLED)
        #expect(settings.javascript_access_clipboard == STATE_ENABLED && settings.javascript_dom_paste == STATE_ENABLED)
        #expect(CefStringUtil.string(from: &settings.standard_font_family) == "Helvetica")
        #expect(CefStringUtil.string(from: &settings.default_encoding) == "ISO-8859-1")
    }

    /// A page's scripts follow its profile's; a page bridge replaces a
    /// profile bridge of the same name; attachments run profile first.
    @Test func pagesTakeTheirProfilesDefaultsFirst() {
        let profile = CefProfile.incognito()
        profile.userScripts = [CefUserScript(source: "profile")]
        let shared = CefBridge(name: "app"), other = CefBridge(name: "tools")
        profile.bridges = [shared, other]
        final class Attachment: CefBrowserAttachment {
            func browserDidCreate(_ browser: CefBrowser) async {}
            func browserDidClose(_ browser: CefBrowser) {}
        }
        let first = Attachment(), second = Attachment()
        profile.attachments = [first]
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        configuration.userScripts = [CefUserScript(source: "page")]
        let own = CefBridge(name: "app")
        configuration.bridges = [own]
        configuration.attachments = [second]
        let page = CefBrowser(configuration: configuration)
        #expect(page.userScripts.map(\.source) == ["profile", "page"])
        #expect(page.bridges.map(ObjectIdentifier.init) == [ObjectIdentifier(own), ObjectIdentifier(other)])
        #expect(page.attachments.map { ObjectIdentifier($0) } == [ObjectIdentifier(first), ObjectIdentifier(second)])
        page.removeUserScript(CefUserScript(source: "page"))
        page.addUserScript(CefUserScript(source: "added"))
        #expect(page.userScripts.map(\.source) == ["profile", "added"])
    }

    @Test func frameOriginsComeFromTheirAddress() {
        #expect(CefBridge.addressOrigin("https://Example.com:443/a") == .tuple("https://example.com"))
        #expect(CefBridge.addressOrigin("about:srcdoc") == .inherited)
        #expect(CefFrame(id: "x", url: nil, isMain: true).origin == nil)
    }
}
