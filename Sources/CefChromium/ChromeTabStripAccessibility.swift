import AppKit
import CefKit

/// Changes to tab groups that only Chromium's own tab strip can make: no
/// WebUI page has `chrome.tabGroups` (Chromium grants it to extensions
/// only), and neither `tab_strip_internals.mojom` nor any Chrome command
/// renames, recolours or collapses a group. Chrome's tab strip is still
/// there beneath the app's views, so CefChromium works its group header
/// through accessibility, as assistive software would: pressing it
/// collapses or expands the group; its menu action opens Chrome's group
/// editor bubble, which CefChromium keeps transparent while it types the
/// name (through the bubble's text input, as a keyboard would) and presses
/// a colour.
@MainActor
enum ChromeTabStripAccessibility {
    enum MouseButton { case left, right }

    /// Collapses or expands `group`, as a click on its header does: the
    /// header takes no accessibility press, so the click is sent to
    /// Chromium's content view at the header, beneath the app's views.
    static func toggleCollapsed(_ group: CefTabGroup, in window: CefChromeWindow) async throws {
        let header = try header(of: group, in: window)
        let wasCollapsed = group.isCollapsed
        try click(header, in: window, button: .left)
        for _ in 0..<15 {
            await window.strip.nextRead()
            if group.isCollapsed != wasCollapsed { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw CefTabStrip.Error.unsupported("Chromium's group header did not take the click.")
    }

    /// Renames or recolours `group` in Chrome's group editor, opened as a
    /// right click on the header opens it, and kept transparent meanwhile.
    static func edit(_ group: CefTabGroup, in window: CefChromeWindow, title: String?, color: CefTabGroup.Color?) async throws {
        let header = try header(of: group, in: window)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        // Transparent from its first frame on.
        let hider = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            guard let shown = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                if !before.contains(ObjectIdentifier(shown)), shown.alphaValue > 0 { shown.alphaValue = 0 }
            }
        }
        defer { NotificationCenter.default.removeObserver(hider) }
        if header.accessibilityPerformShowMenu?() != true { try click(header, in: window, button: .right) }
        var bubble: NSWindow?
        var elements: [AnyObject] = []
        for _ in 0..<50 {
            for candidate in NSApp.windows where !before.contains(ObjectIdentifier(candidate)) {
                guard let content = candidate.contentView else { continue }
                let found = ChromeAccessibilityFilter.descendants(of: content)
                if found.contains(where: { ($0.accessibilityRole?() ?? nil) == .textField }) {
                    bubble = candidate
                    elements = found
                }
            }
            if bubble != nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let bubble, let content = bubble.contentView else {
            let opened = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) }.map { "\(type(of: $0))" }
            throw CefTabStrip.Error.unsupported("Chromium's group editor did not open (new windows: \(opened)).")
        }
        bubble.alphaValue = 0
        if let color {
            // Chrome's colour buttons, in its colour order.
            let swatches = elements.filter {
                let role = $0.accessibilityRole?() ?? nil
                return role == .radioButton || role == .checkBox
            }
            guard swatches.count >= CefTabGroup.Color.allCases.count else {
                content.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
                throw CefTabStrip.Error.unsupported("Chromium's group editor has \(swatches.count) colours.")
            }
            _ = swatches[color.rawValue].accessibilityPerformPress?()
            try? await Task.sleep(for: .milliseconds(30))
        }
        if let title, let field = elements.first(where: { ($0.accessibilityRole?() ?? nil) == .textField }) {
            _ = field.setAccessibilityFocused?(true)
            bubble.makeKey()
            try? await Task.sleep(for: .milliseconds(30))
            // Typed through the bubble's text input, as the keyboard does,
            // so Chromium takes it as the user's edit.
            content.doCommand(by: #selector(NSResponder.selectAll(_:)))
            if let input = content as? NSTextInputClient {
                if title.isEmpty {
                    content.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                } else {
                    input.insertText(title, replacementRange: NSRange(location: NSNotFound, length: 0))
                }
            }
            try? await Task.sleep(for: .milliseconds(30))
            // Return closes the editor, keeping the name.
            content.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        } else {
            content.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        }
        for _ in 0..<25 where bubble.isVisible { try? await Task.sleep(for: .milliseconds(20)) }
        if bubble.isVisible { bubble.close() }
        window.window?.makeKey()
    }

    /// Sends a click at `element`'s middle to the window's content view,
    /// Chromium's, as AppKit would send one that reached it.
    private static func click(_ element: AnyObject, in window: CefChromeWindow, button: MouseButton) throws {
        guard let nsWindow = window.window, let content = nsWindow.contentView,
              let frame = element.accessibilityFrame?() as CGRect?, frame.width > 0
        else { throw CefTabStrip.Error.unsupported("Chromium's group header has no place in the window.") }
        let point = nsWindow.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
        let (down, up): (NSEvent.EventType, NSEvent.EventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        for type in [down, up] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: nsWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == down ? 1 : 0)
            else { continue }
            switch type {
            case .leftMouseDown: content.mouseDown(with: event)
            case .leftMouseUp: content.mouseUp(with: event)
            case .rightMouseDown: content.rightMouseDown(with: event)
            default: content.rightMouseUp(with: event)
            }
        }
    }

    /// The actions an element of Chromium's names.
    private static func actionNames(of element: AnyObject) -> [String] {
        guard let object = element as? NSObject, object.responds(to: NSSelectorFromString("accessibilityActionNames")) else { return [] }
        return object.perform(NSSelectorFromString("accessibilityActionNames"))?.takeUnretainedValue() as? [String] ?? []
    }

    /// Chromium's header view for `group`: the element beside the group's
    /// first tab in Chrome's tab strip that is not a tab.
    private static func header(of group: CefTabGroup, in window: CefChromeWindow) throws -> AnyObject {
        guard let content = window.window?.contentView else { throw CefTabStrip.Error.tabClosed }
        let elements = ChromeAccessibilityFilter.descendants(of: content)
        guard let strip = elements.first(where: { ($0.accessibilityRole?() ?? nil) == .tabGroup }) else {
            throw CefTabStrip.Error.unsupported("Chromium's tab strip is not in the window's accessibility.")
        }
        let children = ChromeAccessibilityFilter.descendants(of: strip, limit: 1)
        let tabs = children.filter { ($0.accessibilityRole?() ?? nil) == .radioButton }
        // Chrome's group headers are tab groups themselves, among the tabs.
        let headers = children.filter { ($0.accessibilityRole?() ?? nil) == .tabGroup }
        // Headers in strip order match groups in strip order.
        let order = window.groups.firstIndex { $0 === group }
        if let order, headers.count == window.groups.count { return headers[order] }
        // Otherwise the one ending where the group's first tab starts.
        if let first = group.tabs.first, first.index < tabs.count,
           let start = (tabs[first.index].accessibilityFrame?() as CGRect?)?.minX {
            if let match = headers.min(by: {
                abs(($0.accessibilityFrame?() ?? .zero).maxX - start) < abs(($1.accessibilityFrame?() ?? .zero).maxX - start)
            }) { return match }
        }
        let seen = children.map { element in
            "\((element.accessibilityRole?() ?? nil)?.rawValue ?? "-") '\((element.accessibilityLabel?() ?? nil) ?? "")' \(actionNames(of: element))"
        }
        throw CefTabStrip.Error.unsupported(
            "Chromium's header for the group was not found (\(headers.count) headers, \(window.groups.count) groups: \(seen)).")
    }
}
