import CefBase
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
package struct CefServiceHost: Hashable, Sendable {
    /// Identifies the host in logs and diagnostics.
    package let name: String
    /// The document the hidden browser shows.
    package let document: String
    /// Whether Chromium can open the host in an incognito profile. It stops
    /// the process when asked to open one it cannot (`chrome://history`).
    package let isAvailableInIncognito: Bool

    package init(name: String, document: String, isAvailableInIncognito: Bool) {
        self.name = name
        self.document = document
        self.isAvailableInIncognito = isAvailableInIncognito
    }

    /// `discards.mojom.DetailsProvider`, Chromium's tab lifecycle units.
    static let discards = CefServiceHost(
        name: "discards", document: "chrome://discards/strings.m.js", isAvailableInIncognito: true)
}

extension CefServiceHost {
    /// A JavaScript object built once per host document and handed to every
    /// call of a service — a bound Mojo remote, or an extension API with its
    /// listeners — together with the hosts that can build it.
    ///
    /// Adding a service is declaring one, in CefKit or in a module built on it
    /// (CefChromium declares its bookmark, history and omnibox services so):
    ///
    /// ```swift
    /// static let downloads = CefServiceHost.Module(name: "downloads", hosts: [.downloads], setup: """
    ///     async emit => {
    ///       const m = await import('chrome://downloads/downloads.mojom-webui.js');
    ///       ...
    ///       return { handler };
    ///     }
    ///     """)
    /// let items = try await profile.serviceHosts.call(
    ///     .downloads, "s => s.handler.getDownloads()", as: [Download].self)
    /// ```
    package struct Module: Sendable {
        package let name: String
        /// Hosts that can build the module, the one to start first. A call goes
        /// to the first of them that is already running.
        package let hosts: [CefServiceHost]
        /// A JavaScript expression evaluating to `async emit => service`.
        /// `emit(name, payload)` delivers an event to
        /// ``CefServiceHosts/events(_:_:bufferingPolicy:)``; while one is
        /// being delivered, a newer event of the same name replaces the one
        /// waiting, so a burst costs one message per round trip.
        package let setup: String

        package init(name: String, hosts: [CefServiceHost], setup: String) {
            self.name = name
            self.hosts = hosts
            self.setup = setup
        }
    }
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
///   browser; the call throws and the next one starts the host again. A
///   call marked idempotent whose host stops before answering is made once
///   more, on a new host.
/// - Cancelling a call's task resumes it at once with `CancellationError`,
///   aborts the call's `AbortSignal` in the host, and drops a result that
///   arrives later without decoding it.
/// - Service browsers are listed in neither ``CefRuntime/browsers`` nor
///   ``CefWindow/all``. Their windows are 1 × 1 point, so their
///   compositor allocates next to nothing, and never shown.
/// - Their addresses carry the ``addressMarker`` fragment: Chromium saves
///   every Chrome-style window in its session and reopens them after a
///   crash, and ``CefRuntime`` closes the ones it recognizes by it.
@MainActor
package final class CefServiceHosts: CefShutdownParticipant {
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

    private var subscribers: [String: [UUID: AsyncStream<CefJSON>.Continuation]] = [:]

    /// Progress handlers of the calls in flight, by call.
    private var progressHandlers: [Int: @MainActor (Data) -> Void] = [:]
    private var lastCall = 0

    init(profile: CefProfile) {
        self.profile = profile
        Self.memoryPressure.watch(self)
        CefRuntime.shared.addShutdownParticipant(self)
    }

    func runtimeWillShutDown() { stopAll() }

    // MARK: Calling

    /// Calls `function` — a JavaScript expression of the form
    /// `async (service, args, context) => value` — on `module`'s service
    /// object with `arguments`, and decodes its value as `Result`.
    ///
    /// `context.signal` is an `AbortSignal` that aborts when the calling
    /// task is cancelled; `context.progress(value)` sends an intermediate
    /// value to `progress` — one at a time, and a value sent while the one
    /// before is on its way replaces the one waiting, so a slow consumer
    /// sees the newest. Neither reaches Swift after the call has returned.
    ///
    /// - Parameter isIdempotent: Whether the call may run twice: a call
    ///   whose host stops before it answers (its renderer crashed, or the
    ///   host was closed) is then made once more, on a new host. Reads are;
    ///   changes are not.
    package func call<Result: Decodable & Sendable, Progress: Decodable>(
        _ module: CefServiceHost.Module, _ function: String, _ arguments: CefJSON = [:], as type: Result.Type,
        timeout: Duration = .seconds(15), isIdempotent: Bool = false, progress: @escaping @MainActor (Progress) -> Void
    ) async throws -> Result {
        try await call(
            module, function, arguments, as: type, timeout: timeout, isIdempotent: isIdempotent,
            onProgress: { (data: Data) in
                guard let value = try? Self.decodeEncoded(Progress.self, from: data) else { return }
                progress(value)
            })
    }

    /// ``call(_:_:_:as:timeout:isIdempotent:progress:)`` without progress.
    package func call<Result: Decodable & Sendable>(
        _ module: CefServiceHost.Module, _ function: String, _ arguments: CefJSON = [:], as type: Result.Type,
        timeout: Duration = .seconds(15), isIdempotent: Bool = false
    ) async throws -> Result {
        try await call(module, function, arguments, as: type, timeout: timeout, isIdempotent: isIdempotent, onProgress: nil)
    }

    /// Calls `function` and returns its value as `CefJSON`.
    package func call(
        _ module: CefServiceHost.Module, _ function: String, _ arguments: CefJSON = [:], timeout: Duration = .seconds(15)
    ) async throws -> CefJSON {
        try await call(module, function, arguments, as: CefJSON.self, timeout: timeout)
    }

    private func call<Result: Decodable & Sendable>(
        _ module: CefServiceHost.Module, _ function: String, _ arguments: CefJSON, as type: Result.Type,
        timeout: Duration, isIdempotent: Bool, onProgress: (@MainActor (Data) -> Void)?
    ) async throws -> Result {
        let started = CefDiagnostics.start()
        defer { CefDiagnostics.record(.serviceCall, since: started) }
        var attempt = 0
        while true {
            attempt += 1
            lastCall += 1
            let call = lastCall
            if let onProgress { progressHandlers[call] = onProgress }
            defer { progressHandlers[call] = nil }
            let host = try runningHost(for: module)
            do {
                return try await host.call(module, function, arguments, call: call, as: type, timeout: timeout)
            } catch let stopped as CefServiceHostBrowser.HostStopped {
                guard isIdempotent, attempt == 1, !Task.isCancelled else {
                    throw CefError.operationFailed(stopped.message)
                }
                CefLog.error("service \(module.name): \(stopped.message); calling again on a new host")
            }
        }
    }

    /// An intermediate value from a host, for the call it belongs to.
    /// A late one, whose call has returned, is dropped undecoded.
    fileprivate func deliverProgress(call: Int, data: Data) {
        progressHandlers[call]?(data)
    }

    /// Decodes `Result` from `payload`, an evaluation's reply whose value
    /// is the wire encoding the host wrote (`CefServiceHostRuntime`): in
    /// place, and off the main actor when the reply is large.
    fileprivate nonisolated static func decode<Result: Decodable & Sendable>(
        _ type: Result.Type, from payload: CefWirePayload
    ) async throws -> Result {
        let started = CefDiagnostics.start()
        defer { CefDiagnostics.record(.serviceDecode, since: started) }
        if payload.bytes.count >= offMainDecodeThreshold {
            return try await Task.detached(priority: .userInitiated) { try decodeNow(type, from: payload) }.value
        }
        return try decodeNow(type, from: payload)
    }

    /// From this size a reply is decoded off the main actor: from about a
    /// millisecond of decoding.
    nonisolated static let offMainDecodeThreshold = 64 << 10

    nonisolated static func decodeNow<Result: Decodable>(_ type: Result.Type, from payload: CefWirePayload) throws -> Result {
        try withExtendedLifetime(payload) { try decodeValue(type, from: payload.bytes, at: CefWireHeader.size) }
    }

    /// Decodes `Result` from the value at `offset` in `bytes`: from inside
    /// it when it is bytes the host encoded, else from the value itself.
    nonisolated static func decodeValue<Result: Decodable>(
        _ type: Result.Type, from bytes: UnsafeRawBufferPointer, at offset: Int
    ) throws -> Result {
        var reader = CefWireReader(bytes, offset: offset)
        guard (try? reader.peekTag()) == .bytes else {
            return try CefWireDecoder(bytes: bytes, offset: offset).decode(type)
        }
        _ = try reader.readTag()
        return try CefWireDecoder(bytes: try reader.readRun()).decode(type)
    }

    /// Decodes `Result` from wire bytes the host encoded.
    nonisolated static func decodeEncoded<Result: Decodable>(_ type: Result.Type, from data: Data) throws -> Result {
        try data.withUnsafeBytes { try CefWireDecoder(bytes: $0).decode(type) }
    }

    /// Events `module` emits as `emit(name, payload)`, while one of its hosts
    /// runs with the module built. Subscribing starts nothing and keeps
    /// nothing running. `bufferingPolicy` matches the events' meaning:
    /// `.bufferingNewest(1)` for invalidations, where only the latest
    /// matters.
    package func events(
        _ module: CefServiceHost.Module, _ name: String,
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
        CefDiagnostics.record(.serviceEvent, amount: 0)
        subscribers["\(module)/\(name)"]?.values.forEach { $0.yield(payload) }
    }

    /// The host to call `module` on: one already running, or the first the
    /// profile can open.
    private func runningHost(for module: CefServiceHost.Module) throws -> CefServiceHostBrowser {
        guard CefRuntime.shared.isRunning, !CefRuntime.shared.isTerminating else {
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
    package func isRunning(_ host: CefServiceHost) -> Bool {
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
    private func stopIdle() {
        hosts.values.filter(\.isIdle).forEach { $0.stop() }
    }

    /// The browser of the running host called `name`. For benchmarks.
    func browser(ofHostNamed name: String) -> CefBrowser? {
        hosts.first { $0.key.name == name }?.value.liveBrowserIfRunning
    }

    /// Kills the renderer of the running host called `name`, as a crash
    /// would. For tests.
    func crashRenderer(ofHostNamed name: String) async {
        await hosts.first { $0.key.name == name }?.value.crashRenderer()
    }

    /// A host's browser closed or is closing.
    fileprivate func hostDidStop(_ browser: CefServiceHostBrowser) {
        if hosts[browser.host] === browser { hosts[browser.host] = nil }
    }

    /// Closes idle hosts of every profile when macOS runs low on memory.
    private static let memoryPressure = MemoryPressureWatch()

    @MainActor
    private final class MemoryPressureWatch {
        private struct Weak { weak var services: CefServiceHosts? }
        private var all: [Weak] = []
        private var source: DispatchSourceMemoryPressure?

        func watch(_ services: CefServiceHosts) {
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
    private weak var services: CefServiceHosts?
    private let profile: CefProfile

    private var window: CefWindow?
    private var browser: CefBrowser?
    private var starting: Task<CefBrowser, Error>?
    private var idleStop: Task<Void, Never>?
    private var callsInProgress = 0
    private var isStopped = false
    private let delegate = ServiceBrowserDelegate()

    /// Whether the document has the runtime (`CefServiceHostRuntime`),
    /// and the functions it has compiled, by handle. Set as the script
    /// that installs them is sent: scripts reach the renderer in order.
    private var hasRuntime = false
    private var definedFunctions: Set<Int> = []

    /// Each function's handle, by module and source, for every host.
    private static var handles: [String: Int] = [:]

    /// The host stopped (its renderer died, or it was closed) before the
    /// call was answered.
    struct HostStopped: Error {
        var message: String
    }

    /// The bridge module events and progress reach Swift through, as
    /// `window.__cefswiftServiceEvents.event({module, name, payload})` and
    /// `.progress({call, data})`: native V8 functions, so the host attaches
    /// no DevTools session.
    private static let eventBridgeName = "__cefswiftServiceEvents"
    private let eventBridge = CefBridge(name: CefServiceHostBrowser.eventBridgeName)

    private struct ModuleEvent: Decodable {
        var module: String
        var name: String
        var payload: CefJSON?
    }

    private struct ProgressMessage: Decodable {
        var call: Int
        var data: Data
    }

    init(host: CefServiceHost, services: CefServiceHosts) {
        self.host = host
        self.services = services
        self.profile = services.profile
        delegate.onTerminated = { [weak self] in self?.stop() }
        eventBridge.handle("event") { [weak self] (event: ModuleEvent) in
            self?.services?.deliver(module: event.module, name: event.name, payload: event.payload ?? .null)
        }
        eventBridge.handle("progress") { [weak self] (message: ProgressMessage) in
            self?.services?.deliverProgress(call: message.call, data: message.data)
        }
    }

    fileprivate var isIdle: Bool { callsInProgress == 0 }

    fileprivate var liveBrowserIfRunning: CefBrowser? { browser?.state == .live ? browser : nil }

    func call<Result: Decodable & Sendable>(
        _ module: CefServiceHost.Module, _ function: String, _ arguments: CefJSON, call: Int, as type: Result.Type,
        timeout: Duration
    ) async throws -> Result {
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
            let browser: CefBrowser
            do {
                browser = try await liveBrowser()
            } catch CefError.browserClosed {
                throw HostStopped(message: "\(module.name): \(host.document) closed while it started")
            }
            var redefined = false
            while true {
                let encodeStarted = CefDiagnostics.start()
                let script = invocation(module, function, arguments, call: call)
                CefDiagnostics.record(.serviceEncode, since: encodeStarted)
                CefDiagnostics.record(.serviceRequestBytes, amount: script.utf8.count)
                do {
                    let payload = try await browser.pageScripting.evaluatedPayload(script, in: nil)
                    return try await CefServiceHosts.decode(type, from: payload)
                } catch is CancellationError {
                    // The caller has resumed already; the host stops the work.
                    browser.pageScripting.evaluateWithoutReply("window.__cefswiftServices?.cancel(\(call))")
                    throw CancellationError()
                } catch let error as CefJavaScriptError {
                    if error.message.contains(CefServiceHostRuntime.undefinedFunctionMarker), !redefined {
                        // The document lost what was installed: install again.
                        redefined = true
                        hasRuntime = false
                        definedFunctions = []
                        continue
                    }
                    if isStopped { throw HostStopped(message: "\(module.name): \(host.document) stopped responding") }
                    throw CefError.operationFailed("\(module.name): \(error.message)")
                } catch CefError.browserClosed, CefError.frameDetached {
                    throw HostStopped(message: "\(module.name): \(host.document) stopped responding")
                }
            }
        }
    }

    /// The script that calls `function` with `arguments` as call `call`,
    /// installing the runtime and defining the function first where the
    /// document has not seen them.
    private func invocation(_ module: CefServiceHost.Module, _ function: String, _ arguments: CefJSON, call: Int) -> String {
        let key = "\(module.name)\u{1}\(function)"
        let handle: Int
        if let known = Self.handles[key] {
            handle = known
        } else {
            handle = Self.handles.count + 1
            Self.handles[key] = handle
        }
        var script = ""
        if !hasRuntime {
            script += CefServiceHostRuntime.bootstrap(eventBridge: Self.eventBridgeName) + ";\n"
            hasRuntime = true
        }
        if definedFunctions.insert(handle).inserted {
            script += "__cefswiftServices.define(\(handle), \(CefJSON.string(module.name).text), (\(module.setup)), (\(function)));\n"
        }
        script += "__cefswiftServices.invoke(\(handle), \(arguments.text), \(call))"
        return script
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: CefServiceHosts.idleTimeout)
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
        var configuration = CefBrowser.Configuration()
        configuration.profile = profile
        configuration.bridges = [eventBridge]
        let browser = CefBrowser(
            url: URL(string: host.document), configuration: configuration, delegate: delegate)
        CefRuntime.shared.registerServiceBrowser(browser)
        var windowConfiguration = CefWindow.Configuration()
        // The compositor sizes its buffers to the window.
        windowConfiguration.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        windowConfiguration.titleFollowsPage = false
        let window = CefWindow(browser: browser, configuration: windowConfiguration)
        window.isService = true
        browser.pageScripting.isServiceHost = true
        window.onClose = { [weak self] in self?.windowDidClose() }
        self.browser = browser
        self.window = window

        try await browser.ready()
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
                    "history.replaceState(null, '', '#\(CefServiceHosts.addressMarker)')")
                return browser
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        stop()
        throw CefError.operationFailed("\(host.document) did not load")
    }

    /// Closes the browser; calls still waiting fail, and the next call
    /// starts a new host.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        idleStop?.cancel()
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
    fileprivate var onTerminated: (() -> Void)?

    func browser(_ browser: CefBrowser, renderProcessDidTerminate reason: CefTerminationReason) {
        onTerminated?()
    }
}

extension CefProfile {
    /// What the running service host called `name` reports about itself:
    /// its calls and the renderer time they took, the calls in flight and
    /// those aborted, and its JavaScript heap.
    /// For benchmarks.
    @_spi(Testing) public func serviceHostStatistics(named name: String) async -> CefJSON? {
        guard let browser = serviceHosts.browser(ofHostNamed: name) else { return nil }
        return try? await browser.evaluateJavaScript("""
            ({
              calls: window.__cefswiftServices?.stats.calls ?? 0,
              ms: window.__cefswiftServices?.stats.ms ?? 0,
              heap: performance.memory?.usedJSHeapSize ?? 0,
              inFlight: window.__cefswiftServices?.calls?.size ?? 0,
              aborts: window.__cefswiftServices?.stats.aborts ?? 0,
            })
            """)
    }

    /// The browser of the running service host called `name`. For
    /// benchmarks.
    @_spi(Testing) public func serviceHostBrowser(named name: String) -> CefBrowser? {
        serviceHosts.browser(ofHostNamed: name)
    }
}
