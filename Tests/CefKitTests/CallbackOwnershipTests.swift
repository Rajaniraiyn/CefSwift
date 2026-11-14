import CCef
import CefBase
import Foundation
import Testing

@testable import CefKit

// CEF passes reference-counted objects into callbacks with a reference the
// callback must release, on every path. These hand the callbacks fake
// objects, allocated like CefKit's own, and check each is freed.

/// Records whether the fake object it owns was freed.
private final class FreedFlag {
    var isFreed = false
}

private final class FakeOwner {
    let flag: FreedFlag
    init(_ flag: FreedFlag) { self.flag = flag }
    deinit { flag.isFreed = true }
}

/// A fake CEF object of type `T` with one reference, for the callee.
private func fake<T>(_ type: T.Type, _ flag: FreedFlag) -> UnsafeMutablePointer<T> {
    cefAllocate(type, owner: FakeOwner(flag))
}

@MainActor
@Suite struct CallbackOwnershipTests {
    @Test func devToolsPopupViewIsReleased() {
        let delegate = BrowserViewDelegate(toolbar: .location, window: nil).makeDelegate()
        defer { cefRelease(delegate) }
        let view = FreedFlag(), popup = FreedFlag()
        _ = delegate.pointee.on_popup_browser_view_created(
            delegate, fake(cef_browser_view_t.self, view), fake(cef_browser_view_t.self, popup), 1)
        #expect(view.isFreed && popup.isFreed)
    }

    @Test func processMessageWithoutMessageReleasesFrame() {
        let client = CefBrowserClient(browser: nil, chromeToolbar: .init())
        let raw = client.makeClient()
        defer { cefRelease(raw) }
        let browser = FreedFlag(), frame = FreedFlag()
        _ = raw.pointee.on_process_message_received(
            raw, fake(cef_browser_t.self, browser), fake(cef_frame_t.self, frame), PID_RENDERER, nil)
        #expect(browser.isFreed && frame.isFreed)
    }

    @Test func downloadWithoutItemReleasesCallback() {
        let client = CefBrowserClient(browser: nil, chromeToolbar: .init())
        let raw = client.makeClient()
        defer { cefRelease(raw) }
        let handler = client.handlers.retained(cef_download_handler_t.self)!
        defer { cefRelease(handler) }
        let browser = FreedFlag(), callback = FreedFlag()
        _ = handler.pointee.on_before_download(
            handler, fake(cef_browser_t.self, browser), nil, nil, fake(cef_before_download_callback_t.self, callback))
        #expect(browser.isFreed && callback.isFreed)
    }

    @Test func credentialsWithoutBrowserReleaseCallback() {
        let client = CefBrowserClient(browser: nil, chromeToolbar: .init())
        let raw = client.makeClient()
        defer { cefRelease(raw) }
        let handler = client.handlers.retained(cef_request_handler_t.self)!
        defer { cefRelease(handler) }
        let callback = FreedFlag()
        _ = handler.pointee.get_auth_credentials(
            handler, nil, nil, 0, nil, 0, nil, nil, fake(cef_auth_callback_t.self, callback))
        #expect(callback.isFreed)
    }

    @Test func schemeReadWithoutBufferReleasesCallback() {
        let resource = SchemeResourceHandler(handler: CefDirectorySchemeHandler(directory: URL(fileURLWithPath: "/tmp")))
            .makeHandler()
        defer { cefRelease(resource) }
        let callback = FreedFlag()
        _ = resource.pointee.read(resource, nil, 0, nil, fake(cef_resource_read_callback_t.self, callback))
        #expect(callback.isFreed)
    }

    /// The client retains its browser until creation, and its handler
    /// structs retain the client; a failed creation must undo both.
    @Test func failedCreationFreesClientAndBrowser() {
        weak var weakClient: CefBrowserClient?
        weak var weakBrowser: CefBrowser?
        do {
            let browser = CefBrowser(url: URL(string: "about:blank"))
            let client = CefBrowserClient(browser: browser, chromeToolbar: .init())
            // A failed creation call releases the client it was given.
            cefRelease(client.makeClient())
            browser.client = client
            weakClient = client
            weakBrowser = browser
            browser.creationFailed()
            #expect(browser.state == .closed)
        }
        #expect(weakClient == nil)
        #expect(weakBrowser == nil)
    }
}
