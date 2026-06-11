import CCef
import Foundation

/// Owner of the `cef_app_t` / `cef_browser_process_handler_t` structs passed
/// to `cef_initialize`. Callbacks may arrive on arbitrary CEF threads; this
/// class is immutable after `makeApp()` and therefore safe to share.
final class CefAppContext: @unchecked Sendable {
    let extraSwitches: [String: String?]
    let useMockKeychain: Bool
    let userCommandLineHook: (@Sendable (CefCommandLine) -> Void)?
    let pump: CefMessagePump

    private(set) var appPointer: UnsafeMutablePointer<cef_app_t>?
    private(set) var browserProcessHandlerPointer: UnsafeMutablePointer<cef_browser_process_handler_t>?

    init(
        extraSwitches: [String: String?],
        useMockKeychain: Bool,
        userCommandLineHook: (@Sendable (CefCommandLine) -> Void)?,
        pump: CefMessagePump
    ) {
        self.extraSwitches = extraSwitches
        self.useMockKeychain = useMockKeychain
        self.userCommandLineHook = userCommandLineHook
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
