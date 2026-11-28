import AVFoundation
import Foundation

/// One page's FairPlay player: AVPlayer on a playlist served from memory,
/// with an AVContentKeySession whose key requests go to the page through
/// the app. On the main queue, which an XPC service's `dispatch_main`
/// drains from worker threads: the queue serializes, but nothing here may
/// assume the main thread or the main actor.
final class FairPlaySession: NSObject, AVAssetResourceLoaderDelegate, AVContentKeySessionDelegate, @unchecked Sendable {
    /// The scheme the playlist is served under, so that AVFoundation asks
    /// the resource loader for it rather than the network.
    static let scheme = "cefswift-fairplay"

    let id: String
    private let playlist: Data
    private let certificate: Data
    private let client: () -> FairPlayClientProtocol?
    private let keySession = AVContentKeySession(keySystem: .fairPlayStreaming)
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    /// Key requests waiting for the page's license, by key URI.
    private var pendingKeys: [String: AVContentKeyRequest] = [:]
    private var failure: String?
    private var ended = false
    private var lastReport: [String: Any] = [:]

    init(id: String, playlist: Data, certificate: Data, client: @escaping () -> FairPlayClientProtocol?) {
        self.id = id
        self.playlist = playlist
        self.certificate = certificate
        self.client = client
    }

    func start() {
        guard let url = URL(string: "\(Self.scheme)://playlist/\(id).m3u8") else { return }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: .main)
        keySession.setDelegate(self, queue: .main)
        keySession.addContentKeyRecipient(asset)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        // Audio only: nothing is drawn, so nothing waits for a layer.
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        self.player = player
        observations = [
            // Key-value observation reports on whatever thread changed the
            // value.
            item.observe(\.status) { [weak self] item, _ in
                DispatchQueue.main.async {
                    if item.status == .failed { self?.fail(item.error.map(Self.describe) ?? "the player failed") }
                    self?.report()
                }
            },
            player.observe(\.timeControlStatus) { [weak self] _, _ in DispatchQueue.main.async { self?.report() } },
            player.observe(\.rate) { [weak self] _, _ in DispatchQueue.main.async { self?.report() } },
        ]
        NotificationCenter.default.addObserver(
            self, selector: #selector(didPlayToEnd), name: .AVPlayerItemDidPlayToEndTime, object: item)
        NotificationCenter.default.addObserver(
            self, selector: #selector(failedToPlayToEnd(_:)), name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
            self?.report()
        }
        report()
    }

    func close() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations = []
        NotificationCenter.default.removeObserver(self)
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        pendingKeys.values.forEach { $0.processContentKeyResponseError(Self.error("closed")) }
        pendingKeys = [:]
    }

    // MARK: Commands

    func control(_ command: String, value: Double) {
        guard let player else { return }
        switch command {
        case "play":
            if ended { player.seek(to: .zero) }
            ended = false
            player.play()
        case "pause": player.pause()
        case "seek":
            guard value.isFinite, value >= 0 else { return }
            ended = false
            player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
                [weak self] _ in DispatchQueue.main.async { self?.report(seeked: true) }
            }
        case "rate":
            guard value.isFinite, value > 0, value <= 4 else { return }
            player.defaultRate = Float(value)
            if player.rate != 0 { player.rate = Float(value) }
        case "volume": player.volume = Float(min(max(value, 0), 1))
        case "muted": player.isMuted = value != 0
        default: break
        }
        report()
    }

    // MARK: Keys

    func provideLicense(keyURI: String, license: Data) {
        guard let request = pendingKeys.removeValue(forKey: keyURI) else { return }
        request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: license))
    }

    func failLicense(keyURI: String, message: String) {
        pendingKeys.removeValue(forKey: keyURI)?.processContentKeyResponseError(Self.error(message))
        fail("no license: \(message)")
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError error: Error) {
        fail("the key request failed: \(Self.describe(error))")
    }

    private func handle(_ keyRequest: AVContentKeyRequest) {
        guard let keyURI = keyRequest.identifier as? String, let identifier = keyURI.data(using: .utf8) else {
            keyRequest.processContentKeyResponseError(Self.error("a key without a URI"))
            return
        }
        // The content identifier FairPlay servers expect: the asset ID, what
        // follows `skd://`, as Apple's FairPlay Streaming samples pass it
        // (they read it as the URI's host, which is the same for plain IDs).
        let assetID = keyURI.hasPrefix("skd://") ? Data(keyURI.dropFirst(6).utf8) : identifier
        keyRequest.makeStreamingContentKeyRequestData(forApp: certificate, contentIdentifier: assetID, options: nil) {
            [weak self] request, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let request else {
                    keyRequest.processContentKeyResponseError(error ?? Self.error("no key request"))
                    self.fail("AVFoundation made no key request: \(error.map(Self.describe) ?? "unknown")")
                    return
                }
                self.pendingKeys[keyURI] = keyRequest
                self.client()?.keyRequest(session: self.id, keyURI: keyURI, request: request)
            }
        }
    }

    // MARK: The playlist, from memory

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = "public.m3u-playlist"
            information.contentLength = Int64(playlist.count)
            information.isByteRangeAccessSupported = false
        }
        if let data = loadingRequest.dataRequest {
            let start = Int(data.requestedOffset)
            let end = data.requestsAllDataToEndOfResource ? playlist.count : min(playlist.count, start + data.requestedLength)
            if start < end { data.respond(with: playlist.subdata(in: start..<end)) }
        }
        loadingRequest.finishLoading()
        return true
    }

    // MARK: Reports

    @objc private func didPlayToEnd() {
        DispatchQueue.main.async { [self] in
            ended = true
            report()
        }
    }

    @objc private func failedToPlayToEnd(_ notification: Notification) {
        let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error).map(Self.describe)
        DispatchQueue.main.async { [self] in fail(message ?? "playback stopped") }
    }

    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        report()
    }

    private func report(seeked: Bool = false) {
        guard let player else { return }
        let item = player.currentItem
        let duration = item.map { CMTimeGetSeconds($0.duration) } ?? .nan
        let bufferedEnd = item?.loadedTimeRanges.last.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) } ?? 0
        var state: [String: Any] = [
            "currentTime": max(0, CMTimeGetSeconds(player.currentTime())),
            "duration": duration.isFinite ? duration : -1,
            "paused": player.timeControlStatus == .paused,
            "waiting": player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
            "rate": Double(player.defaultRate),
            "ended": ended,
            "buffered": bufferedEnd.isFinite ? bufferedEnd : 0,
            "ready": item?.status == .readyToPlay,
        ]
        if seeked { state["seeked"] = true }
        if let failure { state["error"] = failure }
        guard seeked || !NSDictionary(dictionary: state).isEqual(to: lastReport) else { return }
        lastReport = state
        guard let json = try? JSONSerialization.data(withJSONObject: state) else { return }
        client()?.state(session: id, json: json)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "CefFairPlay", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.localizedDescription) (\(error.domain) \(error.code))"
    }
}
