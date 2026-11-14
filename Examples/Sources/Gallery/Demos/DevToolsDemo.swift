import CefSwiftUI
import SwiftUI

/// `browser.devTools` speaks the Chrome DevTools Protocol in-process,
/// without a debugging port: `send(_:_:)` calls a method and
/// `events(_:)` streams an event. `showDevTools()` opens the DevTools
/// window.
struct DevToolsDemo: Demo {
    let title = "DevTools"
    let summary = "The page's console messages streamed through the DevTools Protocol, a phone-sized viewport emulated, and the DevTools window."
    let symbol = "wrench.and.screwdriver"
    let category = DemoCategory.page

    func makeView() -> some View { DevToolsView() }
}

private struct DevToolsView: View {
    @State private var browser = CefBrowser(url: Self.page.url)
    @State private var messages: [String] = []
    @State private var emulatesPhone = false

    var body: some View {
        VSplitView {
            CefWebView(browser).frame(minHeight: 200)
            List(messages.indices.reversed(), id: \.self) { index in
                Text(messages[index]).font(.callout.monospaced())
            }
            .frame(minHeight: 100)
            .overlay { if messages.isEmpty { Text("Console messages appear here").foregroundStyle(.secondary) } }
        }
        .toolbar {
            Toggle("Phone Viewport", systemImage: "iphone", isOn: $emulatesPhone)
            Button("Show DevTools", systemImage: "wrench.and.screwdriver") { browser.showDevTools() }
        }
        .onChange(of: emulatesPhone) {
            Task {
                if emulatesPhone {
                    _ = try? await browser.devTools.send("Emulation.setDeviceMetricsOverride",
                                                    ["width": 390, "height": 844, "deviceScaleFactor": 2, "mobile": true])
                } else {
                    _ = try? await browser.devTools.send("Emulation.clearDeviceMetricsOverride")
                }
            }
        }
        .reportReady {
            // Subscribe before enabling the domain, so no event is missed.
            let events = browser.devTools.events("Runtime.consoleAPICalled")
            try await browser.devTools.send("Runtime.enable")
            Task {
                for await event in events {
                    let text = event["args"].arrayValue?.compactMap { $0["value"].stringValue ?? $0["description"].stringValue }
                    messages.append("\(event["type"].stringValue ?? "log"): \(text?.joined(separator: " ") ?? "")")
                }
            }
        }
        .onDisappear {
            browser.closeDevTools()
            browser.close(force: true)
        }
    }

    static let page = SamplePage("devtools.html", title: "DevTools", body: """
        <h1>DevTools</h1>
        <p>Each click logs to the console; the app reads the messages through the DevTools Protocol.</p>
        <button onclick="console.log('Clicked at', new Date().toLocaleTimeString())">Log a message</button>
        <button onclick="console.warn('Viewport is', innerWidth + '×' + innerHeight)">Log the viewport size</button>
        """)
}
