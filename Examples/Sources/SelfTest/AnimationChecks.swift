import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import IOSurface
import QuartzCore
import SwiftUI
import WebKit

/// Pages under the animations apps use: SwiftUI springs on a page's size,
/// transforms, opacity, clipping, blur, a matched-geometry move between two
/// containers and an inserted page, AppKit's animator and a window's
/// animated resize, for a windowed page, an offscreen one under each
/// resize policy, and `WKWebView`.
///
/// The checks (`animation`) need no steady frame rate: input lands where a
/// transformed page shows it, the page settles at the view's size, a page
/// laid out at another size maps input back, and a page moving to another
/// view is never blank. `-benchmark animation` measures display hitches,
/// resizes and frames that trail the view.
extension SelfTest {
    static func animationChecks() async {
        CefRuntime.shared.energyPolicy = .disabled
        defer { CefRuntime.shared.energyPolicy = .automatic }
        for kind in [AnimationStage.Kind.offscreen(.live), .windowed] {
            guard let stage = await AnimationStage(kind) else {
                check("animation (\(kind.label)): the page loads", false)
                continue
            }
            defer { stage.close() }
            guard stage.window.occlusionState.contains(.visible) else {
                skip("animation (\(kind.label))", because: "the test window is not visible (screen locked or asleep?)", .environment)
                continue
            }
            // A spring on the page's width: the page ends at the view's size.
            await stage.run(.springSize, seconds: 0.9)
            let settled = await waitUntilAsync(timeout: .seconds(5)) { await stage.pageMatchesView() }
            check("animation (\(kind.label)): after a spring resize the page has the view's size",
                  settled, detail: await stage.sizes())
            if case .offscreen = kind {
                // The view tells Chromium once per run-loop pass, not on
                // every one of SwiftUI's frame changes.
                let sample = await stage.measure(.springSize, seconds: 0.9)
                check("animation (offscreen): a spring resize tells Chromium at most once per frame change pass",
                      sample.resizes <= sample.hostFrameChanges / 2 + 2 && sample.resizes > 0,
                      detail: sample.summary)
                // AppKit reports new backing properties on every refresh
                // of a scale animation; the page's size does not change.
                let scaled = await stage.measure(.scale, seconds: 0.9)
                check("animation (offscreen): a scale animation tells Chromium of no resize", scaled.resizes <= 1,
                      detail: scaled.summary)
            }
            // Clicks land where a transformed page shows its content.
            for transform in [AnimationStage.Animation.scale, .rotate, .rotate3D, .offset] {
                await stage.run(transform, seconds: 0.9)
                let result = await stage.clickLanding()
                await stage.run(transform, seconds: 0.9)
                if transform == .rotate3D {
                    // AppKit hit-tests views by their untransformed frames,
                    // so whether a click reaches the page at all depends on
                    // where it falls.
                    print("NOTE animation (\(kind.label)): a click under rotation3DEffect: \(result.summary)")
                    continue
                }
                if case .windowed = kind, transform != .offset {
                    // Chromium converts clicks and sizes its page through
                    // AppKit's view geometry, which a layer transform does
                    // not change consistently: a limit of windowed pages.
                    print("NOTE animation (windowed): a click under \(transform): \(result.summary)")
                    continue
                }
                check("animation (\(kind.label)): a click under \(transform) lands where the page shows it",
                      result.landed, detail: result.summary)
            }
            // Removed with a transition and inserted again: the page is
            // hosted in the new view and answers.
            await stage.run(.insert, seconds: 0.9)
            await stage.run(.insert, seconds: 0.9)
            let answers = await stage.evaluate("1 + 1") == "2"
            check("animation (\(kind.label)): a page removed with a transition and inserted again is shown and answers",
                  stage.cefBrowser?.hostView?.window != nil && answers,
                  detail: "host \(stage.cefBrowser?.hostView.map { String(describing: type(of: $0)) } ?? "none"), answers \(answers), state \(stage.cefBrowser.map { "\($0.state)" } ?? "-"), native view in \(stage.cefBrowser?.nativeView?.superview.map { String(describing: type(of: $0)) } ?? "nothing"), in a window \(stage.cefBrowser?.nativeView?.window != nil)")
        }
        await offscreenPageGeometryChecks()
        await overlayChecks()
    }

