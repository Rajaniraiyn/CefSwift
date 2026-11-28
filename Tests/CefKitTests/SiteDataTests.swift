import Foundation
import Testing

@testable import CefKit

/// What `clearSiteData(for:types:)` asks Chromium for, and when it refuses
/// without asking.
@MainActor
struct SiteDataTests {
    @Test func typesUseTheProtocolsNames() {
        #expect(CefProfile.SiteDataTypes.all.storageTypes == "all")
        #expect(CefProfile.SiteDataTypes([.cookies, .localStorage]).storageTypes == "cookies,local_storage")
        #expect(CefProfile.SiteDataTypes([.indexedDB, .cacheStorage, .serviceWorkers]).storageTypes
            == "indexeddb,cache_storage,service_workers")
        #expect(CefProfile.SiteDataTypes([.fileSystems, .sharedStorage, .storageBuckets, .shaderCache]).storageTypes
            == "file_systems,shared_storage,storage_buckets,shader_cache")
    }

    @Test func anAddressWithoutAHostIsRefused() async {
        await #expect(throws: CefError.self) {
            try await CefProfile.incognito().clearSiteData(for: URL(string: "about:blank")!)
        }
    }

    @Test func aProfileWithoutALivePageIsRefused() async {
        await #expect(throws: CefError.self) {
            try await CefProfile.incognito().clearSiteData(for: URL(string: "https://example.com")!)
        }
    }

    @Test func noTypesIsNothingToDo() async throws {
        try await CefProfile.incognito().clearSiteData(for: URL(string: "https://example.com")!, types: [])
    }
}
