import AppKit
import Foundation
import Testing

@testable import CefChromium
@testable import CefKit

/// The adapters' own logic, without Chromium: latest-wins queries, and the
/// records a host sends decoded into the public types.
@MainActor
struct ServiceAdapterTests {
    /// A query that answers after `delay` with one partial and one complete
    /// result, and records whether it was stopped.
    @MainActor final class FakeQueries {
        var started: [String] = []
        var stopped: Set<String> = []
        let delay: Duration

        init(delay: Duration) { self.delay = delay }

        func query(_ text: String) -> AsyncThrowingStream<CefAutocomplete.Result, Error> {
            started.append(text)
            let (stream, continuation) = AsyncThrowingStream<CefAutocomplete.Result, Error>.makeStream()
            let delay = delay
            let work = Task { @MainActor in
                do {
                    try await Task.sleep(for: delay)
                    continuation.yield(.init(text: text, suggestions: [], isComplete: false))
                    try await Task.sleep(for: delay)
                    continuation.yield(.init(text: text, suggestions: [], isComplete: true))
                    continuation.finish()
                } catch {
                    self.stopped.insert(text)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in work.cancel() }
            return stream
        }
    }

    @Test func aNewerTextStopsTheQueryBeforeIt() async throws {
        let fake = FakeQueries(delay: .milliseconds(40))
        let (texts, typed) = AsyncStream.makeStream(of: String.self)
        let results = CefAutocomplete.latest(following: texts, query: fake.query)
        for text in ["s", "sw", "swi", "swif"] {
            typed.yield(text)
            try await Task.sleep(for: .milliseconds(5))
        }
        typed.yield("swift")
        typed.finish()
        var seen: [CefAutocomplete.Result] = []
        for try await result in results { seen.append(result) }
        // Only the last text's results arrive, ending with the complete one.
        #expect(seen.map(\.text).allSatisfy { $0 == "swift" })
        #expect(seen.last?.isComplete == true)
        #expect(fake.started == ["s", "sw", "swi", "swif", "swift"])
        // Every superseded query was stopped, not left running.
        #expect(await waitUntil { fake.stopped == ["s", "sw", "swi", "swif"] })
    }

    @Test func endingTheConsumerStopsTheRunningQuery() async throws {
        let fake = FakeQueries(delay: .seconds(10))
        let (texts, typed) = AsyncStream.makeStream(of: String.self)
        let results = CefAutocomplete.latest(following: texts, query: fake.query)
        typed.yield("slow")
        let consumer = Task { @MainActor in for try await _ in results {} }
        #expect(await waitUntil { fake.started == ["slow"] })
        consumer.cancel()
        #expect(await waitUntil { fake.stopped == ["slow"] })
    }

    @Test func aFailedQueryEndsTheStreamWithItsError() async throws {
        struct Failed: Error {}
        let (texts, typed) = AsyncStream.makeStream(of: String.self)
        let results = CefAutocomplete.latest(following: texts) { (_: String) in
            AsyncThrowingStream<Int, Error> { $0.finish(throwing: Failed()) }
        }
        typed.yield("x")
        await #expect(throws: Failed.self) {
            for try await _ in results {}
        }
    }

    @Test func iconPixelsBecomeTheImagesBitmap() throws {
        // 2 × 2: red, green, blue, half-transparent white; RGBA, not premultiplied.
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 128])
        let icon = IconRecord(width: 2, height: 2, pixels: pixels)
        let image = try #require(icon.makeImage(size: 16))
        #expect(image.size == NSSize(width: 16, height: 16))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cgImage.width == 2 && cgImage.height == 2)
        // Drawn into an RGBA context of the same size, the pixels come back.
        var drawn = [UInt8](repeating: 0, count: 16)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        drawn.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        #expect(Array(drawn[0..<12]) == [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255])
        #expect(abs(Int(drawn[15]) - 128) <= 1 && abs(Int(drawn[12]) - 128) <= 1)
        // Pixels that do not fill the size are refused, not read past.
        #expect(IconRecord(width: 4, height: 4, pixels: pixels).makeImage(size: 16) == nil)
    }

    @Test func matchesDecodeIntoSuggestions() throws {
        let match = MatchRecord(
            type: "history-url", contents: "swift.org", description: "Swift", url: "https://swift.org/", fill: "swift.org",
            inline: ".org", relevance: 1200, canBeDefault: true, starred: true, isSearch: false)
        let suggestion = CefAutocomplete.Suggestion(match)
        #expect(suggestion.kind == .history)
        #expect(suggestion.url == URL(string: "https://swift.org/"))
        #expect(suggestion.inlineCompletion == ".org" && suggestion.isBookmarked && suggestion.canBeDefault)
        let search = CefAutocomplete.Suggestion(MatchRecord(
            type: "search-what-you-typed", contents: "swi", description: "", url: "", fill: "swi", inline: "",
            relevance: 1300, canBeDefault: true, starred: false, isSearch: true))
        #expect(search.kind == .search && search.url == nil && search.isSearch)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
