import Foundation

extension CefPermissionRequest.Kinds {
    /// The site permissions these kinds are stored as. ``other`` has none,
    /// and neither has ``protectedMediaIdentifier``: Chromium keeps no such
    /// setting on macOS.
    public var sitePermissions: [CefSitePermission] {
        let mapping: [(CefPermissionRequest.Kinds, CefSitePermission)] = [
            (.camera, .camera), (.microphone, .microphone), (.geolocation, .geolocation),
            (.notifications, .notifications), (.clipboard, .clipboard), (.midi, .midiSystemExclusive),
            (.pointerLock, .pointerLock), (.storageAccess, .storageAccess), (.sensors, .sensors),
            (.windowManagement, .windowManagement), (.multipleDownloads, .automaticDownloads),
        ]
        return mapping.filter { contains($0.0) }.map(\.1)
    }

    /// The single kinds in this set.
    var members: [CefPermissionRequest.Kinds] {
        (0..<32).map { CefPermissionRequest.Kinds(rawValue: 1 << $0) }.filter { contains($0) }
    }
}

/// How a request is answered from what a profile stores, before anyone is
/// asked.
struct CefStoredPermissionAnswer: Equatable {
    /// Kinds the profile allows.
    var allowed: CefPermissionRequest.Kinds = []
    /// Kinds the profile blocks.
    var blocked: CefPermissionRequest.Kinds = []
    /// Kinds nothing decides yet: the delegate is asked about these.
    var undecided: CefPermissionRequest.Kinds = []

    /// Sorts `kinds` by the stored setting of each: a kind is allowed or
    /// blocked when every site permission it maps to is, and undecided
    /// otherwise, as is ``CefPermissionRequest/Kinds/other``.
    init(kinds: CefPermissionRequest.Kinds, setting: (CefSitePermission) -> CefSitePermission.Setting) {
        for kind in kinds.members {
            let settings = kind.sitePermissions.map(setting)
            if !settings.isEmpty, settings.allSatisfy({ $0 == .allow }) {
                allowed.insert(kind)
            } else if !settings.isEmpty, settings.contains(.block) {
                blocked.insert(kind)
            } else {
                undecided.insert(kind)
            }
        }
    }

    /// The kinds granted once the delegate has answered about
    /// ``undecided`` with `decision` (`nil` when it was not asked).
    func granted(after decision: CefPermissionDecision?) -> CefPermissionRequest.Kinds {
        decision?.grants == true ? allowed.union(undecided) : allowed
    }
}

extension CefBrowser {
    /// The profile this browser stores site settings in.
    var siteSettingsProfile: CefProfile { configuration.profile ?? .default }

    /// What the profile stores about `request`'s kinds for its origin.
    func storedAnswer(to request: CefPermissionRequest) -> CefStoredPermissionAnswer {
        guard let origin = URL(string: request.origin), origin.host() != nil else {
            return CefStoredPermissionAnswer(kinds: request.kinds) { _ in .ask }
        }
        let settings = siteSettingsProfile.siteSettings
        return CefStoredPermissionAnswer(kinds: request.kinds) { settings.setting(for: $0, origin: origin) }
    }

    /// Stores `decision` for `kinds` on `origin` when it is one of the
    /// remembering decisions.
    func remember(_ decision: CefPermissionDecision, for kinds: CefPermissionRequest.Kinds, origin: String) {
        let setting: CefSitePermission.Setting
        switch decision {
        case .alwaysAllow: setting = .allow
        case .alwaysDeny: setting = .block
        case .allow, .deny, .dismiss: return
        }
        guard let url = URL(string: origin), url.host() != nil else { return }
        let settings = siteSettingsProfile.siteSettings
        for permission in kinds.sitePermissions where permission.supportedSettings.contains(setting) {
            settings.set(setting, for: permission, origin: url)
        }
    }
}
