import Foundation

/// Progress, warnings and errors, in the form the caller reads: `[cef] …`
/// lines for `swift package cef`, and the `error:` / `warning:` lines with
/// an optional `file:line:` that Xcode puts in its Issue navigator for the
/// Xcode build phase.
enum Log {
    enum Style: Sendable { case plugin, xcode }

    /// Set once, by the command, before anything is printed.
    nonisolated(unsafe) static var style: Style = .plugin

    /// Leaves out `info` and `warning` lines, for settings resolved a
    /// second time.
    nonisolated(unsafe) static var isQuiet = false

    static func info(_ message: String) {
        guard !isQuiet else { return }
        print("[cef] \(message)")
        fflush(stdout)
    }

    static func warning(_ message: String, file: URL? = nil, line: Int? = nil) {
        guard !isQuiet else { return }
        emit("warning", message, file: file, line: line)
    }

    static func error(_ message: String, file: URL? = nil, line: Int? = nil) {
        emit("error", message, file: file, line: line)
    }

    /// `[cef] warning: …`, or for Xcode `<file>:<line>: warning: …`.
    static func format(_ kind: String, _ message: String, file: URL?, line: Int?, style: Style) -> String {
        switch style {
        case .plugin:
            return "[cef] \(kind): \(message)"
        case .xcode:
            var location = ""
            if let file { location = file.path + (line.map { ":\($0)" } ?? "") + ": " }
            return "\(location)\(kind): \(message)"
        }
    }

    private static func emit(_ kind: String, _ message: String, file: URL?, line: Int?) {
        let text = format(kind, message, file: file, line: line, style: style)
        if kind == "error" {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        } else {
            print(text)
        }
        fflush(stdout)
    }

    /// The 1-based line of the first `"key"` in a JSON file, for a
    /// diagnostic that points at it.
    static func line(ofKey key: String, in file: URL) -> Int? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.contains("\"\(key)\"") {
            return index + 1
        }
        return nil
    }
}

/// Command-line options in the form `--name value`, `--name=value` and
/// `--flag`, taken out one at a time, as SwiftPM's `ArgumentExtractor`
/// does for plugins.
struct Arguments {
    private(set) var remaining: [String]

    init(_ arguments: [String]) { remaining = arguments }

    /// Every value of `--name`, in order.
    mutating func options(_ name: String) -> [String] {
        var values: [String] = []
        var index = 0
        while index < remaining.count {
            let argument = remaining[index]
            if argument == "--\(name)", index + 1 < remaining.count {
                values.append(remaining[index + 1])
                remaining.removeSubrange(index...(index + 1))
            } else if argument.hasPrefix("--\(name)=") {
                values.append(String(argument.dropFirst(name.count + 3)))
                remaining.remove(at: index)
            } else {
                index += 1
            }
        }
        return values
    }

    mutating func option(_ name: String) -> String? { options(name).last }

    /// Whether `--name` was given, any number of times.
    mutating func flag(_ name: String) -> Bool {
        let count = remaining.filter { $0 == "--\(name)" }.count
        remaining.removeAll { $0 == "--\(name)" }
        return count > 0
    }

    /// `--name` / `--no-name`: true, false, or nil when neither is given.
    mutating func toggle(_ name: String) throws -> Bool? {
        let on = flag(name)
        let off = flag("no-\(name)")
        if on && off { throw BundlingError("Pass either --\(name) or --no-\(name), not both.") }
        return on ? true : off ? false : nil
    }

    /// The first argument that is not an option, taken out.
    mutating func positional() -> String? {
        guard let index = remaining.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
        return remaining.remove(at: index)
    }

    func rejectLeftovers(usage: String) throws {
        guard remaining.isEmpty else {
            throw BundlingError("Unrecognized arguments: \(remaining.joined(separator: " ")).\n\(usage)")
        }
    }
}
