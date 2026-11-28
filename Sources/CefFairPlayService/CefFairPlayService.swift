import AVFoundation
import Foundation

/// The XPC service behind CefProtectedMedia's `CefFairPlay`: plays a
/// page's FairPlay Streaming audio with AVPlayer and AVContentKeySession,
/// inside the App Sandbox with outgoing network connections only.
///
/// `cef bundle` puts it in `Contents/XPCServices/<App> FairPlay.xpc` for
/// apps listing the `fairPlay` capability. The app hands it a playlist the
/// app has checked (https segments, https or `skd://` keys) and the page's
/// certificate; it asks the app for each key's license with the request
/// (SPC) AVFoundation makes, and reports the player's state. Keys and
/// decrypted media stay inside AVFoundation.
@main
enum CefFairPlayService {
    static func main() {
        let delegate = FairPlayServiceDelegate()
        let listener = NSXPCListener.service()
        listener.delegate = delegate
        listener.resume()
    }
}

/// The interface the app calls. Keep it the same as CefProtectedMedia's
/// `CefFairPlayServiceInterface`.
@objc(CefFairPlayServiceProtocol)
protocol FairPlayServiceProtocol {
    /// Starts session `session` on `playlist` (an HLS media playlist the
    /// app checked), with the page's FairPlay certificate. Replies with an
    /// error message, or `nil` once the player exists.
    func open(session: String, playlist: Data, certificate: Data, reply: @escaping @Sendable (String?) -> Void)
    /// The license (CKC) for `keyURI`, from the page's license server.
    func provideLicense(session: String, keyURI: String, license: Data)
    /// The page could not get a license for `keyURI`.
    func failLicense(session: String, keyURI: String, message: String)
    /// `command`: `play`, `pause`, `seek`, `rate`, `volume`, `muted`;
    /// `value` its argument.
    func control(session: String, command: String, value: Double)
    func close(session: String)
}

/// What the service tells the app. Keep it the same as CefProtectedMedia's
/// `CefFairPlayClientInterface`.
@objc(CefFairPlayClientProtocol)
protocol FairPlayClientProtocol {
    /// AVFoundation's key request (SPC) for `keyURI`.
    func keyRequest(session: String, keyURI: String, request: Data)
    /// The player's state, as JSON: `currentTime`, `duration`, `paused`,
    /// `rate`, `ended`, `waiting`, `buffered` (end), `ready`, and `error`
    /// when it failed.
    func state(session: String, json: Data)
}

final class FairPlayServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FairPlayServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: FairPlayClientProtocol.self)
        let service = FairPlayService(client: { connection.remoteObjectProxy as? FairPlayClientProtocol })
        connection.exportedObject = service
        connection.invalidationHandler = { service.closeAll() }
        connection.resume()
        return true
    }
}

/// The connection's sessions. Calls arrive on the connection's queue; the
/// players report on the main queue, which owns the sessions.
final class FairPlayService: NSObject, FairPlayServiceProtocol, @unchecked Sendable {
    /// The most sessions at once: one per tab that plays.
    static let sessionLimit = 8

    private let client: () -> FairPlayClientProtocol?
    private var sessions: [String: FairPlaySession] = [:]

    init(client: @escaping () -> FairPlayClientProtocol?) {
        self.client = client
    }

    func open(session id: String, playlist: Data, certificate: Data, reply: @escaping @Sendable (String?) -> Void) {
        DispatchQueue.main.async { [self] in
            sessions[id]?.close()
            guard sessions.count < Self.sessionLimit else {
                reply("too many FairPlay sessions")
                return
            }
            let session = FairPlaySession(id: id, playlist: playlist, certificate: certificate, client: client)
            sessions[id] = session
            session.start()
            reply(nil)
        }
    }

    func provideLicense(session id: String, keyURI: String, license: Data) {
        DispatchQueue.main.async { [self] in sessions[id]?.provideLicense(keyURI: keyURI, license: license) }
    }

    func failLicense(session id: String, keyURI: String, message: String) {
        DispatchQueue.main.async { [self] in sessions[id]?.failLicense(keyURI: keyURI, message: message) }
    }

    func control(session id: String, command: String, value: Double) {
        DispatchQueue.main.async { [self] in sessions[id]?.control(command, value: value) }
    }

    func close(session id: String) {
        DispatchQueue.main.async { [self] in sessions.removeValue(forKey: id)?.close() }
    }

    func closeAll() {
        DispatchQueue.main.async { [self] in
            sessions.values.forEach { $0.close() }
            sessions = [:]
        }
    }
}
