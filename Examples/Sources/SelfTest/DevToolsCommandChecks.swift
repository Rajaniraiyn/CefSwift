import AppKit
@_spi(Testing) import CefKit

/// Typed DevTools Protocol commands and events against Chromium:
/// screenshots, the accessibility tree, DOM snapshots and input.
extension SelfTest {
    static func devToolsCommandChecks() async {
        CefRuntime.shared.registerSchemeHandler(scheme: "https", domain: "devtools.cefswift.test", handler: DevToolsCommandPage())
        let page = CefPage(url: URL(string: "https://devtools.cefswift.test/")!)
        let view = hostWindowed(page)
        defer {
            page.close(force: true)
            view.removeFromSuperview()
            CefRuntime.shared.removeSchemeHandler(scheme: "https", domain: "devtools.cefswift.test")
        }
        guard await loaded(page, title: "commands") else {
            check("devToolsCommands: page loads", false, detail: page.title)
            return
        }
        let devTools = page.devTools

        await expect("devToolsCommands: a PNG screenshot decodes") {
            let image = NSBitmapImageRep(data: try await devTools.send(CefDevTools.Page.CaptureScreenshot()).data)
            return ((image?.pixelsWide ?? 0) > 100, "\(image?.pixelsWide ?? 0) × \(image?.pixelsHigh ?? 0)")
        }
        await expect("devToolsCommands: a clipped, scaled JPEG") {
            let data = try await devTools.send(CefDevTools.Page.CaptureScreenshot(
                format: .jpeg, quality: 60, clip: (CGRect(x: 0, y: 0, width: 400, height: 300), 0.5))).data
            let image = NSBitmapImageRep(data: data)
            return (data.starts(with: [0xFF, 0xD8]) && (image?.pixelsWide ?? 0) > 0, "\(image?.pixelsWide ?? 0) px wide")
        }
        await expect("devToolsCommands: the accessibility tree names the button") {
            let tree = try await devTools.send(CefDevTools.Accessibility.GetFullAXTree())
            let button = tree.nodes.first { $0.role == "button" && $0.name == "Go" }
            return (button?.backendDOMNodeID != nil, "\(tree.nodes.count) nodes")
        }

        var buttonCenter = CGPoint(x: 160, y: 100)
        await expect("devToolsCommands: a DOM snapshot lays the button out where its style puts it") {
            let snapshot = try await devTools.send(CefDevTools.DOMSnapshot.CaptureSnapshot(computedStyles: ["display"]))
            guard let document = snapshot.documents.first,
                  let node = document.nodes.nodeName.firstIndex(where: { snapshot.string($0) == "BUTTON" }),
                  let box = document.layout.nodeIndex.firstIndex(of: node)
            else { return (false, "no button") }
            // Device pixels: divide by the device pixel ratio for CSS pixels.
            let scale = try await page.evaluateJavaScript("devicePixelRatio").doubleValue ?? 1
            let device = document.layout.bounds[box]
            let bounds = CGRect(x: device.minX / scale, y: device.minY / scale, width: device.width / scale, height: device.height / scale)
            buttonCenter = CGPoint(x: bounds.midX, y: bounds.midY)
            return (abs(bounds.minX - 100) < 1 && abs(bounds.width - 120) < 1
                        && document.nodes.clickableNodes.contains(node) && document.layout.styles[box].count == 1,
                    "\(device) at \(scale)x")
        }
        await expect("devToolsCommands: a click reaches the button") {
            for kind in [CefDevTools.Input.DispatchMouseEvent.Kind.pressed, .released] {
                try await devTools.send(CefDevTools.Input.DispatchMouseEvent(kind, at: buttonCenter, button: .left, clickCount: 1))
            }
            let clicks = try await page.evaluateJavaScript("window.clicks || 0")
            return (clicks.intValue == 1, "\(clicks)")
        }
        await expect("devToolsCommands: text, keys and editing commands reach the field") {
            _ = try await page.evaluateJavaScript("document.getElementById('field').focus(), 0")
            try await devTools.send(CefDevTools.Input.InsertText("hello"))
            try await devTools.send(CefDevTools.Input.DispatchKeyEvent(.keyDown, key: "a", code: "KeyA", text: "a", windowsVirtualKeyCode: 65))
            try await devTools.send(CefDevTools.Input.DispatchKeyEvent(.keyUp, key: "a", code: "KeyA", windowsVirtualKeyCode: 65))
            try await devTools.send(CefDevTools.Input.DispatchKeyEvent(
                .rawKeyDown, key: "a", code: "KeyA", windowsVirtualKeyCode: 65, modifiers: .command, commands: ["selectAll"]))
            try await devTools.send(CefDevTools.Input.DispatchKeyEvent(.keyUp, key: "a", code: "KeyA", windowsVirtualKeyCode: 65, modifiers: .command))
            let state = try await page.evaluateJavaScript(
                "(f => f.value + ':' + (f.selectionEnd - f.selectionStart))(document.getElementById('field'))")
            return (state.stringValue == "helloa:6", "\(state)")
        }
        await expect("devToolsCommands: a typed event stream decodes its events") {
            let events = devTools.events(ConsoleAPICalled.self)
            try await devTools.send("Runtime.enable")
            defer { Task { _ = try? await devTools.send("Runtime.disable") } }
            let reader = Task { @MainActor () -> String? in
                for await event in events { return event.type }
                return nil
            }
            page.executeJavaScript("console.warn('typed')")
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                reader.cancel()
            }
            let type = await reader.value
            timeout.cancel()
            return (type == "warning", type ?? "none")
        }
        await expect("devToolsCommands: an unknown command throws the protocol's error") {
            do {
                try await devTools.send(UnknownCommand())
                return (false, "no error")
            } catch let error as CefDevToolsError {
                return (error.method == UnknownCommand.method, "\(error)")
            }
        }
    }

    struct ConsoleAPICalled: CefDevToolsEvent {
        static let method = "Runtime.consoleAPICalled"
        var type: String
    }

    struct UnknownCommand: CefDevToolsCommand {
        static let method = "SelfTest.unknown"
        typealias Result = CefDevTools.NoResult
    }
}

/// The page the typed-command checks drive.
struct DevToolsCommandPage: CefSchemeHandler {
    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        CefSchemeResponse(mimeType: "text/html", body: Data("""
            <!doctype html><title>commands</title>
            <style>body { margin: 0; font: 16px system-ui }
            button { position: absolute; left: 100px; top: 80px; width: 120px; height: 40px }
            input { position: absolute; left: 100px; top: 160px; width: 200px }</style>
            <h1>Commands</h1>
            <button onclick="window.clicks = (window.clicks || 0) + 1">Go</button>
            <input id=field aria-label=Field>
            """.utf8))
    }
}
