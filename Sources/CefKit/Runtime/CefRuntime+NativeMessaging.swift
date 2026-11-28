import Foundation

extension CefRuntime.Configuration {
    /// Where Google Chrome and Chromium keep the native messaging hosts
    /// other apps install for them, per user and for the whole Mac: the
    /// `NativeMessagingHosts` directories of Google Chrome, Chrome Beta,
    /// Dev and Canary and Chromium in `~/Library/Application Support`, and
    /// Google Chrome's in `/Library/Google/Chrome`. Password managers
    /// (1Password, Bitwarden) and other desktop apps write their hosts'
    /// manifests there. The ``chrome`` preset's
    /// ``nativeMessagingHostDirectories``.
    public static var chromeNativeMessagingHostDirectories: [URL] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let user = ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Dev", "Google/Chrome Canary", "Chromium"]
            .map { support.appendingPathComponent($0, isDirectory: true).appendingPathComponent("NativeMessagingHosts", isDirectory: true) }
        return user + [URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true)]
    }
}

/// Makes the native messaging hosts in
/// ``CefRuntime/Configuration/nativeMessagingHostDirectories`` visible to
/// Chromium, which looks for a host's manifest, `<name>.json`, only in
/// `NativeMessagingHosts` in its user data directory (the root cache
/// directory, `DIR_USER_NATIVE_MESSAGING`) and in
/// `/Library/Application Support/Chromium/NativeMessagingHosts`.
///
/// Each manifest in a configured directory gets a symbolic link of the same
/// name in the root cache directory's `NativeMessagingHosts`, so that a host
/// that rewrites its manifest (a password manager's update moving its
/// binary) is followed. The first directory listed wins a name; a file the
/// app put there itself is never replaced. Links CefKit made for manifests
/// no longer found are removed, so a host the user uninstalled disappears
/// at the next start.
enum CefNativeMessagingHosts {
    static let directoryName = "NativeMessagingHosts"
    /// The names CefKit made links for, so that it removes only its own.
    static let ledgerName = ".cefswift-hosts"

    static func link(_ sources: [URL], rootCache: URL) {
        let fileManager = FileManager.default
        let directory = rootCache.appendingPathComponent(directoryName, isDirectory: true)
        let ledger = directory.appendingPathComponent(ledgerName)
        let linked = Set(((try? String(contentsOf: ledger, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init))

        // The first directory that has a name wins it.
        var chosen: [(name: String, manifest: URL)] = []
        var names = Set<String>()
        for source in sources {
            let entries = (try? fileManager.contentsOfDirectory(
                at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for manifest in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where manifest.pathExtension == "json" {
                let name = manifest.deletingPathExtension().lastPathComponent
                guard isValidName(name), !names.contains(name) else { continue }
                names.insert(name)
                chosen.append((name, manifest.resolvingSymlinksInPath()))
            }
        }

        var made: [String] = []
        for (name, manifest) in chosen {
            let file = directory.appendingPathComponent("\(name).json")
            let existing = try? fileManager.destinationOfSymbolicLink(atPath: file.path)
            if existing == manifest.path {
                made.append(name)
                continue
            }
            // Only CefKit's own links are replaced: a manifest the app wrote
            // there, or a link it made, stays.
            if fileExistsOrIsLink(file) {
                guard linked.contains(name), existing != nil else { continue }
                try? fileManager.removeItem(at: file)
            }
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? fileManager.createSymbolicLink(atPath: file.path, withDestinationPath: manifest.path)) != nil {
                made.append(name)
            }
        }
        for name in linked where !made.contains(name) {
            let file = directory.appendingPathComponent("\(name).json")
            if (try? fileManager.destinationOfSymbolicLink(atPath: file.path)) != nil {
                try? fileManager.removeItem(at: file)
            }
        }
        if made.isEmpty {
            try? fileManager.removeItem(at: ledger)
        } else {
            try? Data(made.sorted().joined(separator: "\n").utf8).write(to: ledger, options: .atomic)
        }
    }

    /// Whether a file, or a link (even a dangling one), is at `url`.
    private static func fileExistsOrIsLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// Chromium's rule for host names (`NativeMessagingHostManifest::IsValidName`):
    /// lowercase letters, digits, `_` and `.`, with no dot first, last or
    /// next to another.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.first != ".", name.last != ".", !name.contains("..") else { return false }
        return name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "."
        }
    }
}
