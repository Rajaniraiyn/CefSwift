import CCef
import CefBase

/// Whether pages can play media in codecs CEF's standard builds leave out,
/// using the decoders macOS ships. **Experimental.**
///
/// CEF's official builds have no AAC, H.264 or HEVC decoder. With
/// ``systemDecoders``, AAC audio plays in Chromium browsers:
///
/// - Media Source Extensions: `MediaSource.isTypeSupported` and
///   `addSourceBuffer` accept `audio/mp4; codecs="mp4a.40.2"` (and HE-AAC,
///   `mp4a.40.5`, `mp4a.40.29`). The page's appends are decoded by the
///   system's AAC decoder and played, losslessly, as FLAC through the page's
///   own native `MediaSource`.
/// - `<audio>` and `<video>` whose source is an AAC-only `.m4a`, `.mp4` or
///   `.aac` file the native player rejects, when the page could read the
///   file itself: same origin, or cross-origin with `crossorigin` and CORS.
///
/// Video in those codecs, encrypted media (EME), and cross-origin files
/// without CORS play as without the shim: not at all. The guide's
/// "Experimental: system-decoder media shim" lists what a page can observe.
public enum CefMediaCompatibility: Sendable, Hashable {
    /// Chromium's own codecs only. The default.
    case none
    /// AAC through the system's decoder, as described above.
    case systemDecoders
}

/// Decodes AAC for renderers of browsers in an app with
/// ``CefMediaCompatibility/systemDecoders``.
///
/// Each stream is one `CefSystemAudioDecoder`, keyed by the frame that
/// asked and the renderer's stream number. The data is the page's: the
/// renderer sends only bytes the page handed to `appendBuffer` or could
/// have fetched itself.
@MainActor
final class CefMediaDecoding {
    static let shared = CefMediaDecoding()

    /// The most streams kept at once; the least recently used goes first.
    private static let streamLimit = 32
    private var decoders: [String: CefSystemAudioDecoder] = [:]
    private var lastUse: [String: Int] = [:]
    private var useCounter = 0

    var isEnabled: Bool { CefRuntime.shared.configuration?.mediaCompatibility == .systemDecoders }

    /// A message from a renderer. Returns whether it was the shim's.
    func received(_ message: CefProcessMessage, from frame: CefRef<cef_frame_t>) -> Bool {
        guard message.name.hasPrefix("cefswift.media.") else { return false }
        guard isEnabled else { return true }
        let frameID = CefStringUtil.takingUserFree(frame.pointer.pointee.get_identifier(frame.pointer)) ?? ""
        let key = "\(frameID)/\(message.int(0))"
        switch message.name {
        case CefMediaShimMessage.decode:
            decode(message, key: key, frame: frame)
        case CefMediaShimMessage.release:
            decoders[key] = nil
            lastUse[key] = nil
        default:
            break
        }
        return true
    }

    private func decode(_ message: CefProcessMessage, key: String, frame: CefRef<cef_frame_t>) {
        let request = Int32(message.int(1))
        let cookie = message.bytes(3)
        if !cookie.isEmpty {
            decoders[key] = CefSystemAudioDecoder(cookie: cookie)
        }
        guard let decoder = decoders[key] else {
            reply(request, nil, to: frame)
            return
        }
        if message.bool(2) { decoder.reset() }
        let sizes = message.string(5).split(separator: ",").compactMap { Int($0) }
        let (pcm, frames) = decoder.decode(packets: message.bytes(4), sizes: sizes)
        useCounter += 1
        lastUse[key] = useCounter
        if decoders.count > Self.streamLimit, let oldest = lastUse.min(by: { $0.value < $1.value })?.key {
            decoders[oldest] = nil
            lastUse[oldest] = nil
        }
        let bytes = pcm.withUnsafeBytes { [UInt8]($0) }
        reply(request, (bytes, decoder.channels, decoder.sampleRate, frames), to: frame)
    }

    private func reply(
        _ request: Int32, _ result: (pcm: [UInt8], channels: Int, rate: Double, frames: [Int])?,
        to frame: CefRef<cef_frame_t>
    ) {
        let arguments: [CefProcessMessage.Argument] = if let result {
            [.int(request), .bool(true), .binary(result.pcm), .int(Int32(result.channels)), .double(result.rate),
             .string(result.frames.map(String.init).joined(separator: ","))]
        } else {
            [.int(request), .bool(false), .binary([]), .int(0), .double(0), .string("")]
        }
        CefProcessMessage(CefMediaShimMessage.decoded, arguments).send(from: frame.pointer, to: PID_RENDERER)
    }
}
