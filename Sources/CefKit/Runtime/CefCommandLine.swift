import CCef
import Foundation
import CefBase

/// The command line Chromium is about to process, passed to
/// ``CefRuntime/Configuration/onBeforeCommandLineProcessing``.
///
/// Valid only during that call: CefKit invalidates it when the call
/// returns, and using it afterwards stops the program.
public final class CefCommandLine: CustomStringConvertible {
    /// Chromium's command line; `nil` once the callback has returned.
    private var borrowed: UnsafeMutablePointer<cef_command_line_t>?

    private init(raw: UnsafeMutablePointer<cef_command_line_t>) {
        borrowed = raw
    }

    /// Runs `body` with a wrapper of the borrowed `raw`, which is
    /// invalidated when `body` returns.
    static func borrowing<R>(_ raw: UnsafeMutablePointer<cef_command_line_t>, _ body: (CefCommandLine) -> R) -> R {
        let commandLine = CefCommandLine(raw: raw)
        defer { commandLine.borrowed = nil }
        return body(commandLine)
    }

    private var raw: UnsafeMutablePointer<cef_command_line_t> {
        guard let borrowed else {
            preconditionFailure("CefCommandLine used after the callback that provided it returned")
        }
        return borrowed
    }

    /// Whether the callback that provided it is still running.
    var isValid: Bool { borrowed != nil }

    /// Appends `--name` (or `--name=value` when `value` is non-nil).
    public func appendSwitch(_ name: String, value: String? = nil) {
        CefStringUtil.withCefString(name) { cefName in
            if let value {
                CefStringUtil.withCefString(value) { cefValue in
                    raw.pointee.append_switch_with_value(raw, cefName, cefValue)
                }
            } else {
                raw.pointee.append_switch(raw, cefName)
            }
        }
    }

    /// Whether `--name` is present.
    public func hasSwitch(_ name: String) -> Bool {
        CefStringUtil.withCefString(name) { cefName in
            raw.pointee.has_switch(raw, cefName) != 0
        }
    }

    /// The value of `--name=value`, or `nil` when the switch is absent or
    /// has no value.
    public func value(forSwitch name: String) -> String? {
        CefStringUtil.withCefString(name) { cefName in
            CefStringUtil.takingUserFree(raw.pointee.get_switch_value(raw, cefName))
                .flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Adds `values` to a comma-separated list switch such as
    /// `--enable-features`, keeping whatever is already there.
    public func appendValues(_ values: Set<String>, toListSwitch name: String) {
        guard !values.isEmpty else { return }
        let existing = value(forSwitch: name)?.split(separator: ",").map(String.init) ?? []
        let merged = existing + values.subtracting(existing).sorted()
        appendSwitch(name, value: merged.joined(separator: ","))
    }

    /// Appends a positional argument.
    public func appendArgument(_ argument: String) {
        CefStringUtil.withCefString(argument) { cefArg in
            raw.pointee.append_argument(raw, cefArg)
        }
    }

    /// Every argument, the program first, as Chromium parsed them.
    var argv: [String] {
        cefStrings { raw.pointee.get_argv(raw, $0) }
    }

    /// The whole command line as one string, for diagnostics.
    public var description: String {
        CefStringUtil.takingUserFree(raw.pointee.get_command_line_string(raw)) ?? ""
    }
}

extension CefCommandLine {
    /// The process arguments Chromium should see. Cocoa reads `-Name value`
    /// pairs into `UserDefaults` (Xcode passes `-NSDocumentRevisionsDebugMode
    /// YES`, for instance); Chromium would take each value for a URL to open
    /// in a window of its own, so both halves of such pairs are left out.
    /// Chromium's own `--switches` and anything after `--` pass through.
    static func chromiumArguments(from arguments: [String]) -> [String] {
        guard let executable = arguments.first else { return [] }
        var kept = [executable]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--" {
                kept += arguments[(index - 1)...]
                break
            }
            guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 1 else {
                kept.append(argument)
                continue
            }
            // A Cocoa argument: skip its value too.
            if index < arguments.count, !arguments[index].hasPrefix("-") {
                index += 1
            }
        }
        return kept
    }
}
