import AppKit
import CCef
import CefBase

// MARK: - Keyboard focus traversal

/// Tab and Shift-Tab between a page and the app's other controls.
///
/// Leaving: when Tab moves past the page's last focusable element (or
/// Shift-Tab past its first), Chromium calls `on_take_focus`, and CefKit
/// selects the next (or previous) key view of the browser's host view in
/// the window's key-view loop, as AppKit would for any other control.
///
/// Entering: the host view (`CefWindowedBrowserView`,
/// `CefOffscreenBrowserView`) is in the key-view loop; when the loop selects
/// it, it calls ``hostViewDidBecomeKey(selecting:)``, which gives the page
/// focus and focuses its first (or last) element.
extension CefBrowser {
    /// Chromium is giving focus away: `next` for Tab past the last element,
    /// `false` for Shift-Tab past the first.
    func pageDidTakeFocus(next: Bool) {
        guard let view = hostView, let window = view.window,
              let target = Self.keyView(after: view, forward: next)
        else { return }
        window.makeFirstResponder(target)
    }

    /// The nearest valid key view outside `view` and its subviews, in the
    /// window's key-view loop; `nil` when the loop has none.
    static func keyView(after view: NSView, forward: Bool) -> NSView? {
        var candidate = forward ? view.nextValidKeyView : view.previousValidKeyView
        var visited = Set<ObjectIdentifier>()
        while let current = candidate, visited.insert(ObjectIdentifier(current)).inserted {
            if current !== view, !current.isDescendant(of: view) { return current }
            candidate = forward ? current.nextValidKeyView : current.previousValidKeyView
        }
        return nil
    }

    /// Whether the window's first responder is `view` or inside it.
    private func isFirstResponderInside(_ view: NSView) -> Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// The first view in `view`'s subtree, depth first, that accepts first
    /// responder.
    static func firstAcceptingResponder(in view: NSView) -> NSView? {
        if view.acceptsFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstAcceptingResponder(in: subview) { return found }
        }
        return nil
    }

    /// Tells Chromium the host view became the key view, as
    /// ``hostViewDidBecomeKey()`` does, moving AppKit's first responder into
    /// a windowed browser's native view; when the key-view loop selected it
    /// (Tab or Shift-Tab from another control), also focuses the page's
    /// first or last focusable element.
    ///
    /// CEF has no call for a page's initial focus, so CefKit clears the
    /// page's focused element in its renderer (one `blur()` through the
    /// helper's renderer code) and sends Chromium a Tab (or Shift-Tab) key
    /// press, which focuses the first (or last) element: an AppKit key
    /// event for a windowed browser, `send_key_event` for an offscreen one.
    public func hostViewDidBecomeKey(selecting direction: NSWindow.SelectionDirection) {
        hostViewDidBecomeKey()
        if !isOffscreen, let native = nativeView, let window = native.window, !isFirstResponderInside(native) {
            // Chromium's view for the page, nested in the browser's view.
            if let target = Self.firstAcceptingResponder(in: native) { window.makeFirstResponder(target) }
        }
        guard direction != .directSelection, state == .live, !isDiscarded else { return }
        let reverse = direction == .selectingPrevious
        Task {
            // The key press must reach the page after the blur, and after
            // the page has taken focus: Chromium tells the renderer about
            // the focus on another channel than the one keys travel on, so
            // a key sent at once can arrive first and move nothing. If the
            // page has not said so in two seconds, the key is sent anyway.
            _ = try? await evaluateJavaScript("""
                document.activeElement?.blur();
                new Promise(resolve => document.hasFocus() ? resolve(0)
                    : addEventListener('focus', () => resolve(0), { once: true }))
                """, timeout: .seconds(2))
            guard state == .live, let view = hostView, let window = view.window, isFirstResponderInside(view) else { return }
            if isOffscreen {
                let modifiers: CefEventModifiers = reverse ? [.shift] : []
                // VK_TAB, kVK_Tab.
                for phase in [CefKeyEvent.Phase.rawKeyDown, .character, .keyUp] {
                    sendKeyEvent(CefKeyEvent(phase: phase, modifiers: modifiers, windowsKeyCode: 0x09, nativeKeyCode: 48,
                                             character: "\t", unmodifiedCharacter: "\t"))
                }
            } else {
                // A windowed browser takes keys from AppKit, through its
                // native view; CEF's send_key_event does not reach its page.
                Self.sendTabKey(to: window, reverse: reverse)
            }
        }
    }

    /// Posts a Tab (or Shift-Tab) press to `window`'s first responder, as
    /// the keyboard would.
    private static func sendTabKey(to window: NSWindow, reverse: Bool) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: reverse ? [.shift] : [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: reverse ? "\u{19}" : "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
            else { continue }
            window.sendEvent(event)
        }
    }
}

// MARK: - Focus handler

extension CefBrowserClient {
    func makeFocusHandler() -> UnsafeMutablePointer<cef_focus_handler_t> {
        let h = cefAllocate(cef_focus_handler_t.self, owner: self)
        h.pointee.on_take_focus = { s, browser, next in
            CefBrowserClient.run(s, browser, default: ()) { _, b in b.pageDidTakeFocus(next: next != 0) }
        }
        return h
    }
}
