import AppKit
import Foundation

/// An extension installed in a profile, as `chrome://extensions` lists it.
///
/// Read from Chromium's extension system (`chrome.developerPrivate`), with
/// what only the extension's manifest says (its toolbar action, the pages it
/// replaces) read from the extension's directory.
public struct CefExtension: Sendable, Identifiable, Hashable {
    /// Chromium's identifier for an extension: 32 letters from `a` to `p`,
    /// the same in every profile and in the Chrome Web Store.
    public struct ID: Sendable, Hashable, CustomStringConvertible, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public var description: String { rawValue }
    }

    /// Whether the extension runs.
    public enum State: Sendable, Hashable {
        case enabled
        /// Turned off, by the user or by Chromium (a permission increase,
        /// an extension another program installed and nobody accepted yet).
        case disabled
        /// Its background crashed; reloading starts it again.
        case terminated
        /// Chromium's blocklist (Safe Browsing) disabled it.
        case blocklisted
    }

    /// Where the extension came from.
    public enum InstallSource: Sendable, Hashable {
        /// The Chrome Web Store, installed by the user.
        case webStore
        /// A developer's unpacked directory: "Load unpacked", or
        /// ``CefKit/CefRuntime/Configuration/Extension/unpacked(at:)``.
        case unpacked
        /// Another program, or ``CefKit/CefRuntime/Configuration/extensions``:
        /// a store identifier or a package.
        case external
        /// Installed by default or by Chromium.
        case installedByDefault
        /// Enterprise policy.
        case policy
        case other
    }

    /// Which sites an extension that asks for site access may read and
    /// change, as the user chose in Chrome's extensions menu.
    public enum SiteAccess: Sendable, Hashable {
        /// Only when the user clicks its action.
        case onClick
        /// Only the sites in ``CefExtension/hosts`` the user allowed.
        case onSpecificSites
        /// Every site it asked for.
        case onAllSites
    }

    /// A keyboard command the extension declares, and its shortcut.
    public struct Command: Sendable, Hashable {
        /// The manifest's name; `_execute_action` is the toolbar action.
        public var name: String
        public var description: String
        /// The shortcut, as Chromium shows it (`⌃⇧Y`); empty when none is set.
        public var shortcut: String
        /// Whether it runs the extension's toolbar action.
        public var isAction: Bool

        /// For previews and tests.
        public init(name: String, description: String, shortcut: String, isAction: Bool) {
            self.name = name
            self.description = description
            self.shortcut = shortcut
            self.isAction = isAction
        }
    }

    /// The extension's toolbar action (`action` in its manifest), as
    /// declared: Chromium does not let other code read what the extension
    /// sets later per tab (its badge, title or icon).
    public struct Action: Sendable, Hashable {
        /// The default tooltip.
        public var title: String
        /// The page its popup shows; `nil` when a click runs its click
        /// handler instead.
        public var popupURL: URL?
        /// The default icon's image file, the largest declared.
        public var iconData: Data?

        /// For previews and tests.
        public init(title: String, popupURL: URL? = nil, iconData: Data? = nil) {
            self.title = title
            self.popupURL = popupURL
            self.iconData = iconData
        }

        /// ``iconData`` as an image.
        public var icon: NSImage? { iconData.flatMap(NSImage.init(data:)) }
    }

    /// A page of Chromium's the extension replaces
    /// (`chrome_url_overrides`).
    public enum ReplacedPage: String, Sendable, Hashable {
        case newTab = "newtab"
        case history
        case bookmarks
    }

    public var id: ID
    public var name: String
    public var version: String
    public var description: String
    /// The extension's icon, as Chromium shows it in `chrome://extensions`
    /// (greyed when disabled): PNG data.
    public var iconData: Data?
    public var state: State
    public var installSource: InstallSource
    /// The directory Chromium runs the extension from.
    public var directory: URL?
    /// Its options page.
    public var optionsURL: URL?
    /// Whether ``optionsURL`` opens in a tab of its own (`options_page`, or
    /// `options_ui` with `open_in_tab`) rather than inside `chrome://extensions`.
    public var opensOptionsInTab: Bool
    public var homepageURL: URL?
    public var webStoreURL: URL?
    /// The permission warnings Chromium shows for it ("Read and change all
    /// your data on all websites").
    public var permissionWarnings: [String]
    /// The sites it asked for, each with whether it may use it.
    public var hosts: [Host]
    /// `nil` for an extension that asks for no site access.
    public var siteAccess: SiteAccess?
    public var isAllowedInIncognito: Bool
    /// Whether the user can disable or remove it: `false` for policy and
    /// component extensions.
    public var isUserModifiable: Bool
    public var commands: [Command]
    public var action: Action?
    /// Pages of Chromium's it replaces, with its page for each.
    public var replacedPages: [ReplacedPage: URL]

    /// A site the extension asked for.
    public struct Host: Sendable, Hashable {
        /// A match pattern, `https://*.example.com/*`.
        public var pattern: String
        public var isGranted: Bool

        /// For previews and tests.
        public init(pattern: String, isGranted: Bool) {
            self.pattern = pattern
            self.isGranted = isGranted
        }
    }

    public var isEnabled: Bool { state == .enabled }

    /// ``iconData`` as an image.
    public var icon: NSImage? { iconData.flatMap(NSImage.init(data:)) }

    /// For previews and tests.
    public init(
        id: ID, name: String, version: String = "1.0", description: String = "", iconData: Data? = nil,
        state: State = .enabled, installSource: InstallSource = .webStore, directory: URL? = nil,
        optionsURL: URL? = nil, opensOptionsInTab: Bool = true, homepageURL: URL? = nil, webStoreURL: URL? = nil,
        permissionWarnings: [String] = [], hosts: [Host] = [], siteAccess: SiteAccess? = nil,
        isAllowedInIncognito: Bool = false, isUserModifiable: Bool = true, commands: [Command] = [],
        action: Action? = nil, replacedPages: [ReplacedPage: URL] = [:]
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.iconData = iconData
        self.state = state
        self.installSource = installSource
        self.directory = directory
        self.optionsURL = optionsURL
        self.opensOptionsInTab = opensOptionsInTab
        self.homepageURL = homepageURL
        self.webStoreURL = webStoreURL
        self.permissionWarnings = permissionWarnings
        self.hosts = hosts
        self.siteAccess = siteAccess
        self.isAllowedInIncognito = isAllowedInIncognito
        self.isUserModifiable = isUserModifiable
        self.commands = commands
        self.action = action
        self.replacedPages = replacedPages
    }
}

