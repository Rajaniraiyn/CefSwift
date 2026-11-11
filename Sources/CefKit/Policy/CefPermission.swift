import CCef
import Foundation

/// The kinds of permission a page can request.
public struct CefPermissionKind: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let camera = CefPermissionKind(rawValue: 1 << 0)
    public static let microphone = CefPermissionKind(rawValue: 1 << 1)
    public static let geolocation = CefPermissionKind(rawValue: 1 << 2)
    public static let notifications = CefPermissionKind(rawValue: 1 << 3)
    public static let clipboard = CefPermissionKind(rawValue: 1 << 4)
    public static let midi = CefPermissionKind(rawValue: 1 << 5)
    public static let pointerLock = CefPermissionKind(rawValue: 1 << 6)
    public static let storageAccess = CefPermissionKind(rawValue: 1 << 7)
    public static let sensors = CefPermissionKind(rawValue: 1 << 8)
    public static let windowManagement = CefPermissionKind(rawValue: 1 << 9)
    public static let downloads = CefPermissionKind(rawValue: 1 << 10)
    /// A permission with no more specific kind.
    public static let other = CefPermissionKind(rawValue: 1 << 31)

    private static let requestTypes: [(cef_permission_request_types_t, CefPermissionKind)] = [
        (CEF_PERMISSION_TYPE_CAMERA_STREAM, .camera),
        (CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, .camera),
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
        (CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, .downloads),
    ]

    /// Maps the `cef_permission_request_types_t` mask passed to
    /// `on_show_permission_prompt`. Types without a kind become ``other``.
    static func fromRequestTypes(_ value: UInt32) -> CefPermissionKind {
        var kinds: CefPermissionKind = []
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
    static func fromMediaTypes(_ value: UInt32) -> CefPermissionKind {
        var kinds: CefPermissionKind = []
        if value & UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue) != 0 { kinds.insert(.microphone) }
        if value & UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue) != 0 { kinds.insert(.camera) }
        if value & UInt32(CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE.rawValue) != 0 { kinds.insert(.microphone) }
        if value & UInt32(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE.rawValue) != 0 { kinds.insert(.camera) }
        return kinds
    }

    /// The media permission mask to grant: these kinds, limited to what was
    /// requested, as CEF requires.
    func mediaMask(within requested: UInt32) -> UInt32 {
        var mask: UInt32 = 0
        if contains(.microphone) {
            mask |= UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue)
            mask |= UInt32(CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE.rawValue)
        }
        if contains(.camera) {
            mask |= UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue)
            mask |= UInt32(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE.rawValue)
        }
        return mask & requested
    }
}

/// The answer to a ``CefPermissionRequest``.
public enum CefPermissionDecision: Sendable, Equatable {
    /// Grant the request.
    case allow
    /// Refuse the request.
    case deny
    /// Dismiss the prompt without deciding; the page may ask again.
    case dismiss
}

/// A permission request delivered to
/// ``CefBrowserDelegate/browser(_:decidePermission:)``.
public struct CefPermissionRequest: Sendable, Equatable {
    /// The permissions requested; a request can combine several.
    public var kinds: CefPermissionKind
    /// The origin asking for permission.
    public var origin: String

    public init(kinds: CefPermissionKind, origin: String) {
        self.kinds = kinds
        self.origin = origin
    }
}

extension CefPermissionDecision {
    var cefResult: cef_permission_request_result_t {
        switch self {
        case .allow: return CEF_PERMISSION_RESULT_ACCEPT
        case .deny: return CEF_PERMISSION_RESULT_DENY
        case .dismiss: return CEF_PERMISSION_RESULT_DISMISS
        }
    }
}
