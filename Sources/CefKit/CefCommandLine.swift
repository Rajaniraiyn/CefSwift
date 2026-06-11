import CCef
import Foundation

/// Minimal wrapper over `cef_command_line_t`, surfaced through
/// ``CefConfiguration/onBeforeCommandLineProcessing``. The wrapper borrows
/// the underlying object for the duration of the callback — do not store it.
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
                    raw.pointee.append_switch_with_value?(raw, cefName, cefValue)
                }
            } else {
                raw.pointee.append_switch?(raw, cefName)
            }
        }
    }

    /// Returns true if the switch is present.
    public func hasSwitch(_ name: String) -> Bool {
        CefStringUtil.withCefString(name) { cefName in
            raw.pointee.has_switch?(raw, cefName) != 0
        }
    }

    /// Returns the value of `--name=value`, or nil when absent/valueless.
    public func switchValue(_ name: String) -> String? {
        CefStringUtil.withCefString(name) { cefName in
            CefStringUtil.takingUserFree(raw.pointee.get_switch_value?(raw, cefName))
                .flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Appends a positional argument.
    public func appendArgument(_ argument: String) {
        CefStringUtil.withCefString(argument) { cefArg in
            raw.pointee.append_argument?(raw, cefArg)
        }
    }

    /// The full command line as a single string (for diagnostics).
    public var commandLineString: String {
        CefStringUtil.takingUserFree(raw.pointee.get_command_line_string?(raw)) ?? ""
    }
}
