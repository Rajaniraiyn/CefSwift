import AppKit
import CefChromium
import CefKit
import SwiftUI

/// Whether pages are on screen, not only loaded: every hosting path, at
/// rest and after what moves a page about.
///
/// The other groups check what Chromium reports (loads, its own
/// screenshots, which it renders on demand) and the app's own layers;
/// none looked at what the window server composites. A page whose frames
/// never reached the screen, or that lay under an opaque view of the
/// library's, passed them all. These checks take a picture of the test's
/// own window (`CGWindowListCreateImage` of a window of this process,
/// which needs no screen-recording permission) and look for a two-colour
/// page where its view is: magenta down to the middle, cyan below, edge
/// to edge, so a page shifted, cut off or covered fails. Where the window
/// server gives no picture they skip, and the capture-free invariants
/// beside them still run.
extension SelfTest {
    static func visibilityChecks() async {
        await windowedVisibilityChecks()
        await windowedResizeDriftChecks()
        await windowedRehostingChecks()
        await offscreenVisibilityChecks()
        await cefWindowVisibilityChecks()
        await chromeWindowVisibilityChecks()
    }

    /// Magenta down to the middle, cyan below, filling the viewport.
    /// (No `#` or `%`: `URL(string:)` escapes the one and reads the other
    /// as the fragment.)
    static let twoColourPage = URL(string: "data:text/html,"
        + "<style>html{color-scheme:light}body{margin:0}div{height:50vh}</style>"
        + "<div style='background:rgb(255,0,255)'></div><div style='background:rgb(0,255,255)'></div>")!

    // MARK: Paths

    private static func windowedVisibilityChecks() async {
        let browser = CefBrowser(url: twoColourPage)
        let view = hostWindowed(browser)
        defer { browser.close(force: true); view.removeFromSuperview() }
        guard await loaded(browser) else { return check("visibility (windowed): loads", false) }
        await expectVisible("visibility (windowed): the page is on screen, edge to edge", in: view)

        // What SwiftUI's effects set on a container's layer: Chromium's
        // layers are composited through them by the window server.
        let content = window.contentView!
        content.wantsLayer = true
        view.removeFromSuperview()
        let container = NSView(frame: content.bounds.insetBy(dx: 80, dy: 60))
        container.wantsLayer = true
        content.addSubview(container)
        defer { container.removeFromSuperview() }
        view.frame = container.bounds
        container.addSubview(view)
        for (effect, apply) in [
            ("a 3D rotation", { (layer: CALayer) in
                var transform = CATransform3DIdentity
                transform.m34 = -1 / 800
                layer.transform = CATransform3DRotate(transform, 0.35, 0, 1, 0)
            }),
            ("opacity and a corner mask", { (layer: CALayer) in
                layer.transform = CATransform3DIdentity
                layer.opacity = 0.8
                layer.cornerRadius = 24
                layer.masksToBounds = true
            }),
        ] {
            if let layer = container.layer { apply(layer) }
            try? await Task.sleep(for: .milliseconds(400))
            await expectCentreShown("visibility (windowed): the page shows under \(effect)", in: container)
        }
    }

    /// The centre of the upper and lower halves of `view` show the
    /// two-colour page, through whatever its layer does to it.
    private static func expectCentreShown(_ name: String, in view: NSView) async {
        guard let window = view.window, let image = windowImage(window) else {
            return skip(name, because: "the window server gives no picture of this process's window here", .environment)
        }
        let rect = view.convert(view.bounds, to: nil)
        let scale = CGFloat(image.width) / window.frame.width
        let upper = samplePixel(image, x: Int(rect.midX * scale), y: Int((window.frame.height - (rect.midY + rect.height / 4)) * scale))
        let lower = samplePixel(image, x: Int(rect.midX * scale), y: Int((window.frame.height - (rect.midY - rect.height / 4)) * scale))
        let shown = upper.map { $0.r > 150 && $0.g < 110 && $0.b > 150 } == true
            && lower.map { $0.r < 110 && $0.g > 150 && $0.b > 150 } == true
        check(name, shown, detail: "upper \(upper.map { "\($0)" } ?? "-"), lower \(lower.map { "\($0)" } ?? "-")")
    }

