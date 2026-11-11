import CCef
import Foundation

/// The command line Chromium is about to process, passed to
/// ``CefConfiguration/onBeforeCommandLineProcessing``. Valid only during
/// that call; do not keep it.
public struct CefCommandLine: @unchecked Sendable {
    let raw: UnsafeMutablePointer<cef_command_line_t>

    init(raw: UnsafeMutablePointer<cef_command_line_t>) {
        self.raw = raw
    }

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
    public func switchValue(_ name: String) -> String? {
        CefStringUtil.withCefString(name) { cefName in
            CefStringUtil.takingUserFree(raw.pointee.get_switch_value(raw, cefName))
                .flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Adds `values` to a comma-separated list switch such as
    /// `--enable-features`, keeping whatever is already there.
    public func mergeList(_ name: String, adding values: Set<String>) {
        guard !values.isEmpty else { return }
        let existing = switchValue(name)?.split(separator: ",").map(String.init) ?? []
        let merged = existing + values.subtracting(existing).sorted()
        appendSwitch(name, value: merged.joined(separator: ","))
    }

    /// Appends a positional argument.
    public func appendArgument(_ argument: String) {
        CefStringUtil.withCefString(argument) { cefArg in
            raw.pointee.append_argument(raw, cefArg)
        }
    }

    /// The whole command line as one string, for diagnostics.
    public var commandLineString: String {
        CefStringUtil.takingUserFree(raw.pointee.get_command_line_string(raw)) ?? ""
    }
}
