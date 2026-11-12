import CCef
import CefBase
import Foundation

/// A per-site permission a profile stores: what a site may use, such as the
/// camera, notifications or pop-ups.
///
/// Each kind is one of Chromium's content settings. Read and change them
/// with ``CefProfile/siteSettings``.
public enum CefSitePermission: String, CaseIterable, Sendable, Codable {
    case camera
    case microphone
    case geolocation
    case notifications
    /// Opening pop-up windows without a user gesture.
    case popups
    case javaScript
    case images
    /// Storing cookies and site data. Also takes ``Setting/sessionOnly``.
    case cookies
    /// Playing sound.
    case sound
    /// Downloading several files one after another.
    case automaticDownloads
    /// Reading the clipboard.
    case clipboard
    /// Web MIDI, with system-exclusive messages.
    case midiSystemExclusive
    /// Motion and light sensors.
    case sensors
    /// Asking to connect to USB devices.
    case usbDevices
    /// Asking to connect to serial ports.
    case serialPorts
    /// Asking to connect to HID devices.
    case hidDevices
    /// Asking to connect to Bluetooth devices.
    case bluetoothDevices
    /// Scanning for nearby Bluetooth devices.
    case bluetoothScanning
    /// Placing windows across displays.
    case windowManagement
    /// Using the fonts installed on this Mac.
    case localFonts
    /// Using its cookies while embedded in another site.
    case storageAccess
    /// Detecting when the user is idle.
    case idleDetection
    /// Asking to edit files and folders.
    case fileEditing
    /// Hiding and locking the pointer.
    case pointerLock
    /// Capturing keys such as Escape and ⌘-Tab.
    case keyboardLock
    /// Entering full screen without a gesture.
    case automaticFullscreen
    /// Entering picture in picture by itself.
    case automaticPictureInPicture
    /// Loading scripts over HTTP on an HTTPS page.
    case insecureContent
    /// Connecting to devices on the local network.
    case localNetworkAccess
    /// Showing ads that Chromium's ad filter flags as intrusive.
    case intrusiveAds
    /// Finishing sends and uploads after the page closes.
    case backgroundSync
    /// Installing payment handlers.
    case paymentHandlers
    /// Moving the camera (pan, tilt, zoom).
    case cameraPanTiltZoom
    /// Running JavaScript with V8's optimizing compilers.
    case javaScriptOptimization

    /// What a profile stores for one permission and site.
    public enum Setting: String, Sendable, Codable, CaseIterable {
        /// The site may use it without asking.
        case allow
        /// The site may not use it, and is not asked about it.
        case block
        /// The site has to ask, and the browser's delegate decides.
        case ask
        /// Cookies only: allowed, and deleted when the session ends.
        case sessionOnly
        /// No value of its own: the profile's default applies.
        case `default`
    }

