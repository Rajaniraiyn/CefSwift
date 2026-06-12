import SwiftUI
import CefKit
import CefSwiftUI

/// A LazyVGrid dashboard of `CefWebView` cards mixed with native SwiftUI controls.
struct GalleryView: View {
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 420), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                MetalOSRCard()
                SwiftJSBridgeCard()
                AlloyStyleCard()
                MutedVideoCard()
                ConsoleLogCard()
                PickerDrivenCard()
            }
            .padding(16)
        }
        .background(.regularMaterial)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings.toggle()
                } label: {
                    Label("CEF Configuration", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    ConfigurationPopover()
                }
            }
        }
        .navigationTitle("CefSwift Gallery")
    }
}

// MARK: - Card chrome

struct GalleryCard<Content: View>: View {
    let title: String
    let symbol: String
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                Text(title).font(.headline)
                Spacer()
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            content
        }
        .background(.background.opacity(0.7), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

// MARK: - Card 0: OSR / Metal — the indistinguishable embedded primitive

/// Renders Chromium offscreen into a shared IOSurface composited in a native
/// CALayer-backed subview, with a native SwiftUI badge composited ON TOP of the
/// web pixels — the compositing advantage over Electron's BrowserView.
private struct MetalOSRCard: View {
    private static let presets: [(name: String, url: String)] = [
        ("Animation", "https://animejs.com"),
        ("CSS demo", "https://example.com"),
        ("WebGL", "https://webglsamples.org/aquarium/aquarium.html"),
    ]

    @State private var model = CefWebViewModel(url: URL(string: Self.presets[0].url)!)
    @State private var selection = MetalOSRCard.presets[0].url
    @State private var pulse = false

    var body: some View {
        GalleryCard(title: "OSR / Metal (premium)", symbol: "square.stack.3d.up.fill",
                    caption: "CefMetalWebView · IOSurface→CALayer") {
            VStack(spacing: 0) {
                Picker("Site", selection: $selection) {
                    ForEach(Self.presets, id: \.url) { Text($0.name).tag($0.url) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                .onChange(of: selection) { _, v in
                    if let url = URL(string: v) { model.load(url) }
                }
                Divider()
                ZStack(alignment: .topTrailing) {
                    // The offscreen web view: a genuine in-tree subview.
                    CefMetalWebView(model: model)
                        .frame(height: 300)
                    // Native SwiftUI badge composited ON TOP of the web pixels.
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .opacity(pulse ? 0.3 : 1)
                        Text("NATIVE OVERLAY")
                            .font(.system(.caption2, design: .rounded).weight(.bold))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.4)))
                    .padding(12)
                    .shadow(radius: 4)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Card 1: alloy runtime style

private struct AlloyStyleCard: View {
    @State private var model: CefWebViewModel = {
        var options = CefBrowserOptions()
        options.runtimeStyle = .alloy // classic chromeless embedding, no Chrome UI features
        return CefWebViewModel(url: URL(string: "https://example.com")!, options: options)
    }()

    var body: some View {
        GalleryCard(title: "Alloy Runtime Style", symbol: "rectangle.dashed",
                    caption: "options.runtimeStyle = .alloy") {
            CefWebView(model: model)
                .frame(height: 280)
        }
    }
}

// MARK: - Card 2: muted media

private struct MutedVideoCard: View {
    @State private var model = CefWebViewModel(
        url: URL(string: "https://www.w3schools.com/html/html5_video.asp")!)
    @State private var isMuted = true

    var body: some View {
        GalleryCard(title: "Muted Audio", symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    caption: "browser.isAudioMuted") {
            VStack(spacing: 0) {
                CefWebView(model: model)
                    .frame(height: 240)
                Divider()
                Toggle("Mute page audio", isOn: $isMuted)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(10)
                    .onChange(of: isMuted) { _, muted in
                        model.browser?.isAudioMuted = muted
                    }
            }
        }
        .task {
            // The CefBrowser is created lazily on first layout; apply the initial
            // mute state as soon as it exists.
            while model.browser == nil {
                guard (try? await Task.sleep(for: .milliseconds(100))) != nil else { return }
            }
            model.browser?.isAudioMuted = isMuted
        }
    }
}

// MARK: - Card 3: console messages → native list

private struct ConsoleLogCard: View {
    private static let demoPage = URL(string: """
        data:text/html,<title>console demo</title>\
        <button onclick="console.log('clicked at '+new Date().toLocaleTimeString())" \
        style="font-size:18px;padding:12px;margin:24px">Log to native SwiftUI</button>\
        <script>console.log('page loaded');console.warn('a warning');</script>
        """.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "about:blank")!

    @State private var model = CefWebViewModel(url: ConsoleLogCard.demoPage)
    @State private var messages: [LogEntry] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let text: String
    }

    var body: some View {
        GalleryCard(title: "Console Bridge", symbol: "terminal",
                    caption: "model.onConsoleMessage") {
            VStack(spacing: 0) {
                CefWebView(model: model)
                    .frame(height: 150)
                Divider()
                List(messages) { entry in
                    Text(entry.text)
                        .font(.system(.caption, design: .monospaced))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .frame(height: 120)
                .overlay {
                    if messages.isEmpty {
                        Text("console output appears here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .onAppear {
            model.onConsoleMessage = { message in
                messages.append(LogEntry(text: message))
                if messages.count > 200 { messages.removeFirst() }
            }
        }
    }
}

// MARK: - Card 4: URL driven by native controls

private struct PickerDrivenCard: View {
    private static let presets: [(name: String, url: String)] = [
        ("Wikipedia", "https://en.wikipedia.org"),
        ("Hacker News", "https://news.ycombinator.com"),
        ("Swift.org", "https://swift.org"),
        ("Example", "https://example.com"),
    ]

    @State private var model = CefWebViewModel(url: URL(string: Self.presets[0].url)!)
    @State private var selection = PickerDrivenCard.presets[0].url
    @State private var customURL = ""

    var body: some View {
        GalleryCard(title: "Native Controls Drive the Web", symbol: "slider.horizontal.3",
                    caption: "model.url = …") {
            VStack(spacing: 0) {
                HStack {
                    Picker("Site", selection: $selection) {
                        ForEach(Self.presets, id: \.url) { preset in
                            Text(preset.name).tag(preset.url)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: selection) { _, newValue in
                        if let url = URL(string: newValue) { model.load(url) }
                    }
                    TextField("https://…", text: $customURL)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 160)
                        .onSubmit {
                            if let url = URL(string: customURL) { model.load(url) }
                        }
                }
                .padding(10)
                Divider()
                CefWebView(model: model)
                    .frame(height: 250)
            }
        }
    }
}

// MARK: - Settings popover: live configuration values

private struct ConfigurationPopover: View {
    private let config = GalleryApp.cefConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Active CefConfiguration", systemImage: "gearshape.2")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("defaultRuntimeStyle", String(describing: config.defaultRuntimeStyle))
                row("noSandbox", String(describing: config.noSandbox))
                row("externalMessagePump", String(describing: config.externalMessagePump))
                row("logSeverity", String(describing: config.logSeverity))
                row("userAgentProduct", config.userAgentProduct ?? "—")
                row("remoteDebuggingPort", config.remoteDebuggingPort.map(String.init) ?? "—")
                row("persistSessionCookies", String(describing: config.persistSessionCookies))
                row("cachePath", config.cachePath?.path() ?? "—")
                ForEach(Array(config.extraCommandLineSwitches.keys.sorted()), id: \.self) { key in
                    row("--\(key)", config.extraCommandLineSwitches[key].flatMap { $0 } ?? "(flag)")
                }
            }
            .font(.system(.caption, design: .monospaced))
        }
        .padding(16)
        .frame(width: 420)
    }

    private func row(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }
}