// MARK: - Decoding

/// `chrome.developerPrivate.ExtensionInfo`, the fields CefChromium reads.
struct DeveloperExtensionInfo: Decodable, Sendable {
    struct Toggle: Decodable, Sendable { var isActive: Bool? }
    struct OptionsPage: Decodable, Sendable { var openInTab: Bool?; var url: String? }
    struct HomePage: Decodable, Sendable { var specified: Bool?; var url: String? }
    struct Permission: Decodable, Sendable { var message: String }
    struct HostGrant: Decodable, Sendable { var host: String; var granted: Bool? }
    struct RuntimeHosts: Decodable, Sendable { var hostAccess: String?; var hosts: [HostGrant]? }
    struct Permissions: Decodable, Sendable {
        var simplePermissions: [Permission]?
        var runtimeHostPermissions: RuntimeHosts?
    }
    struct CommandInfo: Decodable, Sendable {
        var name: String
        var description: String?
        var keybinding: String?
        var isExtensionAction: Bool?
    }

    var id: String
    var name: String
    var version: String?
    var description: String?
    var iconUrl: String?
    var state: String?
    var location: String?
    var path: String?
    var optionsPage: OptionsPage?
    var homePage: HomePage?
    var webStoreUrl: String?
    var permissions: Permissions?
    var incognitoAccess: Toggle?
    var userMayModify: Bool?
    var mustRemainInstalled: Bool?
    var commands: [CommandInfo]?
    /// Set for an extension an administrator's policy installed.
    var controlledInfo: ControlledInfo?
    struct ControlledInfo: Decodable, Sendable { var text: String? }
}

/// The parts of `manifest.json` that `developerPrivate` does not report.
struct ExtensionManifest: Decodable, Sendable {
    struct ActionInfo: Decodable, Sendable {
        var default_title: String?
        var default_popup: String?
        var default_icon: IconSet?
    }

    /// `"icon.png"` or `{"16": "icon16.png", …}`.
    enum IconSet: Decodable, Sendable {
        case single(String)
        case sizes([String: String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let path = try? container.decode(String.self) {
                self = .single(path)
            } else {
                self = .sizes(try container.decode([String: String].self))
            }
        }

        /// The largest icon's path.
        var largest: String? {
            switch self {
            case .single(let path): path
            case .sizes(let sizes): sizes.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }?.value
            }
        }
    }

