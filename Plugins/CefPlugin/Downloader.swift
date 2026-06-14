import Foundation

/// SHA-1 of a file via `/usr/bin/shasum -a 1`.
private func sha1(of file: URL) throws -> String {
    let result = try Shell.runChecked(
        "/usr/bin/shasum", ["-a", "1", file.path],
        hint: "shasum is part of macOS; if this fails the downloaded file may be unreadable."
    )
    guard let hash = result.stdout.split(separator: " ").first else {
        throw CefPluginError("Could not parse shasum output for \(file.path).")
    }
    return String(hash)
}

/// Downloads, verifies, extracts and prepares a pinned CEF binary distribution
/// under `<packageRoot>/.cef/` (gitignored).
///
/// Layout:
///   .cef/downloads/<artifact name>.tar.bz2        — resumable curl target
///   .cef/dist/<cefVersion>_<platform>_<flavor>/   — extracted distro (tar --strip-components=1)
///   .cef/dist/<...>/.ok                           — marker written after successful
///                                                   extraction + framework conversion
struct Downloader {
    static let baseURL = "https://cef-builds.spotifycdn.com"

    let cacheRoot: URL       // <packageRoot>/.cef

    var downloadsDirectory: URL { cacheRoot.appendingPathComponent("downloads") }
    var distDirectory: URL { cacheRoot.appendingPathComponent("dist") }

    func distURL(cefVersion: String, platform: String, flavor: String) -> URL {
        distDirectory.appendingPathComponent("\(cefVersion)_\(platform)_\(flavor)")
    }

    /// The converted framework inside a prepared dist directory.
    func frameworkURL(in dist: URL) -> URL {
        dist.appendingPathComponent("Release/Chromium Embedded Framework.framework")
    }

    func isPrepared(dist: URL) -> Bool {
        FileManager.default.fileExists(atPath: dist.appendingPathComponent(".ok").path)
    }

    /// Ensures the distribution is downloaded, sha1-verified, extracted and the
    /// framework converted to versioned layout. Idempotent: returns immediately
    /// when the `.ok` marker is present.
    @discardableResult
    func ensure(manifest: CefManifest, platform: String, flavor: String) throws -> URL {
        let artifact = try manifest.artifact(platform: platform, flavor: flavor)
        let dist = distURL(cefVersion: manifest.cef, platform: platform, flavor: flavor)

        if isPrepared(dist: dist) {
            print("[cef] Distribution already prepared: \(dist.path)")
            return dist
        }

        let fm = FileManager.default
        try fm.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: distDirectory, withIntermediateDirectories: true)

        let tarball = downloadsDirectory.appendingPathComponent(artifact.name)
        try download(artifact: artifact, to: tarball)
        try verify(artifact: artifact, tarball: tarball)
        try extract(tarball: tarball, to: dist)
        try FrameworkLayout.convertToVersionedBundle(framework: frameworkURL(in: dist))

        // Marker last: only a fully extracted *and* converted dist counts.
        try Data().write(to: dist.appendingPathComponent(".ok"))
        print("[cef] Prepared \(dist.path)")
        return dist
    }

    /// Downloads (or resumes) the tarball with curl. Skips when an existing
    /// file already has the expected sha1.
    private func download(artifact: CefManifest.Artifact, to tarball: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: tarball.path) {
            if (try? sha1(of: tarball)) == artifact.sha1 {
                print("[cef] Using cached download: \(tarball.lastPathComponent)")
                return
            }
            let size = ((try? fm.attributesOfItem(atPath: tarball.path))?[.size] as? Int) ?? 0
            if size >= artifact.size {
                // Complete-sized but wrong hash → corrupt; start over.
                print("[cef] Cached download is corrupt, re-downloading…")
                try fm.removeItem(at: tarball)
            } else {
                print("[cef] Resuming partial download (\(tarball.lastPathComponent))…")
            }
        }

        // '+' must be percent-encoded in the CDN path.
        let encodedName = artifact.name.replacingOccurrences(of: "+", with: "%2B")
        let url = "\(Self.baseURL)/\(encodedName)"
        print("[cef] Downloading \(url)")
        print("[cef] (\(artifact.size / 1_000_000) MB — this can take a while)")

        let status = try Shell.runStreaming("/usr/bin/curl", [
            "--fail", "--location", "--retry", "3",
            "--continue-at", "-",          // resume
            "--progress-bar",
            "--output", tarball.path,
            url,
        ])
        // curl exits 33 / HTTP 416 when resuming an already-complete file.
        if status != 0 {
            if fm.fileExists(atPath: tarball.path),
               (try? sha1(of: tarball)) == artifact.sha1 {
                return
            }
            throw CefPluginError(
                "curl failed with exit code \(status) downloading \(url). " +
                "Check your network connection, and make sure the plugin was granted network access: " +
                "swift package --allow-writing-to-package-directory --allow-network-connections all cef download"
            )
        }
    }

    private func verify(artifact: CefManifest.Artifact, tarball: URL) throws {
        print("[cef] Verifying sha1…")
        let actual = try sha1(of: tarball)
        guard actual == artifact.sha1 else {
            try? FileManager.default.removeItem(at: tarball)
            throw CefPluginError(
                "sha1 mismatch for \(tarball.lastPathComponent): expected \(artifact.sha1), got \(actual). " +
                "The corrupt file was deleted — run the download again. If it keeps failing, the manifest " +
                "(CEF_VERSION.json) may be stale; re-run Scripts/cef-update.sh."
            )
        }
    }

    /// Extracts into a temp sibling, then atomically renames into place so a
    /// half-extracted dist directory never masquerades as complete.
    private func extract(tarball: URL, to dist: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dist.path) {
            try fm.removeItem(at: dist) // incomplete leftover (no .ok marker)
        }
        let staging = distDirectory.appendingPathComponent(".tmp-\(dist.lastPathComponent)")
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        print("[cef] Extracting \(tarball.lastPathComponent)…")
        let status = try Shell.runStreaming("/usr/bin/tar", [
            "xjf", tarball.path,
            "-C", staging.path,
            "--strip-components", "1",   // drop the cef_binary_<…> top directory
        ])
        guard status == 0 else {
            try? fm.removeItem(at: staging)
            throw CefPluginError(
                "tar failed with exit code \(status) extracting \(tarball.path). " +
                "The archive may be corrupt — run 'swift package cef clean' and download again."
            )
        }
        try fm.moveItem(at: staging, to: dist)
    }
}
