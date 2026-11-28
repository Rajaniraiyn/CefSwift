import Foundation
import Testing

@testable import CefProtectedMedia

@Suite struct FairPlayPlaylistTests {
    static let good = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-TARGETDURATION:10
        #EXT-X-MAP:URI="https://audio.example/track/init.mp4"
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key-1",KEYFORMAT="com.apple.streamingkeydelivery",KEYFORMATVERSIONS="1"
        #EXTINF:10.0,
        https://audio.example/track/1.m4s
        #EXTINF:10.0,
        https://audio.example/track/2.m4s
        #EXT-X-ENDLIST
        """

    func playlist(_ text: String) throws -> CefFairPlayPlaylist {
        try CefFairPlayPlaylist(data: Data(text.utf8))
    }

    @Test func acceptsAMediaPlaylistOfHTTPSSegmentsAndSKDKeys() throws {
        let checked = try playlist(Self.good)
        #expect(checked.keyURIs == ["skd://key-1"])
        #expect(checked.segmentCount == 2)
    }

    @Test func refusesSegmentsThatAreNotHTTPS() {
        for segment in ["http://audio.example/1.m4s", "file:///etc/passwd", "data:audio/mp4;base64,AAAA", "1.m4s",
                        "https:///no-host.m4s", "cefswift-fairplay://playlist/x.m4s"] {
            let text = Self.good.replacingOccurrences(of: "https://audio.example/track/2.m4s", with: segment)
            #expect(throws: CefFairPlayPlaylist.Refusal.self, "\(segment)") { try playlist(text) }
        }
    }

    @Test func refusesKeysAndMapsThatAreNotSKDOrHTTPS() {
        let fileKey = Self.good.replacingOccurrences(of: "skd://key-1", with: "file:///key")
        #expect(throws: CefFairPlayPlaylist.Refusal.self) { try playlist(fileKey) }
        let httpMap = Self.good.replacingOccurrences(of: "https://audio.example/track/init.mp4", with: "http://a/init.mp4")
        #expect(throws: CefFairPlayPlaylist.Refusal.self) { try playlist(httpMap) }
        let noURI = Self.good.replacingOccurrences(of: #"URI="skd://key-1","#, with: "")
        #expect(throws: CefFairPlayPlaylist.Refusal.self) { try playlist(noURI) }
    }

    @Test func refusesMasterPlaylistsAndNonsense() {
        #expect(throws: CefFairPlayPlaylist.Refusal.self) {
            try playlist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://a.example/media.m3u8\n")
        }
        #expect(throws: CefFairPlayPlaylist.Refusal.self) { try playlist("<html>") }
        #expect(throws: CefFairPlayPlaylist.Refusal.self) { try playlist("#EXTM3U\n#EXT-X-ENDLIST\n") }
        let huge = Data(repeating: 0x41, count: CefFairPlayPlaylist.maximumSize + 1)
        #expect(throws: CefFairPlayPlaylist.Refusal.self) { try CefFairPlayPlaylist(data: huge) }
    }

    @Test func readsQuotedAndBareAttributes() {
        let line = #"#EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://a,b",KEYFORMAT="x""#
        #expect(CefFairPlayPlaylist.attribute("URI", in: line) == "skd://a,b")
        #expect(CefFairPlayPlaylist.attribute("METHOD", in: line) == "SAMPLE-AES")
        #expect(CefFairPlayPlaylist.attribute("IV", in: line) == nil)
    }

    @Test @MainActor func listsOnlyExactHTTPSOrigins() {
        #expect(CefFairPlay.isHTTPSOrigin("https://open.spotify.com"))
        #expect(!CefFairPlay.isHTTPSOrigin("http://open.spotify.com"))
        #expect(!CefFairPlay.isHTTPSOrigin("https://open.spotify.com/"))
        #expect(!CefFairPlay.isHTTPSOrigin("https://open.spotify.com/track"))
        #expect(!CefFairPlay.isHTTPSOrigin("file://"))
        let fairPlay = CefFairPlay(origins: ["https://open.spotify.com", "http://example.com", "https://a.example/x"])
        #expect(fairPlay.origins == ["https://open.spotify.com"])
        fairPlay.origins.insert("https://music.example")
        #expect(fairPlay.origins == ["https://open.spotify.com", "https://music.example"])
    }
}
