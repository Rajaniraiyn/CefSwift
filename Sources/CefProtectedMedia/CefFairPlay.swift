import CefKit
import Foundation
import Observation

/// FairPlay Streaming in Chromium pages, for the origins an app lists:
/// the page's player gets the `com.apple.fps` key systems through EME, and
/// CefProtectedMedia's FairPlay service, an XPC service in the App
/// Sandbox, plays the stream with AVPlayer and AVContentKeySession. The
/// page's media element mirrors that player. **Experimental**, audio only.
///
/// ```swift
/// let fairPlay = CefFairPlay(origins: CefFairPlay.spotify)
/// fairPlay.install(in: .default)
/// ```
///
/// Nothing happens for other origins, or until ``install(in:)``: their
/// pages keep Chromium's own EME, and the service never starts. For the
/// listed origins, in top-level documents only:
///
/// - A page script offers `com.apple.fps.1_0` (and `com.apple.fps`,
///   `com.apple.fps.3_0`) from `requestMediaKeySystemAccess`, keeps the
///   certificate the player sets, and catches the HLS playlist it gives
///   an element whose MediaKeys are FairPlay's.
/// - The app accepts the bridge's calls only from the main frame of a
///   listed origin, as the browser process establishes the origin from
///   the frame's address (``CefBridge/Call/origin``), and only playlists
///   ``CefFairPlayPlaylist`` passes: a media playlist of `https` segments
///   with `skd://` or `https` keys, within size limits.
/// - The service's key requests (SPC) reach the page as the session's
///   `message` events, and the licenses (CKC) its server returns go back
///   through `update`. Keys and decrypted media stay in AVFoundation.
/// - On any failure the element gets a media error and the delegate is
///   told, so the app can show the page in WebKit instead.
///
/// The app needs the `fairPlay` capability in `cefapp.json`, which puts the
/// service in the bundle (`CefRuntime.shared.capabilities` has no word for
/// it; ``isServiceAvailable`` does).
@MainActor
@Observable
public final class CefFairPlay {
    /// Spotify's web player, where this was first proven (audio).
    public static let spotify: Set<String> = ["https://open.spotify.com"]
    /// The key systems offered to pages.
    public static let keySystems = ["com.apple.fps.1_0", "com.apple.fps", "com.apple.fps.3_0"]

    /// The origins that get FairPlay: exact `https` origins, such as
    /// `"https://open.spotify.com"`. A change reaches pages already open on
    /// them at once, as ``isEnabled`` does; the page script itself reaches
    /// documents loaded afterwards.
    public var origins: Set<String> {
        didSet {
            // Only exact https origins; the assignment comes back here once.
            let accepted = origins.filter(Self.isHTTPSOrigin)
            guard accepted == origins else {
                origins = accepted
                return
            }
            guard origins != oldValue else { return }
            bridge.access = .origins(origins)
            updateScript()
            pushConfiguration()
            for session in sessions.values where !origins.contains(session.origin) { close(session.id) }
        }
    }

