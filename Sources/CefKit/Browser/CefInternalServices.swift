import Foundation

/// A Chromium WebUI host whose renderer can reach some of Chromium's
/// internal services.
///
/// Chromium binds a WebUI page's Mojo interfaces, and grants its extension
/// APIs, by the page's host — `chrome://history` gets
/// `history.mojom.PageHandler`, `chrome://bookmarks` gets `chrome.bookmarks`
/// — whatever the path. A renderer that asks for an interface its host does
/// not bind is killed. So a service host loads the smallest document its
/// host serves (`strings.m.js`, a few kilobytes of JavaScript shown as text)
/// instead of the page's app, and imports only the Mojo modules a service
/// needs.
struct CefServiceHost: Hashable, Sendable {
    /// Identifies the host in logs and diagnostics.
    let name: String
    /// The document the hidden browser shows.
    let document: String
    /// Whether Chromium can open the host in an incognito profile. It stops
    /// the process when asked to open one it cannot (`chrome://history`).
    let isAvailableInIncognito: Bool

    /// `chrome.bookmarks`, `chrome.tabs` and `chrome://favicon2`.
    static let bookmarks = CefServiceHost(
        name: "bookmarks", document: "chrome://bookmarks/strings.m.js", isAvailableInIncognito: true)
    /// `history.mojom.PageHandler` and `chrome://favicon2`.
    static let history = CefServiceHost(
        name: "history", document: "chrome://history/strings.m.js", isAvailableInIncognito: false)
    /// `most_visited.mojom.MostVisitedPageHandlerFactory`, on the new tab
    /// page Chromium uses with third-party search engines, whose WebUI
    /// controller does the least work.
    static let mostVisited = CefServiceHost(
        name: "most-visited", document: "chrome://new-tab-page-third-party/strings.m.js",
        isAvailableInIncognito: false)
    /// `mojom.OmniboxPageHandler`, the address bar's autocomplete controller.
    static let omnibox = CefServiceHost(
        name: "omnibox", document: "chrome://omnibox/strings.m.js", isAvailableInIncognito: true)
    /// `discards.mojom.DetailsProvider`, Chromium's tab lifecycle units.
    static let discards = CefServiceHost(
        name: "discards", document: "chrome://discards/strings.m.js", isAvailableInIncognito: true)
}

/// A JavaScript object built once per host document and handed to every
/// call of a service — a bound Mojo remote, or an extension API with its
/// listeners — together with the hosts that can build it.
///
/// Adding a service is declaring one:
///
/// ```swift
/// static let downloads = CefServiceModule(name: "downloads", hosts: [.downloads], setup: """
///     async emit => {
///       const m = await import('chrome://downloads/downloads.mojom-webui.js');
///       ...
///       return { handler };
///     }
///     """)
/// let items = try await profile.services.call(.downloads, "s => s.handler.getDownloads()")
/// ```
struct CefServiceModule: Sendable {
    let name: String
    /// Hosts that can build the module, the one to start first. A call goes
    /// to the first of them that is already running.
    let hosts: [CefServiceHost]
    /// A JavaScript expression evaluating to `async emit => service`.
    /// `emit(name, payload)` delivers an event to ``CefInternalServices/events(_:_:)``.
    let setup: String
}

/// Calls into Chromium's internal services for one profile, from hidden
/// Chrome-style browsers parked on WebUI hosts.
///
/// - A host's browser starts on the first call that needs it, in about a
///   tenth of a second, and closes after ``idleTimeout`` without calls, when
///   macOS reports memory pressure, when the profile's last browser closes
///   (other than the default profile's) and when the app quits.
/// - Each host is one renderer process; Chromium locks WebUI renderers to
///   their host, so hosts cannot share one.
/// - A call that does not finish in time, or a renderer that dies (Chromium
///   kills a page that sends a malformed Mojo message), closes the host's
///   browser; the call throws and the next one starts the host again.
/// - Service browsers are listed in neither ``CefRuntime/browsers`` nor
///   ``CefBrowserWindow/all``. Their windows are 1 × 1 point, so their
///   compositor allocates next to nothing, and never shown.
/// - Their addresses carry the ``addressMarker`` fragment: Chromium saves
///   every Chrome-style window in its session and reopens them after a
///   crash, and ``CefRuntime`` closes the ones it recognizes by it.
@MainActor
final class CefInternalServices {
    /// The fragment that marks a service page's address.
    nonisolated static let addressMarker = "cefswift-service"

