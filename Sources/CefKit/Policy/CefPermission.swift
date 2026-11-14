import CCef
import Foundation

extension CefPermissionRequest {
    /// The kinds of permission a page can request.
    public struct Kinds: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let camera = CefPermissionRequest.Kinds(rawValue: 1 << 0)
        public static let microphone = CefPermissionRequest.Kinds(rawValue: 1 << 1)
        public static let geolocation = CefPermissionRequest.Kinds(rawValue: 1 << 2)
        public static let notifications = CefPermissionRequest.Kinds(rawValue: 1 << 3)
        public static let clipboard = CefPermissionRequest.Kinds(rawValue: 1 << 4)
        public static let midi = CefPermissionRequest.Kinds(rawValue: 1 << 5)
        public static let pointerLock = CefPermissionRequest.Kinds(rawValue: 1 << 6)
        public static let storageAccess = CefPermissionRequest.Kinds(rawValue: 1 << 7)
        public static let sensors = CefPermissionRequest.Kinds(rawValue: 1 << 8)
        public static let windowManagement = CefPermissionRequest.Kinds(rawValue: 1 << 9)
        /// Downloading several files at once.
        public static let multipleDownloads = CefPermissionRequest.Kinds(rawValue: 1 << 10)
        /// A page asking to identify this device to a protected-media
        /// (DRM) licence server. Chromium asks for it only on Android,
        /// ChromeOS and Windows; on macOS, Widevine plays without it.
        public static let protectedMediaIdentifier = CefPermissionRequest.Kinds(rawValue: 1 << 11)
        /// Moving the camera: pan, tilt and zoom. Separate from ``camera``,
        /// and stored as ``CefSitePermission/cameraPanTiltZoom``.
        public static let cameraPanTiltZoom = CefPermissionRequest.Kinds(rawValue: 1 << 12)
        /// Capturing the screen, a window or a tab (`getDisplayMedia`).
        /// Granting it hands the page what is on screen without a picker.
        /// It is never answered from, or stored in, site settings: every
        /// request asks the delegate, and ``CefPermissionDecision/alwaysAllow``
        /// and ``CefPermissionDecision/alwaysDeny`` apply to that request only.
        public static let screenCapture = CefPermissionRequest.Kinds(rawValue: 1 << 13)
        /// Capturing the sound the Mac plays, along with ``screenCapture``.
        /// Like it, asked about on every request and never stored.
        public static let systemAudioCapture = CefPermissionRequest.Kinds(rawValue: 1 << 14)
        /// A permission with no more specific kind.
        public static let other = CefPermissionRequest.Kinds(rawValue: 1 << 31)

        private static let requestTypes: [(cef_permission_request_types_t, CefPermissionRequest.Kinds)] = [
            (CEF_PERMISSION_TYPE_CAMERA_STREAM, .camera),
            (CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, .cameraPanTiltZoom),
            (CEF_PERMISSION_TYPE_MIC_STREAM, .microphone),
            (CEF_PERMISSION_TYPE_GEOLOCATION, .geolocation),
            (CEF_PERMISSION_TYPE_NOTIFICATIONS, .notifications),
            (CEF_PERMISSION_TYPE_CLIPBOARD, .clipboard),
            (CEF_PERMISSION_TYPE_MIDI_SYSEX, .midi),
            (CEF_PERMISSION_TYPE_POINTER_LOCK, .pointerLock),
            (CEF_PERMISSION_TYPE_STORAGE_ACCESS, .storageAccess),
            (CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, .storageAccess),
            (CEF_PERMISSION_TYPE_SENSORS, .sensors),
            (CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, .windowManagement),
            (CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, .multipleDownloads),
            (CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER, .protectedMediaIdentifier),
        ]

        /// Maps the `cef_permission_request_types_t` mask passed to
        /// `on_show_permission_prompt`. Types without a kind become ``other``.
        static func fromRequestTypes(_ value: UInt32) -> CefPermissionRequest.Kinds {
            var kinds: CefPermissionRequest.Kinds = []
            var unmapped = value
            for (type, kind) in requestTypes where value & UInt32(type.rawValue) != 0 {
                kinds.insert(kind)
                unmapped &= ~UInt32(type.rawValue)
            }
            if unmapped != 0 { kinds.insert(.other) }
            return kinds
        }

