import Foundation

extension CefProfile {
    /// Kinds of data a site keeps in a profile, for
    /// ``clearSiteData(for:types:)``.
    public struct SiteDataTypes: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// The origin's cookies.
        public static let cookies = SiteDataTypes(rawValue: 1 << 0)
        /// `localStorage`.
        public static let localStorage = SiteDataTypes(rawValue: 1 << 1)
        /// IndexedDB databases.
        public static let indexedDB = SiteDataTypes(rawValue: 1 << 2)
        /// Cache Storage (`caches`), as service workers use it.
        public static let cacheStorage = SiteDataTypes(rawValue: 1 << 3)
        /// Registered service workers.
        public static let serviceWorkers = SiteDataTypes(rawValue: 1 << 4)
        /// The origin-private file system and the File System API.
        public static let fileSystems = SiteDataTypes(rawValue: 1 << 5)
        /// Shared Storage.
        public static let sharedStorage = SiteDataTypes(rawValue: 1 << 6)
        /// Storage Buckets.
        public static let storageBuckets = SiteDataTypes(rawValue: 1 << 7)
        /// Compiled shaders WebGL and WebGPU cached for the origin.
        public static let shaderCache = SiteDataTypes(rawValue: 1 << 8)

        /// Everything an origin can keep, these kinds and any Chromium adds.
        public static let all = SiteDataTypes(rawValue: ~0)

        /// The DevTools Protocol's `Storage.StorageType` names, joined
        /// as `Storage.clearDataForOrigin` takes them.
        var storageTypes: String {
            if self == .all { return "all" }
            let names: [(SiteDataTypes, String)] = [
                (.cookies, "cookies"), (.localStorage, "local_storage"), (.indexedDB, "indexeddb"),
                (.cacheStorage, "cache_storage"), (.serviceWorkers, "service_workers"),
                (.fileSystems, "file_systems"), (.sharedStorage, "shared_storage"),
                (.storageBuckets, "storage_buckets"), (.shaderCache, "shader_cache"),
            ]
            return names.filter { contains($0.0) }.map(\.1).joined(separator: ",")
        }
    }

    /// Deletes what the site at `origin` keeps in this profile: its cookies,
    /// storage, databases, caches and service workers, or the `types`
    /// asked for. Other sites' data stays, and so does the HTTP cache
    /// (``clearHTTPCache()``, which is not kept per site).
    ///
    /// ```swift
    /// // "Forget this site", from a site information sheet.
    /// try await page.profile.clearSiteData(for: URL(string: "https://example.com")!)
    /// ```
    ///
    /// Only the scheme, host and port of `origin` count. Cookies are
    /// deleted for that host, as Chromium's site settings do; cookies a
    /// parent domain set (`Domain=example.com` for `www.example.com`)
    /// stay, as ``deleteCookies(for:named:)`` leaves them.
    ///
    /// CEF has no call for this, so it runs Chromium's DevTools Protocol
    /// command `Storage.clearDataForOrigin` in one of the profile's open
    /// pages: that page's ``CefPage/devTools`` session attaches, with no
    /// domain enabled, and stays attached ("Compatibility with bot
    /// protection" in the guide). A discarded page is not restored for
    /// it. Throws ``CefError/operationFailed(_:)`` when the profile has no
    /// live page, and for an `origin` with no host.
    public func clearSiteData(for origin: URL, types: SiteDataTypes = .all) async throws {
        guard let scheme = origin.scheme?.lowercased(), let host = origin.host(), !host.isEmpty else {
            throw CefError.operationFailed("\(origin) is not an origin")
        }
        guard !types.isEmpty else { return }
        let port = origin.port.map { ":\($0)" } ?? ""
        let serialized = "\(scheme)://\(host.contains(":") ? "[\(host)]" : host)\(port)"
        guard let page = pages.first(where: { $0.raw != nil && !$0.isDiscarded }) else {
            throw CefError.operationFailed("clearSiteData(for:) needs a live page in the profile \(id)")
        }
        try await page.devTools.send(
            "Storage.clearDataForOrigin", ["origin": .string(serialized), "storageTypes": .string(types.storageTypes)])
    }
}
