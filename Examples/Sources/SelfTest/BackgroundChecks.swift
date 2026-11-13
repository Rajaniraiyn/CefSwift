import AppKit
@_spi(Testing) import CefKit
import CefSwiftUI
import IOSurface

/// The canvas: what shows where a page paints nothing, in light and dark
/// app appearance, windowed, offscreen and Chrome-style.
///
/// Offscreen browsers are read from the surfaces the view shows; windowed
/// and Chrome-style ones from Chromium's own frame (`Page.captureScreenshot`)
/// and from the layer behind Chromium's view, since reading the screen
/// would need the screen-recording permission.
extension SelfTest {
    static func canvasPage(_ head: String, body: String = "<p>Some text.</p>") -> URL {
        URL(string: "data:text/html;charset=utf-8,"
            + "<!doctype html><title>canvas</title>\(head)\(body)"
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)!
    }

    static let plainPage = canvasPage("")
    static let darkPage = canvasPage("<meta name=color-scheme content=dark>")
    static let lightDarkPage = canvasPage("<meta name=color-scheme content='light dark'>")
    static let transparentPage = canvasPage("<style>html, body { background: transparent }</style>")

    /// An sRGB pixel, 0–255 per channel.
    struct Pixel: Equatable, CustomStringConvertible {
        var red, green, blue, alpha: Int
        var isOpaqueWhite: Bool { alpha == 255 && red >= 250 && green >= 250 && blue >= 250 }
        var isOpaqueDark: Bool { alpha == 255 && red < 60 && green < 60 && blue < 60 }
        var description: String { "rgba(\(red), \(green), \(blue), \(alpha))" }
    }

    /// The pixel near the bottom-right corner of `surface`, where the pages
    /// paint nothing.
    nonisolated static func cornerPixel(of surface: IOSurfaceRef) -> Pixel? {
        guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        guard width > 20, height > 20 else { return nil }
        let pixel = IOSurfaceGetBaseAddress(surface)
            .advanced(by: (height - 10) * IOSurfaceGetBytesPerRow(surface) + (width - 10) * 4)
            .assumingMemoryBound(to: UInt8.self)
        // BGRA.
        return Pixel(red: Int(pixel[2]), green: Int(pixel[1]), blue: Int(pixel[0]), alpha: Int(pixel[3]))
    }

    static func cornerPixel(ofPNG data: Data) -> Pixel? {
        guard let image = NSBitmapImageRep(data: data)?.converting(to: .sRGB, renderingIntent: .default),
              image.pixelsWide > 20, image.pixelsHigh > 20,
              let color = image.colorAt(x: image.pixelsWide - 10, y: image.pixelsHigh - 10)
        else { return nil }
        return Pixel(red: Int((color.redComponent * 255).rounded()), green: Int((color.greenComponent * 255).rounded()),
                     blue: Int((color.blueComponent * 255).rounded()), alpha: Int((color.alphaComponent * 255).rounded()))
    }

    static func pixel(of color: CGColor?) -> Pixel? {
        guard let color = color?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = color.components, c.count >= 4 else { return nil }
        return Pixel(red: Int((c[0] * 255).rounded()), green: Int((c[1] * 255).rounded()),
                     blue: Int((c[2] * 255).rounded()), alpha: Int((c[3] * 255).rounded()))
    }

