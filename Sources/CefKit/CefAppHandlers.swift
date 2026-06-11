import CCef
import Foundation

/// Owner of the `cef_app_t` / `cef_browser_process_handler_t` structs passed
/// to `cef_initialize`. Callbacks may arrive on arbitrary CEF threads; this
/// class is immutable after `makeApp()` and therefore safe to share.
final class CefAppContext: @unchecked Sendable {
    let extraSwitches: [String: String?]
    let useMockKeychain: Bool
    let userCommandLineHook: (@Sendable (CefCommandLine) -> Void)?
    let customSchemes: [CefCustomScheme]
    let pump: CefMessagePump

    private(set) var appPointer: UnsafeMutablePointer<cef_app_t>?
    private(set) var browserProcessHandlerPointer: UnsafeMutablePointer<cef_browser_process_handler_t>?

    init(
        extraSwitches: [String: String?],
        useMockKeychain: Bool,
        userCommandLineHook: (@Sendable (CefCommandLine) -> Void)?,
        customSchemes: [CefCustomScheme],
        pump: CefMessagePump
    ) {
        self.extraSwitches = extraSwitches
        self.useMockKeychain = useMockKeychain
        self.userCommandLineHook = userCommandLineHook
        self.customSchemes = customSchemes
        self.pump = pump
    }

    /// Builds the handler structs. The returned `cef_app_t*` carries one
    /// reference owned by the caller (transferred to CEF by cef_initialize).
    func makeApp() -> UnsafeMutablePointer<cef_app_t> {
        let bp = cefAllocate(cef_browser_process_handler_t.self, owner: self)
        bp.pointee.on_context_initialized = { _ in }
        bp.pointee.on_schedule_message_pump_work = { handlerSelf, delayMS in
            guard let owner = cefOwner(CefAppContext.self, handlerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            owner.pump.scheduleWork(delayMilliseconds: delayMS)
        }
        bp.pointee.on_before_child_process_launch = { handlerSelf, commandLine in
            guard let commandLine else { return }
            // Callback object arguments arrive +1; release when done.
            defer { cefRelease(UnsafeMutableRawPointer(commandLine)) }
            guard let owner = cefOwner(CefAppContext.self, handlerSelf.map(UnsafeMutableRawPointer.init)),
                  !owner.customSchemes.isEmpty
            else { return }
            // CEF does not forward app-registered schemes to subprocesses;
            // pass them on the child command line so helperMain() can mirror
            // the registration (scheme lists must match in every process).
            CefCommandLine(raw: commandLine).appendSwitch(
                CefCustomScheme.childProcessSwitchName,
                value: CefCustomScheme.serialize(owner.customSchemes)
            )
        }
        browserProcessHandlerPointer = bp

        let app = cefAllocate(cef_app_t.self, owner: self)
        app.pointee.get_browser_process_handler = { appSelf in
            guard let owner = cefOwner(CefAppContext.self, appSelf.map(UnsafeMutableRawPointer.init)),
                  let bp = owner.browserProcessHandlerPointer
            else { return nil }
            // Returned objects carry a +1 reference for the caller.
            cefAddRef(UnsafeMutableRawPointer(bp))
            return bp
        }
        app.pointee.on_register_custom_schemes = { appSelf, registrar in
            // The registrar is a scoped (non-refcounted) object — borrow only.
            guard let registrar,
                  let owner = cefOwner(CefAppContext.self, appSelf.map(UnsafeMutableRawPointer.init))
            else { return }
            CefSchemeRegistration.register(owner.customSchemes, with: registrar)
        }
        app.pointee.on_before_command_line_processing = { appSelf, processType, commandLine in
            guard let commandLine else { return }
            // Callback object arguments arrive +1; release when done.
            defer { cefRelease(UnsafeMutableRawPointer(commandLine)) }
            guard let owner = cefOwner(CefAppContext.self, appSelf.map(UnsafeMutableRawPointer.init)) else { return }
            // Only the browser process has an empty process type.
            guard CefStringUtil.string(from: processType).isEmpty else { return }
            let wrapper = CefCommandLine(raw: commandLine)
            for (name, value) in owner.extraSwitches {
                wrapper.appendSwitch(name, value: value)
            }
            // Resolved safeStorage policy: user-specified switches win, so
            // only append when the switch isn't already present.
            if owner.useMockKeychain && !wrapper.hasSwitch("use-mock-keychain") {
                wrapper.appendSwitch("use-mock-keychain")
            }
            owner.userCommandLineHook?(wrapper)
        }
        appPointer = app
        return app
    }
}

/// Owner of the `cef_app_t` passed to `cef_execute_process` in helper
/// processes. Its only job is mirroring the browser process's custom scheme
/// registration (the scheme list arrives on the helper's command line via
/// `--cefswift-schemes`, appended by `on_before_child_process_launch`).
final class CefHelperAppContext: @unchecked Sendable {
    let customSchemes: [CefCustomScheme]

    init(customSchemes: [CefCustomScheme]) {
        self.customSchemes = customSchemes
    }

    /// Builds the helper app struct. The returned `cef_app_t*` carries one
    /// reference owned by the caller (transferred to cef_execute_process).
    func makeApp() -> UnsafeMutablePointer<cef_app_t> {
        let app = cefAllocate(cef_app_t.self, owner: self)
        app.pointee.on_register_custom_schemes = { appSelf, registrar in
            guard let registrar,
                  let owner = cefOwner(CefHelperAppContext.self, appSelf.map(UnsafeMutableRawPointer.init))
            else { return }
            CefSchemeRegistration.register(owner.customSchemes, with: registrar)
        }
        return app
    }
}
