import CefSwiftUI
import SwiftUI

/// Pages under SwiftUI springs: the same page windowed and offscreen side
/// by side, resized, transformed, moved between containers and expanded
/// from a card, and a grid of live previews. The resize policy picker
/// shows what an offscreen page does while its size animates, and the
/// graph the time between display refreshes on the main thread.
struct AnimationDemo: Demo {
    let title = "Animation"
    let summary = "Windowed and offscreen pages under spring resizes, transforms, a matched-geometry move, a card expanding to full size and a live-preview grid."
    let symbol = "wand.and.rays"
    let category = DemoCategory.webViews

    func makeView() -> some View { AnimationView() }
}

private enum Scene: String, CaseIterable, Identifiable {
    case resize = "Spring Resize"
    case transform = "Transform"
    case move = "Move"
    case card = "Card"
    case grid = "Live Previews"
    var id: Self { self }
}

private struct AnimationView: View {
    @State private var windowed = CefBrowser(url: AnimationDemo.page.url)
    @State private var offscreen: CefBrowser = {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen(frameRate: 120)
        return CefBrowser(url: AnimationDemo.page.url, configuration: configuration)
    }()
    @State private var scene = Scene.resize
    @State private var settles = false
    @State private var toggled = false
    @State private var frameTimes = FrameTimes()
    @Namespace private var namespace
    @Environment(\.demoReadiness) private var readiness