    /// The name to show for the permission, such as “Camera”.
    public var localizedName: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .geolocation: "Location"
        case .notifications: "Notifications"
        case .popups: "Pop-ups and redirects"
        case .javaScript: "JavaScript"
        case .images: "Images"
        case .cookies: "Cookies and site data"
        case .sound: "Sound"
        case .automaticDownloads: "Automatic downloads"
        case .clipboard: "Clipboard"
        case .midiSystemExclusive: "MIDI devices"
        case .sensors: "Motion sensors"
        case .usbDevices: "USB devices"
        case .serialPorts: "Serial ports"
        case .hidDevices: "HID devices"
        case .bluetoothDevices: "Bluetooth devices"
        case .bluetoothScanning: "Bluetooth scanning"
        case .windowManagement: "Window management"
        case .localFonts: "Fonts"
        case .storageAccess: "Embedded content"
        case .idleDetection: "Your device use"
        case .fileEditing: "File editing"
        case .pointerLock: "Pointer lock"
        case .keyboardLock: "Keyboard lock"
        case .automaticFullscreen: "Automatic full screen"
        case .automaticPictureInPicture: "Automatic picture in picture"
        case .insecureContent: "Insecure content"
        case .localNetworkAccess: "Local network"
        case .intrusiveAds: "Intrusive ads"
        case .backgroundSync: "Background sync"
        case .paymentHandlers: "Payment handlers"
        case .cameraPanTiltZoom: "Camera movement"
        case .javaScriptOptimization: "JavaScript optimization"
        }
    }

    /// The settings Chromium accepts for this permission, besides
    /// ``Setting/default``. Others are ignored when set.
    public var supportedSettings: [Setting] {
        switch self {
        case .cookies: [.allow, .block, .sessionOnly]
        case .popups, .javaScript, .images, .sound, .sensors, .insecureContent, .intrusiveAds, .backgroundSync,
             .paymentHandlers, .javaScriptOptimization, .automaticFullscreen:
            [.allow, .block]
        case .usbDevices, .serialPorts, .hidDevices, .bluetoothDevices, .bluetoothScanning, .fileEditing:
            [.ask, .block]
        default: [.allow, .block, .ask]
        }
    }

    /// Whether a site gets the permission by asking: a prompt-based
    /// permission rather than a content switch such as images.
    public var isRequestable: Bool { supportedSettings.contains(.ask) }

    /// Chromium's content-setting type.
    var contentType: cef_content_setting_types_t {
        switch self {
        case .camera: CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA
        case .microphone: CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC
        case .geolocation: CEF_CONTENT_SETTING_TYPE_GEOLOCATION
        case .notifications: CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS
        case .popups: CEF_CONTENT_SETTING_TYPE_POPUPS
        case .javaScript: CEF_CONTENT_SETTING_TYPE_JAVASCRIPT
        case .images: CEF_CONTENT_SETTING_TYPE_IMAGES
        case .cookies: CEF_CONTENT_SETTING_TYPE_COOKIES
        case .sound: CEF_CONTENT_SETTING_TYPE_SOUND
        case .automaticDownloads: CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS
        case .clipboard: CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE
        case .midiSystemExclusive: CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX
        case .sensors: CEF_CONTENT_SETTING_TYPE_SENSORS
        case .usbDevices: CEF_CONTENT_SETTING_TYPE_USB_GUARD
        case .serialPorts: CEF_CONTENT_SETTING_TYPE_SERIAL_GUARD
        case .hidDevices: CEF_CONTENT_SETTING_TYPE_HID_GUARD
        case .bluetoothDevices: CEF_CONTENT_SETTING_TYPE_BLUETOOTH_GUARD
        case .bluetoothScanning: CEF_CONTENT_SETTING_TYPE_BLUETOOTH_SCANNING
        case .windowManagement: CEF_CONTENT_SETTING_TYPE_WINDOW_MANAGEMENT
        case .localFonts: CEF_CONTENT_SETTING_TYPE_LOCAL_FONTS
        case .storageAccess: CEF_CONTENT_SETTING_TYPE_STORAGE_ACCESS
        case .idleDetection: CEF_CONTENT_SETTING_TYPE_IDLE_DETECTION
        case .fileEditing: CEF_CONTENT_SETTING_TYPE_FILE_SYSTEM_WRITE_GUARD
        case .pointerLock: CEF_CONTENT_SETTING_TYPE_POINTER_LOCK
        case .keyboardLock: CEF_CONTENT_SETTING_TYPE_KEYBOARD_LOCK
        case .automaticFullscreen: CEF_CONTENT_SETTING_TYPE_AUTOMATIC_FULLSCREEN
        case .automaticPictureInPicture: CEF_CONTENT_SETTING_TYPE_AUTO_PICTURE_IN_PICTURE
        case .insecureContent: CEF_CONTENT_SETTING_TYPE_MIXEDSCRIPT
        case .localNetworkAccess: CEF_CONTENT_SETTING_TYPE_LOCAL_NETWORK_ACCESS
        case .intrusiveAds: CEF_CONTENT_SETTING_TYPE_ADS
        case .backgroundSync: CEF_CONTENT_SETTING_TYPE_BACKGROUND_SYNC
        case .paymentHandlers: CEF_CONTENT_SETTING_TYPE_PAYMENT_HANDLER
        case .cameraPanTiltZoom: CEF_CONTENT_SETTING_TYPE_CAMERA_PAN_TILT_ZOOM
        case .javaScriptOptimization: CEF_CONTENT_SETTING_TYPE_JAVASCRIPT_JIT
        }
    }

    /// The permission for a Chromium content-setting type, if CefSwift has one.
    init?(contentType: cef_content_setting_types_t) {
        guard let match = Self.allCases.first(where: { $0.contentType == contentType }) else { return nil }
        self = match
    }

    /// The name Chromium stores the permission's site exceptions under, in
    /// the `profile.content_settings.exceptions` preference.
    var storageName: String {
        switch self {
        case .camera: "media_stream_camera"
        case .microphone: "media_stream_mic"
        case .geolocation: "geolocation"
        case .notifications: "notifications"
        case .popups: "popups"
        case .javaScript: "javascript"
        case .images: "images"
        case .cookies: "cookies"
        case .sound: "sound"
        case .automaticDownloads: "automatic_downloads"
        case .clipboard: "clipboard"
        case .midiSystemExclusive: "midi_sysex"
        case .sensors: "sensors"
        case .usbDevices: "usb_guard"
        case .serialPorts: "serial_guard"
        case .hidDevices: "hid_guard"
        case .bluetoothDevices: "bluetooth_guard"
        case .bluetoothScanning: "bluetooth_scanning"
        case .windowManagement: "window_placement"
        case .localFonts: "local_fonts"
        case .storageAccess: "storage_access"
        case .idleDetection: "idle_detection"
        case .fileEditing: "file_system_write_guard"
        case .pointerLock: "pointer_lock"
        case .keyboardLock: "keyboard_lock"
        case .automaticFullscreen: "automatic_fullscreen"
        case .automaticPictureInPicture: "auto_picture_in_picture"
        case .insecureContent: "mixed_script"
        case .localNetworkAccess: "local_network_access"
        case .intrusiveAds: "subresource_filter"
        case .backgroundSync: "background_sync"
        case .paymentHandlers: "payment_handler"
        case .cameraPanTiltZoom: "camera_pan_tilt_zoom"
        case .javaScriptOptimization: "javascript_jit"
        }
    }
}

