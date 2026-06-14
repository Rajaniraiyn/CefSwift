import Foundation

/// Error thrown by every plugin code path. Each message states what went wrong
/// *and* how to fix it (Apple-quality diagnostics).
struct CefPluginError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) { self.message = message }
}

/// Thin wrapper over Foundation `Process` for the handful of system tools the
/// plugin shells out to (`curl`, `tar`, `codesign`, `shasum`, `cp`, `swift`).
enum Shell {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `tool` with `arguments`, capturing stdout/stderr.
    @discardableResult
    static func run(
        _ tool: String,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw CefPluginError(
                "Could not launch '\(tool)': \(error.localizedDescription). " +
                "Verify the tool exists at that path (it ships with macOS / the Command Line Tools)."
            )
        }
        // Read concurrently to avoid pipe-buffer deadlock on large output.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Runs `tool`, streaming its output straight to the user's terminal
    /// (used for `curl` progress bars and `tar`).
    static func runStreaming(
        _ tool: String,
        _ arguments: [String],
        currentDirectory: URL? = nil
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        // Inherit stdio so progress renders live.
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            throw CefPluginError(
                "Could not launch '\(tool)': \(error.localizedDescription). " +
                "Verify the tool exists at that path (it ships with macOS / the Command Line Tools)."
            )
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs a tool and throws a descriptive error when it exits non-zero.
    @discardableResult
    static func runChecked(
        _ tool: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        hint: String? = nil
    ) throws -> Result {
        let result = try run(tool, arguments, currentDirectory: currentDirectory)
        guard result.exitCode == 0 else {
            var message = "'\(tool) \(arguments.joined(separator: " "))' failed with exit code \(result.exitCode)."
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty { message += "\n  stderr: \(stderr)" }
            if let hint { message += "\n  Hint: \(hint)" }
            throw CefPluginError(message)
        }
        return result
    }

}
