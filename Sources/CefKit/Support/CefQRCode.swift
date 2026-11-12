import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR codes for an interface of your own in place of Chromium's QR code
/// bubble (``CefChromiumSurface/Kind/qrCode``).
public enum CefQRCode {
    /// A QR code encoding `text`, `size` points square, black on white,
    /// with the standard quiet zone. `nil` when the text is too long to
    /// encode.
    @MainActor
    public static func image(for text: String, size: CGFloat = 240) -> NSImage? {
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