    private let spring = Animation.spring(duration: 0.6, bounce: 0.2)

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Scene", selection: $scene) {
                    ForEach(Scene.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Scale, then settle", isOn: $settles)
                    .help("Offscreen: keep the last frame while the size animates and lay out once it settles")
                Spacer()
                Button("Animate") { withAnimation(spring) { toggled.toggle() } }
                    .keyboardShortcut(.space, modifiers: [])
            }
            FrameTimeGraph(times: frameTimes)
                .frame(height: 36)
            stage
                .offscreenResizePolicy(settles ? .scaleThenSettle : .live)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .onChange(of: scene) { toggled = false }
        .reportReady { try await smokeRun() }
        .task { if AnimationShots.isEnabled { await shotsRun() } }
        .onDisappear {
            windowed.close(force: true)
            offscreen.close(force: true)
        }
    }

    @ViewBuilder private var stage: some View {
        switch scene {
        case .resize:
            HStack(alignment: .top, spacing: 16) {
                labelled("Windowed") { CefWebView(windowed).frame(width: toggled ? 440 : 260, height: toggled ? 420 : 260) }
                labelled("Offscreen") { CefWebView(offscreen).frame(width: toggled ? 440 : 260, height: toggled ? 420 : 260) }
            }
        case .transform:
            HStack(spacing: 40) {
                labelled("Windowed") { transformed(CefWebView(windowed)) }
                labelled("Offscreen") { transformed(CefWebView(offscreen)) }
            }
        case .move:
            // Two layouts: the page in the sidebar, or in the main area. Each
            // is a new CefWebView; the offscreen page arrives with its last
            // frame and leaves one behind while the old view fades.
            HStack(alignment: .top, spacing: 16) {
                VStack {
                    if !toggled { moving.frame(width: 220, height: 300) }
                    Spacer()
                }
                .frame(width: 220)
                .padding(8)
                .background(.quaternary, in: .rect(cornerRadius: 12))
                ZStack {
                    if toggled { moving }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .card:
            GeometryReader { proxy in
                let full = proxy.size
                let card = CGSize(width: 240, height: 160)
                CefWebView(offscreen)
                    // Laid out once at the full size; the card reveals it.
                    .offscreenPageSize(settles ? full : nil)
                    .offscreenFramePlacement(settles ? .topLeading : .stretch)
                    .frame(width: toggled ? full.width : card.width, height: toggled ? full.height : card.height)
                    .clipShape(.rect(cornerRadius: toggled ? 0 : 18, style: .continuous))
                    .shadow(radius: toggled ? 0 : 10, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: toggled ? .topLeading : .center)
            }
        case .grid:
            PreviewGrid(focused: toggled)
        }
    }

    private var moving: some View {
        CefWebView(offscreen)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .matchedGeometryEffect(id: "page", in: namespace)
    }

    private func transformed(_ page: some View) -> some View {
        page
            .frame(width: 280, height: 300)
            .clipShape(.rect(cornerRadius: toggled ? 28 : 0, style: .continuous))
            .rotationEffect(.degrees(toggled ? 8 : 0))
            .scaleEffect(toggled ? 0.75 : 1)
            .opacity(toggled ? 0.7 : 1)
    }

    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    /// For `Gallery -animationShots`: each scene forward and back, with
    /// pictures of the window before, during and after each spring, then
    /// the first two scenes again, which must show their pages again.
    private func shotsRun() async {
        _ = try? await windowed.waitUntilLoaded(timeout: .seconds(30))
        _ = try? await offscreen.waitUntilLoaded(timeout: .seconds(30))
        try? await Task.sleep(for: .seconds(1))
        guard let window = windowed.hostView?.window ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        let instants = [40, 80, 130, 200, 300, 450]
        func play(_ strip: AnimationShots.Strip, _ value: Bool, _ prefix: String) async {
            let start = ContinuousClock.now
            withAnimation(spring) { toggled = value }
            for instant in instants {
                try? await Task.sleep(until: start + .milliseconds(instant))
                strip.shoot("\(prefix)\(instant)ms")
            }
            try? await Task.sleep(until: start + .milliseconds(800))
            strip.shoot("\(prefix)end")
            try? await Task.sleep(until: start + .milliseconds(1800))
            strip.shoot("\(prefix)rest")
        }
        var order = Scene.allCases.map { ($0, $0.rawValue.replacingOccurrences(of: " ", with: "")) }
        order.append((.resize, "SpringResizeAgain"))
        order.append((.transform, "TransformAgain"))
        for (each, name) in order {
            scene = each
            try? await Task.sleep(for: .milliseconds(800))
            // First without pictures, which take the main thread: how long
            // the refreshes of the springs alone take.
            for value in [true, false] {
                let before = frameTimes.recorded
                withAnimation(spring) { toggled = value }
                try? await Task.sleep(for: .milliseconds(900))
                let during = frameTimes.intervals.suffix(min(240, frameTimes.recorded - before))
                print(String(format: "animationShots: %@ %@ refreshes %d, longest %.0f ms, over 25 ms %d",
                             name, value ? "forward" : "back", during.count, during.max() ?? 0, during.filter { $0 > 25 }.count))
            }
            let strip = AnimationShots.Strip(name: name, window: window)
            strip.shoot("start")
            if let view = windowed.hostView { strip.note("layers-start", WindowCapture.describeLayers(of: view)) }
            if let data = try? await windowed.snapshot() { strip.save(data, as: "chromium-start") }
            await play(strip, true, "fwd")
            if let view = windowed.hostView { strip.note("layers-fwd", WindowCapture.describeLayers(of: view)) }
            await play(strip, false, "back")
            if let view = windowed.hostView { strip.note("layers-back", WindowCapture.describeLayers(of: view)) }
            strip.finish(columns: 5)
            print("animationShots: \(name) done; windowed host \(windowed.hostView.map { "\(type(of: $0))" } ?? "none"), state \(windowed.state)")
        }
        NSApp.terminate(nil)
    }

    /// For `Gallery -smoke`: each scene once, then a click on the offscreen
    /// page, which must land on it.
    private func smokeRun() async throws {
        try await windowed.waitUntilLoaded(timeout: .seconds(30))
        try await offscreen.waitUntilLoaded(timeout: .seconds(30))
        guard Smoke.isEnabled else { return }
        for each in Scene.allCases where each != .grid {
            scene = each
            try await Task.sleep(for: .milliseconds(300))
            withAnimation(spring) { toggled = true }
            try await Task.sleep(for: .milliseconds(900))
            guard let view = offscreen.hostView, view.window != nil, view.layer?.sublayers?.first?.contents != nil else {
                throw DemoFailure(reason: "\(each.rawValue): the offscreen page is blank after the animation")
            }
            withAnimation(spring) { toggled = false }
            try await Task.sleep(for: .milliseconds(900))
        }
        scene = .transform
        try await Task.sleep(for: .milliseconds(300))
        withAnimation(spring) { toggled = true }
        try await Task.sleep(for: .milliseconds(900))
        guard let view = offscreen.hostView, let window = view.window, let layer = view.layer,
              let root = window.contentView?.superview, let rootLayer = root.layer
        else {
            throw DemoFailure(reason: "the offscreen page has no view")
        }
        // A quarter of the way into the page, where the scaled and rotated
        // view shows it: through the layers, which carry SwiftUI's
        // transforms (the view is flipped, its layer and the root are not).
        let quarter = CGPoint(x: view.bounds.width / 4, y: view.bounds.height / 4)
        var inRoot = rootLayer.convert(
            layer.contentsAreFlipped() ? quarter : CGPoint(x: quarter.x, y: view.bounds.height - quarter.y), from: layer)
        if rootLayer.contentsAreFlipped() { inRoot.y = root.bounds.height - inRoot.y }
        let point = root.convert(inRoot, to: nil)
        _ = try await offscreen.evaluateJavaScript("window.clicks = []")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        let landed = try await offscreen.evaluateJavaScript(
            "window.clicks.length ? Math.abs(window.clicks[0][0] - innerWidth / 4) + Math.abs(window.clicks[0][1] - innerHeight / 4) : -1")
        guard let distance = landed.doubleValue, distance >= 0, distance < 6 else {
            throw DemoFailure(reason: "a click on the transformed page landed \(landed.doubleValue ?? -1) points away")
        }
        withAnimation(spring) { toggled = false }
    }

    static let pageStyle = """
        :root { color-scheme: light; }
        body { margin: 0; padding: 16px 20px; background: linear-gradient(160deg, #e8f0ff, #ffe8f0); color: #222; }
        h1 { font-size: 22px; margin: 0 0 8px; }
        """
}

extension AnimationDemo {
    static let page = SamplePage("animation.html", title: "Animation", body: """
        <style>\(AnimationView.pageStyle)</style>
        <h1>A page in motion</h1>
        <p>Text reflows at the width the page lays out at. Watch it while the view springs: a page that lays out live reflows as it grows; one that scales, then settles, stretches and reflows once.</p>
        <p><button onclick="this.textContent = 'Clicked ' + (++window.count)">Click me</button></p>
        <script>
        window.count = 0; window.clicks = [];
        addEventListener('mousedown', e => window.clicks.push([e.clientX, e.clientY]));
        </script>
        """)

    static let previews = (1...4).map { number in
        SamplePage("animation-preview-\(number).html", title: "Preview \(number)", body: """
            <style>body { background: hsl(\(number * 70), 70%, 88%); }</style>
            <h1>Preview \(number)</h1>
            <p>Laid out at 1280×800 and shown fitted to its card, live. Clicks land on the page point under the pointer.</p>
            <p><button onclick="this.textContent = 'Clicked'">Button</button></p>
            """)
    }
}

/// Four offscreen pages laid out at a desktop size and shown as fitted
/// thumbnails; the focused one grows to full size.
private struct PreviewGrid: View {
    let focused: Bool
    @State private var browsers: [CefBrowser] = AnimationDemo.previews.map { page in
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen(frameRate: 30)
        return CefBrowser(url: page.url, configuration: configuration)
    }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(browsers.indices, id: \.self) { index in
                CefWebView(browsers[index])
                    .offscreenPageSize(CGSize(width: 1280, height: 800))
                    .offscreenFramePlacement(.aspectFit)
                    .aspectRatio(1.6, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .scaleEffect(focused && index == 0 ? 1.08 : 1)
                    .shadow(radius: focused && index == 0 ? 12 : 3, y: 2)
                    .zIndex(index == 0 ? 1 : 0)
            }
        }
        .onDisappear { browsers.forEach { $0.close(force: true) } }
    }
}

