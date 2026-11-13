import CCef
import CefBase
import Foundation

extension CefRuntime.Configuration.Services {
    /// Whether Chromium can play protected (DRM) media through Encrypted Media
    /// Extensions, with Google's Widevine content decryption module (CDM).
    ///
    /// CEF does not ship the Widevine CDM. Chromium's component updater
    /// downloads it from Google on the user's Mac, which is the route open to
    /// every app: the CDM is Google's proprietary software and may be
    /// redistributed only under a licence from Google. Clear Key
    /// (`org.w3.clearkey`) is built in and works in every mode.
    ///
    /// Widevine in an embedded Chromium plays content that accepts a
    /// software-only (L3) CDM on an unverified host. Streaming services that
    /// require Verified Media Path (VMP) host signing refuse it; see
    /// docs/guide.md#playing-streaming-services, and the Browser example
    /// for showing those services in the system's WebKit, which has FairPlay.
    public enum ProtectedMedia: Sendable, Equatable {
        /// CefSwift neither asks for nor installs the CDM, and
        /// ``CefRuntime/installWidevine()`` returns
        /// ``CefRuntime/WidevineState/unavailable``.
        ///
        /// What reaches pages depends on
        /// ``CefRuntime/Configuration/Services/componentUpdates``. Off, Chromium
        /// registers no component: it neither downloads the CDM nor loads one
        /// already on disk, and `com.widevine.alpha` is refused. On, Chromium
        /// registers Widevine with its other components, and its updater
        /// offers no way to leave one out: it downloads the CDM at its first
        /// check, about a minute after start-up, and pages can then use it.
        case disabled
        /// Chromium's component updater runs, downloads Widevine from Google
        /// when it is missing and keeps it current, whatever
        /// ``CefRuntime/Configuration/Services/componentUpdates`` says.
        ///
        /// CefSwift asks for the CDM as soon as the app creates its first
        /// browser; ``CefRuntime/installWidevine()`` waits for it.
        case automatic
        /// As ``automatic``, with a Widevine CDM your app carries, installed
        /// into the profile directory before Chromium starts so protected media
        /// works on first launch and offline. The directory is one CDM version:
        /// it holds `manifest.json` and `_platform_specific/`.
        ///
        /// Only for apps that hold a Widevine licence from Google allowing them
        /// to distribute the CDM. Chromium's component updater still replaces
        /// it with newer versions.
        case preinstalled(widevineDirectory: URL)

        /// Chromium's component ID for the Widevine CDM.
        static let widevineComponentID = "oimompecagnajdejgnnjijobebaeigek"


        /// Copies a preinstalled CDM into `<rootCache>/WidevineCdm/<version>`,
        /// where Chromium's component installer looks for installed versions,
        /// unless that version is already there.
        func installPreinstalledCDM(rootCache: URL) {
            guard case .preinstalled(let source) = self else { return }
            guard let version = Self.cdmVersion(at: source) else {
                CefLog.error("CefSwift: \(source.path) is not a Widevine CDM directory (no manifest.json with a version)")
                return
            }
            let destination = rootCache.appendingPathComponent("WidevineCdm/\(version)", isDirectory: true)
            let fileManager = FileManager.default
            guard !fileManager.fileExists(atPath: destination.appendingPathComponent("manifest.json").path) else { return }
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                CefLog.error("CefSwift: could not install the Widevine CDM from \(source.path): \(error)")
            }
        }

        /// The `version` in a CDM directory's `manifest.json`.
        static func cdmVersion(at directory: URL) -> String? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = manifest["version"] as? String, !version.isEmpty,
                  !version.contains("/")
            else { return nil }
            return version
        }
    }
}

extension CefRuntime {
    /// Where the Widevine CDM stands in this process. See
    /// ``CefRuntime/widevine`` and ``CefRuntime/installWidevine()``.
    public enum WidevineState: Sendable, Equatable {
        /// Chromium's component updater is off (see
        /// ``CefRuntime/Configuration/Services/componentUpdates``), or Chromium is not
        /// initialized.
        case unavailable
        /// Chromium has not fetched the CDM yet.
        case notInstalled
        /// Chromium is checking for, downloading or installing the CDM.
        case installing
        /// The CDM is installed and pages can use `com.widevine.alpha`.
        case installed(version: String)
        /// The last attempt to fetch the CDM failed, for example offline; the
        /// CDM is not installed. Chromium tries again later, or on
        /// ``CefRuntime/installWidevine()``.
        case failed

        /// Whether pages can use Widevine now.
        public var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }
    }
}

extension CefRuntime {
    /// Where the Widevine CDM stands now: a snapshot of Chromium's component
    /// updater.
    public var widevine: CefRuntime.WidevineState {
        guard isRunning, configuration?.runsComponentUpdater == true, let updater = Self.componentUpdater
        else { return .unavailable }
        let component = CefStringUtil.withCefString(CefRuntime.Configuration.Services.ProtectedMedia.widevineComponentID) {
            updater.pointer.pointee.get_component_by_id(updater.pointer, $0)
        }
        // Chromium registers its components shortly after start-up.
        guard let component = CefRef(adopting: component) else { return .notInstalled }
        let version = CefStringUtil.takingUserFree(component.pointer.pointee.get_version(component.pointer)) ?? ""
        let state = component.pointer.pointee.get_state(component.pointer)
        return Self.widevineState(state: state, version: version)
    }

