import Foundation

extension CefPermissionKind {
    /// The site permissions these kinds are stored as. ``other`` has none,
    /// and neither has ``protectedMediaIdentifier``: Chromium keeps no such
    /// setting on macOS.
    public var sitePermissions: [CefSitePermission] {
        let mapping: [(CefPermissionKind, CefSitePermission)] = [
            (.camera, .camera), (.microphone, .microphone), (.geolocation, .geolocation),
            (.notifications, .notifications), (.clipboard, .clipboard), (.midi, .midiSystemExclusive),
            (.pointerLock, .pointerLock), (.storageAccess, .storageAccess), (.sensors, .sensors),
            (.windowManagement, .windowManagement), (.multipleDownloads, .automaticDownloads),
        ]
        return mapping.filter { contains($0.0) }.map(\.1)
    }

    /// The single kinds in this set.
    var members: [CefPermissionKind] {
        (0..<32).map { CefPermissionKind(rawValue: 1 << $0) }.filter { contains($0) }
    }
}

/// How a request is answered from what a profile stores, before anyone is
/// asked.
struct CefStoredPermissionAnswer: Equatable {
    /// Kinds the profile allows.
    var allowed: CefPermissionKind = []
    /// Kinds the profile blocks.
    var blocked: CefPermissionKind = []
    /// Kinds nothing decides yet: the delegate is asked about these.
    var undecided: CefPermissionKind = []

    /// Sorts `kinds` by the stored setting of each: a kind is allowed or
    /// blocked when every site permission it maps to is, and undecided
    /// otherwise, as is ``CefPermissionKind/other``.
    init(kinds: CefPermissionKind, setting: (CefSitePermission) -> CefSitePermission.Setting) {
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
    func granted(after decision: CefPermissionDecision?) -> CefPermissionKind {
        decision?.grants == true ? allowed.union(undecided) : allowed
    }
}

extension CefBrowser {
    /// The profile this browser stores site settings in.
    var siteSettingsProfile: CefProfile { options.profile ?? .default }

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
    func remember(_ decision: CefPermissionDecision, for kinds: CefPermissionKind, origin: String) {
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
