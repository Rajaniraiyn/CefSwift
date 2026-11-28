import Foundation

/// The XPC service behind `CefRuntime.Configuration.Services.systemMediaDecoders`:
/// decodes pages' audio with the system's decoders, inside the App Sandbox
/// and outside the app's own process.
///
/// `cef bundle` puts it in `Contents/XPCServices/<App> Media.xpc` and signs
/// it with `com.apple.security.app-sandbox` and nothing else: no network,
/// no files outside its container, no devices. The app's process connects
/// to it; renderers cannot reach it. What it receives is the page's
/// compressed audio, which it parses and decodes here rather than in the
/// app, and what it returns is FLAC in fragmented MP4.
@main
enum CefMediaService {
    static func main() {
        let delegate = ServiceDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
    }
}

/// The interface the app calls, matched by its Objective-C name. Keep it
/// the same as CefKit's `CefMediaServiceInterface`.
@objc(CefMediaServiceProtocol)
protocol MediaServiceProtocol {
    /// Decodes packets of the stream named `stream` and replies with the
    /// segments to append, or an error message. `timing` holds each
    /// packet's start and duration in seconds as pairs of little-endian
    /// doubles; `sizes` each packet's byte length as little-endian
    /// 32-bit integers.
    func decodeAudio(
        stream: String, codec: String, sampleRate: Double, channels: Int, configuration: Data,
        discontinuity: Bool, packets: Data, sizes: Data, timing: Data,
        reply: @escaping ([Data]?, String?) -> Void)

    /// Forgets the stream.
    func releaseStream(_ stream: String)
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = MediaService.interface
        connection.exportedObject = MediaService()
        connection.resume()
        return true
    }
}

/// One connection's streams. Calls arrive on the connection's serial
/// queue, one at a time.
final class MediaService: NSObject, MediaServiceProtocol, @unchecked Sendable {
    /// The most streams kept at once; the least recently used goes first.
    static let streamLimit = 32
    /// The largest request, in bytes of packets: a minute of 640 kb/s
    /// E-AC-3 is under 5 MB.
    static let packetLimit = 64 << 20

    static var interface: NSXPCInterface {
        let interface = NSXPCInterface(with: MediaServiceProtocol.self)
        interface.setClasses(
            NSSet(array: [NSArray.self, NSData.self]) as? Set<AnyHashable> ?? [],
            for: #selector(MediaServiceProtocol.decodeAudio(stream:codec:sampleRate:channels:configuration:discontinuity:packets:sizes:timing:reply:)),
            argumentIndex: 0, ofReply: true)
        return interface
    }

    private var streams: [String: AudioStream] = [:]
    private var lastUse: [String: Int] = [:]
    private var useCounter = 0

    func decodeAudio(
        stream key: String, codec: String, sampleRate: Double, channels: Int, configuration: Data,
        discontinuity: Bool, packets: Data, sizes: Data, timing: Data,
        reply: @escaping ([Data]?, String?) -> Void
    ) {
        do {
            let request = try Request(packets: packets, sizes: sizes, timing: timing)
            let stream = try self.stream(key, codec: codec, sampleRate: sampleRate, channels: channels, configuration: configuration)
            let segments = packets.withUnsafeBytes {
                stream.append(packets: $0, sizes: request.sizes, timing: request.timing, discontinuity: discontinuity)
            }
            reply(segments, nil)
        } catch {
            reply(nil, "\(error)")
        }
    }

    func releaseStream(_ key: String) {
        streams[key] = nil
        lastUse[key] = nil
    }

    private func stream(_ key: String, codec: String, sampleRate: Double, channels: Int, configuration: Data) throws -> AudioStream {
        useCounter += 1
        lastUse[key] = useCounter
        if let stream = streams[key] { return stream }
        guard let kind = SystemAudioDecoder.Codec(rawValue: codec) else {
            throw SystemAudioDecoder.Failure("unknown codec \(codec)")
        }
        let decoder = try SystemAudioDecoder(
            codec: kind, sampleRate: sampleRate, channels: channels, configuration: [UInt8](configuration))
        let stream = AudioStream(decoder: decoder)
        streams[key] = stream
        while streams.count > Self.streamLimit, let oldest = lastUse.min(by: { $0.value < $1.value })?.key {
            releaseStream(oldest)
        }
        return stream
    }

    /// A decode request's packet sizes and times, checked against the
    /// packets.
    struct Request {
        var sizes: [Int]
        var timing: [AudioStream.Timing]

        init(packets: Data, sizes sizeBytes: Data, timing timingBytes: Data) throws {
            let count = sizeBytes.count / 4
            guard sizeBytes.count % 4 == 0, timingBytes.count == count * 16, packets.count <= MediaService.packetLimit
            else { throw SystemAudioDecoder.Failure("malformed request") }
            sizes = sizeBytes.withUnsafeBytes { raw in
                (0..<count).map { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
            }
            timing = timingBytes.withUnsafeBytes { raw in
                (0..<count).map {
                    AudioStream.Timing(
                        start: Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 16, as: UInt64.self))),
                        duration: Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 16 + 8, as: UInt64.self))))
                }
            }
            guard sizes.reduce(0, +) <= packets.count, timing.allSatisfy({ $0.start.isFinite && $0.duration.isFinite && $0.duration >= 0 })
            else { throw SystemAudioDecoder.Failure("malformed request") }
        }
    }
}
