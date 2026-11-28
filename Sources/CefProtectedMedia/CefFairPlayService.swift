import Foundation

/// The app's end of the FairPlay service (`Contents/XPCServices/<App>
/// FairPlay.xpc`): one connection, started on the first session, whose
/// reports go to the ``CefFairPlay`` that owns it on the main actor.
@MainActor
final class CefFairPlayService {
    /// The service's name, `<app identifier>.fairplay`, when the bundle has it.
    nonisolated static let name: String? = {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let name = identifier + ".fairplay"
        let services = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices", isDirectory: true)
        let bundles = (try? FileManager.default.contentsOfDirectory(at: services, includingPropertiesForKeys: nil)) ?? []
        return bundles.contains { Bundle(url: $0)?.bundleIdentifier == name } ? name : nil
    }()

    private weak var owner: CefFairPlay?
    private var connection: NSXPCConnection?

    init(owner: CefFairPlay) {
        self.owner = owner
    }

    private func proxy(onFailure failure: @escaping @Sendable (Error) -> Void = { _ in }) -> CefFairPlayServiceInterface? {
        if connection == nil, let name = Self.name {
            let connection = NSXPCConnection(serviceName: name)
            connection.remoteObjectInterface = NSXPCInterface(with: CefFairPlayServiceInterface.self)
            connection.exportedInterface = NSXPCInterface(with: CefFairPlayClientInterface.self)
            connection.exportedObject = CefFairPlayClient(service: self)
            connection.invalidationHandler = Self.invalidated(self)
            connection.interruptionHandler = Self.invalidated(self)
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler(failure) as? CefFairPlayServiceInterface
    }

    private nonisolated static func invalidated(_ service: CefFairPlayService) -> @Sendable () -> Void {
        nonisolated(unsafe) let service = service
        return { Task { @MainActor in service.didExit() } }
    }

    private func didExit() {
        connection = nil
        owner?.serviceDidExit()
    }

    func open(session: String, playlist: Data, certificate: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = CefFairPlayOnce()
            guard let proxy = proxy(onFailure: Self.failure(once, continuation)) else {
                continuation.resume(throwing: CefFairPlayError.serviceUnavailable)
                return
            }
            proxy.open(session: session, playlist: playlist, certificate: certificate, reply: Self.reply(once, continuation))
        }
    }

    // XPC calls these on its own queue: they are not isolated to the main
    // actor, which a closure written in a main-actor method would be.
    private nonisolated static func failure(_ once: CefFairPlayOnce, _ continuation: CheckedContinuation<Void, Error>)
        -> @Sendable (Error) -> Void
    {
        { error in if once.claim() { continuation.resume(throwing: error) } }
    }

    private nonisolated static func reply(_ once: CefFairPlayOnce, _ continuation: CheckedContinuation<Void, Error>)
        -> @Sendable (String?) -> Void
    {
        { message in
            guard once.claim() else { return }
            if let message { continuation.resume(throwing: CefFairPlayError.playback(message)) } else { continuation.resume() }
        }
    }

    func provideLicense(session: String, keyURI: String, license: Data) {
        proxy()?.provideLicense(session: session, keyURI: keyURI, license: license)
    }

    func control(session: String, command: String, value: Double) {
        proxy()?.control(session: session, command: command, value: value)
    }

    func close(session: String) {
        guard connection != nil else { return }
        proxy()?.close(session: session)
    }

    fileprivate func keyRequest(session: String, keyURI: String, request: Data) {
        owner?.keyRequest(session: session, keyURI: keyURI, request: request)
    }

    fileprivate func state(session: String, json: Data) {
        owner?.state(session: session, json: json)
    }
}

/// Claimed once, from any thread: the first of an XPC reply and its error
/// handler wins.
final class CefFairPlayOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// The service's reports, on XPC's queue, handed to the main actor.
final class CefFairPlayClient: NSObject, CefFairPlayClientInterface, @unchecked Sendable {
    private weak var service: CefFairPlayService?

    init(service: CefFairPlayService) {
        self.service = service
    }

    func keyRequest(session: String, keyURI: String, request: Data) {
        Task { @MainActor [weak service] in service?.keyRequest(session: session, keyURI: keyURI, request: request) }
    }

    func state(session: String, json: Data) {
        Task { @MainActor [weak service] in service?.state(session: session, json: json) }
    }
}

/// The service's interface, matched by its Objective-C name. Keep it the
/// same as `FairPlayServiceProtocol` in `Sources/CefFairPlayService`.
@objc(CefFairPlayServiceProtocol)
protocol CefFairPlayServiceInterface {
    func open(session: String, playlist: Data, certificate: Data, reply: @escaping @Sendable (String?) -> Void)
    func provideLicense(session: String, keyURI: String, license: Data)
    func failLicense(session: String, keyURI: String, message: String)
    func control(session: String, command: String, value: Double)
    func close(session: String)
}

/// What the service calls in the app. Keep it the same as
/// `FairPlayClientProtocol` in `Sources/CefFairPlayService`.
@objc(CefFairPlayClientProtocol)
protocol CefFairPlayClientInterface {
    func keyRequest(session: String, keyURI: String, request: Data)
    func state(session: String, json: Data)
}
