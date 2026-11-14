import Foundation

extension CefRuntime.Configuration {
    /// An extension the app installs in Chrome-style profiles: one from the
    /// Chrome Web Store, downloaded in the background; a packed `.crx` the
    /// app ships; or an unpacked directory, loaded as a developer's would
    /// be. See ``CefRuntime/Configuration/extensions``.
    ///
    /// The library ships no extension; these are the app's.
    public struct Extension: Sendable, Hashable {
        enum Source: Sendable, Hashable {
            case webStore(id: String, updateURL: URL)
            case package(URL, id: String, version: String)
            case unpacked(URL)
        }

        let source: Source

        /// The Chrome Web Store's extension with `id` (the 32 letters in its
        /// store address), downloaded and installed in the background the
        /// first time Chromium starts with it configured, and kept up to
        /// date by Chromium's extension updater. Without a network
        /// connection Chromium tries again at its next start and on its
        /// update schedule. `updateURL` is the store's update service; another
        /// is for a self-hosted extension.
        public static func webStore(
            _ id: String, updateURL: URL = URL(string: "https://clients2.google.com/service/update2/crx")!
        ) -> Extension {
            Extension(source: .webStore(id: id, updateURL: updateURL))
        }

        /// A packed extension the app ships, such as a `.crx` in its bundle's
        /// resources, installed without a download. `id` and `version` must
        /// be the package's own (`cef doctor` checks a bundled one);
        /// Chromium installs the package again when `version` changes.
        public static func package(at url: URL, id: String, version: String) -> Extension {
            Extension(source: .package(url, id: id, version: version))
        }

        /// An unpacked extension directory (with its `manifest.json`), loaded
        /// at every start as `chrome://extensions` "Load unpacked" would.
        /// Chromium lists it as a developer's extension; it is not updated,
        /// and a user who removes it gets it back at the next start.
        public static func unpacked(at directory: URL) -> Extension {
            Extension(source: .unpacked(directory))
        }

        /// The extension's identifier, when the configuration names it:
        /// `nil` for an unpacked directory, whose identifier Chromium derives
        /// from its path or its manifest's `key`.
        public var id: String? {
            switch source {
            case .webStore(let id, _), .package(_, let id, _): id
            case .unpacked: nil
            }
        }

        /// What Chromium's external extension provider reads for this one:
        /// the contents of `External Extensions/<id>.json`.
        var externalPreferences: [String: String]? {
            switch source {
            case .webStore(_, let updateURL): ["external_update_url": updateURL.absoluteString]
            case .package(let url, _, let version): ["external_crx": url.path, "external_version": version]
            case .unpacked: nil
            }
        }
    }
}

/// Writes ``CefRuntime/Configuration/extensions`` where Chromium looks for
/// extensions other programs install: `External Extensions/<id>.json` in its
/// user data directory, the root cache directory, which every profile but
/// incognito ones reads at start-up (Chromium's `ExternalPrefLoader` for
/// `DIR_USER_EXTERNAL_EXTENSIONS`). A file CefKit wrote for an extension no
/// longer configured is removed, and Chromium then uninstalls the
/// extension, as it does when another program withdraws one.
enum CefExternalExtensions {
    static let directoryName = "External Extensions"
    /// The identifiers CefKit wrote files for, so that it removes only its own.
    static let ledgerName = ".cefswift-extensions"

    static func write(_ extensions: [CefRuntime.Configuration.Extension], rootCache: URL) {
        let directory = rootCache.appendingPathComponent(directoryName)
        let ledger = directory.appendingPathComponent(ledgerName)
        let written = ((try? String(contentsOf: ledger, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        var configured: [String] = []
        for item in extensions {
            guard let id = item.id, isValidIdentifier(id), let preferences = item.externalPreferences,
                  let data = try? JSONSerialization.data(withJSONObject: preferences, options: [.sortedKeys])
            else { continue }
            configured.append(id)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(id).json")
            if (try? Data(contentsOf: file)) != data { try? data.write(to: file, options: .atomic) }
        }
        for id in written where !configured.contains(id) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
        }
        if configured.isEmpty {
            try? FileManager.default.removeItem(at: ledger)
        } else {
            try? Data(configured.joined(separator: "\n").utf8).write(to: ledger, options: .atomic)
        }
    }

    /// Chromium's extension identifiers: 32 letters from `a` to `p`.
    static func isValidIdentifier(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
    }
}
