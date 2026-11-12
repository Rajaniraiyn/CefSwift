import AppKit
import Testing

@testable import CefKit

@MainActor
@Suite struct SurfaceAnchorTests {
    private func window() -> NSWindow {
        NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: true)
    }

    @Test func hangsBelowTheAnchorWithSpacing() throws {
        let window = window()
        let anchor = CefSurfaceAnchor.rect(CGRect(x: 200, y: 500, width: 300, height: 20), alignment: .leading, spacing: 6)
        let origin = try #require(anchor.origin(for: CGSize(width: 200, height: 100), in: window))
        #expect(origin.x == window.frame.minX + 200)
        #expect(origin.y == window.frame.minY + 500 - 6 - 100)
    }

    @Test func alignsTrailingAndCenter() throws {
        let window = window()
        let rect = CGRect(x: 200, y: 500, width: 300, height: 20)
        let size = CGSize(width: 100, height: 50)
        let trailing = try #require(CefSurfaceAnchor.rect(rect, alignment: .trailing).origin(for: size, in: window))
        #expect(trailing.x == window.frame.minX + 500 - 100)
        let center = try #require(CefSurfaceAnchor.rect(rect, alignment: .center).origin(for: size, in: window))
        #expect(center.x == window.frame.minX + 350 - 50)
    }

    @Test func staysInsideTheWindow() throws {
        let window = window()
        let anchor = CefSurfaceAnchor.rect(CGRect(x: 760, y: 500, width: 30, height: 20), alignment: .leading)
        let origin = try #require(anchor.origin(for: CGSize(width: 200, height: 100), in: window))
        #expect(origin.x + 200 <= window.frame.maxX - 4)
    }

    @Test func viewAnchorNeedsTheViewInTheWindow() {
        let window = window()
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        let anchor = CefSurfaceAnchor.view(view)
        #expect(anchor.origin(for: CGSize(width: 10, height: 10), in: window) == nil)
        #expect(anchor.isAnchored(to: view))
        window.contentView?.addSubview(view)
        #expect(anchor.origin(for: CGSize(width: 10, height: 10), in: window) != nil)
    }
}

@MainActor
@Suite struct ChromiumUITests {
    @Test func presentationsDefaultToNative() {
        var ui = CefChromiumUI()
        #expect(ui[.qrCode] == .native)
        ui[.qrCode] = .hidden
        #expect(ui[.qrCode] == .hidden)
        #expect(ui[.cast] == .native)
    }

    @Test func windowAnchorAppliesToToolbarKindsOnly() {
        var ui = CefChromiumUI()
        let view = NSView()
        ui.anchor = .view(view)
        #expect(ui.anchor(for: .qrCode)?.isAnchored(to: view) == true)
        #expect(ui.anchor(for: .findBar) == nil)
        #expect(ui.anchor(for: .signIn) == nil)
        #expect(ui.anchor(for: .other("Install this page as an app")) != nil)
        #expect(ui.anchor(for: .other("view:AutofillPopupViewViews")) == nil)
        let own = NSView()
        ui.anchors[.findBar] = .view(own)
        ui.anchors[.qrCode] = .view(own)
        #expect(ui.anchor(for: .findBar)?.isAnchored(to: own) == true)
        #expect(ui.anchor(for: .qrCode)?.isAnchored(to: own) == true)
    }
}

@Suite struct SwipeIndicatorTests {
    @Test func rubberBandsPastTheCommitPoint() {
        #expect(CefNavigationGestureIndicatorView.rubberBand(0.5) == 0.5)
        #expect(CefNavigationGestureIndicatorView.rubberBand(1) == 1)
        let far = CefNavigationGestureIndicatorView.rubberBand(3)
        #expect(far > 1 && far < 1.35)
        #expect(CefNavigationGestureIndicatorView.rubberBand(2) < far)
    }
}
