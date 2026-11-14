import AppKit
import CefKit
import Foundation
import Observation

/// The extensions of a ``CefProfile`` — the ones `chrome://extensions`
/// lists, and Chrome's extensions menu and toolbar show in Chrome-style
/// windows.
///
/// ```swift
/// let extensions = CefProfile.default.extensions
/// for item in try await extensions.refresh() { print(item.name, item.isEnabled) }
/// try await extensions.setEnabled(false, for: item.id)
/// ```
///
/// ``installed`` is the list as last read: reading starts on first use, and
/// the list stays current while the app uses it — after each change made
/// here, and as Chromium reports installs, updates and removals, including
/// the user's in Chrome's own interface. ``changes`` yields after each.
///
/// The extensions come from Chromium's extension system itself, through
/// the `chrome.developerPrivate` and `chrome.management` APIs Chromium grants
/// its `chrome://extensions` page, reached from a hidden service host that
/// starts on first use and closes when idle. While it is closed, CefChromium
/// watches the profile's `Extensions` directory and `Preferences` file to
/// notice what changed, and reads again.
///
/// Extensions run in Chrome-style browsers (``CefWindow``,
/// ``CefRuntime/openChromeWindow(url:frame:configuration:delegate:)``);
/// their content scripts and network rules also apply to Alloy-style views.
/// An incognito profile has no extensions of its own: its
/// ``CefProfile/extensions`` are the default profile's, which run in
/// incognito only where ``CefExtension/isAllowedInIncognito``.
@MainActor
@Observable
public final class CefExtensions {
    /// Held, so the profile lives as long as this object is in use.
    @ObservationIgnored private let profile: CefProfile

    /// The installed extensions as last read, by name. Empty until the
    /// first read finishes.
    public private(set) var installed: [CefExtension] = []

    /// Extensions ``CefRuntime/Configuration/extensions`` names, by store
    /// identifier or package, that the profile does not have yet: Chromium
    /// is downloading or installing them, or could not (offline, or the
    /// identifier is not in the store). Chromium reports neither progress
    /// nor a reason; it tries again at its next start and on its update
    /// schedule.
    public private(set) var pendingInstallations: [CefExtension.ID] = []

    /// The last read's error, `nil` once a read succeeds.
    public private(set) var lastError: String?

    @ObservationIgnored private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored private var liveEvents: Task<Void, Never>?
    @ObservationIgnored private var watches: [CefFileWatch] = []
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(profile: CefProfile) {
        self.profile = profile
    }

    private var services: CefServiceHosts { profile.serviceHosts }

    // MARK: Reading

    /// Reads the installed extensions again, updates ``installed`` and
    /// returns it.
    @discardableResult
    public func refresh() async throws -> [CefExtension] {
        startIfNeeded()
        do {
            try await read()
            lastError = nil
            if await acceptConfiguredInstallations() { try await read() }
            return installed
        } catch {
            lastError = "\(error)"
            throw error
        }
    }

    private func read() async throws {
        let infos = try await services.call(
            Self.module, "s => s.d.getExtensionsInfo({includeDisabled: true, includeTerminated: true})",
            as: [DeveloperExtensionInfo].self, isIdempotent: true)
        // Manifests are read from disk, off the main actor.
        var extensions = await Task.detached(priority: .userInitiated) { Self.extensions(from: infos) }.value
        // Chromium reports a package from the user's external extensions
        // directory as of no known location.
        let configured = Set((CefRuntime.shared.configuration?.extensions ?? []).compactMap(\.id))
        for index in extensions.indices
        where extensions[index].installSource == .other && configured.contains(extensions[index].id.rawValue) {
            extensions[index].installSource = .external
        }
        if extensions != installed {
            installed = extensions
            subscribers.values.forEach { $0.yield() }
        }
    }

