import CCef
import CoreGraphics

extension CGColor {
    /// The color as an opaque `cef_color_t`; white when it cannot be
    /// converted.
    var opaqueCefColor: cef_color_t {
        let value = cefColor(self)
        return value == 0 && alpha > 0 ? 0xFFFF_FFFF : value | 0xFF00_0000
    }
}

/// A color as CEF's sRGB ARGB `cef_color_t`, or transparent black when the
/// color cannot be converted.
func cefColor(_ color: CGColor) -> cef_color_t {
    guard let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
          let c = srgb.components, c.count >= 4
    else { return 0 }
    func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
    return (byte(c[3]) << 24) | (byte(c[0]) << 16) | (byte(c[1]) << 8) | byte(c[2])
}