extension CefSitePermission.Setting {
    init(cefValue: cef_content_setting_values_t) {
        switch cefValue {
        case CEF_CONTENT_SETTING_VALUE_ALLOW: self = .allow
        case CEF_CONTENT_SETTING_VALUE_BLOCK: self = .block
        case CEF_CONTENT_SETTING_VALUE_ASK: self = .ask
        case CEF_CONTENT_SETTING_VALUE_SESSION_ONLY: self = .sessionOnly
        default: self = .default
        }
    }

    /// The setting a stored exception's `setting` number stands for.
    init?(storedValue: Int) {
        guard let value = cef_content_setting_values_t(exactly: storedValue) else { return nil }
        self.init(cefValue: value)
    }

    var cefValue: cef_content_setting_values_t {
        switch self {
        case .allow: CEF_CONTENT_SETTING_VALUE_ALLOW
        case .block: CEF_CONTENT_SETTING_VALUE_BLOCK
        case .ask: CEF_CONTENT_SETTING_VALUE_ASK
        case .sessionOnly: CEF_CONTENT_SETTING_VALUE_SESSION_ONLY
        case .default: CEF_CONTENT_SETTING_VALUE_DEFAULT
        }
    }
}

extension cef_content_setting_values_t {
    fileprivate init?(exactly value: Int) {
        guard let raw = UInt32(exactly: value) else { return nil }
        self.init(rawValue: raw)
    }
}

/// A profile's per-site permissions: what each site may use, as Chrome's
/// site settings show them.
///
/// ```swift
/// let site = URL(string: "https://meet.example")!
/// let settings = profile.siteSettings
/// settings.set(.allow, for: .camera, origin: site)
/// settings.setting(for: .notifications, origin: site)   // .ask
/// settings.reset(origin: site)
/// ```
///
/// A stored ``CefSitePermission/Setting/allow`` or
/// ``CefSitePermission/Setting/block`` answers a site's request without
/// asking ``CefBrowserDelegate/browser(_:decidePermissionFor:)``.
///
/// Settings apply to origins: `https://example.com/a` and
/// `https://example.com/b` share theirs.
@MainActor
public struct CefSiteSettings {
    /// The profile whose settings these are.
    public let profile: CefProfile

    init(profile: CefProfile) {
        self.profile = profile
    }

    /// The setting that applies to `origin`: its own, or the profile's
    /// default for the permission when it has none.
    public func setting(for permission: CefSitePermission, origin: URL) -> CefSitePermission.Setting {
        guard let context = profile.requestContext() else { return .default }
        let site = Self.origin(of: origin)
        return CefStringUtil.withCefString(site) { url in
            CefSitePermission.Setting(cefValue: context.pointer.pointee.get_content_setting(
                context.pointer, url, url, permission.contentType))
        }
    }

