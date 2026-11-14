import CefSwiftUI
import SwiftUI

/// A `CefBridge` exposes Swift functions to the page as a global whose
/// methods return promises; arguments and results are any `Codable` type.
/// `emit(_:_:)` sends events the other way, to the page's `app.on`
/// listeners.
struct BridgeDemo: Demo {
    let title = "JavaScript Bridge"
    let summary = "The page calls typed Swift functions and awaits their results; Swift sends events back to the page."
    let symbol = "arrow.left.arrow.right"
    let category = DemoCategory.javaScript

    func makeView() -> some View { BridgeView() }
}

private struct BridgeView: View {
    @State private var model = TodoModel()
    @State private var colors = ["tomato", "seagreen", "royalblue", "goldenrod"]

    var body: some View {
        HSplitView {
            CefWebView(model.browser).frame(minWidth: 360)
            List {
                Section("In Swift") {
                    ForEach(model.todos.indices, id: \.self) { Text(model.todos[$0].title) }
                }
            }
            .frame(minWidth: 200, maxWidth: 280)
        }
        .toolbar {
            Button("Send Color to Page", systemImage: "paintpalette") {
                colors.shuffle()
                model.bridge.emit("accent", colors[0])
            }
        }
        .readyWhenLoaded(model.browser)
        .onDisappear { model.browser.close(force: true) }
    }
}

private struct Todo: Codable, Hashable {
    var title: String
}

@MainActor
@Observable
private final class TodoModel {
    var todos: [Todo] = []
    let bridge = CefBridge(name: "app")
    let browser: CefBrowser

    init() {
        var configuration = CefBrowser.Configuration()
        configuration.bridges = [bridge]
        browser = CefBrowser(url: Self.page.url, configuration: configuration)
        // app.add({ title }) → the number of todos in Swift.
        bridge.handle("add") { [weak self] (todo: Todo) -> Int in
            guard let self else { return 0 }
            todos.append(todo)
            return todos.count
        }
    }

    static let page = SamplePage("bridge.html", title: "Bridge", body: """
        <h1>JavaScript Bridge</h1>
        <form onsubmit="add(event)">
          <input id=title placeholder="A todo for Swift" autofocus> <button>Add</button>
        </form>
        <p id=reply class=muted>Each todo is sent to Swift, which answers with its count.</p>
        <script>
          async function add(event) {
            event.preventDefault();
            const field = document.getElementById('title');
            const count = await app.add({ title: field.value || 'Untitled' });
            document.getElementById('reply').textContent = `Swift has ${count} todo${count == 1 ? '' : 's'}.`;
            field.value = '';
          }
          app.on('accent', color => { document.body.style.borderTop = `8px solid ${color}`; });
        </script>
        """)
}
