import CefSwiftUI
import SwiftUI

/// Chromium shows its own pages (`chrome://settings`, history, extensions)
/// only in windows it creates. A `CefWindow` is one, holding one
/// Chrome-style page, with a toolbar of SwiftUI views. Views that show
/// page state are `View` types of their own, so they read it in `body`.
struct ChromeWindowDemo: Demo {
    let title = "Chrome-Style Window"
    let summary = "A CefWindow with a SwiftUI toolbar: back and forward, an address field, and Chromium's own pages, which only such windows show."
    let symbol = "macwindow.on.rectangle"
    let category = DemoCategory.windows

    func makeView() -> some View { ChromeWindowView() }
}

private struct ChromeWindowView: View {
    @ViewState private var window: CefWindow?

    var body: some View {
        ContentUnavailableView {
            Label(window?.page.title ?? "No Window", systemImage: "macwindow")
        } description: {
            Text("The window opens beside the gallery and closes with this demo.")
        } actions: {
            Button("Show Window", action: show)
        }
        .reportReady {
            show()
            try await window?.page.waitUntilLoaded(timeout: .seconds(30))
        }
        .onDisappear { window?.close() }
    }

    private func show() {
        if let window, !window.isClosed {
            window.show()
            return
        }
        let page = CefPage(url: SamplePage.tour[0].url)
        let window = CefWindow(page: page)
        window.setToolbar {
            NavigationButtons(page: page)
        } principal: {
            AddressField(page: page)
        } trailing: {
            Button("Settings", systemImage: "gearshape") { page.load(URL(string: "chrome://settings")!) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(.horizontal, 6)
        }
        window.show()
        self.window = window
    }
}

private struct NavigationButtons: View {
    let page: CefPage

    var body: some View {
        HStack {
            Button("Back", systemImage: "chevron.left", action: page.goBack).disabled(!page.canGoBack)
            Button("Forward", systemImage: "chevron.right", action: page.goForward).disabled(!page.canGoForward)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
    }
}

private struct AddressField: View {
    let page: CefPage
    @ViewState private var text = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("Address", text: $text)
            .focused($isEditing)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 280, idealWidth: 420)
            .onSubmit {
                if let url = URL(string: text), url.scheme != nil { page.load(url) }
                isEditing = false
            }
            .onChange(of: page.url, initial: true) {
                if !isEditing { text = page.url?.absoluteString ?? "" }
            }
    }
}
