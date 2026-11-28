import CCef
import CefBase
import Foundation

/// Rewrites the body of a response a ``CefRequestFilter`` chose with
/// ``CefResourceRequestAction/rewriteResponse(_:)``: for injecting into a
/// site's HTML, removing what a script or JSON response carries, or
/// replacing a resource's content.
///
/// ```swift
/// profile.requestFilter = CefRequestFilter(hosts: ["example.com"], resourceTypes: [.mainFrame]) { _ in
///     .rewriteResponse(CefResponseRewriter { response in
///         guard response.mimeType == "text/html" else { return nil }
///         return { body in
///             Data(String(decoding: body, as: UTF8.self)
///                 .replacingOccurrences(of: "</head>", with: "<style>.ad { display: none }</style></head>").utf8)
///         }
///     })
/// }
/// ```
///
/// When the response's headers arrive, ``prepare`` sees them (read-only)
/// and returns the rewrite for its body, or `nil` to let the response
/// through untouched, at no further cost. The rewrite gets the whole body
/// at once, after the last byte has arrived, so the page receives nothing
/// of the response until then; a body longer than ``maximumLength`` is not
/// rewritten and passes through as it arrives. The body is what the
/// server sent after Chromium decoded its `Content-Encoding`, in the
/// response's charset.
///
/// Both closures run on Chromium's IO thread, isolated to ``CefIOActor``,
/// as ``CefRequestFilter/decide`` does, and must not block.
///
/// CEF lets an embedder change a response's body as it streams, but not
/// its status or headers: those reach the page as the server sent them.
public struct CefResponseRewriter: Sendable, Equatable {
    /// The longest body that is rewritten; a longer one passes through.
    public var maximumLength: Int
    /// Sees the response's headers and returns the rewrite for its body,
    /// or `nil` to leave the response alone.
    public var prepare: @CefIOActor @Sendable (HTTPURLResponse) -> (@CefIOActor @Sendable (Data) -> Data)?

    /// Identifies this rewriter for `==`: closures cannot be compared.
    private let identity = UUID()

    public init(
        maximumLength: Int = 16 << 20,
        _ prepare: @escaping @CefIOActor @Sendable (HTTPURLResponse) -> (@CefIOActor @Sendable (Data) -> Data)?
    ) {
        self.maximumLength = maximumLength
        self.prepare = prepare
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity == rhs.identity && lhs.maximumLength == rhs.maximumLength
    }
}

/// The `cef_response_filter_t` of one response: collects the body until
/// it ends, rewrites it once, and writes the result out in the buffers
/// CEF offers. Past ``CefResponseRewriter/maximumLength`` it writes what
/// it holds and passes the rest through. IO thread only.
final class ResponseBodyRewrite: @unchecked Sendable {
    /// Runs on the IO thread, which CEF calls the filter on.
    private let rewrite: (Data) -> Data
    private let maximumLength: Int
    private var input = Data()
    /// What is left to write: the rewritten body, or what was held back
    /// when the body turned out too long.
    private var output = Data()
    private var outputOffset = 0
    private var isPassingThrough = false
    private var isRewritten = false

    init(maximumLength: Int, rewrite: @escaping (Data) -> Data) {
        self.maximumLength = maximumLength
        self.rewrite = rewrite
    }

    func makeFilter() -> UnsafeMutablePointer<cef_response_filter_t> {
        let f = cefAllocate(cef_response_filter_t.self, owner: self)
        f.pointee.init_filter = { _ in 1 }
        f.pointee.filter = { s, dataIn, inSize, inRead, dataOut, outSize, outWritten in
            guard let owner = cefOwner(ResponseBodyRewrite.self, s), let inRead, let outWritten else {
                return RESPONSE_FILTER_ERROR
            }
            let input = inSize > 0 ? dataIn.map { UnsafeRawBufferPointer(start: $0, count: inSize) } : nil
            let output = UnsafeMutableRawBufferPointer(start: dataOut, count: dataOut == nil ? 0 : outSize)
            let (read, written, status) = owner.filter(input, into: output)
            inRead.pointee = read
            outWritten.pointee = written
            return status
        }
        return f
    }

    /// One call of CEF's `Filter`: `input` is `nil` once the body has ended.
    private func filter(
        _ input: UnsafeRawBufferPointer?, into out: UnsafeMutableRawBufferPointer
    ) -> (read: Int, written: Int, status: cef_response_filter_status_t) {
        if isPassingThrough {
            // What was held back goes first, then input straight through,
            // as much as fits; CEF offers the rest again.
            var written = drain(into: out)
            var read = 0
            if let input, !input.isEmpty, let base = out.baseAddress, let source = input.baseAddress {
                let count = min(out.count - written, input.count)
                (base + written).copyMemory(from: source, byteCount: count)
                written += count
                read = count
                // Nothing written: CEF needs all of the input read.
                if written == 0 {
                    output.append(contentsOf: input)
                    read = input.count
                }
            }
            let pending = outputOffset < output.count
            return (read, written, pending ? RESPONSE_FILTER_NEED_MORE_DATA : RESPONSE_FILTER_DONE)
        }
        var read = 0
        if let input, !input.isEmpty {
            read = input.count
            if !isRewritten {
                self.input.append(contentsOf: input)
                if self.input.count > maximumLength {
                    // Too long: what was held back goes out unchanged.
                    isPassingThrough = true
                    output = self.input
                    outputOffset = 0
                    self.input = Data()
                    let written = drain(into: out)
                    return (read, written, RESPONSE_FILTER_NEED_MORE_DATA)
                }
            }
        } else if !isRewritten {
            // The body has ended.
            isRewritten = true
            let body = self.input
            self.input = Data()
            output = rewrite(body)
            outputOffset = 0
        }
        let written = drain(into: out)
        let pending = outputOffset < output.count
        return (read, written, pending || !isRewritten ? RESPONSE_FILTER_NEED_MORE_DATA : RESPONSE_FILTER_DONE)
    }

    private func drain(into out: UnsafeMutableRawBufferPointer) -> Int {
        guard let base = out.baseAddress, outputOffset < output.count else { return 0 }
        let count = min(out.count, output.count - outputOffset)
        output.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { base.copyMemory(from: source + outputOffset, byteCount: count) }
        }
        outputOffset += count
        if outputOffset == output.count {
            output = Data()
            outputOffset = 0
        }
        return count
    }
}