    /// Whether `url` is a service page's address — one Chromium reopened
    /// from a previous session, when it does not belong to a live service.
    nonisolated static func isServicePage(_ url: URL) -> Bool {
        // A host closed before it was marked shows its bare document, which
        // no one opens otherwise.
        url.scheme == "chrome" && (url.fragment == addressMarker || url.path == "/strings.m.js")
    }

    /// How long a host stays open after its last call.
    static var idleTimeout: Duration = .seconds(30)

    /// The profile owns its services, and a running host holds the profile.
    unowned let profile: CefProfile

    private var hosts: [CefServiceHost: CefServiceHostBrowser] = [:]

    /// The profile's bookmark state that outlives one ``CefBookmarks``.
    var bookmarkReadSource = CefBookmarks.ReadSource.automatic
    var lastBookmarkWrite: ContinuousClock.Instant?
    private var subscribers: [String: [UUID: AsyncStream<CefJSON>.Continuation]] = [:]

    init(profile: CefProfile) {
        self.profile = profile
        Self.memoryPressure.watch(self)
    }

    // MARK: Calling

    /// Evaluates `function` — a JavaScript expression of the form
    /// `async (service, args) => value` — on `module`'s service object with
    /// `arguments`, and returns its JSON result.
    func call(
        _ module: CefServiceModule, _ function: String, _ arguments: CefJSON = [:], timeout: Duration = .seconds(15)
    ) async throws -> CefJSON {
        let host = try runningHost(for: module)
        return try await host.call(module, function, arguments, timeout: timeout)
    }

    /// Evaluates `function` as ``call(_:_:_:timeout:)`` does and decodes its
    /// result.
    func call<Result: Decodable>(
        _ module: CefServiceModule, _ function: String, _ arguments: CefJSON = [:], as type: Result.Type,
        timeout: Duration = .seconds(15)
    ) async throws -> Result {
        try await call(module, function, arguments, timeout: timeout).decode(Result.self)
    }

    /// Starts `module`'s host, if none is running, and builds the module.
    func prepare(_ module: CefServiceModule) async throws {
        _ = try await call(module, "async () => true")
    }

