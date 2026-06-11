import AppKit
import Foundation
import Testing

@testable import CCef
@testable import CefKit

/// Unit tests for the chrome-style (CEF Views) bridge. No CEF framework is
/// required: the delegate structs are allocated by CefSwift's own
/// ccef_object allocator and their callbacks are exercised directly.
@MainActor
@Suite struct ChromeBrowserOptionsTests {

    @Test func defaults() {
        let options = CefChromeBrowserOptions()
        #expect(options.showsChromeToolbar == false)  // hide Chrome's UI by default
        #expect(options.isFrameless == false)
        #expect(options.initialBounds == nil)
        #expect(options.backgroundColor == nil)
    }

    @Test func screenRectConversionRoundsAndFlips() {
        let rect = CGRect(x: 10.4, y: 20, width: 800.6, height: 600)
        let converted = CefChromeBrowser.cefScreenRect(from: rect)
        #expect(converted.x == 10)
        #expect(converted.width == 801)
        #expect(converted.height == 600)
        // y is flipped against the primary display height (same query the
        // implementation uses; headless fallback flips against rect.maxY).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        #expect(converted.y == Int32((primaryHeight - rect.maxY).rounded()))
    }
}

@MainActor
@Suite struct ChromeDelegateBridgeTests {

    @Test func browserViewDelegateReflectsToolbarOption() {
        for shows in [false, true] {
            var options = CefChromeBrowserOptions()
            options.showsChromeToolbar = shows

            let owner = ChromeBrowserViewDelegate(chrome: nil, options: options)
            let d = owner.makeStruct()
            defer { _ = ccef_object_release(UnsafeMutableRawPointer(d)) }

            #expect(d.pointee.on_browser_created != nil)
            #expect(d.pointee.on_browser_destroyed != nil)
            #expect(d.pointee.get_delegate_for_popup_browser_view != nil)
            #expect(d.pointee.on_popup_browser_view_created != nil)

            let toolbar = d.pointee.get_chrome_toolbar_type?(d, nil)
            #expect(toolbar == (shows ? CEF_CTT_NORMAL : CEF_CTT_NONE))
            #expect(d.pointee.get_browser_runtime_style?(d) == CEF_RUNTIME_STYLE_CHROME)
        }
    }

    @Test func popupDelegateInheritsToolbarConfiguration() throws {
        var options = CefChromeBrowserOptions()
        options.showsChromeToolbar = true

        let owner = ChromeBrowserViewDelegate(chrome: nil, options: options)
        let d = owner.makeStruct()
        defer { _ = ccef_object_release(UnsafeMutableRawPointer(d)) }

        let popup = d.pointee.get_delegate_for_popup_browser_view?(d, nil, nil, nil, 0)
        try #require(popup != nil)
        defer { _ = ccef_object_release(UnsafeMutableRawPointer(popup!)) }
        #expect(popup!.pointee.get_chrome_toolbar_type?(popup, nil) == CEF_CTT_NORMAL)
    }

    @Test func windowDelegateReflectsFramelessOption() {
        for frameless in [false, true] {
            var options = CefChromeBrowserOptions()
            options.isFrameless = frameless

            let owner = ChromeWindowDelegate(chrome: nil, options: options)
            let d = owner.makeStruct()
            defer { _ = ccef_object_release(UnsafeMutableRawPointer(d)) }

            #expect(d.pointee.is_frameless?(d, nil) == (frameless ? 1 : 0))
            // Frameless (embedding) windows hide the traffic lights.
            #expect(d.pointee.with_standard_window_buttons?(d, nil) == (frameless ? 0 : 1))
            #expect(d.pointee.get_initial_show_state?(d, nil) == CEF_SHOW_STATE_NORMAL)
            #expect(d.pointee.get_window_runtime_style?(d) == CEF_RUNTIME_STYLE_CHROME)
            // No chrome browser attached → closing is always allowed.
            #expect(d.pointee.can_close?(d, nil) == 1)
        }
    }

    @Test func windowDelegateInitialBounds() {
        // nil bounds → empty rect (CEF centers using the preferred size path;
        // CefChromeBrowser then calls center_window with a default size).
        let owner = ChromeWindowDelegate(chrome: nil, options: .init())
        let d = owner.makeStruct()
        defer { _ = ccef_object_release(UnsafeMutableRawPointer(d)) }
        let rect = d.pointee.get_initial_bounds?(d, nil)
        #expect(rect?.width == 0)
        #expect(rect?.height == 0)
    }
}