    nonisolated static func extensions(from infos: [DeveloperExtensionInfo]) -> [CefExtension] {
        infos.map { info in
            CefExtension(info, manifest: info.path.flatMap {
                $0.isEmpty ? nil : ExtensionManifest.read(in: URL(fileURLWithPath: $0, isDirectory: true))
            })
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The extension with `id`, freshly read, or `nil` when it is not installed.
    public func `extension`(_ id: CefExtension.ID) async throws -> CefExtension? {
        try await refresh().first { $0.id == id }
    }

    /// Yields after ``installed`` changed. Changes while the consumer is
    /// busy are reported once. The stream ends when the consuming task is
    /// cancelled.
    public var changes: AsyncStream<Void> {
        startIfNeeded()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = UUID()
            subscribers[token] = continuation
            continuation.onTermination = { _ in
                Task { @MainActor in self.subscribers[token] = nil }
            }
        }
    }

    // MARK: Changing

    /// Turns an extension on or off, as its switch in `chrome://extensions` does.
    public func setEnabled(_ isEnabled: Bool, for id: CefExtension.ID) async throws {
        try await write("(s, a) => s.m.setEnabled(a.id, a.enabled)", ["id": .string(id.rawValue), "enabled": .bool(isEnabled)])
    }

    /// Removes an extension, without Chromium's confirmation dialog: ask the
    /// user first. An extension from ``CefRuntime/Configuration/extensions``
    /// stays removed; an unpacked one comes back at the next start.
    public func uninstall(_ id: CefExtension.ID) async throws {
        // Chromium removes an extension only in answer to a click, and
        // confirms with a dialog of its own, which opens over the hidden
        // service host: the app has asked the user, so it is accepted.
        try await services.grantUserActivation(to: Self.module)
        let name = installed.first { $0.id == id }?.name ?? id.rawValue
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        let call = Task {
            try await services.call(
                Self.module, "(s, a) => s.m.uninstall(a.id, {showConfirmDialog: false}).then(() => true)",
                ["id": .string(id.rawValue)], timeout: .seconds(20))
        }
        let accepting = Task { await Self.acceptUninstallDialog(named: name, appearingAfter: before) }
        defer { accepting.cancel() }
        _ = try await call.value
        _ = try? await refresh()
    }

    /// Presses the accepting button of Chromium's uninstall confirmation
    /// (`ExtensionUninstallDialog`, a dialog-model bubble titled "Remove
    /// “<name>”?") once it appears: its last button, as macOS orders a
    /// dialog's buttons.
    private static func acceptUninstallDialog(named name: String, appearingAfter before: Set<ObjectIdentifier>) async {
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            for window in NSApp.windows where !before.contains(ObjectIdentifier(window)) && window.title.contains(name) {
                let classes = CefChromiumSurface.viewClasses(in: window).classes
                guard classes.contains("BubbleDialogModelHostContentsView") else { continue }
                if let accept = dialogButtons(in: window).last {
                    _ = accept.accessibilityPerformPress()
                    return
                }
            }
        }
    }

    /// The buttons of a Views dialog's button row, in order.
    private static func dialogButtons(in window: NSWindow) -> [NSAccessibilityProtocol] {
        var buttons: [NSAccessibilityProtocol] = []
        func visit(_ element: NSObject, depth: Int) {
            guard depth < 16, let accessible = element as? NSAccessibilityProtocol else { return }
            if accessible.accessibilityRole() == .button, CefChromiumSurface.classList(of: element).contains("MdTextButton") {
                buttons.append(accessible)
            }
            for child in accessible.accessibilityChildren() ?? [] {
                if let child = child as? NSObject { visit(child, depth: depth + 1) }
            }
        }
        if let root = window.contentView?.accessibilityChildren()?.first as? NSObject { visit(root, depth: 0) }
        return buttons
    }

    /// Lets the extension run in incognito profiles, or stops it. Off for
    /// every extension until the user or the app turns it on.
    public func setAllowedInIncognito(_ isAllowed: Bool, for id: CefExtension.ID) async throws {
        try await write(
            "(s, a) => s.d.updateExtensionConfiguration({extensionId: a.id, incognitoAccess: a.allowed})",
            ["id": .string(id.rawValue), "allowed": .bool(isAllowed)])
    }

