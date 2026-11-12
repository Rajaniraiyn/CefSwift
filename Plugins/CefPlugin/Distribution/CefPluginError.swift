/// An error whose message says what went wrong and how to fix it.
struct CefPluginError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    init(_ message: String) { self.message = message }
}