    /// SwiftUI content over a page: which one a click reaches.
    static func overlayChecks() async {
        for kind in [AnimationStage.Kind.offscreen(.live), .windowed] {
            guard let stage = await AnimationStage(kind) else { continue }
            defer { stage.close() }
            stage.model.showsOverlay = true
            try? await Task.sleep(for: .milliseconds(300))
            let result = await stage.click(atViewPoint: CGPoint(x: 80, y: 40))
            let hit = stage.window.contentView?.superview?.hitTest(result.windowPoint)
            let reached = "overlay taps \(stage.model.overlayTaps), page clicks \(result.received == nil ? 0 : 1), hit view \(hit.map { String(describing: type(of: $0)) } ?? "none")"
            // AppKit gives the click to SwiftUI's hosting view, which owns
            // the overlay, and not to the page's view. (Whether SwiftUI then
            // runs the overlay's gesture for a synthesized event varies.)
            let page = stage.cefBrowser?.nativeView ?? stage.hostView
            let pageTookIt = hit.map { hit in page.map { hit === $0 || hit.isDescendant(of: $0) } ?? false } ?? true
            check("animation (\(kind.label)): a click on SwiftUI content over the page reaches that content, not the page",
                  !pageTookIt && result.received == nil, detail: reached)
        }
    }

    /// A page laid out at another size than its view, and a page moving to
    /// another view.
    static func offscreenPageGeometryChecks() async {
        guard let stage = await AnimationStage(.offscreen(.live)) else {
            check("animation (offscreen): the page loads", false)
            return
        }
        defer { stage.close() }
        guard stage.window.occlusionState.contains(.visible) else {
            skip("animation (offscreen page size)", because: "the test window is not visible", .environment)
            return
        }
        // A thumbnail: laid out at 1200×800, shown at 300×400 fitted.
        var lastFrame = "none"
        var frameSizes: Set<String> = []
        stage.view?.didPresentFrame = { pixels, content in
            lastFrame = "\(Int(pixels.width))x\(Int(pixels.height)) px\(content.map { ", content \($0)" } ?? "")"
            frameSizes.insert(lastFrame)
        }
        stage.model.pageSize = CGSize(width: 1200, height: 800)
        stage.model.placement = .aspectFit
        let laidOut = await waitUntilAsync(timeout: .seconds(5)) { await stage.innerSize() == "1200x800" }
        check("animation (offscreen): a page size lays the page out at it, whatever the view's size",
              laidOut, detail: await stage.sizes())
        _ = await waitUntil(timeout: .seconds(3)) { (stage.view?.contentFrame.height ?? 400) < 250 }
        let fitted = stage.view?.contentFrame ?? .zero
        check("animation (offscreen): the frame is fitted to the view",
              abs(fitted.width - 300) < 1 && abs(fitted.height - 200) < 1, detail: "\(fitted), last frame \(lastFrame)")
        let click = await stage.clickLanding()
        let mapped = stage.view?.testingPagePoint(fromWindow: click.windowPoint)
        check("animation (offscreen): a click on a page shown at another size lands on the page point",
              click.landed,
              detail: "\(click.summary); last frame \(lastFrame); the view maps it to \(mapped.map { "\($0.point) in a frame of \($0.frameSize)" } ?? "-"); frames \(frameSizes.sorted().joined(separator: " | "))")
        stage.view?.didPresentFrame = nil
        // Straight to Chromium, at the page point, without the view.
        if let browser = stage.cefBrowser {
            _ = await stage.evaluate("window.__clicks = []")
            browser.sendMouseDown(at: CGPoint(x: 300, y: 200), button: .left, clickCount: 1, modifiers: [])
            browser.sendMouseUp(at: CGPoint(x: 300, y: 200), button: .left, clickCount: 1, modifiers: [])
            try? await Task.sleep(for: .milliseconds(300))
            print("NOTE animation (offscreen): a mouse down sent at page point 300,200 reaches the page at \(await stage.evaluate("window.__clicks.length ? window.__clicks[0].join(',') : 'nothing'") ?? "?")")
        }
        stage.model.pageSize = nil
        stage.model.placement = .stretch
        _ = await waitUntilAsync(timeout: .seconds(5)) { await stage.pageMatchesView() }

        // Moving between containers makes a new view: it shows the last
        // frame at once, and the old one keeps it while it animates out.
        guard let before = stage.view else { return }
        withAnimation(.spring(duration: 0.6)) { stage.model.onRight.toggle() }
        let moved = await waitUntil(timeout: .seconds(2)) { stage.view.map { $0 !== before } ?? false }
        let after = stage.view
        let shownAtOnce = after?.layer?.sublayers?.first?.contents != nil
        check("animation (offscreen): a page moving to another CefWebView is never blank there",
              moved && shownAtOnce, detail: "moved \(moved), frame on arrival \(shownAtOnce)")
        check("animation (offscreen): the view it left keeps its last frame, and no browser, while it animates out",
              before.browser == nil && before.layer?.sublayers?.first?.contents != nil,
              detail: "browser \(before.browser == nil ? "none" : "kept"), frame \(before.layer?.sublayers?.first?.contents != nil), in a window \(before.window != nil)")
        try? await Task.sleep(for: .seconds(1))
        withAnimation(.spring(duration: 0.6)) { stage.model.onRight.toggle() }
        _ = await waitUntil(timeout: .seconds(2)) { stage.view.map { $0 !== after } ?? false }
    }
}

