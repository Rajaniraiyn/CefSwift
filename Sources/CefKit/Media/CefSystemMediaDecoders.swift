import CCef
import CefBase
import Foundation

extension CefRuntime.Configuration.Services {
    /// Media that CEF's official builds cannot decode and pages play with
    /// the decoders macOS ships. **Experimental**; none by default.
    ///
    /// CEF's official builds have no AAC, AC-3, E-AC-3 or Apple Lossless
    /// decoder. With ``audio``, audio in those codecs plays in Chromium
    /// pages:
    ///
    /// - Media Source Extensions: `MediaSource.isTypeSupported` and
    ///   `addSourceBuffer` accept `audio/mp4` with `mp4a.40.2` (AAC-LC),
    ///   `mp4a.40.5` (HE-AAC), `mp4a.40.29` (HE-AAC v2), `mp4a.40.42`
    ///   (xHE-AAC), `mp4a.67`, `alac`, `ac-3` and `ec-3`. What the page
    ///   appends is decoded and played, losslessly, as FLAC through the
    ///   page's own native `MediaSource`.
    /// - `<audio>` and `<video>` whose source is an audio-only `.m4a`,
    ///   `.mp4` or `.aac` file the native player rejects, when the page
    ///   could read the file itself: same origin, or cross-origin with
    ///   `crossorigin` and CORS.
    ///
    /// Decoding happens in CefSwift's media service, an XPC service in the
    /// App Sandbox that `cef bundle` adds to apps listing the
    /// `systemMediaDecoders` capability in `cefapp.json`; without the
    /// service the option does nothing and pages see what they would
    /// without it. Video in those codecs, encrypted media (EME), and
    /// cross-origin files without CORS play as without the option: not at
    /// all. The guide's "System media decoders" lists what a page can
    /// observe.
    public struct SystemMediaDecoders: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// AAC, AC-3, E-AC-3 and Apple Lossless audio, as described above.
        public static let audio = SystemMediaDecoders(rawValue: 1 << 0)
    }
}

/// Decodes audio for the renderers of an app with
/// ``CefRuntime/Configuration/Services/SystemMediaDecoders/audio``, through
/// the media service.
///
/// The browser process only relays: a renderer's `cefswift.media.decode`
/// payload carries the page's packets, which go to the service as they
/// are; the service's FLAC segments come back to the frame that asked.
/// Neither the page's audio nor the service's answer is parsed here. Each
/// stream is named by the frame that asked and the renderer's stream
/// number.
@MainActor
final class CefMediaDecoding {
    static let shared = CefMediaDecoding()

    /// The service's bundle in the app: `Contents/XPCServices/*.xpc`
    /// with this bundle identifier suffix.
    nonisolated static let serviceIdentifierSuffix = ".media"

    private var connection: NSXPCConnection?

    /// Whether the option is on and the app carries the service.
    nonisolated static func isAvailable(configuration: CefRuntime.Configuration) -> Bool {
        configuration.services.systemMediaDecoders.contains(.audio) && serviceName != nil
    }

    /// The service's name, the bundle identifier of the app's media
    /// service, when the app has one.
    nonisolated static let serviceName: String? = {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let name = identifier + serviceIdentifierSuffix
        let services = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices", isDirectory: true)
        let bundles = (try? FileManager.default.contentsOfDirectory(at: services, includingPropertiesForKeys: nil)) ?? []
        return bundles.contains { Bundle(url: $0)?.bundleIdentifier == name } ? name : nil
    }()

