import Foundation

/// A bookmark or bookmark folder.
public struct CefBookmark: Sendable, Identifiable, Hashable {
    /// Identifies a bookmark within its profile.
    public struct ID: Sendable, Hashable, CustomStringConvertible {
        let rawValue: String
        public var description: String { rawValue }
    }

    /// The folders every profile has, which cannot be renamed or removed.
    public enum PermanentFolder: Sendable, Hashable {
        case bookmarksBar
        case other
        case mobile
        /// Bookmarks set by enterprise policy; read-only.
        case managed
    }

    public var id: ID
    /// The containing folder; `nil` only for the permanent folders.
    public var parentID: ID?
    /// Position within the parent folder.
    public var index: Int
    public var title: String
    /// The bookmarked address; `nil` for folders.
    public var url: URL?
    public var dateAdded: Date?
    /// Set on the permanent folders.
    public var permanentFolder: PermanentFolder?
    /// Whether the bookmark can be renamed, moved or removed. Permanent
    /// folders and managed bookmarks cannot.
    public var isEditable: Bool
    /// The folder's contents, when the bookmark was read as part of a tree.
    public var children: [CefBookmark]?

    public var isFolder: Bool { url == nil }
}

/// The bookmarks of a ``CefProfile`` — the same ones Chrome's bookmark bar,
/// star button and `chrome://bookmarks` show.
///
/// ```swift
/// let bookmarks = CefProfile.default.bookmarks
/// let added = try await bookmarks.add(URL(string: "https://swift.org")!, title: "Swift")
/// for folder in try await bookmarks.tree() { print(folder.title, folder.children?.count ?? 0) }
/// try await bookmarks.remove(added.id)
/// ```
///
/// Built on the documented `chrome.bookmarks` extension API, which Chromium
/// grants its own `chrome://bookmarks` page. CefKit reaches it through a
/// hidden service browser parked on that page, created on first use. Because
/// it relies on a Chromium-internal page, this API is more likely than the
/// rest of CefKit to need attention when Chromium updates.
///
/// Incognito profiles have no bookmarks of their own; their
/// ``CefProfile/bookmarks`` are the default profile's.
@MainActor
public final class CefBookmarks {
    private let service: CefInternalPageService
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(profile: CefProfile) {
        service = CefInternalPageService(
            profile: profile,
            page: "chrome://bookmarks/",
            setup: Self.setup,
            notificationBinding: Self.notificationBinding)
        service.onNotification = { [weak self] _ in
            self?.subscribers.values.forEach { $0.yield() }
        }
    }

    // MARK: Reading

    /// The permanent folders (bookmarks bar, other bookmarks, …) with all
    /// their contents.
    public func tree() async throws -> [CefBookmark] {
        try await nodes("async b => (await b.getTree())[0]?.children ?? []")
    }

    /// The bookmark with `id`, or `nil` if there is none.
    public func bookmark(_ id: CefBookmark.ID) async throws -> CefBookmark? {
        try await nodes("(b, a) => b.get(a.id).catch(() => [])", ["id": .string(id.rawValue)]).first
    }

    /// The direct contents of `folder`, in order.
    public func children(of folder: CefBookmark.ID) async throws -> [CefBookmark] {
        try await nodes("(b, a) => b.getChildren(a.id)", ["id": .string(folder.rawValue)])
    }

    /// Bookmarks and folders whose title or address contains every word of
    /// `query`.
    public func search(_ query: String) async throws -> [CefBookmark] {
        try await nodes("(b, a) => b.search(a.query)", ["query": .string(query)])
    }

    /// Bookmarks of exactly `url`.
    public func bookmarks(for url: URL) async throws -> [CefBookmark] {
        try await nodes("(b, a) => b.search({url: a.url})", ["url": .string(url.absoluteString)])
    }

    /// The most recently added bookmarks, newest first.
    public func recent(limit: Int = 10) async throws -> [CefBookmark] {
        try await nodes("(b, a) => b.getRecent(a.limit)", ["limit": .number(Double(max(1, limit)))])
    }

    // MARK: Changing

    /// Bookmarks `url`. Without a `folder` it goes into Other Bookmarks;
    /// without an `index`, at the end.
    @discardableResult
    public func add(
        _ url: URL, title: String, in folder: CefBookmark.ID? = nil, at index: Int? = nil
    ) async throws -> CefBookmark {
        try await create(title: title, url: url, folder: folder, index: index)
    }