extension Benchmarks {
    /// `animation`: each animation on each host, twice (there and back),
    /// with display hitches, frame changes, resizes Chromium is told about,
    /// `resize` events the page sees and refreshes on which an offscreen
    /// page's frame trails the view. `-animationOnly <kind>` runs one host.
    static func animation() async {
        CefRuntime.shared.energyPolicy = .disabled
        defer { CefRuntime.shared.energyPolicy = .automatic }
        SelfTest.window.orderOut(nil)
        defer { SelfTest.window.orderFront(nil) }
        let only = UserDefaults.standard.string(forKey: "animationOnly")
        let kinds: [AnimationStage.Kind] = [
            .windowed, .offscreen(.live), .offscreenEveryFrameChange, .offscreen(.scaleThenSettle), .webKit,
        ]
        for kind in kinds where only == nil || kind.label == only {
            guard let stage = await AnimationStage(kind) else {
                print("bench error: \(kind.label) did not load")
                continue
            }
            if case .windowed = kind, let native = stage.cefBrowser?.nativeView {
                print("bench animation windowed layers: \(AnimationStage.layerSummary(native.layer))")
                // Chromium's layers part way through a spring resize.
                stage.start(.springSize)
                for _ in 0..<4 {
                    try? await Task.sleep(for: .milliseconds(60))
                    print("bench animation windowed mid-resize: view \(native.bounds.size), \(AnimationStage.layerGeometry(native.layer))")
                }
                try? await Task.sleep(for: .seconds(1))
                stage.start(.springSize)
                try? await Task.sleep(for: .seconds(1))
            }
            for animation in AnimationStage.Animation.allCases {
                if case .offscreenEveryFrameChange = kind, !animation.changesSize { continue }
                if case .offscreen(.scaleThenSettle) = kind, !animation.changesSize { continue }
                for run in 1...2 {
                    // There, then back: a size grows, then shrinks.
                    for direction in ["there", "back"] {
                        let sample = await stage.measure(animation, seconds: 1.2, returning: false)
                        print("bench animation \(kind.label) \(animation) \(direction) run \(run): \(sample.summary)")
                    }
                }
            }
            stage.close()
            _ = await SelfTest.waitUntil { CefRuntime.shared.browsers.isEmpty }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}

// MARK: - Stage

/// What `AnimationStage` animates.
@MainActor @Observable
final class AnimationStageModel {
    var wide = false
    var scale = 1.0
    var angle = 0.0
    var angle3D = 0.0
    var opacity = 1.0
    var corner = 0.0
    var blur = 0.0
    var offset = 0.0
    var onRight = false
    var shown = true
    var pageSize: CGSize?
    var placement = CefOffscreenBrowserView.FramePlacement.stretch
    var policy = CefOffscreenBrowserView.ResizePolicy.live
    var showsOverlay = false
    var fills = false
    var overlayTaps = 0
}

/// A window showing one page in a SwiftUI layout of two containers.
@MainActor
final class AnimationStage {
    enum Kind {
        case windowed
        case offscreen(CefOffscreenBrowserView.ResizePolicy)
        /// Offscreen, telling Chromium of every frame change at once, as
        /// the view did before it coalesced them.
        case offscreenEveryFrameChange
        case webKit

        var label: String {
            switch self {
            case .windowed: "windowed"
            case .offscreen(.live): "offscreen"
            case .offscreen(.scaleThenSettle): "offscreen-settle"
            case .offscreenEveryFrameChange: "offscreen-every-change"
            case .webKit: "wkwebview"
            }
        }
    }

    enum Animation: String, CaseIterable, CustomStringConvertible {
        case springSize, scale, rotate, rotate3D, opacity, corner, blur, offset, move, insert, appKitFrame, windowResize
        var description: String { rawValue }
        var changesSize: Bool { [.springSize, .appKitFrame, .windowResize, .move].contains(self) }
    }

    let kind: Kind
    let window: NSWindow
    let model = AnimationStageModel()
    private(set) var cefBrowser: CefBrowser?
    private var webView: WKWebView?
    private let webKitHandler = WebKitMessages()
    private var hosting = NSView()

    init?(_ kind: Kind) async {
        self.kind = kind
        window = NSWindow(
            contentRect: CGRect(x: 120, y: 120, width: 1000, height: 520), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        switch kind {
        case .webKit:
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.add(webKitHandler, name: "probe")
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.loadHTMLString(Self.page, baseURL: nil)
            self.webView = webView
            hosting = NSHostingView(rootView: AnimationStageView(model: model) { AnyView(WebKitRepresentable(webView: webView)) })
        default:
            var configuration = CefBrowser.Configuration()
            if case .windowed = kind {} else { configuration.rendering = .offscreen(frameRate: 60) }
            let browser = CefBrowser(url: URL(string: "selftest://bench/animation.html")!, configuration: configuration)
            cefBrowser = browser
            if case .offscreen(let policy) = kind { model.policy = policy }
            CefOffscreenBrowserView.resizesOnEveryFrameChange = {
                if case .offscreenEveryFrameChange = kind { return true }
                return false
            }()
            hosting = NSHostingView(rootView: AnimationStageView(model: model) { AnyView(CefWebView(browser)) })
        }
        // In a plain AppKit container, whose frame the animator can drive.
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 1000, height: 520))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Clicks reach SwiftUI's content only in the key window.
        _ = await SelfTest.waitUntil(timeout: .seconds(3)) { self.window.isKeyWindow }
        if let cefBrowser {
            guard await SelfTest.loaded(cefBrowser, title: "animation") else { close(); return nil }
        } else {
            guard await SelfTest.waitUntilAsync(timeout: .seconds(10), { await self.evaluate("document.title") == "animation" })
            else { close(); return nil }
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    func close() {
        CefOffscreenBrowserView.resizesOnEveryFrameChange = false
        cefBrowser?.close(force: true)
        window.contentView = nil
        window.close()
    }

    /// The view showing the page now.
    var view: CefOffscreenBrowserView? { cefBrowser?.hostView as? CefOffscreenBrowserView }

    /// The view whose frame SwiftUI animates.
    var hostView: NSView? { cefBrowser?.hostView ?? webView }

    func evaluate(_ script: String) async -> String? {
        if let cefBrowser {
            guard let value = try? await cefBrowser.evaluateJavaScript(script) else { return nil }
            return value.stringValue ?? value.intValue.map(String.init) ?? value.doubleValue.map { String(Int($0)) }
        }
        guard let webView else { return nil }
        let result = try? await webView.evaluateJavaScript(script)
        return result.map { "\($0)" }
    }

    func innerSize() async -> String? { await evaluate("innerWidth + 'x' + innerHeight") }

    func pageMatchesView() async -> Bool {
        guard let host = hostView, let size = await innerSize() else { return false }
        return size == "\(Int(host.bounds.width))x\(Int(host.bounds.height))"
    }

    func sizes() async -> String {
        "page \(await innerSize() ?? "?"), view \(hostView.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "none")"
    }

    // MARK: Animating

    /// Starts `animation`, there or back.
    func start(_ animation: Animation) {
        let spring = SwiftUI.Animation.spring(duration: 0.6, bounce: 0.15)
        switch animation {
        case .springSize: withAnimation(spring) { model.wide.toggle() }
        case .scale: withAnimation(spring) { model.scale = model.scale == 1 ? 0.6 : 1 }
        case .rotate: withAnimation(spring) { model.angle = model.angle == 0 ? 12 : 0 }
        case .rotate3D: withAnimation(spring) { model.angle3D = model.angle3D == 0 ? 25 : 0 }
        case .opacity: withAnimation(spring) { model.opacity = model.opacity == 1 ? 0.3 : 1 }
        case .corner: withAnimation(spring) { model.corner = model.corner == 0 ? 28 : 0 }
        case .blur: withAnimation(spring) { model.blur = model.blur == 0 ? 8 : 0 }
        case .offset: withAnimation(spring) { model.offset = model.offset == 0 ? 120 : 0 }
        case .move: withAnimation(spring) { model.onRight.toggle() }
        case .insert: withAnimation(spring) { model.shown.toggle() }
        case .appKitFrame:
            // The animator proxy on the SwiftUI container's frame, as an
            // AppKit layout would animate a split view's pane.
            let frame = hosting.frame
            let hosting = hosting
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                hosting.animator().setFrameSize(CGSize(width: frame.width == 1000 ? 760 : 1000, height: frame.height))
            }
        case .windowResize:
            var frame = window.frame
            frame.size.width = frame.width < 1000 ? 1000 : 820
            // Animated, with live-resize notifications, like a zoom.
            window.setFrame(frame, display: true, animate: true)
        }
    }

    /// Runs `animation` and waits `seconds`.
    func run(_ animation: Animation, seconds: Double) async {
        start(animation)
        try? await Task.sleep(for: .seconds(seconds))
    }

    struct Sample {
        var refreshes = 0
        var hitches = 0
        var longestGap = 0.0
        var hostFrameChanges = 0
        var nativeFrameChanges = 0
        var resizes = 0
        var pageResizes = 0
        var pageFrames = 0
        var presented = 0
        var trailing = 0
        var blank = 0
        var letterboxed = 0
        var blackEdges = 0
        var whiteEdges = 0
        var mainBusy = 0.0
        var appCPU = 0.0
        var seconds = 0.0

        var summary: String {
            String(
                format: "refreshes %d, hitches %d (longest %.1f ms), host frame changes %d, Chromium view frame changes %d, resizes told %d, page resize events %d, page rAF %d, presented %d, letterboxed %d, shown with black edges %d, white edges %d, refreshes with a trailing frame %d, blank %d, main thread busy %.0f%%, app CPU %.0f%%",
                refreshes, hitches, longestGap * 1000, hostFrameChanges, nativeFrameChanges, resizes, pageResizes,
                pageFrames, presented, letterboxed, blackEdges, whiteEdges, trailing, blank, mainBusy * 100,
                appCPU / max(seconds, 0.001) * 100)
        }
    }

    /// Runs `animation` and records for `seconds`, then, if `returning`,
    /// runs it back without recording.
    func measure(_ animation: Animation, seconds: Double, returning: Bool = true) async -> Sample {
        // A page that fills its container, for animations of the container.
        let fills = animation == .appKitFrame || animation == .windowResize
        if fills != model.fills {
            model.fills = fills
            try? await Task.sleep(for: .milliseconds(600))
        }
        _ = await evaluate("window.__resizes = 0, window.__raf = 0")
        var sample = Sample()
        let recorder = RefreshRecorder()
        let tally = Tally()
        let center = NotificationCenter.default
        var observers: [NSObjectProtocol] = []
        for (view, isHost) in [(hostView, true), (cefBrowser?.nativeView, false)] {
            guard let view else { continue }
            view.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { _ in
                MainActor.assumeIsolated {
                    if isHost { tally.hostChanges += 1 } else { tally.nativeChanges += 1 }
                }
            })
        }
        let resizesBefore = cefBrowser?.resizeNotificationCount ?? 0
        func watch(_ view: CefOffscreenBrowserView) {
            view.didPresentFrame = { [weak view] pixels, content in
                tally.presented += 1
                if content != nil { tally.letterboxed += 1 }
                let shown = content ?? CGRect(origin: .zero, size: pixels)
                tally.lastPresented = shown.size
                // The page's gradient has no black or white: an edge of
                // what the view shows that is either is not the page.
                guard let surface = view?.layer?.sublayers?.first?.contents,
                      CFGetTypeID(surface as CFTypeRef) == IOSurfaceGetTypeID()
                else { return }
                let edges = AnimationStage.edgeColors(surface as! IOSurfaceRef, in: shown)
                if edges.contains(where: { $0.max() ?? 0 < 12 }) { tally.blackEdges += 1 }
                if edges.contains(where: { $0.min() ?? 0 > 240 }) { tally.whiteEdges += 1 }
            }
        }
        if let view { watch(view) }
        recorder.onRefresh = { [weak self] in
            // A windowed page: Chromium's layer showing the frame, which
            // has the frame's size, against its view's.
            if let native = self?.cefBrowser?.nativeView, let root = native.layer,
               let frameLayer = AnimationStage.remoteLayer(in: root)?.superlayer {
                // Chromium sizes this layer to the frame it shows.
                let shown = frameLayer.convert(frameLayer.bounds, to: root)
                tally.lastPresented = shown.size
                if abs(shown.width - native.bounds.width) > 1 || abs(shown.height - native.bounds.height) > 1 {
                    tally.trailing += 1
                }
                // Smaller than the view: the view's background shows.
                if shown.width < native.bounds.width - 1 || shown.height < native.bounds.height - 1 {
                    tally.whiteEdges += 1
                }
                return
            }
            // The view showing the page now: a move makes a new one.
            guard let view = self?.view, let window = view.window else { return }
            if view.didPresentFrame == nil { watch(view) }
            let scale = window.backingScaleFactor
            let wanted = CGSize(width: (view.bounds.width * scale).rounded(.down), height: (view.bounds.height * scale).rounded(.down))
            if view.layer?.sublayers?.first?.contents == nil {
                tally.blank += 1
            } else if let shown = tally.lastPresented,
                      abs(shown.width - wanted.width) > scale || abs(shown.height - wanted.height) > scale {
                tally.trailing += 1
            }
        }
        let meter = MainThreadMeter()
        let cpu = ProcessCPU.sample()
        let started = CACurrentMediaTime()
        meter.start()
        recorder.start(in: window.contentView!)
        start(animation)
        try? await Task.sleep(for: .seconds(seconds))
        recorder.stop()
        meter.stop()
        sample.seconds = CACurrentMediaTime() - started
        sample.appCPU = ProcessCPU.used(from: cpu, to: ProcessCPU.sample()).app
        sample.mainBusy = meter.busyFraction
        observers.forEach(center.removeObserver)
        view?.didPresentFrame = nil
        sample.refreshes = recorder.timestamps.count
        let gaps = zip(recorder.timestamps.dropFirst(), recorder.timestamps).map { $0 - $1 }
        let interval = recorder.interval > 0 ? recorder.interval : 1.0 / 60
        sample.hitches = gaps.filter { $0 > interval * 1.5 }.count
        sample.longestGap = gaps.max() ?? 0
        view?.didPresentFrame = nil
        sample.hostFrameChanges = tally.hostChanges
        sample.nativeFrameChanges = tally.nativeChanges
        sample.resizes = (cefBrowser?.resizeNotificationCount ?? 0) - resizesBefore
        sample.presented = tally.presented
        sample.trailing = tally.trailing
        sample.blank = tally.blank
        sample.letterboxed = tally.letterboxed
        sample.blackEdges = tally.blackEdges
        sample.whiteEdges = tally.whiteEdges
        sample.pageResizes = Int(await evaluate("window.__resizes") ?? "") ?? -1
        sample.pageFrames = Int(await evaluate("window.__raf") ?? "") ?? -1
        // Back where it started, without measuring.
        if returning { await run(animation, seconds: 1.0) }
        return sample
    }

    // MARK: Input

    struct ClickResult {
        var expected: CGPoint
        var received: CGPoint?
        /// Where the view's own conversion, which applies no 3D transform,
        /// put the click: what the view sent before it converted through
        /// its layers.
        var viewConversion: CGPoint
        var windowPoint: NSPoint = .zero
        var landed: Bool {
            guard let received else { return false }
            return abs(received.x - expected.x) <= 3 && abs(received.y - expected.y) <= 3
        }
        var summary: String {
            "expected \(Int(expected.x)),\(Int(expected.y)); received \(received.map { "\(Int($0.x)),\(Int($0.y))" } ?? "nothing"); view conversion \(Int(viewConversion.x)),\(Int(viewConversion.y))"
        }
    }

    /// Clicks the page where it shows the page point a quarter of the way
    /// in, converting through the layers, and reads where the page got it.
    func clickLanding() async -> ClickResult {
        guard let host = cefBrowser?.nativeView ?? hostView else { return ClickResult(expected: .zero, viewConversion: .zero) }
        // The page point and where it shows in the view.
        let pageSize = CGSize(
            width: Double(await evaluate("innerWidth") ?? "") ?? host.bounds.width,
            height: Double(await evaluate("innerHeight") ?? "") ?? host.bounds.height)
        let expected = CGPoint(x: (pageSize.width / 4).rounded(), y: (pageSize.height / 4).rounded())
        let frame = view?.contentFrame ?? host.bounds
        let inView = CGPoint(
            x: frame.minX + expected.x * frame.width / pageSize.width,
            y: frame.minY + expected.y * frame.height / pageSize.height)
        var result = await click(atViewPoint: inView)
        result.expected = expected
        return result
    }

    /// Clicks where the page's host view shows `point` (top-left origin,
    /// in the view's points), converting through the layers, and reads
    /// where the page got the click.
    func click(atViewPoint point: CGPoint) async -> ClickResult {
        guard let host = cefBrowser?.nativeView ?? hostView, let rootView = window.contentView?.superview,
              let hostLayer = host.layer, let rootLayer = rootView.layer
        else { return ClickResult(expected: .zero, viewConversion: .zero) }
        var inView = point
        if !host.isFlipped { inView.y = host.bounds.height - inView.y }
        var inLayer = inView
        if hostLayer.contentsAreFlipped() != host.isFlipped { inLayer.y = host.bounds.height - inLayer.y }
        var inRoot = rootLayer.convert(inLayer, from: hostLayer)
        if rootLayer.contentsAreFlipped() != rootView.isFlipped { inRoot.y = rootView.bounds.height - inRoot.y }
        let windowPoint = rootView.convert(inRoot, to: nil)
        var viewConversion = host.convert(windowPoint, from: nil)
        if !host.isFlipped { viewConversion.y = host.bounds.height - viewConversion.y }
        _ = await evaluate("window.__clicks = []")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        var received: CGPoint?
        _ = await SelfTest.waitUntilAsync(timeout: .seconds(2)) {
            guard let text = await self.evaluate("window.__clicks.length ? window.__clicks[0].join(',') : ''"),
                  case let parts = text.split(separator: ","), parts.count == 2,
                  let x = Double(parts[0]), let y = Double(parts[1])
            else { return false }
            received = CGPoint(x: x, y: y)
            return true
        }
        return ClickResult(expected: point, received: received, viewConversion: viewConversion, windowPoint: windowPoint)
    }

    /// The colours (red, green, blue) a few pixels in from the middle of
    /// each edge of `rect` in `surface`.
    static func edgeColors(_ surface: IOSurfaceRef, in rect: CGRect) -> [[UInt8]] {
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return [] }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let row = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let inset: CGFloat = 3
        let points = [
            CGPoint(x: rect.midX, y: rect.minY + inset), CGPoint(x: rect.midX, y: rect.maxY - inset),
            CGPoint(x: rect.minX + inset, y: rect.midY), CGPoint(x: rect.maxX - inset, y: rect.midY),
        ]
        return points.compactMap { point in
            let x = Int(point.x), y = Int(point.y)
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let pixel = base + y * row + x * 4
            return [pixel[2], pixel[1], pixel[0]]
        }
    }