/// The time between the main thread's display refreshes, from
/// `TimelineView(.animation)`: a gap above the refresh interval is a
/// refresh the main thread missed.
@MainActor @Observable
private final class FrameTimes {
    private(set) var intervals: [Double] = []
    /// How many intervals were recorded in all.
    @ObservationIgnored private(set) var recorded = 0
    @ObservationIgnored private var last: Date?

    func record(_ date: Date) {
        defer { last = date }
        guard let last else { return }
        intervals.append(date.timeIntervalSince(last) * 1000)
        recorded += 1
        if intervals.count > 240 { intervals.removeFirst(intervals.count - 240) }
    }
}

private struct FrameTimeGraph: View {
    let times: FrameTimes

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { graphics, size in
                let values = times.intervals
                let ceiling = 50.0
                let barWidth = size.width / 240
                for (index, value) in values.enumerated() {
                    let height = min(value / ceiling, 1) * size.height
                    let rect = CGRect(x: CGFloat(index) * barWidth, y: size.height - height, width: max(barWidth - 0.5, 0.5), height: height)
                    graphics.fill(Path(rect), with: .color(value > 25 ? .red : value > 18 ? .orange : .green))
                }
                let worst = values.suffix(120).max() ?? 0
                graphics.draw(Text(String(format: "longest %.0f ms", worst)).font(.caption.monospacedDigit()),
                              at: CGPoint(x: size.width - 4, y: 2), anchor: .topTrailing)
            }
            .onChange(of: context.date) { _, date in times.record(date) }
        }
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}