    /// The components Chromium's updater has registered, as "name version
    /// (state n)".
    @_spi(Testing) public var registeredComponents: [String] {
        guard isRunning, let updater = Self.componentUpdater else { return [] }
        var count = updater.pointer.pointee.get_component_count(updater.pointer)
        guard count > 0 else { return [] }
        let components = UnsafeMutablePointer<UnsafeMutablePointer<cef_component_t>?>.allocate(capacity: count)
        defer { components.deallocate() }
        components.initialize(repeating: nil, count: count)
        updater.pointer.pointee.get_components(updater.pointer, &count, components)
        return (0..<count).compactMap { index in
            guard let component = components[index] else { return nil }
            defer { cefRelease(component) }
            let name = CefStringUtil.takingUserFree(component.pointee.get_name(component)) ?? ""
            let version = CefStringUtil.takingUserFree(component.pointee.get_version(component)) ?? ""
            return "\(name) \(version) (state \(component.pointee.get_state(component).rawValue))"
        }
    }

    private static var componentUpdater: CefRef<cef_component_updater_t>? {
        CefRef(adopting: cef_component_updater_get())
    }

    nonisolated static func widevineState(state: cef_component_state_t, version: String) -> CefRuntime.WidevineState {
        let installedVersion = version.isEmpty || version == "0.0.0.0" ? nil : version
        switch state {
        case CEF_COMPONENT_STATE_CHECKING, CEF_COMPONENT_STATE_CAN_UPDATE, CEF_COMPONENT_STATE_DOWNLOADING,
             CEF_COMPONENT_STATE_DECOMPRESSING, CEF_COMPONENT_STATE_PATCHING, CEF_COMPONENT_STATE_UPDATING:
            return installedVersion.map { .installed(version: $0) } ?? .installing
        case CEF_COMPONENT_STATE_UPDATE_ERROR:
            return installedVersion.map { .installed(version: $0) } ?? .failed
        default:
            return installedVersion.map { .installed(version: $0) } ?? .notInstalled
        }
    }

    /// Asks Chromium to fetch the Widevine CDM now and returns where it
    /// stands once Chromium has finished. Returns at once when the CDM is
    /// already installed (Chromium keeps it current on its own), and with
    /// ``CefRuntime/WidevineState/unavailable`` when protected media is
    /// ``CefRuntime/Configuration/Services/ProtectedMedia/disabled``.
    ///
    /// CefSwift already asks when the app creates its first browser; call
    /// this to wait for the CDM, or to try again after
    /// ``CefRuntime/WidevineState/failed``. Chromium's update service fetches
    /// nothing until a browser exists, so before that the request waits.
    /// The download takes from a few seconds to tens of seconds. Pages that asked for Widevine earlier and were refused need
    /// to ask again (usually a reload).
    @discardableResult
    public func installWidevine() async -> CefRuntime.WidevineState {
        guard isRunning, let configuration, configuration.services.protectedMedia != .disabled,
              configuration.runsComponentUpdater, let updater = Self.componentUpdater
        else { return .unavailable }
        let current = widevine
        if current.isInstalled { return current }
        if let widevineInstallation { return await widevineInstallation.value }
        let installation = Task { @MainActor in
            let error = await withCheckedContinuation {
                (continuation: CheckedContinuation<cef_component_update_error_t, Never>) in
                let callback = ComponentUpdateCallback(continuation: continuation).makeCallback()
                CefStringUtil.withCefString(CefRuntime.Configuration.Services.ProtectedMedia.widevineComponentID) {
                    // update() consumes the callback reference.
                    updater.pointer.pointee.update(updater.pointer, $0, CEF_COMPONENT_UPDATE_PRIORITY_FOREGROUND, callback)
                }
            }
            let state = widevine
            if error != CEF_COMPONENT_UPDATE_ERROR_NONE, !state.isInstalled {
                CefLog.notice("CefSwift: fetching the Widevine CDM failed (component update error \(error.rawValue))")
                return CefRuntime.WidevineState.failed
            }
            return state
        }
        widevineInstallation = installation
        let state = await installation.value
        widevineInstallation = nil
        return state
    }
}

/// Resumes once with the result of `cef_component_updater_t.update`, or
/// with a service error if CEF drops the callback unanswered.
private final class ComponentUpdateCallback: Sendable {
    private let continuation: CefResumeOnce<cef_component_update_error_t>

    init(continuation: CheckedContinuation<cef_component_update_error_t, Never>) {
        self.continuation = CefResumeOnce(continuation, fallback: CEF_COMPONENT_UPDATE_ERROR_SERVICE_ERROR)
    }

    func makeCallback() -> UnsafeMutablePointer<cef_component_update_callback_t> {
        let callback = cefAllocate(cef_component_update_callback_t.self, owner: self)
        callback.pointee.on_complete = { s, _, error in
            cefOwner(ComponentUpdateCallback.self, s)?.continuation.resume(returning: error)
        }
        return callback
    }
}