    /// Whether listed origins get FairPlay. Turned off, their pages get
    /// Chromium's EME as other pages do, and playing sessions stop.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            pushConfiguration()
            if !isEnabled { for id in Array(sessions.keys) { close(id) } }
        }
    }

    /// Told when FairPlay fails in a page, so the app can fall back.
    public weak var delegate: (any CefFairPlayDelegate)?

    /// Pages playing through the service now, and whether each plays.
    public private(set) var playingPages: [ObjectIdentifier: Bool] = [:]

    /// Whether the app carries the FairPlay service.
    public nonisolated static var isServiceAvailable: Bool { CefFairPlayService.name != nil }

    let bridge = CefBridge(name: "cefswiftFairPlay")
    private var script: CefUserScript?
    private var profiles: [CefProfile] = []
    private var sessions: [String: Session] = [:]
    @ObservationIgnored private lazy var service = CefFairPlayService(owner: self)

    struct Session {
        let id: String
        let origin: String
        weak var page: CefPage?
        var isPlaying = false
    }

    public init(origins: Set<String> = CefFairPlay.spotify) {
        self.origins = origins.filter(Self.isHTTPSOrigin)
        bridge.access = .origins(self.origins)
        installHandlers()
    }

    /// Adds FairPlay to `profile`'s pages: its bridge, its page script for
    /// the listed origins, and an attachment that ends a page's session
    /// when the page closes.
    public func install(in profile: CefProfile) {
        guard !profiles.contains(where: { $0 === profile }) else { return }
        profiles.append(profile)
        profile.bridges.append(bridge)
        if let script { profile.userScripts.append(script) } else { updateScript() }
        profile.attachments.append(CefFairPlayAttachment(fairPlay: self))
    }

    // MARK: The page script

    private func updateScript() {
        let old = script
        let new = CefUserScript(
            source: "(\(Self.pageScript))(\(Self.json([bridge.name]).dropFirst().dropLast()), \(Self.json(Self.keySystems)));",
            matching: origins.sorted().map { "\($0)/*" }, injectionTime: .documentStart, frames: .mainFrame)
        script = new
        for profile in profiles {
            var scripts = profile.userScripts
            scripts.removeAll { $0 == old }
            if !origins.isEmpty { scripts.append(new) }
            profile.userScripts = scripts
        }
    }

    private func pushConfiguration() {
        bridge.emit("config", ["enabled": isEnabled])
    }

    // MARK: The bridge

    struct Open: Decodable { var session: String; var playlist: String; var certificate: String }
    struct License: Decodable { var keyURI: String; var license: String }
    struct Control: Decodable { var session: String; var command: String; var value: Double }
    struct Close: Decodable { var session: String }

    /// The largest certificate and license accepted, in bytes.
    static let maximumCertificateSize = 64 << 10
    static let maximumLicenseSize = 256 << 10

    private func installHandlers() {
        bridge.handle("hello") { [weak self] (_: CefJSON, call: CefBridge.Call) -> [String: Bool] in
            guard let self else { return ["enabled": false] }
            return ["enabled": self.isEnabled && self.accepts(call) && Self.isServiceAvailable]
        }
        bridge.handle("open") { [weak self] (request: Open, call: CefBridge.Call) async throws -> Bool in
            guard let self else { throw CefFairPlayError.refused("closed") }
            return try await self.open(request, call: call)
        }
        bridge.handle("license") { [weak self] (request: License, call: CefBridge.Call) throws -> Bool in
            guard let self, self.accepts(call),
                  let session = self.sessions.values.first(where: { $0.page === call.page }),
                  let license = Data(base64Encoded: request.license), license.count <= Self.maximumLicenseSize,
                  request.keyURI.count <= 4096
            else { throw CefFairPlayError.refused("license") }
            self.service.provideLicense(session: session.id, keyURI: request.keyURI, license: license)
            return true
        }
        bridge.handle("control") { [weak self] (request: Control, call: CefBridge.Call) throws -> Bool in
            guard let self, self.accepts(call), let id = self.session(named: request.session, in: call.page) else {
                throw CefFairPlayError.refused("control")
            }
            self.service.control(session: id, command: request.command, value: request.value)
            return true
        }
        bridge.handle("close") { [weak self] (request: Close, call: CefBridge.Call) -> Bool in
            guard let self, let id = self.session(named: request.session, in: call.page) else { return false }
            self.close(id)
            return true
        }
    }

    /// The app's name for the session the page calls `name`: a page can
    /// reach only its own.
    private func session(named name: String, in page: CefPage) -> String? {
        sessions.values.first { $0.page === page && pageSessionIDs[$0.id] == name }?.id
    }

    /// Only the main frame of a listed `https` origin, while on, may call.
    func accepts(_ call: CefBridge.Call) -> Bool {
        isEnabled && call.frame.isMain && origins.contains(call.origin) && Self.isHTTPSOrigin(call.origin)
    }

    private func open(_ request: Open, call: CefBridge.Call) async throws -> Bool {
        guard accepts(call) else { throw CefFairPlayError.refused("origin") }
        guard Self.isServiceAvailable else {
            fail(call.page, .serviceUnavailable)
            throw CefFairPlayError.refused("no FairPlay service")
        }
        guard request.session.count <= 64, request.session.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            throw CefFairPlayError.refused("session")
        }
        guard let certificate = Data(base64Encoded: request.certificate), !certificate.isEmpty,
              certificate.count <= Self.maximumCertificateSize
        else {
            fail(call.page, .refused("the certificate is missing or too large"))
            throw CefFairPlayError.refused("certificate")
        }
        let playlist: CefFairPlayPlaylist
        do {
            playlist = try CefFairPlayPlaylist(data: Data(request.playlist.utf8))
        } catch {
            fail(call.page, .refused(error.description))
            throw CefFairPlayError.refused(error.description)
        }
        // One session per page.
        for session in sessions.values where session.page === call.page { close(session.id) }
        let id = "\(ObjectIdentifier(call.page).hashValue)-\(request.session)"
        sessions[id] = Session(id: id, origin: call.origin, page: call.page)
        // Before the service starts: its first key request may come before
        // `open` returns.
        pageSessionIDs[id] = request.session
        do {
            try await service.open(session: id, playlist: Data(playlist.text.utf8), certificate: certificate)
        } catch {
            sessions[id] = nil
            fail(call.page, .playback("\(error)"))
            throw error
        }
        followMute(of: call.page, session: id)
        return true
    }

    /// The page's own name for each session.
    private var pageSessionIDs: [String: String] = [:]

    func close(_ id: String) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        service.close(session: id)
        pageSessionIDs[id] = nil
        if let page = session.page { playingPages[ObjectIdentifier(page)] = nil }
    }

    func pageDidClose(_ page: CefPage) {
        for session in sessions.values where session.page == nil || session.page === page { close(session.id) }
    }

    // MARK: The service's reports

    func keyRequest(session id: String, keyURI: String, request: Data) {
        guard let session = sessions[id], let page = session.page, let pageID = pageSessionIDs[id] else { return }
        bridge.emit("keyRequest", ["session": pageID, "keyURI": keyURI, "request": request.base64EncodedString()],
                    to: page)
    }

    func state(session id: String, json: Data) {
        guard var session = sessions[id], let page = session.page, let pageID = pageSessionIDs[id],
              let state = try? JSONDecoder().decode(CefJSON.self, from: json)
        else { return }
        bridge.emit("state", ["session": CefJSON.string(pageID), "state": state], to: page)
        let playing = state["paused"].boolValue == false && state["ended"].boolValue != true
        if playing != session.isPlaying {
            session.isPlaying = playing
            sessions[id] = session
            playingPages[ObjectIdentifier(page)] = playing
            delegate?.fairPlay(self, page: page, didChangePlaying: playing)
        }
        if let message = state["error"].stringValue {
            close(id)
            fail(page, .playback(message))
        }
    }

    func serviceDidExit() {
        for session in sessions.values {
            if let page = session.page { fail(page, .playback("the FairPlay service exited")) }
        }
        sessions = [:]
        pageSessionIDs = [:]
        playingPages = [:]
    }

    private func fail(_ page: CefPage, _ reason: CefFairPlayError) {
        delegate?.fairPlay(self, page: page, didFail: reason)
    }

    /// The tab's mute applies to the service's player.
    private func followMute(of page: CefPage, session id: String) {
        withObservationTracking { _ = page.isAudioMuted } onChange: { [weak self, weak page] in
            Task { @MainActor in
                guard let self, let page, self.sessions[id] != nil else { return }
                self.service.control(session: id, command: "muted", value: page.isAudioMuted ? 1 : 0)
                self.followMute(of: page, session: id)
            }
        }
        if page.isAudioMuted { service.control(session: id, command: "muted", value: 1) }
    }

    // MARK: Helpers

    static func isHTTPSOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.path.isEmpty, url.query == nil, url.fragment == nil
        else { return false }
        return true
    }

    static func json(_ value: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "[]"
    }

    /// `Resources/fairplay.js`, a function of the bridge and the key systems.
    static let pageScript: String = {
        guard let url = Bundle.module.url(forResource: "fairplay", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "(function () {})" }
        return text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }()
}