    /// Events `module` emits as `emit(name, payload)`, while one of its hosts
    /// runs with the module built. Subscribing starts nothing and keeps
    /// nothing running. `bufferingPolicy` matches the events' meaning:
    /// `.bufferingNewest(1)` for invalidations, where only the latest
    /// matters.
    func events(
        _ module: CefServiceModule, _ name: String,
        bufferingPolicy: AsyncStream<CefJSON>.Continuation.BufferingPolicy
    ) -> AsyncStream<CefJSON> {
        let key = "\(module.name)/\(name)"
        let (stream, continuation) = AsyncStream<CefJSON>.makeStream(bufferingPolicy: bufferingPolicy)
        let token = UUID()
        subscribers[key, default: [:]][token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[key]?[token] = nil }
        }
        return stream
    }

    func deliver(module: String, name: String, payload: CefJSON) {
        subscribers["\(module)/\(name)"]?.values.forEach { $0.yield(payload) }
    }

    /// The host to call `module` on: one already running, or the first the
    /// profile can open.
    private func runningHost(for module: CefServiceModule) throws -> CefServiceHostBrowser {
        guard CefRuntime.shared.isInitialized, !CefRuntime.shared.isTerminating else {
            throw CefError.notInitialized
        }
        if let running = module.hosts.lazy.compactMap({ self.hosts[$0] }).first {
            return running
        }
        let available = module.hosts.filter { $0.isAvailableInIncognito || profile.kind != .incognito }
        guard let host = available.first else {
            throw CefError.operationFailed("\(module.name) is not available in an incognito profile")
        }
        let browser = CefServiceHostBrowser(host: host, services: self)
        hosts[host] = browser
        return browser
    }

    // MARK: Lifetime

    /// Whether `host`'s browser is open or opening.
    func isRunning(_ host: CefServiceHost) -> Bool {
        hosts[host] != nil
    }

    /// The names of the hosts open or opening.
    var runningHostNames: [String] {
        hosts.keys.map(\.name).sorted()
    }

    /// Closes every host; the next call starts its host again.
    func stopAll() {
        hosts.values.forEach { $0.stop() }
    }

    /// Closes the hosts without a call in progress.
    func stopIdle() {
        hosts.values.filter(\.isIdle).forEach { $0.stop() }
    }

    /// Kills `host`'s renderer, as a crash would. For tests.
    func crashRenderer(of host: CefServiceHost) async {
        await hosts[host]?.crashRenderer()
    }

    /// A host's browser closed or is closing.
    func hostDidStop(_ browser: CefServiceHostBrowser) {
        if hosts[browser.host] === browser { hosts[browser.host] = nil }
    }

    /// Closes idle hosts of every profile when macOS runs low on memory.
    private static let memoryPressure = MemoryPressureWatch()

    @MainActor
    private final class MemoryPressureWatch {
        private struct Weak { weak var services: CefInternalServices? }
        private var all: [Weak] = []
        private var source: DispatchSourceMemoryPressure?

        func watch(_ services: CefInternalServices) {
            all.removeAll { $0.services == nil }
            all.append(Weak(services: services))
            guard source == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.all.forEach { $0.services?.stopIdle() } }
            }
            source.activate()
            self.source = source
        }
    }
}

/// One host's hidden browser: started on demand, closed when idle.
@MainActor
final class CefServiceHostBrowser {
    let host: CefServiceHost
    private weak var services: CefInternalServices?
    private let profile: CefProfile

    private var window: CefBrowserWindow?
    private var browser: CefBrowser?
    private var starting: Task<CefBrowser, Error>?
    private var events: Task<Void, Never>?
    private var idleStop: Task<Void, Never>?
    private var callsInProgress = 0
    private var isStopped = false
    private let delegate = ServiceBrowserDelegate()

    /// The binding module events reach Swift through.
    private static let eventBinding = "__cefswiftServiceEvent"

    init(host: CefServiceHost, services: CefInternalServices) {
        self.host = host
        self.services = services
        self.profile = services.profile
        delegate.onTerminated = { [weak self] _ in self?.stop() }
    }

    var isIdle: Bool { callsInProgress == 0 }

    func call(
        _ module: CefServiceModule, _ function: String, _ arguments: CefJSON, timeout: Duration
    ) async throws -> CefJSON {
        callsInProgress += 1
        idleStop?.cancel()
        defer {
            callsInProgress -= 1
            if callsInProgress == 0 { scheduleIdleStop() }
        }
        // One deadline over the whole call, starting the host included: an
        // await inside the start-up that never returns must not hold the
        // caller past it.
        let message = "\(module.name) on \(host.name): no answer in \(timeout)"
        return try await withDeadline(timeout, timeoutError: CefError.operationFailed(message)) { [weak self] in
            CefLog.error("service \(message)")
            self?.stop()
        } _: { [self] in
            let browser = try await liveBrowser()
            do {
                return try await browser.evaluateJavaScript(Self.script(module, function, arguments))
            } catch let error as CefJavaScriptError {
                throw CefError.operationFailed("\(module.name): \(error.message)")
            } catch CefError.browserClosed {
                throw CefError.operationFailed("\(module.name): \(host.document) stopped responding")
            }
        }
    }