        /// Maps the `cef_media_access_permission_types_t` mask passed to
        /// `on_request_media_access_permission`.
        static func fromMediaTypes(_ value: UInt32) -> CefPermissionRequest.Kinds {
            var kinds: CefPermissionRequest.Kinds = []
            if value & UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue) != 0 { kinds.insert(.microphone) }
            if value & UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue) != 0 { kinds.insert(.camera) }
            if value & UInt32(CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE.rawValue) != 0 { kinds.insert(.systemAudioCapture) }
            if value & UInt32(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE.rawValue) != 0 { kinds.insert(.screenCapture) }
            return kinds
        }

        /// Each media kind and the one `cef_media_access_permission_types_t`
        /// bit it grants.
        private static let mediaTypes: [(CefPermissionRequest.Kinds, cef_media_access_permission_types_t)] = [
            (.microphone, CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE),
            (.camera, CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE),
            (.systemAudioCapture, CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE),
            (.screenCapture, CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE),
        ]

        /// The media permission mask to grant: these kinds, limited to what was
        /// requested, as CEF requires. A device kind never grants desktop
        /// capture, nor the reverse.
        func mediaMask(within requested: UInt32) -> UInt32 {
            var mask: UInt32 = 0
            for (kind, type) in Self.mediaTypes where contains(kind) { mask |= UInt32(type.rawValue) }
            return mask & requested
        }
    }
}

/// The answer to a ``CefPermissionRequest``.
///
/// For prompt-based permissions (notifications, location, MIDI, window
/// management, …) Chromium itself keeps ``allow`` and ``deny`` for the
/// origin, as Chrome does, so the site is not asked again. Camera and
/// microphone answers apply to the one request; ``alwaysAllow`` and
/// ``alwaysDeny`` store them in the profile's ``CefProfile/siteSettings``.
/// Screen and system-audio capture are never stored: every such request
/// asks again.
public enum CefPermissionDecision: Sendable, Equatable {
    /// Grant the request.
    case allow
    /// Refuse the request.
    case deny
    /// Dismiss the prompt without deciding; the page may ask again.
    case dismiss
    /// Grant the request and store ``CefSitePermission/Setting/allow`` for
    /// each requested permission, so later requests are granted without
    /// asking.
    case alwaysAllow
    /// Refuse the request and store ``CefSitePermission/Setting/block`` for
    /// each requested permission, so later requests are refused without
    /// asking.
    case alwaysDeny

    /// Whether the decision grants the request.
    public var grants: Bool { self == .allow || self == .alwaysAllow }
}

/// A permission request a page makes, delivered to its delegate's
/// ``CefBrowserDelegate/browser(_:decidePermissionFor:)`` and, by
/// default, from there to its profile's
/// ``CefProfileDelegate/profile(_:decidePermissionFor:in:)``.
///
/// Origins are URLs, as ``CefSiteSettings`` takes them, so an answer can
/// be checked against or stored in the profile's site settings.
public struct CefPermissionRequest: Sendable, Equatable {
    /// The permissions requested; a request can combine several.
    public var kinds: CefPermissionRequest.Kinds
    /// The origin asking for permission, `scheme://host[:port]`: the
    /// requesting frame's.
    public var origin: URL
    /// The origin of the page's top-level document, which Chromium shows
    /// in the address bar; `nil` before the page has one. It differs from
    /// ``origin`` when an embedded frame asks.
    public var topLevelOrigin: URL?
    /// The frame asking, where CEF names it: for camera, microphone and
    /// screen capture. `nil` for the other kinds, whose requests CEF
    /// reports with their origin only.
    public var frame: CefFrame?

    /// Whether the top-level document asks: the asking ``frame`` is the
    /// main frame or, where CEF names no frame, ``origin`` is the
    /// ``topLevelOrigin``.
    public var isMainFrame: Bool {
        if let frame { return frame.isMain }
        return topLevelOrigin.map { CefSiteSettings.origin(of: $0) == CefSiteSettings.origin(of: origin) } ?? true
    }

    /// Creates a value of your own, for previews and tests.
    public init(kinds: CefPermissionRequest.Kinds, origin: URL, topLevelOrigin: URL? = nil, frame: CefFrame? = nil) {
        self.kinds = kinds
        self.origin = origin
        self.topLevelOrigin = topLevelOrigin
        self.frame = frame
    }

    /// A request from `page`, whose top-level origin is its address's;
    /// `nil` when CEF's origin is not an address with a host (an opaque
    /// origin), which nothing can be stored for.
    @MainActor
    init?(kinds: CefPermissionRequest.Kinds, origin: String, frame: CefFrame?, in page: CefBrowser) {
        guard let url = URL(string: origin), url.scheme != nil, url.host() != nil else { return nil }
        self.init(
            kinds: kinds, origin: URL(string: CefSiteSettings.origin(of: url)) ?? url,
            topLevelOrigin: page.url.flatMap { $0.host() == nil ? nil : URL(string: CefSiteSettings.origin(of: $0)) },
            frame: frame)
    }
}

extension CefPermissionDecision {
    var cefResult: cef_permission_request_result_t {
        switch self {
        case .allow, .alwaysAllow: return CEF_PERMISSION_RESULT_ACCEPT
        case .deny, .alwaysDeny: return CEF_PERMISSION_RESULT_DENY
        case .dismiss: return CEF_PERMISSION_RESULT_DISMISS
        }
    }
}
