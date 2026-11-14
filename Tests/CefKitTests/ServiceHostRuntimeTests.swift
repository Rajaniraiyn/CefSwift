import CefBase
import Foundation
import JavaScriptCore
import Testing

@testable import CefKit

/// The service hosts' JavaScript encoder (`CefServiceHostRuntime.encoder`),
/// run in JavaScriptCore, against the browser process's wire decoder: what
/// a host writes is what Swift reads, as `JSON.stringify` would see it.
@Suite struct ServiceHostRuntimeTests {
    /// JavaScriptCore has no `TextEncoder`; the hosts' renderers do.
    static let textEncoder = """
        globalThis.TextEncoder ??= class {
          encodeInto(s, out) {
            let w = 0;
            for (let i = 0; i < s.length; i++) {
              let c = s.charCodeAt(i);
              if (c >= 0xD800 && c < 0xDC00 && i + 1 < s.length && (s.charCodeAt(i + 1) & 0xFC00) === 0xDC00) {
                c = 0x10000 + ((c - 0xD800) << 10) + (s.charCodeAt(++i) - 0xDC00);
              } else if (c >= 0xD800 && c < 0xE000) {
                c = 0xFFFD;
              }
              if (c < 0x80) { out[w++] = c; }
              else if (c < 0x800) { out[w++] = 0xC0 | (c >> 6); out[w++] = 0x80 | (c & 63); }
              else if (c < 0x10000) { out[w++] = 0xE0 | (c >> 12); out[w++] = 0x80 | ((c >> 6) & 63); out[w++] = 0x80 | (c & 63); }
              else { out[w++] = 0xF0 | (c >> 18); out[w++] = 0x80 | ((c >> 12) & 63); out[w++] = 0x80 | ((c >> 6) & 63); out[w++] = 0x80 | (c & 63); }
            }
            return { read: s.length, written: w };
          }
        };
        """

    /// The bytes `encode(<expression>)` returns.
    func encoded(_ expression: String) throws -> [UInt8] {
        let context = try #require(JSContext())
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        context.evaluateScript(Self.textEncoder)
        let value = context.evaluateScript("(() => { \(CefServiceHostRuntime.encoder); return encode(\(expression)); })()")
        if let exception { throw CefError.operationFailed(exception) }
        let buffer = try #require(value?.jsValueRef)
        let ref = context.jsGlobalContextRef
        let count = JSObjectGetArrayBufferByteLength(ref, buffer, nil)
        let bytes = try #require(JSObjectGetArrayBufferBytesPtr(ref, buffer, nil))
        return Array(UnsafeRawBufferPointer(start: bytes, count: count))
    }

    func decode<T: Decodable>(_ type: T.Type, _ expression: String) throws -> T {
        try encoded(expression).withUnsafeBytes { try CefWireDecoder(bytes: $0).decode(type) }
    }

    @Test func primitives() throws {
        #expect(try decode(CefJSON.self, "null") == .null)
        #expect(try decode(Bool.self, "true") == true)
        #expect(try decode(Bool.self, "false") == false)
        #expect(try decode(Int.self, "-42") == -42)
        #expect(try decode(Double.self, "0.25") == 0.25)
        // Past Int32: a Float64, which decodes as an integer when it is one.
        #expect(try decode(Int64.self, "1.7e12") == 1_700_000_000_000)
        #expect(try decode(String.self, "'Grüße 😀 — 中文'") == "Grüße 😀 — 中文")
        #expect(try decode(String.self, "''") == "")
        // ASCII is copied unit by unit until the first other character.
        #expect(try decode(String.self, "'plain ascii, then é'") == "plain ascii, then é")
        #expect(try decode(String.self, "'x'.repeat(65) + 'é'") == String(repeating: "x", count: 65) + "é")
        #expect(try decode([String: Int].self, "({ 'clé': 1, key: 2 })") == ["clé": 1, "key": 2])
        // Not representable in JSON: null, as JSON.stringify writes them.
        #expect(try decode(CefJSON.self, "NaN") == .null)
        #expect(try decode(CefJSON.self, "Infinity") == .null)
        #expect(try decode(CefJSON.self, "undefined") == .null)
    }

