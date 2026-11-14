import Foundation

/// Builds a directory beside its destination and moves it into place only
/// once it is complete, so a build that fails leaves the previous one as
/// it was.
enum StagedDirectory {
    /// Calls `build` with a path in a sibling staging directory, then
    /// replaces `destination` with what it made. The staging directory is
    /// removed either way.
    static func replace(_ destination: URL, build: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // In the same directory, so the move is a rename on one volume.
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        try build(staged)
        guard fm.fileExists(atPath: staged.path) else {
            throw BundlingError("Nothing was assembled at \(staged.path).")
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }
}
