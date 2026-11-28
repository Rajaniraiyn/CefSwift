import CCef
import CefBase
import Foundation
import Testing

@testable import CefKit

/// `ResponseBodyRewrite`, the `cef_response_filter_t` behind
/// `CefResourceRequestAction.rewriteResponse(_:)`, driven as CEF drives
/// it: chunks of input, an output buffer of CEF's size, and calls with no
/// input once the body has ended.
struct ResponseBodyRewriteTests {
    /// Feeds `body` in `chunk`-sized pieces into an output buffer of
    /// `outputSize`, then calls with no input until the filter is done.
    func run(_ rewrite: ResponseBodyRewrite, body: Data, chunk: Int, outputSize: Int) -> Data {
        let filter = rewrite.makeFilter()
        defer { cefRelease(filter) }
        #expect(filter.pointee.init_filter(filter) == 1)
        var result = Data()
        var output = [UInt8](repeating: 0, count: outputSize)
        func call(_ input: UnsafeMutableRawPointer?, _ size: Int) -> (read: Int, status: cef_response_filter_status_t) {
            var read = 0, written = 0
            let status = output.withUnsafeMutableBytes { out in
                filter.pointee.filter(filter, input, size, &read, out.baseAddress, out.count, &written)
            }
            result.append(contentsOf: output[0..<written])
            return (read, status)
        }
        var bytes = [UInt8](body)
        var offset = 0
        while offset < bytes.count {
            let size = min(chunk, bytes.count - offset)
            let read = bytes.withUnsafeMutableBytes { call($0.baseAddress! + offset, size).read }
            offset += read
        }
        for _ in 0..<10_000 {
            if call(nil, 0).status != RESPONSE_FILTER_NEED_MORE_DATA { break }
        }
        return result
    }

    @Test func rewritesTheWholeBodyOnce() {
        nonisolated(unsafe) var calls = 0
        let rewrite = ResponseBodyRewrite(maximumLength: 1 << 20) { body in
            calls += 1
            return Data(String(decoding: body, as: UTF8.self).uppercased().utf8)
        }
        let body = Data(String(repeating: "abc", count: 5000).utf8)
        let result = run(rewrite, body: body, chunk: 700, outputSize: 1024)
        #expect(result == Data(String(repeating: "ABC", count: 5000).utf8))
        #expect(calls == 1)
    }

    @Test func writesALongerBodyAcrossManyCalls() {
        let rewrite = ResponseBodyRewrite(maximumLength: 1 << 20) { $0 + Data(repeating: 7, count: 100_000) }
        let result = run(rewrite, body: Data("ok".utf8), chunk: 64, outputSize: 333)
        #expect(result.count == 100_002)
        #expect(result.prefix(2) == Data("ok".utf8))
    }

    @Test func replacesAnEmptyBody() {
        let rewrite = ResponseBodyRewrite(maximumLength: 1 << 20) { _ in Data("filled".utf8) }
        #expect(run(rewrite, body: Data(), chunk: 64, outputSize: 64) == Data("filled".utf8))
    }

    @Test func passesALongBodyThroughUnchanged() {
        nonisolated(unsafe) var calls = 0
        let rewrite = ResponseBodyRewrite(maximumLength: 10_000) { _ in
            calls += 1
            return Data()
        }
        let body = Data((0..<50_000).map { UInt8($0 % 251) })
        #expect(run(rewrite, body: body, chunk: 4096, outputSize: 2048) == body)
        #expect(calls == 0)
    }
}