    @Test func containersAsJSONStringifySeesThem() throws {
        let expression = """
            { a: 1, skip: undefined, f() {}, nested: { list: [1, undefined, () => 0, 'x', null] },
              date: new Date(Date.UTC(2026, 10, 14, 1, 2, 3)), custom: { toJSON: () => 'custom' } }
            """
        let json = try decode(CefJSON.self, expression)
        #expect(json["a"] == .number(1))
        #expect(json["skip"] == .null && json.objectValue?["skip"] == nil)
        #expect(json.objectValue?["f"] == nil)
        #expect(json["nested"]["list"] == [1, .null, .null, "x", .null])
        #expect(json["date"] == "2026-11-14T01:02:03.000Z")
        #expect(json["custom"] == "custom")
    }

    @Test func aValueInsideItselfIsNull() throws {
        let json = try decode(CefJSON.self, "(() => { const a = { name: 'a' }; a.self = a; a.list = [a]; return a; })()")
        #expect(json["name"] == "a")
        #expect(json["self"] == .null)
        #expect(json["list"] == [.null])
        // A value seen twice, not inside itself, is written twice.
        let shared = try decode(CefJSON.self, "(() => { const s = { v: 1 }; return [s, s]; })()")
        #expect(shared == [["v": 1], ["v": 1]])
    }

    @Test func nestingPastTheLimitIsNull() throws {
        let deep = try decode(CefJSON.self, "(() => { let v = 'leaf'; for (let i = 0; i < 70; i++) v = [v]; return v; })()")
        var depth = 0
        var value = deep
        while case .array(let elements) = value, let first = elements.first {
            depth += 1
            value = first
        }
        #expect(depth == 64)
        #expect(value == .null)
    }

    @Test func bytesTravelAsBytes() throws {
        struct Icon: Decodable { var width: Int; var pixels: Data }
        let icon = try decode(Icon.self, "({ width: 2, pixels: new Uint8Array([1, 2, 3, 250]).buffer })")
        #expect(icon.width == 2)
        #expect(icon.pixels == Data([1, 2, 3, 250]))
        #expect(try decode(Data.self, "new Uint8Array([9, 8, 7]).subarray(1)") == Data([8, 7]))
    }

    @Test func decodesTypedRecordsDirectly() throws {
        struct Entry: Decodable, Equatable { var url: String; var title: String; var time: Double; var starred: Bool }
        let entries = try decode(
            [Entry].self,
            "Array.from({ length: 5000 }, (_, i) => ({ url: 'https://example.com/' + i, title: 'Page ' + i, time: 1.7e12 + i / 4, starred: i % 2 === 0, extra: [i] }))")
        #expect(entries.count == 5000)
        #expect(entries[4999] == Entry(url: "https://example.com/4999", title: "Page 4999", time: 1.7e12 + 4999.0 / 4, starred: false))
    }

    @Test func malformedBytesAreRejected() throws {
        var bytes = try encoded("{ title: 'x', list: [1, 2, 3] }")
        // A container claiming more members than its bytes hold.
        bytes[5] = 200
        #expect(throws: DecodingError.self) {
            _ = try bytes.withUnsafeBytes { try CefWireDecoder(bytes: $0).decode(CefJSON.self) }
        }
    }

    /// A reply carries the host's encoding as one bytes value after the
    /// header; the engine decodes from inside it.
    @Test func aReplyIsDecodedFromInsideItsBytes() throws {
        let inner = try encoded("{ id: 7, name: 'seven' }")
        var reply = CefWireBuffer()
        reply.append(header: CefWireHeader(target: 1, succeeded: true))
        reply.append(bytes: inner.count) { target in inner.withUnsafeBytes { target.copyMemory(from: $0.baseAddress!, byteCount: inner.count) } }
        reply.materializeDeferred()
        struct Record: Decodable, Equatable { var id: Int; var name: String }
        let record = try CefServiceHosts.decodeValue(Record.self, from: reply.bytes, at: CefWireHeader.size)
        #expect(record == Record(id: 7, name: "seven"))
        // A value the host did not encode decodes as itself.
        var plain = CefWireBuffer()
        plain.append(header: CefWireHeader(target: 1, succeeded: true))
        plain.append(Int32(5))
        #expect(try CefServiceHosts.decodeValue(Int.self, from: plain.bytes, at: CefWireHeader.size) == 5)
    }
}

