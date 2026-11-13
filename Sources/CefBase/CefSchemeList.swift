import CCef

/// The custom URL schemes every process registers, and how the browser
/// process hands them to helpers: CEF does not pass app-registered schemes
/// on, so the browser process adds `--cefswift-schemes=name:options,…` to
/// each child's command line.
package enum CefSchemeList {
    package typealias Entry = (name: String, options: Int32)

    /// The switch's name, without dashes.
    package static let switchName = "cefswift-schemes"

    /// Encodes `entries` as the switch value.
    package static func encode(_ entries: [Entry]) -> String {
        entries.map { "\($0.name):\($0.options)" }.joined(separator: ",")
    }

    /// Reads a switch value, skipping malformed entries.
    package static func decode(_ value: String) -> [Entry] {
        value.split(separator: ",").compactMap { entry in
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, let options = Int32(parts[1]) else { return nil }
            return (String(parts[0]), options)
        }
    }

    /// The list a helper's command line carries; empty without the switch.
    package static func entries(inArguments arguments: [String]) -> [Entry] {
        let prefix = "--\(switchName)="
        return arguments.first { $0.hasPrefix(prefix) }.map { decode(String($0.dropFirst(prefix.count))) } ?? []
    }

    /// Registers `entries` from `on_register_custom_schemes`. The registrar
    /// is not reference-counted and is valid only during that call.
    package static func register(_ entries: [Entry], with registrar: UnsafeMutablePointer<cef_scheme_registrar_t>) {
        for entry in entries {
            _ = CefStringUtil.withCefString(entry.name) { registrar.pointee.add_custom_scheme(registrar, $0, entry.options) }
        }
    }
}
