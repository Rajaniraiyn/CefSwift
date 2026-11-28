import Foundation
import Testing

@testable import CefBase
@testable import CefKit

@Suite struct SystemMediaDecodersTests {
    @Test func offByDefaultInEveryPreset() {
        #expect(CefRuntime.Configuration().services.systemMediaDecoders.isEmpty)
        #expect(CefRuntime.Configuration.embedded.services.systemMediaDecoders.isEmpty)
        #expect(CefRuntime.Configuration.chrome.services.systemMediaDecoders.isEmpty)
    }

    /// The test runner carries no media service, so the option on does
    /// nothing: renderers get no shim.
    @Test @MainActor func doesNothingWithoutTheService() {
        var configuration = CefRuntime.Configuration()
        configuration.services.systemMediaDecoders = .audio
        #expect(CefMediaDecoding.serviceName == nil)
        #expect(!CefMediaDecoding.isAvailable(configuration: configuration))
        #expect(!CefAppCapabilities.current.hasSystemMediaService)
    }

    @Test func readsTheValuesADecodeRequestCarries() throws {
        var buffer = CefWireBuffer()
        buffer.append(header: CefWireHeader(target: 7, call: 3, succeeded: true))
        buffer.append("mp4a")
        buffer.append(48000.0)
        buffer.append(Int32(2))
        buffer.append(bytes: 4) { $0.copyMemory(from: [1, 2, 3, 4] as [UInt8], byteCount: 4) }
        buffer.appendNull()
        buffer.materializeDeferred()
        var reader = CefWireReader(buffer.bytes)
        let header = try reader.header()
        reader.skipHeader()
        #expect(header.target == 7 && header.call == 3 && header.succeeded == 1)
        #expect(try reader.readString() == "mp4a")
        #expect(try reader.readNumber() == 48000)
        #expect(try reader.readNumber() == 2)
        #expect(Array(try reader.readBytes()) == [1, 2, 3, 4])
        #expect(try reader.readBytes().isEmpty)
        #expect(reader.isAtEnd)
    }

    @Test func mediaMessagesAreTold() {
        #expect(CefMediaMessage.isMedia(CefMediaMessage.decode.pointer))
        #expect(CefMediaMessage.isMedia(CefMediaMessage.decoded.pointer))
        #expect(!CefMediaMessage.isMedia(CefPageScriptingMessage.call.pointer))
    }
}
