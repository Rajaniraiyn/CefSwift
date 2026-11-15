import os
import AppKit
import CCef
import Foundation
import CefBase

extension CefBrowserClient {
    // MARK: Display

    func makeDisplayHandler() -> UnsafeMutablePointer<cef_display_handler_t> {
        let h = cefAllocate(cef_display_handler_t.self, owner: self)
        h.pointee.on_title_change = { s, page, title in
            let title = CefStringUtil.string(from: title)
            CefBrowserClient.run(s, page, default: ()) { _, b in b.applyTitle(title) }
        }
        h.pointee.on_address_change = { s, page, frame, url in
            let isMain = frame.map { $0.pointee.is_main($0) != 0 } ?? false
            let id = frame.flatMap { CefStringUtil.takingUserFree($0.pointee.get_identifier($0)) }
            cefRelease(frame)
            let url = CefStringUtil.string(from: url)
            CefBrowserClient.run(s, page, default: ()) { _, b in
                if let id { b.frameDidUpdate(id, url: URL(string: url)) }
                if isMain {
                    b.applyURL(url)
                    b.trackMainFrameAddressDidChange(URL(string: url))
                    b.refreshConnectionSecurity()
                }
            }
        }
        h.pointee.on_favicon_urlchange = { s, page, iconURLs in
            let urls = cefStrings(from: iconURLs).compactMap(URL.init(string:))
            CefBrowserClient.run(s, page, default: ()) { _, b in b.applyFavicon(urls) }
        }
        h.pointee.on_fullscreen_mode_change = { s, page, fullscreen in
            CefBrowserClient.run(s, page, default: ()) { _, b in b.applyFullscreen(fullscreen != 0) }
        }
        h.pointee.on_loading_progress_change = { s, page, progress in
            CefBrowserClient.run(s, page, default: ()) { _, b in b.applyProgress(progress) }
        }
        h.pointee.on_status_message = { s, page, value in
            let text = CefStringUtil.string(from: value)
            CefBrowserClient.run(s, page, default: ()) { _, b in b.applyStatusText(text) }
        }
        h.pointee.on_console_message = { s, page, level, message, source, line in
            CefBrowserClient.run(s, page, default: ()) { _, b in
                // Converted only for a delegate; the strings live for this call.
                guard let delegate = b.delegate else { return }
                delegate.page(b, didLog: CefConsoleMessage(
                    level: CefLogSeverity(cefValue: level),
                    text: CefStringUtil.string(from: message),
                    source: CefStringUtil.string(from: source),
                    line: Int(line)
                ))
            }
            return 0  // keep Chromium's own logging
        }
        h.pointee.on_media_access_change = { s, page, hasVideo, hasAudio in
            var capture: CefPage.MediaCapture = []
            if hasVideo != 0 { capture.insert(.video) }
            if hasAudio != 0 { capture.insert(.audio) }
            CefBrowserClient.run(s, page, default: ()) { _, b in
                if b.mediaCapture != capture { b.mediaCapture = capture }
            }
        }
        h.pointee.on_cursor_change = { s, page, _, type, _ in
            let cursor = CefCursorType(cefValue: type)
            // Windowed pages apply the cursor themselves; offscreen ones
            // have no window, so the host does it.
            CefBrowserClient.run(s, page, default: ()) { client, _ in client.offscreenHost?.offscreenDidChangeCursor(cursor) }
            return 0
        }
        // Windowed and Chrome-style pages show their tooltips unless this
        // returns 1; offscreen ones leave them to the host, and CEF ignores
        // the return value.
        h.pointee.on_tooltip = { s, page, text in
            let tip = text.map { CefStringUtil.string(from: $0.pointee) } ?? ""
            return CefBrowserClient.run(s, page, default: Int32(0)) { client, b in
                let custom = b.tooltipDidChange(tip)
                client.offscreenHost?.offscreenDidChangeToolTip(custom || tip.isEmpty ? nil : tip)
                return custom ? 1 : 0
            }
        }
        return h
    }
}

extension CefBrowserClient {
    // MARK: Keyboard

    func makeKeyboardHandler() -> UnsafeMutablePointer<cef_keyboard_handler_t> {
        let h = cefAllocate(cef_keyboard_handler_t.self, owner: self)
        h.pointee.on_pre_key_event = { s, page, event, _, _ in
            let keyEvent = event.map { CefKeyEvent(raw: $0.pointee) }
            return CefBrowserClient.run(s, page, default: 0) { _, b in
                guard let keyEvent, let delegate = b.delegate else { return 0 }
                return delegate.page(b, handleKeyEvent: keyEvent, isBeforePage: true) ? 1 : 0
            }
        }
        h.pointee.on_key_event = { s, page, event, _ in
            let keyEvent = event.map { CefKeyEvent(raw: $0.pointee) }
            return CefBrowserClient.run(s, page, default: 0) { _, b in
                guard let keyEvent, let delegate = b.delegate else { return 0 }
                return delegate.page(b, handleKeyEvent: keyEvent, isBeforePage: false) ? 1 : 0
            }
        }
        return h
    }
}

extension CefBrowserClient {
    // MARK: Find

    func makeFindHandler() -> UnsafeMutablePointer<cef_find_handler_t> {
        let h = cefAllocate(cef_find_handler_t.self, owner: self)
        h.pointee.on_find_result = { s, page, _, count, selection, activeMatch, finalUpdate in
            let rect = selection.map { CGRect($0.pointee) }.flatMap { $0.isEmpty ? nil : $0 }
            let result = CefPage.FindResult(
                matchCount: Int(count), activeMatchIndex: Int(activeMatch), isFinal: finalUpdate != 0, selectionRect: rect)
            CefBrowserClient.run(s, page, default: ()) { _, b in b.applyFindResult(result) }
        }
        return h
    }
}