    /// The sizes an animation gives a view, fractional, on every refresh:
    /// Chromium's frame layer must stay the view's size.
    private static func windowedResizeDriftChecks() async {
        let browser = CefBrowser(url: twoColourPage)
        let view = CefWindowedBrowserView(browser: browser)
        let content = window.contentView!
        view.frame = CGRect(x: 20, y: 20, width: 300, height: 260)
        content.addSubview(view)
        defer { browser.close(force: true); view.removeFromSuperview() }
        guard await loaded(browser) else { return check("visibility (windowed resize): loads", false) }
        for (from, to) in [(CGSize(width: 300, height: 260), CGSize(width: 520, height: 470)),
                           (CGSize(width: 520, height: 470), CGSize(width: 300, height: 260))] {
            for step in 0...60 {
                let t = (1 - cos(Double(step) / 60 * .pi)) / 2
                view.setFrameSize(CGSize(width: from.width + (to.width - from.width) * t + 0.37,
                                         height: from.height + (to.height - from.height) * t + 0.29))
                try? await Task.sleep(for: .milliseconds(4))
            }
        }
        view.setFrameSize(CGSize(width: 300, height: 260))
        try? await Task.sleep(for: .milliseconds(500))
        let layer = chromiumFrameLayer(in: view)
        check("visibility (windowed resize): Chromium's frame layer is the view's size after a spring of fractional sizes",
              layer.map { abs($0.bounds.width - 300) < 1 && abs($0.bounds.height - 260) < 1 } == true,
              detail: "\(layer.map { "\($0.bounds.size)" } ?? "no layer") in a 300×260 view")
        await expectVisible("visibility (windowed resize): the page is on screen, edge to edge, after the spring", in: view)
    }

    /// A page taken out of its view and shown in a new one, again and
    /// again, as SwiftUI does when it removes and inserts a `CefWebView`.
    private static func windowedRehostingChecks() async {
        let browser = CefBrowser(url: twoColourPage)
        var view = hostWindowed(browser)
        defer { browser.close(force: true); view.removeFromSuperview() }
        guard await loaded(browser) else { return check("visibility (windowed re-hosting): loads", false) }
        for _ in 0..<5 {
            view.removeFromSuperview()
            view.browser = nil
            try? await Task.sleep(for: .milliseconds(100))
            view = hostWindowed(browser)
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(500))
        check("visibility (windowed re-hosting): the page is live and in its fifth view",
              browser.state == .live && browser.nativeView?.superview === view && browser.nativeView?.isHiddenOrHasHiddenAncestor == false,
              detail: "state \(browser.state), in view \(browser.nativeView?.superview === view)")
        await expectVisible("visibility (windowed re-hosting): the page is on screen after five moves", in: view)
    }

    private static func offscreenVisibilityChecks() async {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        let browser = CefBrowser(url: twoColourPage, configuration: configuration)
        let view = hostOffscreen(browser)
        defer { browser.close(force: true); view.removeFromSuperview() }
        guard await loaded(browser) else { return check("visibility (offscreen): loads", false) }
        await expectVisible("visibility (offscreen): the page is on screen, edge to edge", in: view)
    }

    private static func cefWindowVisibilityChecks() async {
        let browser = CefBrowser(url: twoColourPage)
        let cefWindow = CefWindow(browser: browser)
        cefWindow.show()
        defer { cefWindow.close() }
        guard await loaded(browser), await waitUntil(timeout: .seconds(5), { cefWindow.window.flatMap(pageView(in:)) != nil }),
              let page = cefWindow.window.flatMap(pageView(in:))
        else { return check("visibility (CefWindow): loads and shows its page", false) }
        await expectVisible("visibility (CefWindow): the page is on screen, edge to edge", in: page)
        cefWindow.close()
        _ = await waitUntil { cefWindow.isClosed && browser.state == .closed }
    }

