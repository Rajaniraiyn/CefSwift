import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI

/// Checks of the offscreen accessibility tree, read the way assistive apps
/// read it: through the NSAccessibility protocol of the host view.
extension SelfTest {
    static func offscreenAccessibilityChecks() async {
        await accessibilityTreeChecks()
        await accessibilityDisabledChecks()
        await accessibilityDiscardChecks()
        // The cost measurement loads large pages; it runs only on its own.
        if ProcessInfo.processInfo.environment["SELFTEST_ONLY"] == "accessibility" {
            await accessibilityCostChecks()
        }
    }

    // MARK: The tree

    static func accessibilityTreeChecks() async {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        let browser = CefBrowser(url: URL(string: "selftest://ax/page.html")!, configuration: configuration)
        let view = hostOffscreen(browser)
        defer { view.removeFromSuperview() }

        let recorder = NotificationRecorder(view: view)
        defer { recorder.stop() }

        check("accessibility: page loads offscreen", await loaded(browser, title: "ax"), detail: browser.title)
        let assistiveAppPresent = NSWorkspace.shared.isVoiceOverEnabled || CefApplication.isAccessibilityRequested
        if assistiveAppPresent {
            skip("accessibility: tree stays off until asked", because: "an assistive app is already running", .environment)
        } else {
            check("accessibility: tree stays off until asked", !browser.isAccessibilityEnabled)
        }

        // The first query from an assistive app turns the tree on.
        _ = view.accessibilityChildren()
        check("accessibility: first query turns the tree on", browser.isAccessibilityEnabled)
        let loaded = await waitUntil {
            allElements(under: view).contains { ($0.accessibilityTitle() ?? $0.accessibilityLabel()) == "Inner button" }
        }
        check("accessibility: tree arrives, iframe included", loaded,
              detail: "\(browser.accessibilityTree.nodeCount) nodes, enabled \(browser.isAccessibilityEnabled), discarded \(browser.isDiscarded), state \(browser.state), title \(browser.title), loading \(browser.isLoading)")

        let children = view.accessibilityChildren() ?? []
        let webArea = children.first as? NSAccessibilityElement
        check("accessibility: host view's child is the web area",
              children.count == 1 && webArea?.accessibilityRole()?.rawValue == "AXWebArea"
                  && (webArea?.accessibilityParent() as AnyObject?) === view,
              detail: "\(children.count) children, \(String(describing: webArea?.accessibilityRole()))")

        let elements = allElements(under: view)
        func find(_ role: NSAccessibility.Role, _ name: String) -> NSAccessibilityElement? {
            elements.first { $0.accessibilityRole() == role && ($0.accessibilityTitle() ?? $0.accessibilityLabel()) == name }
        }

        let heading = find(.init(rawValue: "AXHeading"), "Accessible heading")
        check("accessibility: heading with level", (heading?.accessibilityValue() as? NSNumber)?.intValue == 1,
              detail: String(describing: heading?.accessibilityValue()))
        let link = find(.link, "Example link")
        check("accessibility: link with URL", link?.accessibilityURL()?.fragment == "target",
              detail: String(describing: link?.accessibilityURL()))
        let button = find(.button, "Press me")
        check("accessibility: button", button != nil && button?.isAccessibilityEnabled() == true)
        let field = elements.first { $0.accessibilityRole() == .textField && ($0.accessibilityValue() as? String) == "Ada" }
        check("accessibility: text field with label, value and placeholder",
              field != nil && (field?.accessibilityTitle() ?? field?.accessibilityLabel()) == "Name"
                  && field?.accessibilityPlaceholderValue() == "Your name"
                  && field?.accessibilityNumberOfCharacters() == 3
                  && field?.accessibilityString(for: NSRange(location: 1, length: 2)) == "da",
              detail: "\(String(describing: field?.accessibilityTitle())) \(String(describing: field?.accessibilityPlaceholderValue()))")
        let checkbox = find(.checkBox, "Subscribe")
        check("accessibility: checkbox state", (checkbox?.accessibilityValue() as? NSNumber)?.intValue == 1,
              detail: String(describing: checkbox?.accessibilityValue()))
        let list = elements.first { $0.accessibilityRole() == .list }
        check("accessibility: list with items", list?.accessibilityChildren()?.count == 3,
              detail: "\(list?.accessibilityChildren()?.count ?? -1) items")
        let image = find(.image, "A red square")
        check("accessibility: image with alt text", image != nil)
        let landmark = elements.first { $0.accessibilitySubrole()?.rawValue == "AXLandmarkNavigation" }
        check("accessibility: landmark", landmark != nil)

        let innerButton = find(.button, "Inner button")
        let frameGroup = innerButton.flatMap { ancestor(of: $0, role: .group, below: view) }
        check("accessibility: iframe content inside the iframe",
              innerButton != nil && frameGroup.map { $0.accessibilityFrame().insetBy(dx: -1, dy: -1).contains(innerButton!.accessibilityFrame()) } == true,
              detail: "\(String(describing: innerButton?.accessibilityFrame())) in \(String(describing: frameGroup?.accessibilityFrame()))")

        // Frames: in the view's screen rect, and where the page draws them.
        let viewFrame = window.convertToScreen(view.convert(view.bounds, to: nil))
        await expect("accessibility: frames match the page's layout") {
            guard let button else { return false }
            let rect = try await browser.evaluateJavaScript(
                "(() => { const r = document.getElementById('press').getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; })()"
            ).arrayValue?.compactMap(\.doubleValue) ?? []
            guard rect.count == 4 else { return false }
            let expected = window.convertToScreen(view.convert(CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), to: nil))
            let actual = button.accessibilityFrame()
            let close = abs(actual.minX - expected.minX) < 2 && abs(actual.minY - expected.minY) < 2
                && abs(actual.width - expected.width) < 2 && abs(actual.height - expected.height) < 2
            if !close { print("     frame \(actual) expected \(expected)") }
            return close && viewFrame.contains(actual)
        }

