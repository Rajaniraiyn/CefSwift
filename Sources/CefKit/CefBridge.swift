import CCef
import Foundation

/// JS ↔ Swift function bridge, built on the reserved `cefswift://` scheme.
///
/// Register Swift functions by name; page JavaScript calls them through a
/// small shim (`window.cefSwift.invoke(name, params) → Promise`):
///
/// ```swift
/// // Swift (any time after CefRuntime.initialize):
/// struct Greeting: Codable { let message: String }
/// struct Person: Codable { let name: String }
/// CefRuntime.shared.bridge.register("greet") { (person: Person) in
///     Greeting(message: "Hello, \(person.name)!")
/// }
/// ```
///
/// ```js
/// // JavaScript:
/// const reply = await window.cefSwift.invoke('greet', { name: 'Ada' });
/// console.log(reply.message); // "Hello, Ada!"
/// ```
///
/// Mechanics: the shim POSTs to `cefswift://bridge/<name>`; the reserved
/// `cefswift` custom scheme (standard | secure | corsEnabled | fetchEnabled)
/// is registered in every process automatically, and its handler dispatches
/// to your registered functions. Responses are JSON.
///
/// **Shim injection.** When ``autoInjectsShim`` is `true` (the default) the
/// shim is injected into every page at `onLoadEnd` — *after* the page's own
/// scripts started running, so early page code must wait for
/// `window.cefSwift` to appear. For production, embed
/// ``javascriptShim`` in your own pages (e.g. a `<script>` tag served by a
/// ``CefBundleSchemeHandler``) and set ``autoInjectsShim`` to `false`.
///
/// **Security.** Bridge functions run with full app privileges and are
/// callable by *any* page loaded in any browser of this app — treat every
/// payload as untrusted input, validate it, and never expose dangerous
/// primitives ("run shell command") directly. See `docs/configuration.md`
/// (JS ↔ Swift bridge).
public final class CefBridge: @unchecked Sendable {
    /// The reserved bridge scheme name.
    public static let schemeName = "cefswift"
    /// The host the shim targets: `cefswift://bridge/<function>`.
    static let bridgeHost = "bridge"
    /// The scheme declaration CefSwift registers automatically.
    static let customScheme = CefCustomScheme(
        name: schemeName,
        options: [.standard, .secure, .corsEnabled, .fetchEnabled]
    )

    /// A raw bridge function: request body bytes in, response bytes out
    /// (the typed `register` overload wraps this with Codable + JSON).
    public typealias RawHandler = @Sendable (Data) async throws -> Data

    private let lock = NSLock()
    private var handlers: [String: RawHandler] = [:]
    private var _autoInjectsShim = true

    init() {}

    /// Whether ``javascriptShim`` is injected into every page when it
    /// finishes loading (only while at least one function is registered).
    /// Late injection misses page-load-time JS — see the type docs.
    public var autoInjectsShim: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _autoInjectsShim }
        set { lock.lock(); defer { lock.unlock() }; _autoInjectsShim = newValue }
    }

    /// Whether any bridge function is registered.
    var hasRegisteredFunctions: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !handlers.isEmpty
    }

    /// Registers (or replaces) a raw bridge function.
    /// - Parameters:
    ///   - name: the function name JS passes to `cefSwift.invoke`.
    ///   - handler: receives the request body verbatim; its returned bytes
    ///     are sent back as `application/json`. Thrown errors become HTTP
    ///     500 responses whose body is the error description.
    public func register(_ name: String, handler: @escaping RawHandler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[name] = handler
    }

    /// Registers a typed bridge function: the JS params object is decoded as
    /// `Input` JSON and the result is encoded back as JSON.
    public func register<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        _ name: String,
        handler: @escaping @Sendable (Input) async throws -> Output
    ) {
        register(name) { body in
            let input = try JSONDecoder().decode(Input.self, from: body)
            let output = try await handler(input)
            return try JSONEncoder().encode(output)
        }
    }

    /// Removes a registered function.
    public func unregister(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers[name] = nil
    }

    // MARK: Dispatch (pure logic; exercised directly by unit tests)

    /// Extracts the function name from a bridge request URL
    /// (`cefswift://bridge/<name>`), or nil for malformed/foreign URLs.
    static func functionName(for url: URL?) -> String? {
        guard let url,
              url.scheme == schemeName,
              url.host() == bridgeHost
        else { return nil }
        let name = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return name.removingPercentEncoding ?? name
    }

    /// Synchronous, lock-scoped handler lookup (NSLock is not usable
    /// directly from async contexts).
    private func handler(named name: String) -> RawHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[name]
    }

    /// Dispatches one bridge request to its registered function and shapes
    /// the scheme response (CORS headers included so fetch() from any page
    /// origin works).
    func dispatch(_ request: CefSchemeRequest) async -> CefSchemeResponse {
        var corsHeaders = [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
        ]
        // CORS preflight (fetch sends one when the page sets content-type).
        if request.method.uppercased() == "OPTIONS" {
            return CefSchemeResponse(status: 204, headers: corsHeaders, mimeType: "text/plain", body: Data())
        }
        corsHeaders.removeValue(forKey: "Access-Control-Allow-Methods")
        corsHeaders.removeValue(forKey: "Access-Control-Allow-Headers")

        guard let name = Self.functionName(for: request.url) else {
            return CefSchemeResponse(
                status: 400, headers: corsHeaders, mimeType: "text/plain",
                body: Data("Malformed bridge URL: \(request.urlString)".utf8))
        }
        guard let handler = handler(named: name) else {
            return CefSchemeResponse(
                status: 404, headers: corsHeaders, mimeType: "text/plain",
                body: Data("No bridge function registered for '\(name)'".utf8))
        }
        do {
            let result = try await handler(request.body ?? Data())
            return CefSchemeResponse(status: 200, headers: corsHeaders, mimeType: "application/json", body: result)
        } catch {
            return CefSchemeResponse(
                status: 500, headers: corsHeaders, mimeType: "text/plain",
                body: Data(String(describing: error).utf8))
        }
    }

    // MARK: JavaScript shim

    /// The page-side shim defining `window.cefSwift.invoke(name, params)`.
    /// Inject it yourself (recommended: serve it inside your pages) or rely
    /// on ``autoInjectsShim``. Idempotent.
    public static let javascriptShim = """
        (function () {
          if (window.cefSwift && window.cefSwift.invoke) { return; }
          window.cefSwift = {
            invoke: function (name, params) {
              return fetch('cefswift://bridge/' + encodeURIComponent(name), {
                method: 'POST',
                body: params === undefined ? '' : JSON.stringify(params)
              }).then(function (response) {
                return response.text().then(function (text) {
                  if (!response.ok) {
                    throw new Error('cefSwift.invoke(' + name + ') failed (' + response.status + '): ' + text);
                  }
                  var contentType = response.headers.get('Content-Type') || '';
                  if (contentType.indexOf('application/json') !== -1 && text.length) {
                    return JSON.parse(text);
                  }
                  return text;
                });
              });
            }
          };
        })();
        """
}

/// The ``CefSchemeHandler`` serving `cefswift://bridge/*`.
struct CefBridgeSchemeHandler: CefSchemeHandler {
    let bridge: CefBridge

    func response(for request: CefSchemeRequest) async -> CefSchemeResponse {
        await bridge.dispatch(request)
    }
}