    /// Stores `setting` for `permission` on `origin`.
    /// ``CefSitePermission/Setting/default`` removes the site's own value.
    /// A setting the permission does not support (see
    /// ``CefSitePermission/supportedSettings``) is ignored.
    public func set(_ setting: CefSitePermission.Setting, for permission: CefSitePermission, origin: URL) {
        guard let context = profile.requestContext() else { return }
        guard setting == .default || permission.supportedSettings.contains(setting) else { return }
        let site = Self.origin(of: origin)
        CefStringUtil.withCefString(site) { url in
            context.pointer.pointee.set_content_setting(context.pointer, url, url, permission.contentType, setting.cefValue)
        }
    }

    /// The profile's default for `permission`: what applies to a site with
    /// no value of its own.
    public func defaultSetting(for permission: CefSitePermission) -> CefSitePermission.Setting {
        guard let context = profile.requestContext() else { return .default }
        return CefSitePermission.Setting(cefValue: context.pointer.pointee.get_content_setting(
            context.pointer, nil, nil, permission.contentType))
    }

    /// Changes the profile's default for `permission`;
    /// ``CefSitePermission/Setting/default`` restores Chromium's. An
    /// incognito profile keeps the default of the profile it came from:
    /// Chromium ignores this there.
    public func setDefaultSetting(_ setting: CefSitePermission.Setting, for permission: CefSitePermission) {
        guard let context = profile.requestContext() else { return }
        guard setting == .default || permission.supportedSettings.contains(setting) else { return }
        context.pointer.pointee.set_content_setting(context.pointer, nil, nil, permission.contentType, setting.cefValue)
    }

    /// Removes every value `origin` has of its own, so the profile's
    /// defaults apply to it again.
    public func reset(origin: URL) {
        for permission in CefSitePermission.allCases {
            set(.default, for: permission, origin: origin)
        }
    }

    /// Whether `origin` has a value of its own for `permission`, among
    /// those ``exceptions(for:)`` lists.
    public func hasOwnSetting(_ permission: CefSitePermission, origin: URL) -> Bool {
        exceptions(for: permission).contains { $0.applies(to: origin) }
    }

    // MARK: Stored exceptions

    /// A site's own value for one permission, as the profile stores it.
    public struct Exception: Sendable, Hashable {
        /// The permission.
        public var permission: CefSitePermission
        /// The site, when the stored pattern names one origin.
        public var origin: URL?
        /// Chromium's pattern for the sites it covers, such as
        /// `https://example.com:443` or `[*.]example.com`.
        public var pattern: String
        /// The stored value.
        public var setting: CefSitePermission.Setting

        /// Whether the exception's pattern covers `url`'s origin.
        public func applies(to url: URL) -> Bool {
            CefSiteSettings.pattern(pattern, matches: url)
        }
    }

    /// The values sites have of their own for `permission`, or for every
    /// permission when `permission` is `nil`.
    ///
    /// Chromium has no call that lists them; they come from the profile's
    /// `profile.content_settings.exceptions` preference, where it keeps
    /// them. An incognito profile keeps its values in memory, so for one
    /// this lists none of its own.
    public func exceptions(for permission: CefSitePermission? = nil) -> [Exception] {
        let permissions = permission.map { [$0] } ?? CefSitePermission.allCases
        return permissions.flatMap { permission -> [Exception] in
            guard let stored = profile.preference("profile.content_settings.exceptions.\(permission.storageName)")
            else { return [] }
            return Self.exceptions(of: permission, stored: stored)
        }
    }

    /// Parses one `profile.content_settings.exceptions.<name>` dictionary:
    /// keys are `"<primary pattern>,<secondary pattern>"`, values hold a
    /// `setting` number.
    nonisolated static func exceptions(of permission: CefSitePermission, stored: CefJSON) -> [Exception] {
        guard let entries = stored.objectValue else { return [] }
        return entries.compactMap { key, value -> Exception? in
            guard let number = value["setting"].intValue, let setting = CefSitePermission.Setting(storedValue: number)
            else { return nil }
            let primary = String(key.split(separator: ",", maxSplits: 1).first ?? "")
            return Exception(permission: permission, origin: originURL(ofPattern: primary), pattern: primary, setting: setting)
        }
        .sorted { $0.pattern < $1.pattern }
    }

