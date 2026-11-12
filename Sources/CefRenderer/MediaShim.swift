import CCef
import CefBase

/// The renderer half of the experimental system-decoder media shim
/// (`CefMediaCompatibility.systemDecoders`): AAC in pages, decoded by the
/// system in the browser process.
///
/// When a document's main world is created, before its scripts, the
/// shim's script (``MediaShimScript``) runs as a function and is handed the
/// decoder as an argument, so the page's globals gain nothing. The script
/// replaces `MediaSource.isTypeSupported`, `addSourceBuffer`,
/// `removeSourceBuffer`, `endOfStream` and `HTMLMediaElement`'s
/// `canPlayType`, `src` and `currentSrc` with its own functions.
@MainActor
final class MediaShim: CefRendererExtension {
    let messagePrefix = "cefswift.media."

    private struct Pending {
        var context: V8Context
        var promise: V8Value
    }

    private var pending: [Int: Pending] = [:]
    private var nextRequest = 0

    func contextCreated(_ context: V8Context, in frame: CefRendererFrame) {
        guard let mainWorld = frame.mainWorldContext, mainWorld.isSame(context) else { return }
        // Web pages and the app's own schemes; not Chromium's own pages.
        let url = frame.url
        let chromiumSchemes = ["chrome:", "chrome-extension:", "chrome-untrusted:", "devtools:", "data:", "javascript:"]
        guard !chromiumSchemes.contains(where: url.hasPrefix), !url.hasPrefix("about:") || url == "about:blank"
        else { return }
        guard case .success(let install) = context.run(MediaShimScript.source), install.isFunction,
              let native = makeDecoder(for: context)
        else { return }
        install.call(this: nil, [native])
    }

    func contextReleased(_ context: V8Context, in frame: CefRendererFrame) {
        for (request, entry) in pending where entry.context.isSame(context) {
            pending[request] = nil
        }
    }

    /// `decode(stream, reset, descriptor, packets, sizes)` and
    /// `release(stream)`, for the script only. The object keeps its
    /// context's wrapper, which nothing else holds after this callback.
    private func makeDecoder(for context: V8Context) -> V8Value? {
        V8Value.object { [weak self] name in
            guard let self else { return nil }
            switch name {
            case "decode":
                return V8Value.function("decode") { [weak self] _, arguments in
                    guard let self, arguments.count >= 5 else { return .success(nil) }
                    return .success(self.decode(arguments, in: context))
                }
            case "release":
                return V8Value.function("release") { _, arguments in
                    if let stream = arguments.first {
                        Self.send(CefProcessMessage(CefMediaShimMessage.release, [.int(stream.intValue)]), from: context)
                    }
                    return .success(nil)
                }
            default:
                return nil
            }
        }
    }

    private func decode(_ arguments: [V8Value], in context: V8Context) -> V8Value? {
        guard let promise = V8Value.promise() else { return nil }
        nextRequest += 1
        let request = nextRequest
        let sizes = arguments[4]
        let sizeList = (0..<sizes.arrayLength).compactMap { sizes[$0].map { String($0.intValue) } }.joined(separator: ",")
        let message = CefProcessMessage(CefMediaShimMessage.decode, [
            .int(arguments[0].intValue), .int(Int32(request)), .bool(arguments[1].boolValue),
            .binary(arguments[2].arrayBufferBytes), .binary(arguments[3].arrayBufferBytes), .string(sizeList),
        ])
        if Self.send(message, from: context) {
            pending[request] = Pending(context: context, promise: promise)
        } else {
            promise.reject("The document is closing.")
        }
        return promise
    }

    @discardableResult
    private static func send(_ message: CefProcessMessage, from context: V8Context) -> Bool {
        guard let frame = context.raw.pointee.get_frame(context.raw) else { return false }
        defer { cefRelease(frame) }
        return message.send(from: frame, to: PID_BROWSER)
    }

    func received(_ message: CefProcessMessage, in frame: CefRendererFrame) {
        guard message.name == CefMediaShimMessage.decoded,
              let entry = pending.removeValue(forKey: message.int(0)), entry.context.isValid
        else { return }
        entry.context.entered {
            guard message.bool(1), let pcm = V8Value.arrayBuffer(copying: message.bytes(2)) else {
                entry.promise.reject("The system decoder could not decode the audio.")
                return
            }
            let result = V8Value.object()
            result.set("pcm", pcm)
            result.set("channels", .int(Int32(message.int(3))))
            result.set("rate", .double(message.double(4)))
            let frames = message.string(5).split(separator: ",").compactMap { Int32($0) }
            let list = V8Value.array(count: frames.count)
            for (index, count) in frames.enumerated() { list.set(index, .int(count)) }
            result.set("frames", list)
            entry.promise.resolve(result)
        }
        entry.context.runMicrotasksSoon()
    }
}