/// Why FairPlay did not play in a page.
public enum CefFairPlayError: Error, Sendable, Equatable {
    /// The app carries no FairPlay service (the `fairPlay` capability).
    case serviceUnavailable
    /// The page's request did not pass the checks: an origin or frame not
    /// allowed, a playlist with a segment that is not `https`, sizes over
    /// the limits.
    case refused(String)
    /// AVFoundation or the license failed while playing.
    case playback(String)
}

/// Told about FairPlay in pages.
@MainActor
public protocol CefFairPlayDelegate: AnyObject {
    /// FairPlay failed in `page`; the page's element has a media error.
    /// Show the page in WebKit, for example.
    func fairPlay(_ fairPlay: CefFairPlay, page: CefPage, didFail error: CefFairPlayError)
    /// The service's player in `page` started or stopped playing, for a
    /// tab's playing indicator.
    func fairPlay(_ fairPlay: CefFairPlay, page: CefPage, didChangePlaying isPlaying: Bool)
}

extension CefFairPlayDelegate {
    public func fairPlay(_ fairPlay: CefFairPlay, page: CefPage, didChangePlaying isPlaying: Bool) {}
}

/// Ends a page's FairPlay session when the page closes.
@MainActor
final class CefFairPlayAttachment: CefPageAttachment {
    weak var fairPlay: CefFairPlay?
    init(fairPlay: CefFairPlay) { self.fairPlay = fairPlay }
    func pageDidClose(_ page: CefPage) { fairPlay?.pageDidClose(page) }
}
