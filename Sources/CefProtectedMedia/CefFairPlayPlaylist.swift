import Foundation

/// A page's HLS media playlist, checked before any of it reaches
/// AVFoundation.
///
/// The playlist comes from the page, so it decides what the FairPlay
/// service fetches and plays. A playlist passes only when it is a media
/// playlist of reasonable size whose segments and initialization map are
/// `https` addresses, and whose keys are `skd://` or `https`. Anything
/// else (`file:`, `data:`, other schemes, relative addresses, a master
/// playlist, which would make AVFoundation load playlists the app has not
/// seen) is refused with a reason.
public struct CefFairPlayPlaylist: Sendable, Equatable {
    /// The largest playlist accepted, in bytes: a three-hour track of
    /// two-second segments is about 400 KB.
    public static let maximumSize = 2 << 20

    /// The playlist's text.
    public let text: String
    /// The key URIs it names, in order.
    public let keyURIs: [String]
    /// How many segments it lists.
    public let segmentCount: Int

    /// Why a playlist was refused.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// Checks `data`, the playlist's bytes.
    public init(data: Data) throws(Refusal) {
        guard data.count <= Self.maximumSize else { throw Refusal("the playlist is larger than \(Self.maximumSize) bytes") }
        guard let text = String(data: data, encoding: .utf8) else { throw Refusal("the playlist is not UTF-8") }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U" else { throw Refusal("not an HLS playlist") }
        var keys: [String] = []
        var segments = 0
        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-STREAM-INF") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF")
                || line.hasPrefix("#EXT-X-MEDIA:") {
                throw Refusal("a master playlist; only media playlists are accepted")
            }
            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                guard let uri = Self.attribute("URI", in: line) else {
                    if Self.attribute("METHOD", in: line) == "NONE" { continue }
                    throw Refusal("a key without a URI")
                }
                guard uri.hasPrefix("skd://") || Self.isHTTPS(uri) else { throw Refusal("a key that is not skd:// or https: \(uri)") }
                keys.append(uri)
                continue
            }
            if line.hasPrefix("#EXT-X-MAP:") {
                guard let uri = Self.attribute("URI", in: line), Self.isHTTPS(uri) else {
                    throw Refusal("an initialization map that is not https")
                }
                continue
            }
            if line.hasPrefix("#") { continue }
            guard Self.isHTTPS(line) else { throw Refusal("a segment that is not https: \(line.prefix(80))") }
            segments += 1
        }
        guard segments > 0 else { throw Refusal("no segments") }
        self.text = text
        keyURIs = keys
        segmentCount = segments
    }

    static func isHTTPS(_ address: String) -> Bool {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }

    /// A quoted or bare attribute of an `#EXT-X-…:` line.
    static func attribute(_ name: String, in line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var rest = Substring(line[line.index(after: colon)...])
        while !rest.isEmpty {
            guard let equals = rest.firstIndex(of: "=") else { return nil }
            let key = rest[..<equals].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: equals)...]
            let value: Substring
            if rest.first == "\"" {
                rest = rest.dropFirst()
                guard let close = rest.firstIndex(of: "\"") else { return nil }
                value = rest[..<close]
                rest = rest[rest.index(after: close)...]
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end]
                rest = rest[end...]
            }
            if rest.first == "," { rest = rest.dropFirst() }
            if key == name { return String(value) }
        }
        return nil
    }
}