        if let button {
            let center = CGPoint(x: button.accessibilityFrame().midX, y: button.accessibilityFrame().midY)
            let hit = view.accessibilityHitTest(center) as AnyObject?
            check("accessibility: hit test finds the button", hit === button,
                  detail: String(describing: (hit as? NSAccessibilityElement)?.accessibilityRole()))
        }

        if let field {
            recorder.posted.removeAll()
            field.setAccessibilityFocused(true)
            let focused = await waitUntil(timeout: .seconds(5)) {
                recorder.posted.contains { $0.notification == .focusedUIElementChanged && $0.element == ObjectIdentifier(field) }
            }
            check("accessibility: focusing the field posts focus changed", focused,
                  detail: recorder.posted.map(\.notification.rawValue).joined(separator: ","))
            check("accessibility: focused element is the field",
                  (view.accessibilityFocusedUIElement as AnyObject?) === field && field.isAccessibilityFocused())
            await expect("accessibility: page focus follows") {
                try await browser.evaluateJavaScript("document.activeElement.id").stringValue == "field"
            }

            recorder.posted.removeAll()
            let fallbacks = CefAccessibilityTesting.setValueProtocolFallbacks
            field.setAccessibilityValue("Grace")
            await expect("accessibility: setting the value types into the field") {
                let typed = await waitUntilAsync(timeout: .seconds(5)) {
                    (try? await browser.evaluateJavaScript("document.getElementById('field').value").stringValue) == "Grace"
                }
                let reflected = await waitUntil(timeout: .seconds(5)) {
                    (field.accessibilityValue() as? String) == "Grace"
                        && recorder.posted.contains { $0.notification == .valueChanged && $0.element == ObjectIdentifier(field) }
                }
                return typed && reflected
            }
            check("accessibility: the value goes in as input-method text, not through the DevTools Protocol",
                  CefAccessibilityTesting.setValueProtocolFallbacks == fallbacks)
        }

        if let button {
            _ = button.accessibilityPerformPress()
            check("accessibility: press activates the button", await waitUntil(timeout: .seconds(5)) { browser.title == "pressed" },
                  detail: browser.title)
        }

        if let far = find(.button, "Far button") {
            check("accessibility: far button starts out of view", !viewFrame.intersects(far.accessibilityFrame()),
                  detail: "\(far.accessibilityFrame())")
            // AXScrollToVisible exists only in the informal protocol.
            far.perform(NSSelectorFromString("accessibilityPerformAction:"), with: "AXScrollToVisible")
            check("accessibility: scroll to visible brings it into view", await waitUntil(timeout: .seconds(5)) {
                viewFrame.contains(far.accessibilityFrame())
            }, detail: "\(far.accessibilityFrame()) in \(viewFrame)")
        } else {
            check("accessibility: far button exists", false)
        }

        recorder.posted.removeAll()
        browser.executeJavaScript("document.getElementById('live').textContent = 'Saved'")
        check("accessibility: live region announces", await waitUntil(timeout: .seconds(5)) {
            recorder.posted.contains { $0.notification == .announcementRequested }
        }, detail: recorder.posted.map(\.notification.rawValue).joined(separator: ","))