    /// Creates a folder.
    @discardableResult
    public func addFolder(
        _ title: String, in folder: CefBookmark.ID? = nil, at index: Int? = nil
    ) async throws -> CefBookmark {
        try await create(title: title, url: nil, folder: folder, index: index)
    }

    /// Renames a bookmark or folder, or changes a bookmark's address.
    @discardableResult
    public func update(_ id: CefBookmark.ID, title: String? = nil, url: URL? = nil) async throws -> CefBookmark {
        var changes: [String: CefJSON] = [:]
        if let title { changes["title"] = .string(title) }
        if let url { changes["url"] = .string(url.absoluteString) }
        return try await node(
            "(b, a) => b.update(a.id, a.changes)", ["id": .string(id.rawValue), "changes": .object(changes)])
    }

    /// Moves a bookmark or folder into `folder`, at `index` or the end.
    @discardableResult
    public func move(_ id: CefBookmark.ID, to folder: CefBookmark.ID, at index: Int? = nil) async throws -> CefBookmark {
        var destination: [String: CefJSON] = ["parentId": .string(folder.rawValue)]
        if let index { destination["index"] = .number(Double(index)) }
        return try await node(
            "(b, a) => b.move(a.id, a.destination)", ["id": .string(id.rawValue), "destination": .object(destination)])
    }

    /// Removes a bookmark, or a folder with everything in it.
    public func remove(_ id: CefBookmark.ID) async throws {
        _ = try await service.call(
            "async (b, a) => { const [n] = await b.get(a.id); await (n.url ? b.remove(a.id) : b.removeTree(a.id)); return true; }",
            ["id": .string(id.rawValue)])
    }

    // MARK: Observing

    /// Yields whenever bookmarks are added, changed, moved or removed — by
    /// the user in Chrome's UI or through this API. The stream ends when the
    /// consuming task is cancelled.
    public var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let token = UUID()
            subscribers[token] = continuation
            service.keepsRunning = true
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.subscribers[token] = nil
                    self.service.keepsRunning = !self.subscribers.isEmpty
                }
            }
            // Listeners are installed when the service page is set up.
            Task { try? await self.service.start() }
        }
    }

    // MARK: Plumbing

    private static let notificationBinding = "__cefswiftBookmarksChanged"

    private static let setup = """
        async () => {
          const b = chrome.bookmarks;
          if (!b) throw new Error('chrome.bookmarks is not available on this page');
          for (const event of ['onCreated', 'onRemoved', 'onChanged', 'onMoved', 'onChildrenReordered', 'onImportEnded']) {
            b[event].addListener(() => window.\(notificationBinding)?.(event));
          }
          return b;
        }
        """

    private func create(title: String, url: URL?, folder: CefBookmark.ID?, index: Int?) async throws -> CefBookmark {
        var details: [String: CefJSON] = ["title": .string(title)]
        if let url { details["url"] = .string(url.absoluteString) }
        if let folder { details["parentId"] = .string(folder.rawValue) }
        if let index { details["index"] = .number(Double(index)) }
        return try await node("(b, a) => b.create(a)", .object(details))
    }

    private func nodes(_ function: String, _ arguments: CefJSON = [:]) async throws -> [CefBookmark] {
        try await service.call(function, arguments).decode([BookmarkNode].self).map(CefBookmark.init)
    }

    private func node(_ function: String, _ arguments: CefJSON) async throws -> CefBookmark {
        CefBookmark(try await service.call(function, arguments).decode(BookmarkNode.self))
    }
}

/// `chrome.bookmarks.BookmarkTreeNode`.
private struct BookmarkNode: Decodable {
    var id: String
    var parentId: String?
    var index: Int?
    var title: String
    var url: String?
    var dateAdded: Double?
    var folderType: String?
    var unmodifiable: String?
    var children: [BookmarkNode]?
}

extension CefBookmark {
    fileprivate init(_ node: BookmarkNode) {
        id = ID(rawValue: node.id)
        parentID = node.parentId.flatMap { $0 == "0" ? nil : ID(rawValue: $0) }
        index = node.index ?? 0
        title = node.title
        url = node.url.flatMap(URL.init(string:))
        dateAdded = node.dateAdded.map { Date(timeIntervalSince1970: $0 / 1000) }
        permanentFolder =
            switch node.folderType {
            case "bookmarks-bar": .bookmarksBar
            case "other": .other
            case "mobile": .mobile
            case "managed": .managed
            default: nil
            }
        isEditable = node.unmodifiable == nil && permanentFolder == nil
        children = node.children?.map(CefBookmark.init)
    }
}
