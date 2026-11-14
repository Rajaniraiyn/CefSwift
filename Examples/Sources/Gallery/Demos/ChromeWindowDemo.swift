import CefSwiftUI
import SwiftUI

/// Chromium shows its own pages (`chrome://settings`, history, extensions)
/// only in windows it creates. A `CefWindow` is one, holding one
/// Chrome-style browser, with a toolbar of SwiftUI views. Views that show
/// browser state are `View` types of their own, so they read it in `body`.
struct ChromeWindowDemo: Demo {
    let title = "Chrome-Style Window"
    let summary = "A CefWindow with a SwiftUI toolbar: back and forward, an address field, and Chromium's own pages, which only such windows show."
    let symbol = "macwindow.on.rectangle"
    let category = DemoCategory.windows

    func makeView() -> some View { ChromeWindowView() }
}

private struct ChromeWindowView: View {
    @State private var window: CefWindow?

    var body: some View {
        ContentUnavailableView {
            Label(window?.browser.title ?? "No Window", systemImage: "macwindow")
        } description: {
            Text("The window opens beside the gallery and closes with this demo.")
        } actions: {
            Button("Show Window", action: show)
        }
        .reportReady {
            show()
            try await window?.browser.waitUntilLoaded(timeout: .seconds(30))
        }
        .onDisappear { window?.close() }
    }

    private func show() {
        if let window, !window.isClosed {
            window.show()
            return
        }
        let browser = CefBrowser(url: SamplePage.tour[0].url)
        let window = CefWindow(browser: browser)
        window.setToolbar {
            NavigationButtons(browser: browser)
        } principal: {
            AddressField(browser: browser)
        } trailing: {
            Button("Settings", systemImage: "gearshape") { browser.load(URL(string: "chrome://settings")!) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
        }
        window.show()
        self.window = window
    }
}

private struct NavigationButtons: View {
    let browser: CefBrowser

    var body: some View {
        HStack {
            Button("Back", systemImage: "chevron.left", action: browser.goBack).disabled(!browser.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: browser.goForward).disabled(!browser.canGoForward)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
    }
}

private struct AddressField: View {
    let browser: CefBrowser
    @State private var text = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("Address", text: $text)
            .focused($isEditing)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 280, idealWidth: 420)
            .onSubmit {
                if let url = URL(string: text), url.scheme != nil { browser.load(url) }
                isEditing = false
            }
            .onChange(of: browser.url, initial: true) {
                if !isEditing { text = browser.url?.absoluteString ?? "" }
            }
    }
}