    /// What the offscreen `view` shows at its corner: its current surface
    /// over its own background.
    static func offscreenCorner(_ view: NSView) -> (surface: Pixel?, background: Pixel?) {
        let contents = view.layer?.sublayers?.first?.contents
        var surface: Pixel?
        if let contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            surface = cornerPixel(of: contents as! IOSurfaceRef)
        }
        return (surface, pixel(of: view.layer?.backgroundColor))
    }

    static func backgroundChecks() async {
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let mode = appearance == .aqua ? "light" : "dark"
            await windowedCanvasChecks(mode)
            await offscreenCanvasChecks(mode)
            await chromeStyleCanvasChecks(mode)
        }
        NSApp.appearance = previousAppearance
        await transparentCanvasChecks()
    }

    static func windowedCanvasChecks(_ mode: String) async {
        let browser = CefBrowser(url: plainPage)
        let view = hostWindowed(browser)
        defer { browser.close(force: true); view.removeFromSuperview() }
        check("background (windowed, \(mode) app): the view behind the page is the white canvas",
              pixel(of: view.layer?.backgroundColor)?.isOpaqueWhite == true,
              detail: "\(String(describing: pixel(of: view.layer?.backgroundColor)))")
        guard await loaded(browser) else { return check("background (windowed, \(mode) app): loads", false) }
        await expectCanvas("windowed, \(mode) app", browser, plain: true)
        await expectCanvas("windowed, \(mode) app", browser, plain: false)
    }

    static func chromeStyleCanvasChecks(_ mode: String) async {
        let browser = CefBrowser(url: plainPage)
        let cefWindow = CefWindow(browser: browser)
        cefWindow.show()
        defer { cefWindow.close() }
        guard await loaded(browser) else { return check("background (Chrome style, \(mode) app): loads", false) }
        // A Chrome-style page leaves its canvas transparent (its own frame
        // reads transparent), and the web contents view paints behind it.
        let behind = cefWindow.webContentsBackgroundColor
        check("background (Chrome style, \(mode) app): the color behind an unstyled page is opaque white",
              behind == 0xFFFF_FFFF, detail: behind.map { String($0, radix: 16) } ?? "no view")
        let canvas = (try? await browser.snapshot()).flatMap(cornerPixel(ofPNG:))
        print("NOTE background (Chrome style, \(mode) app): Chromium's own frame of an unstyled page reads \(canvas.map { "\($0)" } ?? "-")")
        _ = await load(darkPage, in: browser)
        skip("background (Chrome style, \(mode) app): a color-scheme: dark page is dark",
             because: "Chrome style paints no canvas of its own, so a dark page shows the browser's backgroundColor", .limitation)
        cefWindow.close()
        _ = await waitUntil { cefWindow.isClosed && browser.state == .closed }
    }

    /// Checks Chromium's own frame of `browser`: white for the plain page,
    /// dark for the one that opts into a dark color scheme.
    static func expectCanvas(_ label: String, _ browser: CefBrowser, plain: Bool) async {
        let url = plain ? plainPage : darkPage
        if browser.url != url { _ = await load(url, in: browser) }
        var corner: Pixel?
        _ = await waitUntilAsync(timeout: .seconds(5)) {
            corner = (try? await browser.snapshot()).flatMap(cornerPixel(ofPNG:))
            return plain ? corner?.isOpaqueWhite == true : corner?.isOpaqueDark == true
        }
        check("background (\(label)): \(plain ? "an unstyled page is opaque white" : "a color-scheme: dark page is dark")",
              plain ? corner?.isOpaqueWhite == true : corner?.isOpaqueDark == true,
              detail: "\(corner.map { "\($0)" } ?? "no frame")")
    }

    static func offscreenCanvasChecks(_ mode: String) async {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        let browser = CefBrowser(url: plainPage, configuration: configuration)
        let view = hostOffscreen(browser)
        defer { browser.close(force: true); view.removeFromSuperview() }
        let label = "offscreen, \(mode) app"
        check("background (\(label)): the view behind the page is the white canvas",
              pixel(of: view.layer?.backgroundColor)?.isOpaqueWhite == true,
              detail: "\(String(describing: pixel(of: view.layer?.backgroundColor)))")
        guard await loaded(browser), window.occlusionState.contains(.visible) else {
            return skip("background (\(label))", because: "the test window is not visible", .environment)
        }
        _ = await waitUntil { offscreenCorner(view).surface != nil }
        check("background (\(label)): an unstyled page is opaque white",
              await waitUntil(timeout: .seconds(5)) { offscreenCorner(view).surface?.isOpaqueWhite == true },
              detail: "\(offscreenCorner(view))")

        // Every surface shown while moving between two opaque pages.
        let second = canvasPage("", body: "<p>Another page.</p>")
        var seen: [Pixel] = []
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                if let pixel = offscreenCorner(view).surface, seen.last != pixel { seen.append(pixel) }
                try? await Task.sleep(for: .milliseconds(4))
            }
        }
        _ = await load(second, in: browser)
        try? await Task.sleep(for: .milliseconds(300))
        _ = await load(plainPage, in: browser)
        try? await Task.sleep(for: .milliseconds(300))
        sampler.cancel()
        check("background (\(label)): no frame between two opaque pages is transparent or dark",
              !seen.isEmpty && seen.allSatisfy(\.isOpaqueWhite), detail: "\(seen)")

        _ = await load(darkPage, in: browser)
        check("background (\(label)): a color-scheme: dark page is dark",
              await waitUntil(timeout: .seconds(5)) { offscreenCorner(view).surface?.isOpaqueDark == true },
              detail: "\(offscreenCorner(view))")
        _ = await load(lightDarkPage, in: browser)
        let followsApp = await waitUntil(timeout: .seconds(5)) {
            let corner = offscreenCorner(view).surface
            return mode == "dark" ? corner?.isOpaqueDark == true : corner?.isOpaqueWhite == true
        }
        check("background (\(label)): a color-scheme: light dark page follows the app's appearance", followsApp,
              detail: "\(offscreenCorner(view))")
        _ = await load(transparentPage, in: browser)
        check("background (\(label)): a page with a transparent background still shows the white canvas",
              await waitUntil(timeout: .seconds(5)) { offscreenCorner(view).surface?.isOpaqueWhite == true },
              detail: "\(offscreenCorner(view))")
    }

    /// `drawsBackground = false` makes an offscreen page see-through, and a
    /// custom canvas color shows where pages paint nothing.
    static func transparentCanvasChecks() async {
        var configuration = CefBrowser.Configuration()
        configuration.rendering = .offscreen
        configuration.drawsBackground = false
        let browser = CefBrowser(url: transparentPage, configuration: configuration)
        let view = hostOffscreen(browser)
        guard await loaded(browser), window.occlusionState.contains(.visible) else {
            await closeHosted(browser, view)
            return skip("background (transparent)", because: "the test window is not visible", .environment)
        }
        check("background (offscreen, drawsBackground off): the page is see-through, the view too",
              await waitUntil(timeout: .seconds(5)) {
                  let corner = offscreenCorner(view)
                  return corner.surface?.alpha == 0 && corner.background?.alpha == 0
              }, detail: "\(offscreenCorner(view))")
        await closeHosted(browser, view)

        var tinted = CefBrowser.Configuration()
        tinted.rendering = .offscreen
        tinted.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)
        let blue = CefBrowser(url: plainPage, configuration: tinted)
        let blueView = hostOffscreen(blue)
        _ = await loaded(blue)
        check("background (offscreen): a custom canvas color shows, opaque",
              await waitUntil(timeout: .seconds(5)) {
                  let corner = offscreenCorner(blueView)
                  return corner.surface == Pixel(red: 0, green: 0, blue: 255, alpha: 255)
                      && corner.background == Pixel(red: 0, green: 0, blue: 255, alpha: 255)
              }, detail: "\(offscreenCorner(blueView))")
        await closeHosted(blue, blueView)

        var windowedTinted = CefBrowser.Configuration()
        windowedTinted.backgroundColor = .systemBlue
        windowedTinted.drawsBackground = false
        let windowed = CefBrowser(url: plainPage, configuration: windowedTinted)
        let windowedView = hostWindowed(windowed)
        _ = await loaded(windowed)
        var corner: Pixel?
        _ = await waitUntilAsync(timeout: .seconds(5)) {
            corner = (try? await windowed.snapshot()).flatMap(cornerPixel(ofPNG:))
            return corner?.alpha == 255 && corner?.blue ?? 0 > 200 && corner?.red ?? 255 < 100
        }
        check("background (windowed): a custom canvas color shows, and drawsBackground cannot make it see-through",
              corner?.alpha == 255 && corner?.blue ?? 0 > 200 && corner?.red ?? 255 < 100,
              detail: "\(corner.map { "\($0)" } ?? "no frame")")
        await closeHosted(windowed, windowedView)
    }
}
