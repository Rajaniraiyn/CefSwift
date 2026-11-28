import AudioToolbox

/// Puts a decoder's channels in FLAC's order.
///
/// FLAC fixes the order by channel count (RFC 9639, section 9.1.3):
///
/// | Channels | Order |
/// |---|---|
/// | 1 | mono |
/// | 2 | left, right |
/// | 3 | left, right, center |
/// | 4 | front left, front right, back left, back right |
/// | 5 | front left, front right, center, back left, back right |
/// | 6 | front left, front right, center, LFE, back left, back right |
/// | 7 | front left, front right, center, LFE, back center, side left, side right |
/// | 8 | front left, front right, center, LFE, back left, back right, side left, side right |
///
/// Decoders name their channels with Core Audio labels in an order of
/// their own: AAC's 5.1 comes out center first (MPEG 5.1 D). Where a
/// layout has one surround pair, FLAC's "back" pair takes it, whatever
/// Core Audio calls it; with two, the rear pair goes back and the other to
/// the sides.
enum AudioChannelOrder {
    private enum Slot: Equatable {
        case left, right, center, lfe, backLeft, backRight, backCenter, sideLeft, sideRight
    }

    private static let slots: [Int: [Slot]] = [
        3: [.left, .right, .center],
        4: [.left, .right, .backLeft, .backRight],
        5: [.left, .right, .center, .backLeft, .backRight],
        6: [.left, .right, .center, .lfe, .backLeft, .backRight],
        7: [.left, .right, .center, .lfe, .backCenter, .sideLeft, .sideRight],
        8: [.left, .right, .center, .lfe, .backLeft, .backRight, .sideLeft, .sideRight],
    ]

    /// For each FLAC channel, the index of the decoder's channel that goes
    /// there. The decoder's order when its labels do not fill FLAC's
    /// slots one to one.
    static func flacOrder(of labels: [AudioChannelLabel], channels: Int) -> [Int] {
        let identity = Array(0..<channels)
        guard labels.count == channels, let wanted = slots[channels] else { return identity }
        let surrounds: Set<AudioChannelLabel> = [
            kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
            kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect,
        ]
        let rears: Set<AudioChannelLabel> = [kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]
        let hasTwoPairs = labels.contains(where: surrounds.contains) && labels.contains(where: rears.contains)
        func slot(_ label: AudioChannelLabel) -> Slot? {
            switch label {
            case kAudioChannelLabel_Left: return .left
            case kAudioChannelLabel_Right: return .right
            case kAudioChannelLabel_Center, kAudioChannelLabel_Mono: return .center
            case kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LFE2: return .lfe
            case kAudioChannelLabel_CenterSurround: return .backCenter
            case kAudioChannelLabel_RearSurroundLeft: return .backLeft
            case kAudioChannelLabel_RearSurroundRight: return .backRight
            case kAudioChannelLabel_LeftSurround, kAudioChannelLabel_LeftSurroundDirect:
                return hasTwoPairs || wanted.contains(.sideLeft) && !wanted.contains(.backLeft) ? .sideLeft : .backLeft
            case kAudioChannelLabel_RightSurround, kAudioChannelLabel_RightSurroundDirect:
                return hasTwoPairs || wanted.contains(.sideRight) && !wanted.contains(.backRight) ? .sideRight : .backRight
            default: return nil
            }
        }
        var order: [Int] = []
        for target in wanted {
            let matches = labels.indices.filter { slot(labels[$0]) == target }
            guard matches.count == 1 else { return identity }
            order.append(matches[0])
        }
        return Set(order).count == channels ? order : identity
    }

    /// The labels of a layout, in order, however the layout states them.
    static func labels(of layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions || layout.pointee.mNumberChannelDescriptions > 0 {
            // The descriptions run past the struct's one-element array, in
            // the layout's own memory.
            let count = Int(layout.pointee.mNumberChannelDescriptions)
            guard let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return [] }
            let first = (UnsafeRawPointer(layout) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
            return UnsafeBufferPointer(start: first, count: count).map(\.mChannelLabel)
        }
        var specifier: UInt32 = 0
        var propertyID = kAudioFormatProperty_ChannelLayoutForTag
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            specifier = layout.pointee.mChannelBitmap.rawValue
            propertyID = kAudioFormatProperty_ChannelLayoutForBitmap
        } else {
            specifier = tag
        }
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(propertyID, 4, &specifier, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size)
        else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioFormatGetProperty(propertyID, 4, &specifier, &size, raw) == noErr else { return [] }
        let expanded = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        // The expansion lists the descriptions, whatever tag it keeps.
        guard expanded.pointee.mNumberChannelDescriptions > 0 else { return [] }
        return labels(of: expanded)
    }
}
