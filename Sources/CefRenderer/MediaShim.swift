import CCef
import CefBase

/// The renderer half of the system media decoders
/// (`CefRuntime.Configuration.Services.SystemMediaDecoders`): audio in
/// codecs Chromium lacks, decoded by the system in CefSwift's media
/// service.
///
/// When a document's main world is created, before its scripts, the
/// shim's script (``MediaShimScript``, generated from `MediaShim/*.js`)
/// runs as a function and is handed `native`, an object only it sees, so
/// the page's globals gain nothing:
///
/// - `decode(stream, discontinuity, codec, rate, channels, configuration,
///   packets, sizes, timing)` sends the packets to the browser process,
///   which relays them to the media service, and returns a promise of the
///   FLAC segments to append.
/// - `release(stream)` forgets a stream.
/// - `function(name, implementation)` returns a native function named
///   `name` that calls `implementation` with its `this` and arguments and
///   rethrows what it throws. The script installs these in place of
///   `MediaSource` and `HTMLMediaElement` members, so
///   `Function.prototype.toString` shows `[native code]` for them as for
///   the originals.
@MainActor
final class MediaShim: CefRendererExtension {
    let messagePrefix = CefMediaMessage.prefix

    private struct Pending {
        var context: V8Context
        var promise: V8Value
    }

    private var pending: [Int32: Pending] = [:]
    private var nextRequest: Int32 = 0

    func contextCreated(_ context: V8Context, in frame: CefRendererFrame) {
        guard let mainWorld = frame.mainWorldContext, mainWorld.isSame(context) else { return }
        // Web pages and the app's own schemes; not Chromium's own pages.
        let url = frame.url
        let chromiumSchemes = ["chrome:", "chrome-extension:", "chrome-untrusted:", "devtools:", "javascript:"]
        guard !chromiumSchemes.contains(where: url.hasPrefix) else { return }
        guard case .success(let install) = context.run(utf8: MediaShimScript.source), install.isFunction,
              let native = makeNative(for: context)
        else { return }
        install.call(this: nil, [native])
    }

    func contextReleased(_ context: V8Context, in frame: CefRendererFrame) {
        for (request, entry) in pending where entry.context.isSame(context) {
            pending[request] = nil
        }
    }

    /// The object handed to the script. It keeps its context's wrapper,
    /// which nothing else holds after this callback.
    private func makeNative(for context: V8Context) -> V8Value? {
        V8Value.object { [weak self] name in
            guard let self else { return nil }
            switch name {
            case "decode":
                return V8Value.function("decode") { [weak self] _, arguments in
                    guard let self, arguments.count >= 9 else { return .success(nil) }
                    return .success(self.decode(arguments, in: context))
                }
            case "release":
                return V8Value.function("release") { _, arguments in
                    if let stream = arguments.first {
                        var buffer = CefWireBuffer()
                        buffer.append(header: CefWireHeader(target: stream.intValue))
                        Self.send(buffer, CefMediaMessage.release, from: context)
                    }
                    return .success(nil)
                }
            case "function":
                return V8Value.function("function") { _, arguments in
                    guard arguments.count >= 2, arguments[1].isFunction else { return .success(nil) }
                    return .success(Self.nativeFunction(named: arguments[0].stringValue, calling: arguments[1]))
                }
            default:
                return nil
            }
        }
    }

    /// A native function that calls `implementation`. What the
    /// implementation throws propagates to the caller as thrown, its
    /// type and stack included.
    private static func nativeFunction(named name: String, calling implementation: V8Value) -> V8Value? {
        _ = implementation.raw.pointee.set_rethrow_exceptions(implementation.raw, 1)
        return V8Value.function(name) { this, arguments in
            // On an exception the result is nil and the exception is on
            // its way to the caller; the context is not touched again.
            .success(implementation.callRethrowing(this: this, arguments))
        }
    }

    // MARK: Decoding

    private func decode(_ arguments: [V8Value], in context: V8Context) -> V8Value? {
        guard let promise = V8Value.promise() else { return nil }
        nextRequest &+= 1
        let request = nextRequest
        var buffer = CefWireBuffer()
        buffer.append(header: CefWireHeader(target: arguments[0].intValue, call: request, succeeded: arguments[1].boolValue))
        buffer.append(arguments[2].stringValue)
        buffer.append(arguments[3].doubleValue)
        buffer.append(arguments[4].doubleValue)
        // The ArrayBuffers' bytes are copied once, into the message, before
        // this returns to JavaScript.
        for value in arguments[5...8] {
            guard let bytes = value.arrayBufferBytes, !bytes.isEmpty else {
                buffer.appendNull()
                continue
            }
            nonisolated(unsafe) let source = bytes
            buffer.append(bytes: bytes.count) { target in target.copyMemory(from: source.baseAddress!, byteCount: source.count) }
        }
        if Self.send(buffer, CefMediaMessage.decode, from: context) {
            pending[request] = Pending(context: context, promise: promise)
        } else {
            promise.reject("The document is closing.")
        }
        return promise
    }

    @discardableResult
    private static func send(_ buffer: borrowing CefWireBuffer, _ name: CefStaticString, from context: V8Context) -> Bool {
        guard let frame = context.raw.pointee.get_frame(context.raw) else { return false }
        defer { cefRelease(frame) }
        return buffer.send(name, from: frame, to: PID_BROWSER)
    }

    func received(mediaPayload payload: CefWirePayload, in frame: CefRendererFrame) {
        var reader = payload.reader
        guard let header = try? reader.header(),
              let entry = pending.removeValue(forKey: header.call), entry.context.isValid
        else { return }
        reader.skipHeader()
        entry.context.entered {
            guard header.succeeded != 0 else {
                entry.promise.reject((try? reader.readString()) ?? "The system decoder could not decode the audio.")
                return
            }
            var segments: [V8Value] = []
            while !reader.isAtEnd {
                // One copy, from the message into the ArrayBuffer.
                guard let bytes = try? reader.readBytes(), let segment = V8Value.arrayBuffer(copying: bytes) else {
                    entry.promise.reject("The media service sent a malformed reply.")
                    return
                }
                segments.append(segment)
            }
            let list = V8Value.array(count: segments.count)
            for (index, segment) in segments.enumerated() { list.set(index, segment) }
            entry.promise.resolve(list)
        }
    }
}