        browser.close(force: true)
        check("accessibility: browser closes", await waitUntil { browser.state == .closed })
        check("accessibility: tree is emptied at close",
              browser.accessibilityTree.isEmpty && !browser.isAccessibilityEnabled && (view.accessibilityChildren() ?? []).isEmpty
                  && button?.isAccessibilityElement() == false)
    }

    // MARK: Outside clients

    /// Shows the page without querying it, so that a separate process can
    /// read it through the system's AXUIElement API, and reports whether
    /// that client's request turned the tree on.
    static func accessibilityExternalClientSession() async {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        let browser = CefBrowser(url: URL(string: "selftest://ax/page.html")!, configuration: configuration)
        let view = hostOffscreen(browser)
        _ = await loaded(browser, title: "ax")
        print("READY \(ProcessInfo.processInfo.processIdentifier)")
        check("external: tree turns on for an outside client", await waitUntil(timeout: .seconds(30)) {
            browser.isAccessibilityEnabled && browser.accessibilityTree.nodeCount > 40
        })
        check("external: AXManualAccessibility was seen", CefApplication.isAccessibilityRequested)
        let hold = Double(ProcessInfo.processInfo.environment["SELFTEST_AX_HOLD"] ?? "") ?? 15
        try? await Task.sleep(for: .seconds(hold))
        print("NOTE external: page title after the client's press: \(browser.title)")
        await closeHosted(browser, view)
    }

    // MARK: Discarding

    static func accessibilityDiscardChecks() async {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        configuration.offscreenAccessibility = .enabled
        let browser = CefBrowser(url: URL(string: "selftest://ax/plain.html")!, configuration: configuration)
        let view = hostOffscreen(browser)
        defer { view.removeFromSuperview() }
        func hasButton() -> Bool {
            allElements(under: view).contains { ($0.accessibilityTitle() ?? $0.accessibilityLabel()) == "Plain button" }
        }
        check("accessibility: .enabled builds the tree at creation", await waitUntil { browser.isAccessibilityEnabled && hasButton() })
        view.isHidden = true
        await expect("accessibility: a discarded browser empties its tree") {
            _ = await waitUntil(timeout: .seconds(5)) { !browser.isLoading }
            try await browser.discard()
            return browser.isDiscarded && browser.accessibilityTree.isEmpty && (view.accessibilityChildren() ?? []).isEmpty
        }
        view.isHidden = false
        browser.restore()
        check("accessibility: the tree comes back after a restore", await waitUntil { !browser.isDiscarded && browser.isAccessibilityEnabled && hasButton() },
              detail: "\(browser.accessibilityTree.nodeCount) nodes, enabled \(browser.isAccessibilityEnabled), discarded \(browser.isDiscarded), state \(browser.state), title \(browser.title), loading \(browser.isLoading)")
        browser.close(force: true)
        _ = await waitUntil { browser.state == .closed }
    }

    // MARK: Opting out

    static func accessibilityDisabledChecks() async {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        configuration.offscreenAccessibility = .disabled
        let browser = CefBrowser(url: URL(string: "selftest://ax/page.html")!, configuration: configuration)
        let view = hostOffscreen(browser)
        _ = await loaded(browser, title: "ax")
        _ = view.accessibilityChildren()
        try? await Task.sleep(for: .milliseconds(300))
        check("accessibility: .disabled keeps the page a single element",
              !browser.isAccessibilityEnabled && browser.accessibilityTree.isEmpty && (view.accessibilityChildren() ?? []).isEmpty
                  && view.isAccessibilityElement())
        await closeHosted(browser, view)
    }

    // MARK: Cost

    /// Reports how long a large page takes to load with and without the
    /// tree. Informational: printed, not checked.
    static func accessibilityCostChecks() async {
        for mode in [CefBrowser.AccessibilityPolicy.disabled, .enabled, .disabled, .enabled] {
            var configuration = CefBrowser.Configuration()
            configuration.rendering = .offscreen
            configuration.offscreenAccessibility = mode
            let browser = CefBrowser(url: URL(string: "selftest://ax/large.html")!, configuration: configuration)
            let view = CefOffscreenBrowserView(browser: browser)
            view.frame = window.contentView!.bounds
            let start = ContinuousClock.now
            window.contentView!.addSubview(view)
            _ = await loaded(browser, title: "large", timeout: .seconds(30))
            let loaded = ContinuousClock.now - start
            var treeReady = Duration.zero
            if mode == .enabled {
                _ = await waitUntil(timeout: .seconds(30)) { browser.accessibilityTree.nodeCount > 6000 && browser.accessibilityTree.isLoaded }
                treeReady = ContinuousClock.now - start
            }
            let rss = residentMemory()
            print("NOTE accessibility cost: \(mode == .enabled ? "tree on " : "tree off") load \(loaded.milliseconds) ms"
                  + (mode == .enabled ? ", tree \(browser.accessibilityTree.nodeCount) nodes at \(treeReady.milliseconds) ms" : "")
                  + ", browser-process RSS \(rss / 1_048_576) MB")
            await closeHosted(browser, view)
        }
    }

    private static func residentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    // MARK: Walking

    /// Every element below `root`, depth first, through the public
    /// NSAccessibility protocol.
    static func allElements(under root: NSView) -> [NSAccessibilityElement] {
        var result: [NSAccessibilityElement] = []
        func walk(_ children: [Any]?, depth: Int) {
            guard depth < 64 else { return }
            for case let element as NSAccessibilityElement in children ?? [] {
                result.append(element)
                walk(element.accessibilityChildren(), depth: depth + 1)
            }
        }
        walk(root.accessibilityChildren(), depth: 0)
        return result
    }

    /// The nearest ancestor of `element` with `role` whose own parent is a
    /// web area — for an iframe's content, the iframe.
    static func ancestor(of element: NSAccessibilityElement, role: NSAccessibility.Role, below view: NSView) -> NSAccessibilityElement? {
        var current = element.accessibilityParent() as? NSAccessibilityElement
        var sawFrameRoot = false
        while let candidate = current {
            if sawFrameRoot, candidate.accessibilityRole() == role { return candidate }
            if candidate.accessibilityRole()?.rawValue == "AXWebArea" { sawFrameRoot = true }
            current = candidate.accessibilityParent() as? NSAccessibilityElement
        }
        return nil
    }
}