    /// The `CALayerHost` that shows a windowed page's frames, drawn by the
    /// GPU process.
    static func remoteLayer(in layer: CALayer) -> CALayer? {
        if String(describing: type(of: layer)) == "CALayerHost" { return layer }
        for sublayer in layer.sublayers ?? [] {
            if let found = remoteLayer(in: sublayer) { return found }
        }
        return nil
    }

    /// Each layer's class, frame, bounds and transform, down the last
    /// branch.
    static func layerGeometry(_ layer: CALayer?) -> String {
        var parts: [String] = []
        var current = layer
        while let each = current {
            let transform = CATransform3DIsIdentity(each.transform) ? "" : " transform \(each.transform.m11)x\(each.transform.m22)"
            parts.append("\(type(of: each)) frame \(each.frame.integral) bounds \(each.bounds.size)\(transform) masks \(each.masksToBounds)")
            current = each.sublayers?.last
        }
        return parts.joined(separator: " > ")
    }

    /// The classes and contents of a layer tree, a few levels deep.
    static func layerSummary(_ layer: CALayer?, depth: Int = 0) -> String {
        guard let layer, depth < 6 else { return "" }
        let contents = layer.contents.map { CFGetTypeID($0 as CFTypeRef) == IOSurfaceGetTypeID() ? "IOSurface" : "\(type(of: $0))" } ?? "-"
        let children = (layer.sublayers ?? []).prefix(4).map { layerSummary($0, depth: depth + 1) }.joined(separator: ", ")
        return "\(type(of: layer))[\(contents)]" + (children.isEmpty ? "" : "{\(children)}")
    }

