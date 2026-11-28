import AppKit
import CefSwiftUI
import SwiftUI

/// An app shell whose sections are web pages, in native SwiftUI: its own
/// content served from the app's resources at `app://content/` (a custom
/// scheme), a JavaScript bridge between that content and Swift, and a
/// section that shows a website.
///
/// Launch arguments (read as user defaults):
///
/// - `-smoke YES` prints `PASS loaded <address>` once the first page has
///   loaded and quits, or prints `FAIL …` and exits with status 1 after
///   60 seconds.
@main
struct __NAME__App: CefSwiftApp {
    static var runtimeConfiguration: CefRuntime.Configuration {
        var configuration = CefRuntime.Configuration.embedded
        configuration.customSchemes = [CefCustomScheme(name: "app")]
        return configuration
    }

    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { SmokeTest.shared.start() }
        }
        .defaultSize(width: 1100, height: 760)
    }
}

/// One section of the app: a page, and the sidebar row that shows it.
struct AppSection: Identifiable, Hashable {
    var id: String
    var title: String
    var symbol: String
    var url: URL
}

@MainActor
@Observable
final class AppModel {
    let sections = [
        AppSection(id: "home", title: "Home", symbol: "house",
                url: URL(string: "app://content/index.html")!),
        AppSection(id: "docs", title: "Swift Documentation", symbol: "book",
                url: URL(string: "https://www.swift.org/documentation/")!),
    ]
    var selection: AppSection.ID? = "home"
    /// What the page has sent to Swift through the bridge.
    var notes: [String] = []

    /// `window.app` in the app's own pages: `app.addNote(text)` returns the
    /// number of notes, and `app.on('cleared', …)` hears from Swift.
    let bridge = CefBridge(name: "app")
    @ObservationIgnored private var pages: [AppSection.ID: CefPage] = [:]

    init() {
        // Register the handler before any page loads from the scheme.
        if let content = Self.webContent {
            CefRuntime.shared.registerSchemeHandler(
                scheme: "app", domain: "content", handler: CefDirectorySchemeHandler(directory: content))
        }
        bridge.handle("addNote") { [weak self] (text: String) -> Int in
            guard let self else { return 0 }
            notes.append(text)
            return notes.count
        }
    }

    /// `Web/`: SwiftPM copies it into the target's resource bundle; an
    /// Xcode target copies its files into the app's resources.
    private static var webContent: URL? {
        #if SWIFT_PACKAGE
        Bundle.module.url(forResource: "Web", withExtension: nil)
        #else
        Bundle.main.resourceURL
        #endif
    }

    /// Each section keeps its page, so switching back finds it as it was.
    func page(for section: AppSection) -> CefPage {
        if let page = pages[section.id] { return page }
        var configuration = CefPage.Configuration()
        configuration.bridges = [bridge]
        let page = CefPage(url: section.url, configuration: configuration, delegate: SmokeTest.shared)
        pages[section.id] = page
        return page
    }

    func clearNotes() {
        notes.removeAll()
        bridge.emit("cleared", notes.count)
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(model.sections, selection: $model.selection) { section in
                Label(section.title, systemImage: section.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            if !model.notes.isEmpty {
                GroupBox("Notes from the page") {
                    ForEach(Array(model.notes.enumerated()), id: \.offset) { Text($0.element).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("Clear") { model.clearNotes() }
                }
                .padding()
            }
        } detail: {
            if let section = model.sections.first(where: { $0.id == model.selection }) {
                PageView(page: model.page(for: section))
                    .id(section.id)
            }
        }
    }
}

/// A page with back, forward and reload in the window's toolbar.
struct PageView: View {
    let page: CefPage

    var body: some View {
        CefWebView(page)
            .navigationTitle(page.title.isEmpty ? "__DISPLAY_NAME__" : page.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left") { page.goBack() }
                        .disabled(!page.canGoBack)
                    Button("Forward", systemImage: "chevron.right") { page.goForward() }
                        .disabled(!page.canGoForward)
                }
                ToolbarItem {
                    Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
                }
            }
    }
}

/// The `-smoke YES` launch argument: a check that the bundle starts
/// Chromium and loads the app's own content.
@MainActor
final class SmokeTest: CefPageDelegate {
    static let shared = SmokeTest()

    private let isEnabled = UserDefaults.standard.bool(forKey: "smoke")
    private var isDone = false

    func start() {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard !self.isDone else { return }
            print("FAIL the page did not load within 60 seconds")
            exit(1)
        }
    }

    func page(_ page: CefPage, didFinishLoadWithStatus httpStatus: Int) {
        guard isEnabled, !isDone else { return }
        isDone = true
        print("PASS loaded \(page.url?.absoluteString ?? "") (HTTP \(httpStatus))")
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
