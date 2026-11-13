import CefKit
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
/// Changes, searches and lookups by address go through the documented
/// `chrome.bookmarks` extension API, which Chromium grants its own
/// `chrome://bookmarks` host; CefChromium reaches it from a hidden service host
/// that starts on first use and closes when idle. While that host is not
/// running, ``tree()``, ``children(of:)``, ``bookmark(_:)`` and
/// ``recent(limit:)`` read Chromium's `Bookmarks` file instead, and
/// ``changes`` watches it; neither needs a renderer. Chromium writes the
/// file about 2.5 seconds after a change, so an edit made in Chrome's own
/// UI can take that long to show in those reads. While the app shows no
/// page in a visible window, Chromium holds the save back, and a new
/// profile has no file until its first save. Reads go to the host while the file is
/// missing or a change made through this API is not saved yet. Both paths
/// rely on Chromium internals, so this API is more likely than CefKit to
/// need attention when Chromium updates.
///
/// Incognito profiles have no bookmarks of their own; their
/// ``CefProfile/bookmarks`` are the default profile's.
@MainActor
public final class CefBookmarks {
    /// Held, so the profile lives as long as this object is in use.
    private let profile: CefProfile
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var liveEvents: Task<Void, Never>?
    private var fileWatch: CefFileWatch?
    private var lastLiveEvent: ContinuousClock.Instant?

    init(profile: CefProfile) {
        self.profile = profile
    }

    private var services: CefServiceHosts { profile.serviceHosts }

    /// Where reads come from. `.automatic` reads Chromium's file while the
    /// service host is not running.
    @_spi(Testing) public enum ReadSource: Sendable { case automatic, file, service }
    @_spi(Testing) public var readSource: ReadSource {
        get { profile.chromiumStores.bookmarkReadSource }
        set { profile.chromiumStores.bookmarkReadSource = newValue }
    }

    /// When the last change made through this API, for the profile,
    /// finished; reads go to the host until Chromium has saved it.
    private var unsavedWrite: Date? {
        get { profile.chromiumStores.unsavedBookmarkWrite }
        set { profile.chromiumStores.unsavedBookmarkWrite = newValue }
    }

    /// Whether a change made through this API is not yet in Chromium's
    /// `Bookmarks` file, so reads still go to the service host.
    @_spi(Testing) public var hasUnsavedChanges: Bool {
        refreshSaveState()
        return unsavedWrite != nil
    }

    // MARK: Reading

    /// The permanent folders (bookmarks bar, other bookmarks, …) with all
    /// their contents.
    public func tree() async throws -> [CefBookmark] {
        if let file = try await storedBookmarks() { return file.roots }
        return try await nodes("async b => (await b.getTree())[0]?.children ?? []")
    }

    /// The bookmark with `id`, or `nil` if there is none.
    public func bookmark(_ id: CefBookmark.ID) async throws -> CefBookmark? {
        if let file = try await storedBookmarks() { return file.node(id)?.withoutChildren }
        return try await nodes("(b, a) => b.get(a.id).catch(() => [])", ["id": .string(id.rawValue)]).first
    }

    /// The direct contents of `folder`, in order.
    public func children(of folder: CefBookmark.ID) async throws -> [CefBookmark] {
        if let file = try await storedBookmarks() {
            guard let node = file.node(folder) else {
                throw CefError.operationFailed("bookmarks: Can't find parent bookmark for id.")
            }
            return (node.children ?? []).map(\.withoutChildren)
        }
        return try await nodes("(b, a) => b.getChildren(a.id)", ["id": .string(folder.rawValue)])
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
        if let file = try await storedBookmarks() { return file.recent(limit: max(1, limit)) }
        return try await nodes("(b, a) => b.getRecent(a.limit)", ["limit": .number(Double(max(1, limit)))])
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
        return try await write(
            "(b, a) => b.update(a.id, a.changes)", ["id": .string(id.rawValue), "changes": .object(changes)])
    }

    /// Moves a bookmark or folder into `folder`, at `index` or the end.
    @discardableResult
    public func move(_ id: CefBookmark.ID, to folder: CefBookmark.ID, at index: Int? = nil) async throws -> CefBookmark {
        var destination: [String: CefJSON] = ["parentId": .string(folder.rawValue)]
        if let index { destination["index"] = .number(Double(index)) }
        return try await write(
            "(b, a) => b.move(a.id, a.destination)", ["id": .string(id.rawValue), "destination": .object(destination)])
    }

    /// Removes a bookmark, or a folder with everything in it.
    public func remove(_ id: CefBookmark.ID) async throws {
        defer { unsavedWrite = Date() }
        _ = try await services.call(
            Self.module,
            "async (b, a) => { const [n] = await b.get(a.id); await (n.url ? b.remove(a.id) : b.removeTree(a.id)); return true; }",
            ["id": .string(id.rawValue)])
    }

    // MARK: Observing

