import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code for an address, drawn crisply at any size: the browser's own
/// QR code panel in place of Chromium's bubble.
struct QRCodeView: View {
    private let text: String

    /// A QR code encoding `url`.
    init(url: URL?) {
        text = url?.absoluteString ?? ""
    }

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(1, contentMode: .fit)
                .accessibilityLabel(Text("QR code for \(text)"))
        }
    }

    /// A QR code encoding `text`, `size` points square, black on white,
    /// with the standard quiet zone. `nil` when the text is too long to
    /// encode.
    @MainActor
    static func image(for text: String, size: CGFloat = 240) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = (size * 2 / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: max(scale, 1), y: max(scale, 1)))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: size, height: size))
    }
}