    var action: ActionInfo?
    /// Manifest V2's toolbar actions.
    var browser_action: ActionInfo?
    var page_action: ActionInfo?
    var chrome_url_overrides: [String: String]?

    /// The manifest in `directory`. Chromium has parsed it already; one it
    /// rewrote in a way this cannot read gives nothing.
    static func read(in directory: URL) -> ExtensionManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(ExtensionManifest.self, from: data)
    }
}

extension CefExtension {
    /// The extension `info` describes, with what `manifest` adds.
    init(_ info: DeveloperExtensionInfo, manifest: ExtensionManifest?) {
        let base = URL(string: "chrome-extension://\(info.id)/")
        let directory = info.path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        func resource(_ path: String?) -> URL? {
            guard let path, !path.isEmpty, let base else { return nil }
            return URL(string: path, relativeTo: base)?.absoluteURL
        }
        func file(_ path: String?) -> Data? {
            guard let path, let directory, !path.contains("..") else { return nil }
            let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return try? Data(contentsOf: directory.appendingPathComponent(trimmed))
        }
        let declaredAction = manifest?.action ?? manifest?.browser_action ?? manifest?.page_action
        let commands = (info.commands ?? []).map {
            Command(name: $0.name, description: $0.description ?? "", shortcut: $0.keybinding ?? "",
                    isAction: $0.isExtensionAction ?? false)
        }
        let hasAction = declaredAction != nil || commands.contains(where: \.isAction)
        var replaced: [ReplacedPage: URL] = [:]
        for (key, path) in manifest?.chrome_url_overrides ?? [:] {
            if let page = ReplacedPage(rawValue: key), let url = resource(path) { replaced[page] = url }
        }
        self.init(
            id: ID(info.id),
            name: info.name,
            version: info.version ?? "",
            description: info.description ?? "",
            iconData: info.iconUrl.flatMap(Self.dataURLContents),
            state: Self.state(info.state),
            installSource: info.controlledInfo != nil ? .policy : Self.installSource(info.location),
            directory: directory,
            optionsURL: info.optionsPage?.url.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            opensOptionsInTab: info.optionsPage?.openInTab ?? true,
            homepageURL: info.homePage?.url.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            webStoreURL: info.webStoreUrl.flatMap { $0.isEmpty ? nil : URL(string: $0) },
            permissionWarnings: (info.permissions?.simplePermissions ?? []).map(\.message),
            hosts: (info.permissions?.runtimeHostPermissions?.hosts ?? []).map {
                Host(pattern: $0.host, isGranted: $0.granted ?? false)
            },
            siteAccess: Self.siteAccess(info.permissions?.runtimeHostPermissions?.hostAccess),
            isAllowedInIncognito: info.incognitoAccess?.isActive ?? false,
            isUserModifiable: (info.userMayModify ?? true) && !(info.mustRemainInstalled ?? false),
            commands: commands,
            action: hasAction
                ? Action(
                    title: declaredAction?.default_title ?? info.name,
                    popupURL: resource(declaredAction?.default_popup),
                    iconData: file(declaredAction?.default_icon?.largest))
                : nil,
            replacedPages: replaced)
    }

    /// The bytes of a `data:` URL in base64, as `developerPrivate` gives icons.
    static func dataURLContents(_ url: String) -> Data? {
        guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ","),
              url[..<comma].hasSuffix(";base64")
        else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    static func state(_ value: String?) -> State {
        switch value {
        case "ENABLED": .enabled
        case "TERMINATED": .terminated
        case "BLOCKLISTED", "BLACKLISTED": .blocklisted
        default: .disabled
        }
    }

    static func installSource(_ value: String?) -> InstallSource {
        switch value {
        case "FROM_STORE": .webStore
        case "UNPACKED": .unpacked
        case "THIRD_PARTY": .external
        case "INSTALLED_BY_DEFAULT": .installedByDefault
        default: .other
        }
    }

    static func siteAccess(_ value: String?) -> SiteAccess? {
        switch value {
        case "ON_CLICK": .onClick
        case "ON_SPECIFIC_SITES": .onSpecificSites
        case "ON_ALL_SITES": .onAllSites
        default: nil
        }
    }
}

extension CefExtension.SiteAccess {
    /// `chrome.developerPrivate.HostAccess`.
    var developerValue: String {
        switch self {
        case .onClick: "ON_CLICK"
        case .onSpecificSites: "ON_SPECIFIC_SITES"
        case .onAllSites: "ON_ALL_SITES"
        }
    }
}