    /// Which sites the extension may read and change.
    public func setSiteAccess(_ access: CefExtension.SiteAccess, for id: CefExtension.ID) async throws {
        try await write(
            "(s, a) => s.d.updateExtensionConfiguration({extensionId: a.id, hostAccess: a.access})",
            ["id": .string(id.rawValue), "access": .string(access.developerValue)])
    }

    /// Shows the extension's action in Chrome's toolbar, or only in its
    /// extensions menu. Only for extensions with an action, in profiles
    /// whose windows show Chrome's toolbar.
    public func setPinnedToToolbar(_ isPinned: Bool, for id: CefExtension.ID) async throws {
        try await write(
            "(s, a) => s.d.updateExtensionConfiguration({extensionId: a.id, pinnedToToolbar: a.pinned})",
            ["id": .string(id.rawValue), "pinned": .bool(isPinned)])
    }

    /// Restarts an extension; an unpacked one is read from its directory again.
    public func reload(_ id: CefExtension.ID) async throws {
        try await write("(s, a) => s.d.reload(a.id, {failQuietly: true})", ["id": .string(id.rawValue)])
    }

    /// Asks Chromium's extension updater to check every extension now, as
    /// `chrome://extensions`' Update button does. Updates install in the
    /// background; ``installed`` shows them when they have.
    public func checkForUpdates() async throws {
        try await write("s => s.d.autoUpdate()", [:])
    }

    /// Whether `chrome://extensions` is in developer mode, which loading
    /// unpacked extensions needs.
    public func isDeveloperModeEnabled() async throws -> Bool {
        struct Configuration: Decodable { var inDeveloperMode: Bool }
        return try await services.call(
            Self.module, "s => s.d.getProfileConfiguration()", as: Configuration.self, isIdempotent: true
        ).inDeveloperMode
    }

    public func setDeveloperModeEnabled(_ isEnabled: Bool) async throws {
        try await write(
            "(s, a) => s.d.updateProfileConfiguration({inDeveloperMode: a.on})", ["on": .bool(isEnabled)])
    }

    /// Loads the unpacked extension in `directory`, as "Load unpacked" in
    /// `chrome://extensions` does, and returns it. Chromium allows this only
    /// in developer mode (``setDeveloperModeEnabled(_:)``); the extension
    /// stays installed, from that directory, until removed.
    @discardableResult
    public func loadUnpacked(at directory: URL) async throws -> CefExtension {
        let before = Set(try await refresh().map(\.id))
        // Chromium asks for the directory with a file dialog of the page
        // that called; the service host answers it.
        services.fileDialogAnswers[Self.host.name] = [directory.standardizedFileURL]
        defer { services.fileDialogAnswers[Self.host.name] = nil }
        struct LoadError: Decodable { var error: String?; var path: String? }
        let failure = try await services.call(
            Self.module, "s => s.d.loadUnpacked({failQuietly: true, populateError: true}).then(e => e ?? {})",
            as: LoadError.self)
        if let error = failure.error {
            throw CefError.operationFailed("extensions: \(error)")
        }
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let after = try await refresh()
        if let loaded = after.first(where: { !before.contains($0.id) })
            ?? after.first(where: { $0.directory?.resolvingSymlinksInPath().path == path }) {
            return loaded
        }
        throw CefError.operationFailed("extensions: \(directory.path) did not load")
    }

    /// Packs the extension in `directory` into a `.crx` beside it, as "Pack
    /// extension" in `chrome://extensions` does, signing it with the private
    /// key at `privateKey`, or with a new key that is written beside it as a
    /// `.pem` file. Returns the package and the key. Keep the key: an
    /// update must be signed with it.
    public func pack(_ directory: URL, privateKey: URL? = nil) async throws -> (package: URL, privateKey: URL) {
        struct Response: Decodable { var status: String; var message: String? }
        let response = try await services.call(
            Self.module, "(s, a) => s.d.packDirectory(a.path, a.key, 0)",
            ["path": .string(directory.standardizedFileURL.path), "key": .string(privateKey?.path ?? "")],
            as: Response.self, timeout: .seconds(60))
        guard response.status == "SUCCESS" else {
            throw CefError.operationFailed("extensions: \(response.message ?? response.status)")
        }
        let base = directory.standardizedFileURL.deletingPathExtension()
        return (base.appendingPathExtension("crx"), privateKey ?? base.appendingPathExtension("pem"))
    }

