import CCef
import Foundation

/// Owner of the `cef_app_t` and process-level handlers passed to
/// `cef_initialize`. Immutable after `makeApp()`, so safe to call from any
/// CEF thread.
final class CefAppContext: @unchecked Sendable {
    let configuration: CefConfiguration
    let customSchemes: [CefCustomScheme]
    let pump: CefMessagePump
    /// The client for browsers created through Chrome's own UI (+1, held
    /// for the process lifetime).
    let defaultClient: UnsafeMutablePointer<cef_client_t>
    private let stringOverrides: [Int32: String]

    private var browserProcessHandler: UnsafeMutablePointer<cef_browser_process_handler_t>?
    private var resourceBundleHandler: UnsafeMutablePointer<cef_resource_bundle_handler_t>?

    init(
        configuration: CefConfiguration,
        pump: CefMessagePump,
        defaultClient: UnsafeMutablePointer<cef_client_t>
    ) {
        self.configuration = configuration
        self.customSchemes = configuration.customSchemes
        self.pump = pump
        self.defaultClient = defaultClient
        self.stringOverrides = Dictionary(
            uniqueKeysWithValues: configuration.stringOverrides.map { ($0.key.rawValue, $0.value) })
    }

    /// Builds the handler structs. The returned `cef_app_t*` carries one
    /// reference, consumed by `cef_initialize`.
    func makeApp() -> UnsafeMutablePointer<cef_app_t> {
        let process = cefAllocate(cef_browser_process_handler_t.self, owner: self)
        process.pointee.on_schedule_message_pump_work = { s, delayMS in
            cefOwner(CefAppContext.self, s)?.pump.scheduleWork(delayMilliseconds: delayMS)
        }
        process.pointee.on_before_child_process_launch = { s, commandLine in
            defer { cefRelease(commandLine) }
            guard let commandLine, let owner = cefOwner(CefAppContext.self, s), !owner.customSchemes.isEmpty
            else { return }
            // CEF does not tell subprocesses about app-registered schemes;
            // pass them along so helperMain() registers the same list.
            CefCommandLine(raw: commandLine).appendSwitch(
                CefCustomScheme.childProcessSwitchName,
                value: CefCustomScheme.serialize(owner.customSchemes))
        }
        process.pointee.on_already_running_app_relaunch = { s, commandLine, currentDirectory in
            defer { cefRelease(commandLine) }
            let arguments = commandLine.map { Array(CefCommandLine(raw: $0).argv.dropFirst()) } ?? []
            let path = CefStringUtil.string(from: currentDirectory)
            let directory = path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
            // Handled either way: Chromium's default would open a window of
            // Chrome's design, or show one of CefKit's hidden ones.
            MainActor.assumeIsolated { CefRuntime.shared.handleRelaunch(arguments: arguments, workingDirectory: directory) }
            return 1
        }
        process.pointee.get_default_client = { s in
            cefRetained(cefOwner(CefAppContext.self, s)?.defaultClient)
        }
        browserProcessHandler = process

        if !stringOverrides.isEmpty {
            let bundle = cefAllocate(cef_resource_bundle_handler_t.self, owner: self)
            bundle.pointee.get_localized_string = { s, stringID, output in
                guard let output, let replacement = cefOwner(CefAppContext.self, s)?.stringOverrides[stringID]
                else { return 0 }
                CefStringUtil.set(replacement, into: &output.pointee)
                return 1
            }
            resourceBundleHandler = bundle
        }

        let app = cefAllocate(cef_app_t.self, owner: self)
        app.pointee.get_browser_process_handler = { s in
            cefRetained(cefOwner(CefAppContext.self, s)?.browserProcessHandler)
        }
        app.pointee.get_resource_bundle_handler = { s in
            cefRetained(cefOwner(CefAppContext.self, s)?.resourceBundleHandler)
        }
        app.pointee.on_register_custom_schemes = { s, registrar in
            guard let registrar, let owner = cefOwner(CefAppContext.self, s) else { return }
            CefCustomScheme.register(owner.customSchemes, with: registrar)
        }
        app.pointee.on_before_command_line_processing = { s, processType, commandLine in
            defer { cefRelease(commandLine) }
            guard let commandLine, let owner = cefOwner(CefAppContext.self, s),
                  CefStringUtil.string(from: processType).isEmpty  // browser process only
            else { return }
            owner.configureCommandLine(CefCommandLine(raw: commandLine))
        }
        return app
    }

    private func configureCommandLine(_ commandLine: CefCommandLine) {
        for (name, value) in configuration.extraCommandLineSwitches {
            commandLine.appendSwitch(name, value: value)
        }
        if configuration.safeStorage.resolved() == .mockKeychain, !commandLine.hasSwitch("use-mock-keychain") {
            commandLine.appendSwitch("use-mock-keychain")
        }

        var disabledFeatures = configuration.disabledFeatures
        if !configuration.extensions.isEmpty {
            commandLine.appendSwitch(
                "load-extension", value: configuration.extensions.map(\.path).joined(separator: ","))
            // Chromium is phasing out --load-extension behind this feature.
            disabledFeatures.insert("DisableLoadExtensionCommandLineSwitch")
        }
        commandLine.appendValues(configuration.enabledFeatures, toListSwitch: "enable-features")
        commandLine.appendValues(disabledFeatures, toListSwitch: "disable-features")

        configuration.onBeforeCommandLineProcessing?(commandLine)
    }
}

/// Owner of the `cef_app_t` passed to `cef_execute_process` in helper
/// processes; mirrors the browser process's custom scheme registration.
final class CefHelperAppContext: @unchecked Sendable {
    let customSchemes: [CefCustomScheme]

    init(customSchemes: [CefCustomScheme]) {
        self.customSchemes = customSchemes
    }

    func makeApp() -> UnsafeMutablePointer<cef_app_t> {
        let app = cefAllocate(cef_app_t.self, owner: self)
        app.pointee.on_register_custom_schemes = { s, registrar in
            guard let registrar, let owner = cefOwner(CefHelperAppContext.self, s) else { return }
            CefCustomScheme.register(owner.customSchemes, with: registrar)
        }
        return app
    }
}