    // MARK: Page

    nonisolated static let page = """
        <!doctype html><title>animation</title>
        <style>
        html, body { margin: 0; height: 100%; font: 15px -apple-system, sans-serif; }
        body { background: linear-gradient(135deg, #2b6cb0, #9b2c2c); color: white; }
        p { margin: 0; padding: 12px 16px; }
        </style>
        <body>
        <p>A page under animation. Its text wraps at the width it is laid out at, so a resize that reaches the page reflows it, and one that does not stretches it.</p>
        <p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.</p>
        <script>
        window.__resizes = 0; window.__raf = 0; window.__clicks = [];
        addEventListener('resize', () => { window.__resizes++; });
        (function frame() { window.__raf++; requestAnimationFrame(frame); })();
        addEventListener('mousedown', e => { window.__clicks.push([e.clientX, e.clientY]); });
        </script>
        """
}

/// The layout the stage animates: two containers, the page in one of them.
private struct AnimationStageView: View {
    @Bindable var model: AnimationStageModel
    let page: () -> AnyView
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 20) {
            container(onRight: false)
            container(onRight: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.2))
    }

    private func container(onRight: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if model.onRight == onRight && model.shown {
                page()
                    .offscreenResizePolicy(model.policy)
                    .offscreenFramePlacement(model.placement)
                    .offscreenPageSize(model.pageSize)
                    .frame(width: model.fills ? nil : model.wide ? 440 : 300, height: model.fills ? nil : 400)
                    .frame(maxWidth: model.fills ? .infinity : nil, maxHeight: model.fills ? .infinity : nil)
                    .overlay(alignment: .topLeading) {
                        if model.showsOverlay {
                            // SwiftUI content over the page.
                            Color.orange
                                .frame(width: 120, height: 40)
                                .contentShape(.rect)
                                .onTapGesture { model.overlayTaps += 1 }
                                .padding(20)
                        }
                    }
                    .clipShape(.rect(cornerRadius: model.corner, style: .continuous))
                    .blur(radius: model.blur)
                    .opacity(model.opacity)
                    .rotation3DEffect(.degrees(model.angle3D), axis: (x: 0, y: 1, z: 0))
                    .rotationEffect(.degrees(model.angle))
                    .scaleEffect(model.scale)
                    .offset(x: model.offset)
                    .matchedGeometryEffect(id: "page", in: namespace)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: model.fills ? nil : 460, height: model.fills ? nil : 440, alignment: .topLeading)
        .frame(maxWidth: model.fills ? .infinity : nil, maxHeight: model.fills ? .infinity : nil)
    }
}

private struct WebKitRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

private final class WebKitMessages: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

/// Counts for one measurement.
@MainActor
private final class Tally {
    var hostChanges = 0
    var nativeChanges = 0
    var presented = 0
    var lastPresented: CGSize?
    var trailing = 0
    var blank = 0
    var letterboxed = 0
    var blackEdges = 0
    var whiteEdges = 0
}

/// Display refreshes, from the window's display link.
@MainActor
private final class RefreshRecorder: NSObject {
    private(set) var timestamps: [CFTimeInterval] = []
    private(set) var interval: CFTimeInterval = 0
    private var link: CADisplayLink?
    var onRefresh: (() -> Void)?

    func start(in view: NSView) {
        timestamps = []
        let link = view.displayLink(target: self, selector: #selector(refresh(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func refresh(_ link: CADisplayLink) {
        timestamps.append(link.timestamp)
        interval = link.duration
        onRefresh?()
    }

    func stop() {
        link?.invalidate()
        link = nil
        onRefresh = nil
    }
}