/// What a host document has installed, as `CefServiceHostBrowser` keeps
/// it: recorded only for a script that was sent, so a call cancelled
/// before its script left (as during the host's start-up) leaves the next
/// call to install the runtime.
@Suite struct ServiceHostInstallationTests {
    typealias Installation = CefServiceHostRuntime.Installation

    func script(_ installation: Installation, handle: Int = 1, call: Int = 1)
        -> (script: String, additions: Installation.Additions) {
        installation.script(
            handle: handle, module: "m", setup: "async () => ({ twice: n => n * 2 })",
            function: "(s, a) => s.twice(a.n)", arguments: ["n": 21], call: call, eventBridge: "__bridge")
    }

    /// Runs `sources` in order in `context`; the first exception's message.
    func run(_ sources: [String], in context: JSContext) -> String? {
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        for source in sources {
            context.evaluateScript(source)
            if exception != nil { break }
        }
        return exception
    }

    func makeContext() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("globalThis.window = globalThis;")
        context.evaluateScript(ServiceHostRuntimeTests.textEncoder)
        return context
    }

    @Test func aScriptThatWasNotSentInstallsNothing() {
        var installation = Installation()
        let first = script(installation)
        #expect(first.additions == .init(runtime: true, function: 1))
        #expect(first.script.contains("__cefswiftServices ??="))
        // Cancelled before it was sent: the next call carries it all again.
        let retry = script(installation, call: 2)
        #expect(retry.additions == first.additions)
        #expect(retry.script.contains("__cefswiftServices ??="))
        installation.didSend(retry.additions)
        let later = script(installation, call: 3)
        #expect(later.additions == .init())
        #expect(!later.script.contains("??=") && !later.script.contains(".define("))
        // Another function needs its definition only.
        let other = script(installation, handle: 2, call: 4)
        #expect(other.additions == .init(runtime: false, function: 2))
        installation.reset()
        #expect(installation == Installation())
    }

    /// A document without the runtime, as the poisoned state left it,
    /// fails with the marker that makes the engine install it again, not
    /// with a ReferenceError it would report as the call's failure.
    @Test func aDocumentWithoutTheRuntimeAsksForItAgain() throws {
        var installation = Installation()
        installation.didSend(script(installation).additions)
        // That first script never reached this document.
        let context = try makeContext()
        let message = try #require(run([script(installation, call: 2).script], in: context))
        #expect(message.contains(CefServiceHostRuntime.undefinedFunctionMarker), "\(message)")
        // Installed again, the call runs.
        installation.reset()
        #expect(run([script(installation, call: 3).script], in: context) == nil)
        #expect(context.evaluateScript("typeof window.__cefswiftServices.invoke").toString() == "function")
    }

    /// The runtime and its `define` are idempotent: two calls built before
    /// either was sent both carry them, and the second keeps the first's
    /// runtime, with its calls in flight.
    @Test func installingTwiceIsHarmless() throws {
        let installation = Installation()
        let context = try makeContext()
        #expect(run([script(installation, call: 1).script], in: context) == nil)
        context.evaluateScript("window.__first = window.__cefswiftServices;")
        #expect(run([script(installation, call: 2).script], in: context) == nil)
        #expect(context.evaluateScript("window.__first === window.__cefswiftServices").toBool())
    }
}
