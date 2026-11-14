import SwiftUI

/// Which demo is open.
@MainActor
@Observable
final class GalleryModel {
    var selection: String? {
        didSet { if selection != oldValue { readiness = DemoReadiness() } }
    }

    /// The open demo's, for `-smoke`.
    private(set) var readiness = DemoReadiness()

    init() {
        let requested = AnimationShots.isEnabled ? "AnimationDemo" : UserDefaults.standard.string(forKey: "demo")
        selection = Demos.all.first { $0.id == requested }?.id ?? Demos.all.first?.id
    }

    var selectedDemo: (any Demo)? {
        Demos.all.first { $0.id == selection }
    }
}

struct GalleryView: View {
    @Bindable var model: GalleryModel
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(DemoCategory.allCases, id: \.self) { category in
                    let demos = demos(in: category)
                    if !demos.isEmpty {
                        Section(category.rawValue) {
                            ForEach(demos, id: \.id) { demo in
                                Label(demo.title, systemImage: demo.symbol).tag(demo.id)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search Demos")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let demo = model.selectedDemo {
                DemoDetail(demo: demo)
                    .environment(\.demoReadiness, model.readiness)
                    // A fresh view, and fresh browsers, for each demo.
                    .id(demo.id)
            } else {
                ContentUnavailableView("Choose a Demo", systemImage: "square.grid.2x2")
            }
        }
    }

    private func demos(in category: DemoCategory) -> [any Demo] {
        Demos.all.filter { demo in
            demo.category == category
                && (search.isEmpty || demo.title.localizedStandardContains(search)
                    || demo.summary.localizedStandardContains(search))
        }
    }
}

/// A demo with its summary and the file that holds its code.
struct DemoDetail: View {
    let demo: any Demo

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(demo.summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(demo.sourceFile)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            AnyView(demo.makeView())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(demo.title)
    }
}
