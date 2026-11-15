import Foundation

/// Chromium's `Bookmarks` file, read as `chrome.bookmarks` would report it.
///
/// Chromium keeps a profile's bookmarks in memory and saves them to this
/// JSON file (`components/bookmarks/browser/bookmark_codec.cc`, format
/// version 1) about 2.5 seconds after each change, replacing it atomically.
/// Reading it needs no renderer. Anything unexpected in it makes the read
/// fail, and ``CefBookmarks`` asks Chromium's service instead.
///
/// The format is Chromium's own and can change with it.
struct CefBookmarkFile: Sendable {
    /// The permanent folders, in `chrome.bookmarks.getTree()` order.
    let roots: [CefBookmark]

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let file = try? JSONDecoder().decode(StoredFile.self, from: data),
              file.version == 1
        else { return nil }
        let permanent: [(StoredNode?, CefBookmark.PermanentFolder)] = [
            (file.roots.bookmark_bar, .bookmarksBar), (file.roots.other, .other), (file.roots.synced, .mobile),
        ]
        var roots: [CefBookmark] = []
        for (index, (node, folder)) in permanent.enumerated() {
            guard let node else {
                // Chromium writes all three; a file without the first two
                // is not one CefChromium knows.
                if folder == .mobile { continue } else { return nil }
            }
            guard var root = Self.bookmark(node, parent: nil, index: index) else { return nil }
            root.permanentFolder = folder
            root.isEditable = false
            // The mobile folder is listed only when it holds something, as
            // Chromium hides it on desktop otherwise.
            if folder == .mobile, root.children?.isEmpty ?? true { continue }
            roots.append(root)
        }
        self.roots = roots
    }

    /// The bookmark or folder with `id`, with its contents.
    func node(_ id: CefBookmark.ID) -> CefBookmark? {
        func find(_ nodes: [CefBookmark]) -> CefBookmark? {
            for node in nodes {
                if node.id == id { return node }
                if let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        return find(roots)
    }

    /// The `limit` most recently added bookmarks (not folders), newest
    /// first, as `chrome.bookmarks.getRecent` orders them.
    func recent(limit: Int) -> [CefBookmark] {
        var all: [CefBookmark] = []
        func collect(_ nodes: [CefBookmark]) {
            for node in nodes {
                if node.url != nil { all.append(node.withoutChildren) }
                collect(node.children ?? [])
            }
        }
        collect(roots)
        // Stable: among equal dates, the one found first stays first.
        let sorted = all.enumerated().sorted { a, b in
            let (da, db) = (a.element.dateAdded ?? .distantPast, b.element.dateAdded ?? .distantPast)
            return da != db ? da > db : a.offset < b.offset
        }
        return sorted.prefix(limit).map(\.element)
    }

    // MARK: Decoding

    private struct StoredFile: Decodable {
        struct Roots: Decodable {
            var bookmark_bar: StoredNode?
            var other: StoredNode?
            var synced: StoredNode?
        }
        var roots: Roots
        var version: Int
    }

    private struct StoredNode: Decodable {
        var id: String
        var name: String
        var type: String
        var url: String?
        var date_added: String?
        var children: [StoredNode]?
    }

    private static func bookmark(_ node: StoredNode, parent: CefBookmark.ID?, index: Int) -> CefBookmark? {
        let isFolder: Bool
        switch node.type {
        case "folder": isFolder = true
        case "url": isFolder = false
        default: return nil
        }
        let url = isFolder ? nil : node.url.flatMap(URL.init(string:))
        if !isFolder, url == nil { return nil }
        let id = CefBookmark.ID(rawValue: node.id)
        var children: [CefBookmark]?
        if isFolder {
            var contents: [CefBookmark] = []
            for (position, child) in (node.children ?? []).enumerated() {
                guard let bookmark = bookmark(child, parent: id, index: position) else { return nil }
                contents.append(bookmark)
            }
            children = contents
        }
        // Microseconds since 1601, as Chromium's `base::Time` counts.
        let dateAdded = node.date_added.flatMap(Int64.init).flatMap { microseconds -> Date? in
            microseconds == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(microseconds) / 1_000_000 - 11_644_473_600)
        }
        return CefBookmark(
            id: id, parentID: parent, index: index, title: node.name, url: url, dateAdded: dateAdded,
            permanentFolder: nil, isEditable: true, children: children)
    }
}

/// Calls `onChange` on the main actor whenever the file at `url` is
/// written, replaced, created or removed. Watching stops when the object
/// is released.
@MainActor
final class CefFileWatch {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var modified: [Int]?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        modified = Self.modificationDate(of: url)
        watch()
    }

    deinit {
        source?.cancel()
    }

    /// Watches the file itself, or its directory until the file appears.
    /// Chromium replaces the file by renaming a new one over it, which ends
    /// a watch on the old one; each event starts a new watch.
    private func watch() {
        source?.cancel()
        source = nil
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let path = fileExists ? url.path : url.deletingLastPathComponent().path
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: fileExists ? [.write, .delete, .rename, .extend] : [.write],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleEvent() }
        }
        source.setCancelHandler { close(descriptor) }
        source.activate()
        self.source = source
    }

    private func handleEvent() {
        let now = Self.modificationDate(of: url)
        let changed = now != modified
        modified = now
        watch()
        if changed { onChange() }
    }

    /// The file's inode and modification time; Chromium's replacement is a
    /// new inode.
    private static func modificationDate(of url: URL) -> [Int]? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return [Int(info.st_ino), info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, Int(info.st_size)]
    }
}
