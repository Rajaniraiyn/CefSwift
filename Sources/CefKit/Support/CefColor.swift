import CCef
import CoreGraphics

/// A color as CEF's sRGB ARGB `cef_color_t`, or transparent black when the
/// color cannot be converted.
func cefColor(_ color: CGColor) -> cef_color_t {
    guard let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
          let c = srgb.components, c.count >= 4
    else { return 0 }
    func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
    return (byte(c[3]) << 24) | (byte(c[0]) << 16) | (byte(c[1]) << 8) | byte(c[2])
}
