import Foundation

/// What text typed into the address field, or passed at launch, means.
enum TypedAddress {
    /// Turns typed text into a URL: an address if it looks like one,
    /// otherwise a web search. `nil` for blank text.
    static func destination(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("about:"), let url = URL(string: trimmed) {
            return url
        }
        if !trimmed.contains(" "), trimmed.contains(".") || trimmed.hasPrefix("localhost"),
           let url = URL(string: "https://\(trimmed)") {
            return url
        }
        return searchURL(for: trimmed)
    }

    /// A web search for `query`. Suggested searches use it too, so every
    /// search goes to the same engine whatever Chromium's own default is.
    static func searchURL(for query: String) -> URL? {
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: query)]
        return search.url
    }

    /// A URL from a command-line argument: an address with a scheme, or a
    /// file path that exists. Switches and anything else give `nil`.
    static func url(fromArgument argument: String, relativeTo directory: URL?) -> URL? {
        guard !argument.hasPrefix("-") else { return nil }
        if argument.contains(":"), let url = URL(string: argument), url.scheme != nil { return url }
        let file = URL(fileURLWithPath: argument, relativeTo: directory).absoluteURL
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}
