import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Pictures of the app's own windows as the window server composites them,
/// Chromium's layers included, for `Gallery -animationShots`.
///
/// `CGWindowListCreateImage` of a window of the calling process needs no
/// screen-recording permission; the macOS 15 SDK and later mark it
/// unavailable to Swift, so it is looked up at run time. Never use it for
/// other apps' windows: that is what needs the permission.
@MainActor
enum WindowCapture {
    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private static let createImage: CreateImage? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: CreateImage.self)
    }()

    /// `window` as it is on screen, at its backing scale; nil when the
    /// window server gives nothing.
    static func image(of window: NSWindow) -> CGImage? {
        guard let createImage, window.windowNumber > 0 else { return nil }
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        return createImage(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The images side by side, `columns` to a row, each scaled to `width`
    /// pixels and labelled.
    static func sheet(_ images: [(String, CGImage)], columns: Int, width: Int) -> CGImage? {
        guard let first = images.first?.1 else { return nil }
        let height = width * first.height / max(first.width, 1)
        let label = 22
        let rows = (images.count + columns - 1) / columns
        guard let context = CGContext(
            data: nil, width: columns * width, height: rows * (height + label), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.interpolationQuality = .high
        for (index, (name, image)) in images.enumerated() {
            let x = index % columns * width
            let top = context.height - index / columns * (height + label)
            context.draw(image, in: CGRect(x: x, y: top - label - height, width: width, height: height))
            let text = NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 15)])
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = CGPoint(x: x + 6, y: top - label + 6)
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }

    /// The layer tree under `view`, and the chain of its ancestors' layers,
    /// with what decides whether a layer shows: frame, hidden, opacity,
    /// masks, transforms, background.
    static func describeLayers(of view: NSView) -> String {
        var lines: [String] = ["ancestors:"]
        var ancestor: CALayer? = view.layer?.superlayer
        while let layer = ancestor {
            lines.append("  " + describe(layer))
            ancestor = layer.superlayer
        }
        lines.append("tree:")
        func walk(_ layer: CALayer, _ depth: Int) {
            lines.append(String(repeating: "  ", count: depth + 1) + describe(layer))
            for sublayer in layer.sublayers ?? [] { walk(sublayer, depth + 1) }
        }
        if let layer = view.layer { walk(layer, 0) }
        lines.append("views:")
        func walkViews(_ view: NSView, _ depth: Int) {
            lines.append(String(repeating: "  ", count: depth + 1)
                + "\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) flipped=\(view.isFlipped) layer=\(view.layer.map { "\(type(of: $0))" } ?? "-")")
            for subview in view.subviews { walkViews(subview, depth + 1) }
        }
        walkViews(view, 0)
        return lines.joined(separator: "\n")
    }

    private static func describe(_ layer: CALayer) -> String {
        var parts = ["\(type(of: layer))", "frame=\(layer.frame)", "bounds=\(layer.bounds)"]
        if layer.isHidden { parts.append("HIDDEN") }
        if layer.opacity != 1 { parts.append("opacity=\(layer.opacity)") }
        if layer.masksToBounds { parts.append("masks") }
        if layer.mask != nil { parts.append("mask=\(type(of: layer.mask!)) \(layer.mask!.frame)") }
        if layer.cornerRadius != 0 { parts.append("radius=\(layer.cornerRadius)") }
        if !CATransform3DIsIdentity(layer.transform) {
            let t = CATransform3DGetAffineTransform(layer.transform)
            parts.append("transform=[\(t.a) \(t.b) \(t.c) \(t.d) \(t.tx) \(t.ty)]\(CATransform3DIsAffine(layer.transform) ? "" : " 3D")")
        }
        if !CATransform3DIsIdentity(layer.sublayerTransform) { parts.append("sublayerTransform") }
        if layer.isGeometryFlipped { parts.append("geometryFlipped") }
        if layer.shouldRasterize { parts.append("RASTERIZED") }
        if let filters = layer.filters, !filters.isEmpty { parts.append("filters=\(filters.count)") }
        if let color = layer.backgroundColor, color.alpha > 0 {
            parts.append("bg=\((color.components ?? []).map { String(format: "%.2f", $0) }.joined(separator: ","))")
        }
        if layer.contents != nil { parts.append("contents") }
        if layer.responds(to: Selector(("contextId"))), let id = layer.value(forKey: "contextId") {
            parts.append("contextId=\(id)")
        }
        if let presentation = layer.presentation(), presentation.frame != layer.frame {
            parts.append("presentation=\(presentation.frame)")
        }
        return parts.joined(separator: " ")
    }
}