    /// The service, through a proxy that runs `failure` on XPC's queue if
    /// the call cannot reach it or the service exits before replying.
    private func service(onFailure failure: @escaping @Sendable (Error) -> Void = { _ in })
        -> CefMediaServiceInterface?
    {
        if connection == nil, let name = Self.serviceName {
            let connection = NSXPCConnection(serviceName: name)
            connection.remoteObjectInterface = CefMediaServiceInterfaceDescription.make()
            // A service that exits or crashes is started again by the next
            // call; the streams it held start over.
            connection.invalidationHandler = Self.invalidated
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler(failure) as? CefMediaServiceInterface
    }

    private nonisolated static let invalidated: @Sendable () -> Void = {
        Task { @MainActor in CefMediaDecoding.shared.connection = nil }
    }

    /// A media message from a renderer. Returns whether it was one.
    func received(_ name: String, payload: CefWirePayload, from frame: CefRef<cef_frame_t>) -> Bool {
        guard name.hasPrefix(CefMediaMessage.prefix) else { return false }
        guard CefRuntime.shared.configuration?.services.systemMediaDecoders.contains(.audio) == true else { return true }
        let frameID = CefStringUtil.takingUserFree(frame.pointer.pointee.get_identifier(frame.pointer)) ?? ""
        var reader = payload.reader
        guard let header = try? reader.header() else { return true }
        reader.skipHeader()
        let stream = "\(frameID)/\(header.target)"
        switch name {
        case CefMediaMessage.decode.text:
            decode(stream: stream, request: header.call, discontinuity: header.succeeded != 0, reader: reader,
                   payload: payload, frame: frame)
        case CefMediaMessage.release.text:
            service()?.releaseStream(stream)
        default:
            break
        }
        return true
    }

    /// Values: codec, sample rate, channels, configuration (bytes), packets
    /// (bytes), sizes (bytes), timing (bytes). The byte runs stay in the
    /// payload's memory until the service has its copy.
    private func decode(
        stream: String, request: Int32, discontinuity: Bool, reader: CefWireReader, payload: CefWirePayload,
        frame: CefRef<cef_frame_t>
    ) {
        var reader = reader
        guard let codec = try? reader.readString(),
              let rate = try? reader.readNumber(), let channels = try? reader.readNumber(),
              let configuration = try? reader.readBytes(), let packets = try? reader.readBytes(),
              let sizes = try? reader.readBytes(), let timing = try? reader.readBytes(),
              let service = service(onFailure: Self.failureHandler(request, to: frame))
        else {
            Self.reply(request, result: .failure("The request could not be read."), to: frame)
            return
        }
        // The payload outlives these: XPC copies them before the call
        // returns.
        func data(_ run: UnsafeRawBufferPointer) -> Data {
            run.isEmpty ? Data() : Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: run.baseAddress!), count: run.count, deallocator: .none)
        }
        nonisolated(unsafe) let frame = frame
        withExtendedLifetime(payload) {
            service.decodeAudio(
                stream: stream, codec: codec, sampleRate: rate, channels: Int(channels), configuration: data(configuration),
                discontinuity: discontinuity, packets: data(packets), sizes: data(sizes), timing: data(timing),
                reply: Self.replyHandler(request, to: frame))
        }
    }

    /// The service's reply, on its queue: the message is built there and
    /// sent from the UI thread. Not isolated to the main actor, which the
    /// queue is not on.
    private nonisolated static func replyHandler(_ request: Int32, to frame: CefRef<cef_frame_t>)
        -> @Sendable ([Data]?, String?) -> Void
    {
        nonisolated(unsafe) let frame = frame
        return { segments, error in
            let result: Result = segments.map { .success($0) } ?? .failure(error ?? "The media service failed.")
            reply(request, result: result, to: frame)
        }
    }

    /// A call that never reached the service, or whose service exited:
    /// the page's append fails rather than waiting.
    private nonisolated static func failureHandler(_ request: Int32, to frame: CefRef<cef_frame_t>)
        -> @Sendable (Error) -> Void
    {
        nonisolated(unsafe) let frame = frame
        return { error in reply(request, result: .failure("The media service failed: \(error.localizedDescription)"), to: frame) }
    }

    enum Result {
        case success([Data])
        case failure(String)
    }

    /// Header: `call` the request, `succeeded`. Values: the segments to
    /// append (bytes each), or the error message.
    private nonisolated static func reply(_ request: Int32, result: Result, to frame: CefRef<cef_frame_t>) {
        var buffer = CefWireBuffer()
        switch result {
        case .success(let segments):
            buffer.append(header: CefWireHeader(call: request, succeeded: true))
            for segment in segments {
                buffer.append(bytes: segment.count) { target in segment.copyBytes(to: target.assumingMemoryBound(to: UInt8.self), count: segment.count) }
            }
        case .failure(let message):
            buffer.append(header: CefWireHeader(call: request, succeeded: false))
            buffer.append(message)
        }
        guard let message = buffer.makeMessage(CefMediaMessage.decoded) else { return }
        nonisolated(unsafe) let sent = message
        nonisolated(unsafe) let frame = frame
        // CEF's UI thread is the main thread.
        DispatchQueue.main.async {
            if frame.pointer.pointee.is_valid(frame.pointer) != 0 {
                frame.pointer.pointee.send_process_message(frame.pointer, PID_RENDERER, sent)
            } else {
                cefRelease(sent)
            }
        }
    }
}

/// The media service's interface, matched by its Objective-C name. Keep
/// it the same as `MediaServiceProtocol` in `Sources/CefMediaService`.
@objc(CefMediaServiceProtocol)
protocol CefMediaServiceInterface {
    func decodeAudio(
        stream: String, codec: String, sampleRate: Double, channels: Int, configuration: Data,
        discontinuity: Bool, packets: Data, sizes: Data, timing: Data,
        reply: @escaping ([Data]?, String?) -> Void)
    func releaseStream(_ stream: String)
}

enum CefMediaServiceInterfaceDescription {
    static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: CefMediaServiceInterface.self)
        interface.setClasses(
            NSSet(array: [NSArray.self, NSData.self]) as? Set<AnyHashable> ?? [],
            for: #selector(CefMediaServiceInterface.decodeAudio(stream:codec:sampleRate:channels:configuration:discontinuity:packets:sizes:timing:reply:)),
            argumentIndex: 0, ofReply: true)
        return interface
    }
}