    /// Builds the module on first use in this document, then calls
    /// `function` with it.
    private static func script(_ module: CefServiceModule, _ function: String, _ arguments: CefJSON) -> String {
        let name = CefJSON.string(module.name).text
        return """
            (async () => {
              const registry = window.__cefswiftServices ??= {};
              const emit = (event, payload) => window.\(eventBinding)?.(
                JSON.stringify({ module: \(name), name: event, payload: payload ?? null }));
              const service = await (registry[\(name)] ??= (\(module.setup))(emit).catch(error => {
                delete registry[\(name)];
                throw error;
              }));
              return await (\(function))(service, \(arguments.text));
            })()
            """
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: CefInternalServices.idleTimeout)
            guard !Task.isCancelled, let self, self.isIdle else { return }
            self.stop()
        }
    }

    private func liveBrowser() async throws -> CefBrowser {
        if let starting { return try await starting.value }
        if let browser, browser.state == .live { return browser }
        guard !isStopped else {
            throw CefError.operationFailed("\(host.document) stopped responding")
        }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func launch() async throws -> CefBrowser {
        var options = CefBrowserOptions()
        options.profile = profile
        let browser = CefBrowser(
            url: URL(string: host.document), options: options, delegate: delegate)
        CefRuntime.shared.registerServiceBrowser(browser)
        var configuration = CefBrowserWindow.Configuration()
        // The compositor sizes its buffers to the window.
        configuration.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        configuration.titleFollowsPage = false
        let window = CefBrowserWindow(browser: browser, configuration: configuration)
        window.isService = true
        window.onClose = { [weak self] in self?.windowDidClose() }
        self.browser = browser
        self.window = window

        try await browser.ready()
        try await listenForEvents(in: browser)
        let deadline = ContinuousClock.now + .seconds(15)
        let document = CefJSON.string(host.document).text
        while ContinuousClock.now < deadline, browser.state == .live, !isStopped {
            let loaded = try? await browser.evaluateJavaScript(
                "document.readyState === 'complete' && location.href.startsWith(\(document))")
            if loaded?.boolValue == true {
                // Marks the address Chromium saves in its session. A WebUI
                // data source fails a load whose address has a fragment or
                // query, so the mark is added once the document is shown.
                _ = try? await browser.evaluateJavaScript(
                    "history.replaceState(null, '', '#\(CefInternalServices.addressMarker)')")
                return browser
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        stop()
        throw CefError.operationFailed("\(host.document) did not load")
    }

    /// Installs the event binding as a page global; the DevTools Protocol
    /// reports its calls once the Runtime domain is enabled.
    private func listenForEvents(in browser: CefBrowser) async throws {
        // Every event is a module's, which the loop below hands on at once.
        let stream = browser.devTools.events("Runtime.bindingCalled", bufferingPolicy: .unbounded)
        try await browser.devTools.send("Runtime.enable")
        try await browser.devTools.send("Runtime.addBinding", ["name": .string(Self.eventBinding)])
        events = Task { [weak self] in
            for await event in stream where event["name"].stringValue == Self.eventBinding {
                guard let text = event["payload"].stringValue, let data = text.data(using: .utf8),
                      let message = try? CefJSON(data: data), let module = message["module"].stringValue,
                      let name = message["name"].stringValue
                else { continue }
                self?.services?.deliver(module: module, name: name, payload: message["payload"])
            }
        }
    }

    /// Closes the browser; calls still waiting fail, and the next call
    /// starts a new host.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        idleStop?.cancel()
        events?.cancel()
        services?.hostDidStop(self)
        if window != nil { retain = self }
        if browser?.state == .live {
            browser?.close(force: true)
        } else {
            // Stopped while Chromium creates the browser, as a call whose
            // deadline passes during start-up is: the window closes it.
            window?.close()
        }
    }

    /// Kills the renderer through the DevTools Protocol.
    func crashRenderer() async {
        _ = try? await browser?.devTools.send("Page.crash")
    }

    /// A closed window still holds its browser, and so the profile, until
    /// Chromium has destroyed it; the host browser stays alive as long.
    private var retain: CefServiceHostBrowser?

    private func windowDidClose() {
        window = nil
        browser = nil
        if !isStopped { stop() }
        retain = nil
    }
}

/// Watches a service browser for a dead renderer, whose pending evaluations
/// would otherwise never finish.
private final class ServiceBrowserDelegate: CefBrowserDelegate {
    var onTerminated: ((CefBrowser) -> Void)?

    func browser(_ browser: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason) {
        onTerminated?(browser)
    }
}
