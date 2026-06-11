import Foundation

/// Converts the flat "Chromium Embedded Framework.framework" that ships in CEF
/// binary distributions into the versioned bundle layout required by newer
/// Xcode releases (Xcode 26), exactly per the distro README.txt:
///
///   Chromium Embedded Framework.framework
///   ├── Chromium Embedded Framework -> Versions/A/Chromium Embedded Framework
///   ├── Libraries                   -> Versions/A/Libraries
///   ├── Resources                   -> Versions/A/Resources
///   └── Versions
///      ├── A   (actual framework contents)
///      │   ├── Chromium Embedded Framework
///      │   ├── Libraries
///      │   └── Resources
///      └── Current -> A
enum FrameworkLayout {
    static let frameworkName = "Chromium Embedded Framework"
    static let topLevelEntries = ["Chromium Embedded Framework", "Libraries", "Resources"]

    /// Converts in place. Idempotent: a framework that already has `Versions/`
    /// is left untouched.
    static func convertToVersionedBundle(framework: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: framework.path) else {
            throw CefPluginError(
                "Framework not found at \(framework.path). The extracted distribution is incomplete — " +
                "run 'swift package cef clean' and then 'swift package cef download' again."
            )
        }

        let versions = framework.appendingPathComponent("Versions")
        if fm.fileExists(atPath: versions.path) {
            return // already converted
        }

        let versionA = versions.appendingPathComponent("A")
        try fm.createDirectory(at: versionA, withIntermediateDirectories: true)

        for entry in topLevelEntries {
            let source = framework.appendingPathComponent(entry)
            guard fm.fileExists(atPath: source.path) else {
                throw CefPluginError(
                    "Expected '\(entry)' inside \(framework.path) but it is missing. " +
                    "The distribution may be corrupt — run 'swift package cef clean' and download again."
                )
            }
            // Move real contents into Versions/A, then leave a relative symlink behind.
            try fm.moveItem(at: source, to: versionA.appendingPathComponent(entry))
            try fm.createSymbolicLink(
                atPath: source.path,
                withDestinationPath: "Versions/A/\(entry)"
            )
        }

        try fm.createSymbolicLink(
            atPath: versions.appendingPathComponent("Current").path,
            withDestinationPath: "A"
        )
    }

    /// Sanity check used before bundling: the framework binary must resolve
    /// through the symlink structure.
    static func validate(framework: URL) throws {
        let binary = framework.appendingPathComponent(frameworkName)
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw CefPluginError(
                "Framework binary does not resolve at \(binary.path). " +
                "The versioned-bundle symlinks are broken — run 'swift package cef clean' and download again."
            )
        }
    }
}