    /// The origin a pattern such as `https://example.com:443` names, or
    /// `nil` for a wildcard pattern.
    nonisolated static func originURL(ofPattern pattern: String) -> URL? {
        guard !pattern.contains("*"), !pattern.contains("["),
              let components = URLComponents(string: pattern), let scheme = components.scheme, components.host != nil
        else { return nil }
        var origin = components
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        if origin.port == defaultPort { origin.port = nil }
        return origin.url
    }

    /// Whether a Chromium site pattern — `[scheme://][[*.]]host[:port]`,
    /// or `*` — covers `url`.
    nonisolated static func pattern(_ pattern: String, matches url: URL) -> Bool {
        guard pattern != "*" else { return true }
        guard let host = url.host()?.lowercased() else { return false }
        var rest = Substring(pattern)
        if let separator = rest.range(of: "://") {
            let scheme = rest[..<separator.lowerBound]
            guard scheme == "*" || scheme.lowercased() == url.scheme?.lowercased() else { return false }
            rest = rest[separator.upperBound...]
        }
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        var patternPort: Substring?
        if let colon = rest.lastIndex(of: ":"), !rest.hasSuffix("]") {
            patternPort = rest[rest.index(after: colon)...]
            rest = rest[..<colon]
        }
        if let patternPort, patternPort != "*" {
            let defaultPort = url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil
            guard Int(patternPort) == (url.port ?? defaultPort) else { return false }
        }
        let patternHost = rest.lowercased()
        if patternHost == "*" { return true }
        if patternHost.hasPrefix("[*.]") {
            let domain = patternHost.dropFirst(4)
            return host == domain || host.hasSuffix("." + domain)
        }
        return host == patternHost
    }

    /// The origin of `url`, as `scheme://host[:port]`.
    nonisolated static func origin(of url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host() else { return url.absoluteString }
        var origin = "\(scheme)://\(host)"
        if let port = url.port { origin += ":\(port)" }
        return origin
    }

    // MARK: Changes

    /// One change to a site setting.
    public struct Change: Sendable, Equatable {
        /// The permission that changed; `nil` for one of Chromium's settings
        /// CefSwift has no kind for.
        public var permission: CefSitePermission?
        /// The site whose value changed; `nil` when the profile's default
        /// changed, or for a change to many sites at once.
        public var origin: URL?
        /// The top-level site the change is scoped to, when there is one.
        public var topLevelOrigin: URL?
    }

    /// Every change to the profile's site settings, as it happens: from
    /// ``set(_:for:origin:)``, from Chromium's own permission prompts and
    /// site-settings pages, and from answers that store a decision.
    ///
    /// The stream observes for as long as it is iterated.
    public var changes: AsyncStream<Change> {
        let (stream, continuation) = AsyncStream<Change>.makeStream(bufferingPolicy: .bufferingNewest(256))
        guard let context = profile.requestContext(), let add = context.pointer.pointee.add_setting_observer else {
            continuation.finish()
            return stream
        }
        let observer = SettingObserver(continuation: continuation).makeObserver()
        guard let registration = CefObserverRegistration(adopting: add(context.pointer, observer)) else {
            continuation.finish()
            return stream
        }
        registration.end(with: continuation)
        return stream
    }
}

extension CefProfile {
    /// The profile's per-site permissions.
    public var siteSettings: CefSiteSettings { CefSiteSettings(profile: self) }
}

/// Owner of a `cef_setting_observer_t` feeding a stream. Called on the UI
/// thread.
private final class SettingObserver: Sendable {
    let continuation: AsyncStream<CefSiteSettings.Change>.Continuation

    init(continuation: AsyncStream<CefSiteSettings.Change>.Continuation) {
        self.continuation = continuation
    }

    func makeObserver() -> UnsafeMutablePointer<cef_setting_observer_t> {
        let observer = cefAllocate(cef_setting_observer_t.self, owner: self)
        observer.pointee.on_setting_changed = { s, requestingURL, topLevelURL, type in
            guard let owner = cefOwner(SettingObserver.self, s) else { return }
            let origin = CefStringUtil.string(from: requestingURL)
            let topLevel = CefStringUtil.string(from: topLevelURL)
            owner.continuation.yield(CefSiteSettings.Change(
                permission: CefSitePermission(contentType: type),
                origin: origin.isEmpty ? nil : CefSiteSettings.originURL(ofPattern: origin) ?? URL(string: origin),
                topLevelOrigin: topLevel.isEmpty ? nil : CefSiteSettings.originURL(ofPattern: topLevel) ?? URL(string: topLevel)))
        }
        return observer
    }
}
