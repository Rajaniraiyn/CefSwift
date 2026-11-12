import Foundation
import Testing

@testable import CefKit

@Suite struct BookmarkFileTests {
    /// A file as Chromium 156 writes it (`bookmark_codec.cc`), trimmed.
    static let sample = """
        {
           "checksum": "5e5f7d0b3c1c0f4c9b3fe1a0a3f0a3c2",
           "roots": {
              "bookmark_bar": {
                 "children": [ {
                    "date_added": "13438952551346372", "date_last_used": "0",
                    "guid": "084ff8bf-1374-4331-8950-2fb7071fc8b7", "id": "5",
                    "meta_info": { "power_bookmark_meta": "" },
                    "name": "Swift", "type": "url", "url": "https://swift.org/"
                 }, {
                    "children": [ {
                       "date_added": "13438952600000000", "guid": "1d0e6c9e-0000-4000-8000-000000000001",
                       "id": "7", "name": "Newer", "type": "url", "url": "https://example.com/newer"
                    } ],
                    "date_added": "13438952560000000", "date_modified": "0",
                    "guid": "1d0e6c9e-0000-4000-8000-000000000000", "id": "6", "name": "Folder", "type": "folder"
                 } ],
                 "date_added": "13438952301712585", "date_modified": "13438952551346372",
                 "guid": "0bc5d13f-2cba-5d74-951f-3f233fe6c908", "id": "1", "name": "Bookmarks bar", "type": "folder"
              },
              "other": {
                 "children": [], "date_added": "13438952301712585", "date_modified": "0",
                 "guid": "82b081ec-3dd3-529c-8475-ab6c344590dd", "id": "2", "name": "Other bookmarks", "type": "folder"
              },
              "synced": {
                 "children": [], "date_added": "13438952301712585", "date_modified": "0",
                 "guid": "4cf2e351-0e85-532b-bb37-df045d8f8d0f", "id": "3", "name": "Mobile bookmarks", "type": "folder"
              }
           },
           "version": 1
        }
        """

    func file(_ text: String) throws -> CefBookmarkFile? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bookmarks-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return CefBookmarkFile(contentsOf: url)
    }

    @Test func readsTheTreeAsChromeBookmarksReportsIt() throws {
        let file = try #require(try file(Self.sample))
        // An empty mobile folder is not listed.
        #expect(file.roots.map(\.permanentFolder) == [.bookmarksBar, .other])
        let bar = file.roots[0]
        #expect(bar.id.rawValue == "1" && bar.parentID == nil && !bar.isEditable && bar.title == "Bookmarks bar")
        let swift = try #require(bar.children?.first)
        #expect(swift.parentID?.rawValue == "1" && swift.index == 0 && swift.url?.absoluteString == "https://swift.org/")
        #expect(swift.children == nil && swift.isEditable)
        // 13438952551346372 µs after 1601-01-01.
        #expect(abs((swift.dateAdded?.timeIntervalSince1970 ?? 0) - 1_794_478_951.346372) < 0.001)
        let folder = try #require(file.node(CefBookmark.ID(rawValue: "6")))
        #expect(folder.isFolder && folder.index == 1 && folder.children?.map(\.title) == ["Newer"])
    }

    @Test func recentListsBookmarksNewestFirst() throws {
        let file = try #require(try file(Self.sample))
        #expect(file.recent(limit: 5).map(\.id.rawValue) == ["7", "5"])
        #expect(file.recent(limit: 1).first?.children == nil)
    }

    @Test func refusesWhatItDoesNotKnow() throws {
        #expect(try file(Self.sample.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2")) == nil)
        #expect(try file(Self.sample.replacingOccurrences(of: "\"type\": \"url\"", with: "\"type\": \"note\"")) == nil)
        #expect(try file("{}") == nil)
        #expect(try file("not json") == nil)
    }
}