    private func write(_ function: String, _ arguments: CefJSON) async throws {
        _ = try await services.call(Self.module, "(s, a) => (\(function))(s, a).then(() => true)", arguments)
        _ = try? await refresh()
    }

    // MARK: Configured installations

    /// Accepts, once, each extension ``CefRuntime/Configuration/extensions``
    /// installed: Chromium installs one another program adds disabled until
    /// the user accepts it. An extension the user later disables stays so.
    /// Returns whether it enabled any.
    private func acceptConfiguredInstallations() async -> Bool {
        guard !profile.isIncognito else { return false }
        let configured = (CefRuntime.shared.configuration?.extensions ?? []).compactMap(\.id).map { CefExtension.ID($0) }
        let installedIDs = Set(installed.map(\.id))
        let pending = configured.filter { !installedIDs.contains($0) }
        if pending != pendingInstallations { pendingInstallations = pending }
        guard !configured.isEmpty, let ledger = acceptedLedgerURL else { return false }
        var accepted = Set(((try? String(contentsOf: ledger, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        var enabled = false
        var changed = false
        for id in configured where !accepted.contains(id.rawValue) {
            guard let item = installed.first(where: { $0.id == id }) else { continue }
            if item.state == CefExtension.State.disabled {
                do {
                    _ = try await services.call(
                        Self.module, "(s, a) => s.m.setEnabled(a.id, true).then(() => true)", ["id": .string(id.rawValue)])
                    enabled = true
                } catch {
                    continue
                }
            }
            accepted.insert(id.rawValue)
            changed = true
        }
        if changed {
            try? Data(accepted.sorted().joined(separator: "\n").utf8).write(to: ledger, options: .atomic)
        }
        return enabled
    }

    /// Which configured extensions CefChromium has accepted in this profile.
    private var acceptedLedgerURL: URL? {
        profile.directory?.appendingPathComponent("CefSwift Accepted Extensions")
    }

    // MARK: Observing

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        let events = services.events(Self.module, "changed", bufferingPolicy: .bufferingNewest(1))
        liveEvents = Task { [weak self] in
            for await _ in events { self?.scheduleRefresh() }
        }
        if let directory = profile.directory {
            for name in ["Extensions", "Preferences", "Secure Preferences"] {
                watches.append(CefFileWatch(url: directory.appendingPathComponent(name)) { [weak self] in
                    self?.scheduleRefresh()
                })
            }
        }
        scheduleRefresh()
    }

    /// Reads again soon: Chromium writes several files for one change.
    private func scheduleRefresh() {
        guard pendingRefresh == nil else { return }
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.pendingRefresh = nil
            _ = try? await self.refresh()
        }
    }

    // MARK: Plumbing

    static let host = CefServiceHost(
        name: "extensions", document: "chrome://extensions/strings.m.js", isAvailableInIncognito: false)

    /// `chrome.developerPrivate` and `chrome.management`, with listeners
    /// that report every change.
    static let module = CefServiceHost.Module(
        name: "extensions", hosts: [host],
        setup: """
            async emit => {
              const d = chrome.developerPrivate, m = chrome.management;
              if (!d || !m) throw new Error('chrome.developerPrivate is not available on this page');
              d.onItemStateChanged.addListener(e => emit('changed', e.event_type));
              d.onProfileStateChanged.addListener(() => emit('changed', 'profile'));
              return { d, m };
            }
            """)
}

extension CefProfile {
    /// The profile's extensions. An incognito profile shares the default
    /// profile's, as Chrome's incognito windows share theirs.
    public var extensions: CefExtensions {
        if isIncognito { return CefProfile.default.extensions }
        let stores = chromiumStores
        if let extensions = stores.extensions { return extensions }
        let made = CefExtensions(profile: self)
        stores.extensions = made
        return made
    }
}
