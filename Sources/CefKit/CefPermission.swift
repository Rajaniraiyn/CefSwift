import CCef
import Foundation

/// A class of permission a page can request. Maps the
/// `cef_permission_request_types_t` and `cef_media_access_permission_types_t`
/// bit flags onto a Swift `OptionSet`.
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
    /// Any requested permission not mapped to a more specific case above.
    public static let other = CefPermissionKind(rawValue: 1 << 31)

    /// Maps `cef_permission_request_types_t` flags (used by
    /// `on_show_permission_prompt`).
    static func fromRequestTypes(_ value: UInt32) -> CefPermissionKind {
        var kinds: CefPermissionKind = []
        func test(_ cef: cef_permission_request_types_t, _ kind: CefPermissionKind) {
            if value & UInt32(cef.rawValue) != 0 { kinds.insert(kind) }
        }
        test(CEF_PERMISSION_TYPE_CAMERA_STREAM, .camera)
        test(CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, .camera)
        test(CEF_PERMISSION_TYPE_MIC_STREAM, .microphone)
        test(CEF_PERMISSION_TYPE_GEOLOCATION, .geolocation)
        test(CEF_PERMISSION_TYPE_NOTIFICATIONS, .notifications)
        test(CEF_PERMISSION_TYPE_CLIPBOARD, .clipboard)
        test(CEF_PERMISSION_TYPE_MIDI_SYSEX, .midi)
        test(CEF_PERMISSION_TYPE_POINTER_LOCK, .pointerLock)
        test(CEF_PERMISSION_TYPE_STORAGE_ACCESS, .storageAccess)
        test(CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, .storageAccess)
        test(CEF_PERMISSION_TYPE_SENSORS, .sensors)
        test(CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, .windowManagement)
        test(CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, .downloads)
        // Anything requested but unmapped: surface as .other so the app can
        // make an informed allow/deny decision rather than silently dropping.
        let mappedMask: UInt32 =
            UInt32(CEF_PERMISSION_TYPE_CAMERA_STREAM.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_MIC_STREAM.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_GEOLOCATION.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_NOTIFICATIONS.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_CLIPBOARD.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_MIDI_SYSEX.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_POINTER_LOCK.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_STORAGE_ACCESS.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_SENSORS.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS.rawValue)
        if value & ~mappedMask != 0 { kinds.insert(.other) }
        return kinds
    }

    /// Maps `cef_media_access_permission_types_t` flags (used by
    /// `on_request_media_access_permission`).
    static func fromMediaTypes(_ value: UInt32) -> CefPermissionKind {
        var kinds: CefPermissionKind = []
        if value & UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue) != 0 { kinds.insert(.microphone) }
        if value & UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue) != 0 { kinds.insert(.camera) }
        if value & UInt32(CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE.rawValue) != 0 { kinds.insert(.microphone) }
        if value & UInt32(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE.rawValue) != 0 { kinds.insert(.camera) }
        return kinds
    }

    /// Re-encodes media kinds back to `cef_media_access_permission_types_t`
    /// flags for the allow path (CEF requires the allowed mask to be a subset
    /// of the requested mask).
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

/// How to resolve a ``CefPermissionRequest``.
public enum CefPermissionDecision: Sendable, Equatable {
    /// Grant the request.
    case allow
    /// Refuse the request.
    case deny
    /// Dismiss without a decision (the page may ask again).
    case dismiss
}

/// A permission request delivered to
/// ``CefBrowserDelegate/browser(_:requestsPermission:)``.
public struct CefPermissionRequest: Sendable, Equatable {
    /// The permission classes requested (may combine several).
    public var kinds: CefPermissionKind
    /// The origin (scheme + host) requesting permission.
    public var origin: String

    public init(kinds: CefPermissionKind, origin: String) {
        self.kinds = kinds
        self.origin = origin
    }
}

extension CefPermissionDecision {
    /// Maps to the `cef_permission_request_result_t` continue value.
    var cefResult: cef_permission_request_result_t {
        switch self {
        case .allow: return CEF_PERMISSION_RESULT_ACCEPT
        case .deny: return CEF_PERMISSION_RESULT_DENY
        case .dismiss: return CEF_PERMISSION_RESULT_DISMISS
        }
    }
}