/// Records the accessibility notifications a view posts.
@MainActor
final class NotificationRecorder {
    var posted: [(notification: NSAccessibility.Notification, element: ObjectIdentifier)] = []
    private var observer: NSObjectProtocol?

    init(view: CefOffscreenBrowserView) {
        observer = NotificationCenter.default.addObserver(
            forName: CefOffscreenBrowserView.didPostAccessibilityNotification, object: view, queue: nil
        ) { [weak self] note in
            guard let name = note.userInfo?[CefOffscreenBrowserView.accessibilityNotificationKey] as? NSAccessibility.Notification,
                  let element = note.userInfo?[CefOffscreenBrowserView.accessibilityElementKey]
            else { return }
            let identifier = ObjectIdentifier(element as AnyObject)
            MainActor.assumeIsolated { self?.posted.append((name, identifier)) }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

extension Duration {
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}

/// Serves the accessibility checks' pages.
struct AccessibilityPages: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        let html: String
        switch request.url?.path {
        case "/page.html":
            html = """
                <title>ax</title>
                <style>body { margin: 8px; font: 16px sans-serif } iframe { width: 320px; height: 80px }</style>
                <nav aria-label="Site"><a href="#target" id="link">Example link</a></nav>
                <h1>Accessible heading</h1>
                <button id="press" onclick="document.title = 'pressed'">Press me</button>
                <p><label for="field">Name</label> <input id="field" type="text" placeholder="Your name" value="Ada"></p>
                <p><label><input id="check" type="checkbox" checked> Subscribe</label></p>
                <ul><li>One</li><li>Two</li><li>Three</li></ul>
                <img alt="A red square" width="40" height="40"
                     src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='40'%3E%3Crect width='40' height='40' fill='red'/%3E%3C/svg%3E">
                <iframe srcdoc="<button>Inner button</button>"></iframe>
                <div aria-live="polite" id="live"></div>
                <div style="height: 2000px"></div>
                <button id="far">Far button</button>
                <p id="target">target</p>
                """
        case "/plain.html":
            html = "<title>plain</title><h1>Plain</h1><button>Plain button</button>"
        case "/large.html":
            let rows = (0..<1500).map { "<li><a href='#\($0)'>Item \($0)</a> <span>detail \($0)</span></li>" }.joined()
            html = "<title>large</title><h1>Large</h1><ul>\(rows)</ul>"
        default:
            html = "ok"
        }
        return CefSchemeResponse(mimeType: "text/html", body: Data(html.utf8))
    }
}