    /// Yields whenever bookmarks are added, changed, moved or removed — by
    /// the user in Chrome's UI or through this API. The stream ends when the
    /// consuming task is cancelled.
    ///
    /// While the service host runs, every change is reported at once;
    /// otherwise when Chromium has written its `Bookmarks` file, about 2.5
    /// seconds later. Watching starts no service host. Changes made while
    /// the consumer is busy are reported once: each element means "read
    /// again".
    public var changes: AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = UUID()
            subscribers[token] = continuation
            startObserving()
            // The stream holds this object, and so the profile, until it
            // ends.
            continuation.onTermination = { _ in
                Task { @MainActor in
                    self.subscribers[token] = nil
                    if self.subscribers.isEmpty { self.stopObserving() }
                }
            }
        }
    }

    private func startObserving() {
        if liveEvents == nil {
            let events = services.events(Self.module, "changed", bufferingPolicy: .bufferingNewest(1))
            liveEvents = Task { [weak self] in
                for await _ in events {
                    guard let self else { return }
                    self.lastLiveEvent = .now
                    self.notify()
                }
            }
        }
        if fileWatch == nil, let url = bookmarksFileURL {
            fileWatch = CefFileWatch(url: url) { [weak self] in
                guard let self else { return }
                // Chromium saving changes the service host reported already.
                if let last = self.lastLiveEvent, ContinuousClock.now - last < .seconds(5) { return }
                self.notify()
            }
        }
    }

    private func stopObserving() {
        liveEvents?.cancel()
        liveEvents = nil
        fileWatch = nil
    }

    private func notify() {
        subscribers.values.forEach { $0.yield() }
    }

    // MARK: Plumbing

    /// `chrome.bookmarks`, with listeners that report every change.
    static let module = CefServiceHost.Module(
        name: "bookmarks", hosts: [.bookmarks],
        setup: """
            async emit => {
              const b = chrome.bookmarks;
              if (!b) throw new Error('chrome.bookmarks is not available on this page');
              for (const event of ['onCreated', 'onRemoved', 'onChanged', 'onMoved', 'onChildrenReordered', 'onImportEnded']) {
                b[event].addListener(() => emit('changed', event));
              }
              return b;
            }
            """)

    private var bookmarksFileURL: URL? {
        profile.directory?.appendingPathComponent("Bookmarks")
    }

    /// Chromium's `Bookmarks` file, when it can stand in for the service:
    /// the service host is not running, Chromium has saved every change
    /// made through it, the file is in the format CefChromium reads, and the profile has no
    /// enterprise-managed or account bookmarks, which the file does not
    /// hold.
    private func storedBookmarks() async throws -> CefBookmarkFile? {
        switch readSource {
        case .service:
            return nil
        case .file:
            guard let file = await loadFile() else { throw CefError.operationFailed("bookmarks: no readable Bookmarks file") }
            return file
        case .automatic:
            guard !services.isRunning(.bookmarks) else { return nil }
            refreshSaveState()
            guard unsavedWrite == nil else { return nil }
            return await loadFile()
        }
    }

    /// Forgets the unsaved change once Chromium has written the file after
    /// it. Chromium saves about 2.5 seconds after a change, but holds the
    /// save back while the app shows no page in a visible window.
    private func refreshSaveState() {
        guard let written = unsavedWrite, let url = bookmarksFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let saved = attributes[.modificationDate] as? Date, saved > written
        else { return }
        unsavedWrite = nil
    }

    /// The file, parsed off the main actor, or as last parsed while it
    /// has not changed since: a tree of 10 000 bookmarks takes about 25 ms
    /// to parse, and the bookmark bar reads it on every change.
    private func loadFile() async -> CefBookmarkFile? {
        guard let url = bookmarksFileURL else { return nil }
        let account = url.deletingLastPathComponent().appendingPathComponent("AccountBookmarks")
        guard !FileManager.default.fileExists(atPath: account.path),
              (profile.preferences.value(named: "policy.managed_bookmarks")?.arrayValue ?? []).isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return nil }
        // Chromium replaces the file to save it, so a save changes its
        // inode as well as its date and size.
        let stamp = BookmarkFileStamp(
            modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue,
            inode: (attributes[.systemFileNumber] as? NSNumber)?.intValue)
        let stores = profile.chromiumStores
        if let cached = stores.bookmarkFile, cached.stamp == stamp { return cached.file }
        let file = await Task.detached(priority: .userInitiated) { CefBookmarkFile(contentsOf: url) }.value
        if let file { stores.bookmarkFile = (stamp, file) }
        return file
    }

    private func create(title: String, url: URL?, folder: CefBookmark.ID?, index: Int?) async throws -> CefBookmark {
        var details: [String: CefJSON] = ["title": .string(title)]
        if let url { details["url"] = .string(url.absoluteString) }
        if let folder { details["parentId"] = .string(folder.rawValue) }
        if let index { details["index"] = .number(Double(index)) }
        return try await write("(b, a) => b.create(a)", .object(details))
    }

    private func nodes(_ function: String, _ arguments: CefJSON = [:]) async throws -> [CefBookmark] {
        try await services.call(Self.module, function, arguments, as: [BookmarkNode].self, isIdempotent: true)
            .map(CefBookmark.init)
    }

    private func write(_ function: String, _ arguments: CefJSON) async throws -> CefBookmark {
        // Set when the call ends, failed or not: a call that timed out may
        // still have changed the bookmarks.
        defer { unsavedWrite = Date() }
        return CefBookmark(try await services.call(Self.module, function, arguments, as: BookmarkNode.self))
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
    /// The bookmark as `chrome.bookmarks` returns it outside a tree.
    var withoutChildren: CefBookmark {
        var node = self
        node.children = nil
        return node
    }

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