    private static func chromeWindowVisibilityChecks() async {
        let chromeWindow: CefChromeWindow
        do {
            chromeWindow = try await CefChromeWindow.open(url: twoColourPage, frame: CGRect(x: 140, y: 140, width: 900, height: 700))
        } catch {
            return check("visibility (CefChromeWindow): opens", false, detail: "\(error)")
        }
        defer { chromeWindow.close() }
        _ = await waitUntil(timeout: .seconds(10)) { chromeWindow.window != nil && chromeWindow.activeTab?.browser != nil }
        if let browser = chromeWindow.activeTab?.browser { _ = await loaded(browser) }
        chromeWindow.window?.makeKeyAndOrderFront(nil)
        for showsChromeUI in [true, false] {
            let label = showsChromeUI ? "with Chrome's UI" : "under the app's top bar"
            chromeWindow.showsChromeUI = showsChromeUI
            if !showsChromeUI {
                chromeWindow.setTopBar { Color.indigo.frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            _ = await waitUntil(timeout: .seconds(3)) { showsChromeUI || chromeWindow.topBarHeight > 0 }
            try? await Task.sleep(for: .milliseconds(500))
            guard let nsWindow = chromeWindow.window, let page = pageView(in: nsWindow) else {
                check("visibility (CefChromeWindow, \(label)): shows its page", false)
                continue
            }
            // Capture-free: nothing opaque of the library's over the page.
            let covering = opaqueLibraryViews(in: nsWindow).filter { view in
                view.convert(view.bounds, to: nil).intersection(page.convert(page.bounds, to: nil)).width > 1
                    && view.convert(view.bounds, to: nil).intersection(page.convert(page.bounds, to: nil)).height > 1
            }
            check("visibility (CefChromeWindow, \(label)): no opaque view of the library's lies over the page",
                  covering.isEmpty, detail: covering.map { "\(type(of: $0)) \($0.frame)" }.joined(separator: ", "))
            await expectVisible("visibility (CefChromeWindow, \(label)): the page is on screen, edge to edge", in: page)
        }
    }

    // MARK: Looking

    /// Takes a picture of `view`'s window and checks the two-colour page
    /// fills `view`: magenta along its top edge, cyan along its bottom.
    private static func expectVisible(_ name: String, in view: NSView) async {
        guard let window = view.window else { return check(name, false, detail: "the view is in no window") }
        window.orderFront(nil)
        var detail = ""
        let shown = await waitUntilAsync(timeout: .seconds(5)) {
            guard let image = windowImage(window) else { return false }
            let rect = view.convert(view.bounds, to: nil)
            let windowHeight = window.frame.height
            let scale = CGFloat(image.width) / window.frame.width
            // Window coordinates have their origin at the bottom left, the
            // picture at the top left; it includes the title bar.
            func pixel(_ x: CGFloat, _ y: CGFloat) -> (r: Int, g: Int, b: Int)? {
                samplePixel(image, x: Int(x * scale), y: Int((windowHeight - y) * scale))
            }
            let points = [
                ("top", rect.midX, rect.maxY - 4, true), ("top left", rect.minX + 6, rect.maxY - 6, true),
                ("upper middle", rect.midX, rect.midY + rect.height / 4, true),
                ("lower middle", rect.midX, rect.midY - rect.height / 4, false),
                ("bottom", rect.midX, rect.minY + 4, false), ("bottom right", rect.maxX - 6, rect.minY + 6, false),
            ]
            var wrong: [String] = []
            for (label, x, y, magenta) in points {
                guard let p = pixel(x, y) else { wrong.append("\(label): outside"); continue }
                let matches = magenta ? (p.r > 190 && p.g < 90 && p.b > 190) : (p.r < 90 && p.g > 190 && p.b > 190)
                if !matches { wrong.append("\(label) is (\(p.r),\(p.g),\(p.b))") }
            }
            detail = wrong.joined(separator: "; ")
            return wrong.isEmpty
        }
        guard let image = windowImage(window) else {
            return skip(name, because: "the window server gives no picture of this process's window here", .environment)
        }
        // SELFTEST_PICTURES=<directory> keeps the pictures, to look at.
        if let directory = ProcessInfo.processInfo.environment["SELFTEST_PICTURES"] {
            let file = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appending(path: "\(file).png"))
        }
        check(name, shown, detail: detail)
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage`, which the macOS 15 SDK and later keep
    /// from Swift, for a window of this process.
    private static func windowImage(_ window: NSWindow) -> CGImage? {
        guard window.windowNumber > 0,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming
        return create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }

    nonisolated private static func samplePixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    /// The shown page view Chromium put in `window`: its largest visible
    /// `WebContentsViewCocoa`.
    static func pageView(in window: NSWindow) -> NSView? {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if "\(type(of: view))" == "WebContentsViewCocoa", !view.isHiddenOrHasHiddenAncestor { found.append(view) }
            view.subviews.forEach(walk)
        }
        if let frameView = window.contentView?.superview { walk(frameView) }
        return found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// The layer Chromium shows its frames in, under its view's background
    /// layer: the one it keeps sized to the view.
    static func chromiumFrameLayer(in view: NSView) -> CALayer? {
        var found: NSView?
        func walk(_ view: NSView) {
            if "\(type(of: view))" == "RenderWidgetHostViewCocoa" { found = view }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found?.layer?.sublayers?.first { $0.isGeometryFlipped }
    }

    /// Views of CefChromium's cover with an opaque layer.
    private static func opaqueLibraryViews(in window: NSWindow) -> [NSView] {
        guard let frameView = window.contentView?.superview,
              let cover = frameView.subviews.first(where: { "\(type(of: $0))" == "ChromeUICoverView" })
        else { return [] }
        return cover.subviews.filter { !$0.isHidden && ($0.layer?.backgroundColor?.alpha ?? 0) > 0.5 }
    }
}
