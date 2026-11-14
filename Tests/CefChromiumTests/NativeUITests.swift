import AppKit
import Testing

@testable import CefChromium
import CefKit

@MainActor
@Suite struct SurfaceAnchorTests {
    private func window() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: true)
    }

    @Test func hangsBelowTheAnchorWithSpacing() throws {
        let window = window()
        let anchor = CefChromiumSurface.Anchor.rect(CGRect(x: 200, y: 500, width: 300, height: 20), alignment: .leading, spacing: 6)
        let origin = try #require(anchor.origin(for: CGSize(width: 200, height: 100), in: window))
        #expect(origin.x == window.frame.minX + 200)
        #expect(origin.y == window.frame.minY + 500 - 6 - 100)
    }

    @Test func alignsTrailingAndCenter() throws {
        let window = window()
        let rect = CGRect(x: 200, y: 500, width: 300, height: 20)
        let size = CGSize(width: 100, height: 50)
        let trailing = try #require(CefChromiumSurface.Anchor.rect(rect, alignment: .trailing).origin(for: size, in: window))
        #expect(trailing.x == window.frame.minX + 500 - 100)
        let center = try #require(CefChromiumSurface.Anchor.rect(rect, alignment: .center).origin(for: size, in: window))
        #expect(center.x == window.frame.minX + 350 - 50)
    }

    @Test func staysInsideTheWindow() throws {
        let window = window()
        let anchor = CefChromiumSurface.Anchor.rect(CGRect(x: 760, y: 500, width: 30, height: 20), alignment: .leading)
        let origin = try #require(anchor.origin(for: CGSize(width: 200, height: 100), in: window))
        #expect(origin.x + 200 <= window.frame.maxX - 4)
    }

    @Test func viewAnchorNeedsTheViewInTheWindow() {
        let window = window()
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        let anchor = CefChromiumSurface.Anchor.view(view)
        #expect(anchor.origin(for: CGSize(width: 10, height: 10), in: window) == nil)
        #expect(anchor.isAnchored(to: view))
        window.contentView?.addSubview(view)
        #expect(anchor.origin(for: CGSize(width: 10, height: 10), in: window) != nil)
    }
}

@MainActor
@Suite struct SurfacePolicyTests {
    @Test func presentationsDefaultToNative() {
        var policy = CefChromiumSurface.Policy()
        #expect(policy[.qrCode] == .native)
        policy[.qrCode] = .hidden
        #expect(policy[.qrCode] == .hidden)
        #expect(policy[.cast] == .native)
    }

    @Test func windowAnchorAppliesToToolbarKindsOnly() {
        var policy = CefChromiumSurface.Policy()
        let view = NSView()
        policy.anchor = .view(view)
        #expect(policy.anchor(for: .qrCode)?.isAnchored(to: view) == true)
        #expect(policy.anchor(for: .findBar) == nil)
        #expect(policy.anchor(for: .signIn) == nil)
        #expect(policy.anchor(for: .other("Install this page as an app")) != nil)
        #expect(policy.anchor(for: .other("view:AutofillPopupViewViews")) == nil)
        let own = NSView()
        policy.anchors[.findBar] = .view(own)
        policy.anchors[.qrCode] = .view(own)
        #expect(policy.anchor(for: .findBar)?.isAnchored(to: own) == true)
        #expect(policy.anchor(for: .qrCode)?.isAnchored(to: own) == true)
    }
}

@MainActor
@Suite struct SurfaceCapabilityTests {
    @Test func replaceableKindsAreThoseTheAppCanGetTheContentOf() {
        let replaceable: [CefChromiumSurface.Kind] = [.findBar, .qrCode, .cast, .share, .statusBubble, .fullscreenNotice,
                                                     .downloads, .bookmark, .pageInfo, .zoom]
        let notReplaceable: [CefChromiumSurface.Kind] = [.signIn, .translate, .savePassword, .autofillSuggestions,
                                                        .deviceChooser, .paymentRequest, .printPreview, .permissionPrompt,
                                                        .other("Install app?"), .other("view:TabGroupEditorBubbleView")]
        #expect(replaceable.allSatisfy { $0.capabilities.contains(.replace) })
        #expect(notReplaceable.allSatisfy { !$0.capabilities.contains(.replace) })
    }

    @Test func everyKindCanBeHidden() {
        let kinds: [CefChromiumSurface.Kind] = [.findBar, .statusBubble, .autofillSuggestions, .printPreview, .other("")]
        #expect(kinds.allSatisfy { $0.capabilities.contains(.hide) })
    }

    @Test func untitledOtherSurfacesBelongToThePage() {
        #expect(CefChromiumSurface.Kind.other("view:PopupViewViews").capabilities == [.hide])
        #expect(CefChromiumSurface.Kind.other("").capabilities == [.hide])
        #expect(CefChromiumSurface.Kind.other("Sign in to Chromium?").capabilities == [.anchor, .hide, .dismiss])
    }

    @Test func kindsWithoutAnchoringIgnoreAnchors() {
        var policy = CefChromiumSurface.Policy()
        let view = NSView()
        policy.anchor = .view(view)
        policy.anchors[.printPreview] = .view(view)
        policy.anchors[.autofillSuggestions] = .view(view)
        #expect(policy.anchor(for: .printPreview) == nil)
        #expect(policy.anchor(for: .autofillSuggestions) == nil)
        #expect(policy.anchor(for: .deviceChooser)?.isAnchored(to: view) == true)
    }

    @Test func leadingIsTheRightEdgeRightToLeft() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.userInterfaceLayoutDirection = .rightToLeft
        let rect = CGRect(x: 200, y: 500, width: 300, height: 20)
        let size = CGSize(width: 100, height: 50)
        let leading = try #require(CefChromiumSurface.Anchor.rect(rect, alignment: .leading).origin(for: size, in: window))
        #expect(leading.x == window.frame.minX + 500 - 100)
        let trailing = try #require(CefChromiumSurface.Anchor.rect(rect, alignment: .trailing).origin(for: size, in: window))
        #expect(trailing.x == window.frame.minX + 200)
    }
}
