import Foundation

/// `cef package` and `cef notarize`: wraps a signed app in a zip or disk
/// image, sends it to Apple's notary service with `notarytool`, and
/// staples the ticket. Follows Apple's "Customizing the notarization
/// workflow".
enum Notarizer {
    enum Format: String {
        case zip, dmg
    }

    /// Writes `<App>.zip` (with `ditto`, which keeps the bundle's symlinks
    /// and extended attributes) or `<App>.dmg` (with `hdiutil`, signed with
    /// `identity` when given) next to the app, or into `output`.
    static func package(_ app: URL, format: Format, output: URL?, identity: String?, keychain: String?) throws -> URL {
        let name = app.deletingPathExtension().lastPathComponent
        let directory = output ?? app.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("\(name).\(format.rawValue)")
        try? FileManager.default.removeItem(at: archive)
        switch format {
        case .zip:
            try Shell.runChecked(
                "/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, archive.path],
                hint: "Could not create \(archive.path).")
        case .dmg:
            try Shell.runChecked(
                "/usr/bin/hdiutil",
                ["create", "-volname", name, "-srcfolder", app.path, "-ov", "-format", "UDZO", archive.path],
                hint: "Could not create \(archive.path) with hdiutil. SwiftPM's plugin sandbox keeps hdiutil " +
                    "from attaching disk images; run the command above in Terminal, or use --format zip.")
            if let identity, identity != "-" {
                var arguments = ["--force", "--sign", identity, "--timestamp"]
                if let keychain { arguments += ["--keychain", keychain] }
                try Shell.runChecked("/usr/bin/codesign", arguments + [archive.path],
                                     hint: "Could not sign \(archive.lastPathComponent) with '\(identity)'.")
            }
        }
        print("[cef] Created \(archive.path)")
        return archive
    }

    /// Submits `archive`, waits for the result, and staples the ticket to
    /// `app` (for a zip, whose contents are what users run) or to the disk
    /// image.
    static func notarize(archive: URL, app: URL, keychainProfile: String) throws {
        print("[cef] Submitting \(archive.lastPathComponent) to Apple's notary service (this takes minutes)…")
        let submit = try Shell.run("/usr/bin/xcrun", [
            "notarytool", "submit", archive.path, "--keychain-profile", keychainProfile,
            "--wait", "--output-format", "json",
        ])
        let response = (try? JSONSerialization.jsonObject(with: Data(submit.stdout.utf8))) as? [String: Any]
        let status = response?["status"] as? String
        let id = response?["id"] as? String
        guard submit.exitCode == 0, status == "Accepted" else {
            var message = "Notarization did not succeed (status: \(status ?? "unknown"))."
            if let id {
                let log = try? Shell.run("/usr/bin/xcrun", [
                    "notarytool", "log", id, "--keychain-profile", keychainProfile,
                ])
                if let log, log.exitCode == 0 { message += "\nNotary log:\n\(log.stdout)" }
                message += "\nSee the log again with: xcrun notarytool log \(id) --keychain-profile \(keychainProfile)"
            }
            let stderr = submit.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty { message += "\n\(stderr)" }
            message += "\nCheck that the app is signed with Developer ID, the hardened runtime and a secure " +
                "timestamp (swift package cef doctor \(app.path)), and that the keychain profile exists " +
                "(xcrun notarytool store-credentials \(keychainProfile))."
            throw BundlingError(message)
        }
        print("[cef] Accepted (submission \(id ?? "?")).")

        let target = archive.pathExtension == "dmg" ? archive : app
        try Shell.runChecked("/usr/bin/xcrun", ["stapler", "staple", target.path],
                             hint: "The ticket exists but could not be stapled; Gatekeeper still finds it online.")
        try Shell.runChecked("/usr/bin/xcrun", ["stapler", "validate", target.path],
                             hint: "The stapled ticket does not validate.")
        print("[cef] Stapled the ticket to \(target.lastPathComponent).")
        if archive.pathExtension == "zip" {
            // The submitted zip holds the unstapled app; replace it.
            _ = try package(app, format: .zip, output: archive.deletingLastPathComponent(), identity: nil, keychain: nil)
        }
    }
}
