import Foundation

/// Converts the flat `Chromium Embedded Framework.framework` in CEF binary
/// distributions to the versioned bundle layout Xcode 26 and codesign
/// require, as the distribution's README.txt describes:
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
    static let topLevelEntries = [frameworkName, "Libraries", "Resources"]

    /// Converts in place. A framework that already has `Versions/` is left
    /// as it is.
    static func convertToVersionedBundle(framework: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: framework.path) else {
            throw BundlingError(
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
                throw BundlingError(
                    "Expected '\(entry)' inside \(framework.path) but it is missing. " +
                    "The distribution may be corrupt — run 'swift package cef clean' and download again."
                )
            }
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

    /// Checks that the framework binary resolves through the symlinks.
    static func validate(framework: URL) throws {
        let binary = framework.appendingPathComponent(frameworkName)
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw BundlingError(
                "Framework binary does not resolve at \(binary.path). " +
                "The versioned-bundle symlinks are broken — run 'swift package cef clean' and download again."
            )
        }
    }
}
