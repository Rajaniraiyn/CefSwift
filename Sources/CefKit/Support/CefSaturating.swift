import CoreGraphics

extension Int32 {
    /// `value` rounded to the nearest whole number, clamped to `Int32`'s
    /// range; `0` for NaN. For coordinates and sizes CEF takes as `int`,
    /// which `Int32(_:)` would trap on when out of range: Chromium's
    /// numbers can be a renderer's, and an app's can be anything.
    init(saturating value: CGFloat) {
        guard !value.isNaN else {
            self = 0
            return
        }
        let rounded = value.rounded()
        if rounded <= CGFloat(Int32.min) {
            self = .min
        } else if rounded >= CGFloat(Int32.max) {
            self = .max
        } else {
            self = Int32(rounded)
        }
    }
}
