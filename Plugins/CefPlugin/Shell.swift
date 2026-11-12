import Foundation

/// Runs the system tools the plugin relies on: `curl`, `tar`, `shasum`, `cp`,
/// `codesign`, `security` and `swift`.
enum Shell {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `tool` and captures its output.
    static func run(_ tool: String, _ arguments: [String]) throws -> Result {
        let process = makeProcess(tool, arguments)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try launch(process)

        // Drain stderr on another thread so neither pipe can fill up and
        // block the tool.
        let stderr = Output()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            stderr.data = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: stderr.data, as: UTF8.self)
        )
    }

    /// Runs `tool` with its output going straight to the terminal, so
    /// progress shows as it happens. Returns the exit status.
    static func runStreaming(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = makeProcess(tool, arguments)
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try launch(process)
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Runs `tool` and throws, including its error output and `hint`, if it
    /// fails.
    @discardableResult
    static func runChecked(_ tool: String, _ arguments: [String], hint: String) throws -> Result {
        let result = try run(tool, arguments)
        guard result.exitCode == 0 else {
            var message = "'\(([tool] + arguments).joined(separator: " "))' failed with exit code \(result.exitCode)."
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty { message += "\n  \(stderr)" }
            message += "\n  \(hint)"
            throw CefPluginError(message)
        }
        return result
    }

    private static func makeProcess(_ tool: String, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        return process
    }

    private static func launch(_ process: Process) throws {
        do {
            try process.run()
        } catch {
            throw CefPluginError(
                "Could not run \(process.executableURL?.path ?? "a tool"): \(error.localizedDescription)"
            )
        }
    }

    /// Output read on a background thread; read only after it finishes.
    private final class Output: @unchecked Sendable {
        var data = Data()
    }
}
