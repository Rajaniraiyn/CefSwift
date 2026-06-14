import AppKit
import CCef
import CCefAppKit
import Foundation

// MARK: - Settings mapping (inlined from CefSettingsMapping.swift)

/// Owns a fully-populated `cef_settings_t` whose string members are released
/// on deinit. Kept alive for the duration of `cef_initialize` (CEF copies
/// what it needs).
private final class MappedCefSettings {
    var raw = cef_settings_t()

    /// - Parameters:
    ///   - configuration: the user configuration.
    ///   - frameworkDirectory: resolved `.framework` directory (maps to
    ///     `framework_dir_path`), or nil to let CEF use defaults.
    init(configuration: CefConfiguration, frameworkDirectory: URL?) {
        raw.size = MemoryLayout<cef_settings_t>.stride
        raw.no_sandbox = configuration.noSandbox ? 1 : 0
        raw.external_message_pump = configuration.externalMessagePump ? 1 : 0
        raw.multi_threaded_message_loop = 0  // unsupported on macOS
        raw.log_severity = configuration.logSeverity.cefValue
        raw.persist_session_cookies = configuration.persistSessionCookies ? 1 : 0
        raw.remote_debugging_port = Int32(configuration.remoteDebuggingPort ?? 0)
        raw.windowless_rendering_enabled = configuration.windowlessRenderingEnabled ? 1 : 0

        // CEF requires cache_path to equal or live under root_cache_path. When only
        // cachePath is given, derive the root from it so the pair is always valid.
        let rootCache: URL
        if let explicitRoot = configuration.rootCachePath {
            rootCache = explicitRoot
        } else if let cache = configuration.cachePath {
            rootCache = cache.deletingLastPathComponent()
        } else {
            rootCache = Self.defaultRootCachePath()
        }
        try? FileManager.default.createDirectory(at: rootCache, withIntermediateDirectories: true)
        CefStringUtil.set(rootCache.path, into: &raw.root_cache_path)
        CefStringUtil.set((configuration.cachePath ?? rootCache).path, into: &raw.cache_path)

        CefStringUtil.set(configuration.locale, into: &raw.locale)
        CefStringUtil.set(configuration.userAgentProduct, into: &raw.user_agent_product)
        CefStringUtil.set(configuration.logFile?.path, into: &raw.log_file)
        CefStringUtil.set(frameworkDirectory?.path, into: &raw.framework_dir_path)
        CefStringUtil.set(configuration.browserSubprocessPath?.path, into: &raw.browser_subprocess_path)
    }

    /// Default per-app CEF data directory:
    /// `~/Library/Application Support/<bundle id | "CefSwift">/CefSwift`.
    static func defaultRootCachePath() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier
            ?? ProcessInfo.processInfo.processName
        return appSupport.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("CefSwift", isDirectory: true)
    }

    deinit {
        ccef_string_clear(&raw.root_cache_path)
        ccef_string_clear(&raw.cache_path)
        ccef_string_clear(&raw.locale)
        ccef_string_clear(&raw.user_agent_product)
        ccef_string_clear(&raw.log_file)
        ccef_string_clear(&raw.framework_dir_path)
        ccef_string_clear(&raw.browser_subprocess_path)
    }
}

// MARK: -

/// Routes CEFApplication's terminate: through the runtime so quitting closes
/// CEF browsers cleanly first. Returns true when termination may proceed.
private let cefTerminateHandler: CEFApplicationTerminateHandler = { () -> ObjCBool in
    ObjCBool(
        MainActor.assumeIsolated {
            CefRuntime.shared.handleTerminationRequest()
        }
    )
}

/// Process-wide CEF lifecycle: framework loading, `cef_initialize`,
/// the external message pump, and shutdown.
///
/// ```swift
/// try CefRuntime.shared.initialize()
/// ```
///
/// `initialize` must be called on the main thread before any browser is
/// created and before SwiftUI/AppKit start delivering events. It installs
/// ``CEFApplication`` automatically when no NSApplication exists yet.
@MainActor
public final class CefRuntime {
    /// The shared runtime.
    public static let shared = CefRuntime()

    /// Whether `cef_initialize` has completed successfully.
    public private(set) var isInitialized = false

    /// The configuration passed to ``initialize(configuration:)``; `nil`
    /// before initialization.
    public private(set) var configuration: CefConfiguration?

    /// The JS ↔ Swift function bridge. Register functions any time; pages
    /// call them via `window.cefSwift.invoke(name, params)`. See ``CefBridge``.
    public let bridge = CefBridge()

    var messagePump: CefMessagePump?
    private var appContext: CefAppContext?
    private var settings: MappedCefSettings?
    private var browsers: [Int32: CefBrowser] = [:]
    private var isTerminationRequested = false

    private init() {}

    /// Initializes CEF in the browser (main) process.
    ///
    /// Call exactly once, on the main thread, before creating browsers.
    /// If `NSApp` does not exist yet, ``CEFApplication`` is installed first;
    /// if another NSApplication subclass was already instantiated this is a
    /// fatal programmer error (CEF requires the NSApplication to conform to
    /// CefAppProtocol from the very first event).
    public func initialize(configuration: CefConfiguration = .default) throws(CefError) {
        precondition(Thread.isMainThread, "CefRuntime.initialize must run on the main thread.")
        guard !isInitialized else { throw CefError.alreadyInitialized }

        // CEFApplication must exist before cef_initialize.
        if NSApp == nil {
            CEFApplication.install()
        } else {
            precondition(
                NSApp is CEFApplication,
                """
                NSApp is \(type(of: NSApp!)), not CEFApplication. Call \
                CefRuntime.initialize() (or CEFApplication.install()) before \
                anything else touches NSApp — i.e. before NSApplicationMain \
                or SwiftUI's App.main().
                """
            )
        }

        let frameworkBinary = try Self.resolveFrameworkBinary(override: configuration.frameworkDirectory)
        guard ccef_load_framework(frameworkBinary.path) != 0 else {
            throw CefError.loadFailed(String(cString: ccef_loader_error()))
        }

        // Configure the API version and verify ABI compatibility before any
        // other CEF call.
        do {
            try Self.verifyAPIHash()
        } catch {
            ccef_unload_framework()
            throw error
        }

        // Custom schemes must be registered identically in every process;
        // the reserved bridge scheme is always present so CefBridge works
        // without configuration.
        var customSchemes = configuration.customSchemes
        if !customSchemes.contains(where: { $0.name == CefBridge.schemeName }) {
            customSchemes.append(CefBridge.customScheme)
        }

        let pump = CefMessagePump()
        let context = CefAppContext(
            extraSwitches: configuration.extraCommandLineSwitches,
            useMockKeychain: configuration.safeStorage.resolved() == .mockKeychain,
            userCommandLineHook: configuration.onBeforeCommandLineProcessing,
            customSchemes: customSchemes,
            pump: pump
        )
        let app = context.makeApp()
        let mapped = MappedCefSettings(
            configuration: configuration,
            frameworkDirectory: frameworkBinary.deletingLastPathComponent()
        )

        var mainArgs = cef_main_args_t(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        // cef_initialize consumes our +1 reference on `app`.
        let result = cef_initialize(&mainArgs, &mapped.raw, app, nil)
        guard result != 0 else {
            let exitCode = cef_get_exit_code()
            ccef_unload_framework()
            throw CefError.initializationFailed(exitCode: exitCode)
        }

        appContext = context
        settings = mapped
        self.configuration = configuration
        messagePump = pump
        pump.start()
        CEFApplication.setTerminateHandler(cefTerminateHandler)
        isInitialized = true

        // Route cefswift://bridge/* to the bridge dispatcher.
        registerSchemeHandler(scheme: CefBridge.schemeName, handler: CefBridgeSchemeHandler(bridge: bridge))
    }

    // MARK: Custom scheme handlers

    /// Registers `handler` as the content source for `scheme` (optionally
    /// restricted to `domain` for standard schemes). Call after
    /// ``initialize(configuration:)``; for custom (non-built-in) schemes the
    /// scheme must also be declared in ``CefConfiguration/customSchemes``.
    /// Registering again for the same scheme/domain replaces the handler.
    public func registerSchemeHandler(scheme: String, domain: String? = nil, handler: some CefSchemeHandler) {
        precondition(
            isInitialized,
            "CefRuntime.registerSchemeHandler requires initialize() to have succeeded first."
        )
        let factory = SchemeHandlerFactory(handler: handler)
        // cef_register_scheme_handler_factory consumes our +1 factory ref.
        let factoryPointer = factory.makeFactory()
        let registered = CefStringUtil.withCefString(scheme) { cefScheme in
            if let domain {
                return CefStringUtil.withCefString(domain) { cefDomain in
                    cef_register_scheme_handler_factory(cefScheme, cefDomain, factoryPointer)
                }
            }
            return cef_register_scheme_handler_factory(cefScheme, nil, factoryPointer)
        }
        if registered == 0 {
            FileHandle.standardError.write(
                Data("CefSwift: cef_register_scheme_handler_factory failed for scheme '\(scheme)'.\n".utf8))
        }
    }

    /// Shuts CEF down and unloads the framework. All browsers must already
    /// be closed. Call once, at process exit.
    public func shutdown() {
        guard isInitialized else { return }
        messagePump?.stop()
        messagePump = nil
        CEFApplication.setTerminateHandler(nil)
        cef_shutdown()
        ccef_unload_framework()
        appContext = nil
        settings = nil
        configuration = nil
        isInitialized = false
    }

    // MARK: Helper process

    /// Entry point for helper executables (`cef-helper`'s main.swift calls
    /// only this). Seals the macOS sandbox when requested (i.e. unless CEF
    /// passed `--no-sandbox`), loads the framework from the helper-relative
    /// bundle location (or `CEF_FRAMEWORK_PATH`), mirrors any custom scheme
    /// registration forwarded on the command line, runs
    /// `cef_execute_process`, and exits with its return code. Never returns.
    public static func helperMain() -> Never {
        let arguments = CommandLine.arguments

        // Sandbox: when the browser process runs with no_sandbox=0, CEF stops
        // passing --no-sandbox to subprocesses; each helper must then load
        // libcef_sandbox.dylib and seal itself BEFORE the framework loads.
        if !arguments.contains("--no-sandbox") {
            guard ccef_sandbox_initialize(CommandLine.argc, CommandLine.unsafeArgv) != 0 else {
                let message = String(cString: ccef_sandbox_error())
                FileHandle.standardError.write(Data("cef-helper: sandbox initialization failed: \(message)\n".utf8))
                exit(125)
            }
        }

        let binary: URL
        do {
            binary = try resolveHelperFrameworkBinary()
        } catch {
            FileHandle.standardError.write(Data("cef-helper: \(error)\n".utf8))
            exit(125)
        }
        guard ccef_load_framework(binary.path) != 0 else {
            let message = String(cString: ccef_loader_error())
            FileHandle.standardError.write(Data("cef-helper: \(message)\n".utf8))
            exit(125)
        }
        do {
            try verifyAPIHash()
        } catch {
            FileHandle.standardError.write(Data("cef-helper: \(error)\n".utf8))
            exit(125)
        }

        // Custom schemes must be registered in every process: the browser
        // forwarded its list via --cefswift-schemes (see CefAppContext).
        let customSchemes = CefCustomScheme.parse(fromArguments: arguments)
        var helperApp: UnsafeMutablePointer<cef_app_t>?
        if !customSchemes.isEmpty {
            // cef_execute_process consumes our +1 reference on the app.
            helperApp = CefHelperAppContext(customSchemes: customSchemes).makeApp()
        }

        var mainArgs = cef_main_args_t(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        let code = cef_execute_process(&mainArgs, helperApp, nil)
        exit(code)
    }

    // MARK: Framework resolution

    nonisolated static let frameworkBinaryName = "Chromium Embedded Framework"
    nonisolated static let frameworkBundleName = "Chromium Embedded Framework.framework"

    /// Resolves the framework binary for the browser process:
    /// explicit override → app bundle Frameworks dir → CEF_FRAMEWORK_PATH.
    nonisolated static func resolveFrameworkBinary(override: URL?) throws(CefError) -> URL {
        var searched: [String] = []

        if let override {
            let candidate = binaryURL(for: override)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            searched.append("frameworkDirectory override: \(candidate.path)")
        }

        if let frameworks = Bundle.main.privateFrameworksURL {
            let candidate = frameworks
                .appendingPathComponent(frameworkBundleName)
                .appendingPathComponent(frameworkBinaryName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            searched.append("app bundle: \(candidate.path)")
        }

        if let env = ProcessInfo.processInfo.environment["CEF_FRAMEWORK_PATH"], !env.isEmpty {
            let candidate = binaryURL(for: URL(fileURLWithPath: env))
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            searched.append("CEF_FRAMEWORK_PATH: \(candidate.path)")
        } else {
            searched.append("CEF_FRAMEWORK_PATH: (not set)")
        }

        throw CefError.frameworkNotFound("Searched: \(searched.joined(separator: "; ")).")
    }

    /// Helper-process resolution: CEF_FRAMEWORK_PATH override, then the
    /// standard helper-relative location
    /// `<exe>/../../../Chromium Embedded Framework.framework/...`
    /// (helpers live in `Contents/Frameworks/` of the main app).
    nonisolated static func resolveHelperFrameworkBinary() throws(CefError) -> URL {
        if let env = ProcessInfo.processInfo.environment["CEF_FRAMEWORK_PATH"], !env.isEmpty {
            let candidate = binaryURL(for: URL(fileURLWithPath: env))
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = executable
            .deletingLastPathComponent()  // MacOS/
            .deletingLastPathComponent()  // Contents/
            .deletingLastPathComponent()  // <Helper>.app/  -> Contents/Frameworks/
            .deletingLastPathComponent()
            .appendingPathComponent(frameworkBundleName)
            .appendingPathComponent(frameworkBinaryName)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw CefError.frameworkNotFound("Helper searched: \(candidate.path).")
    }

    /// Accepts either a `.framework` directory or a direct binary path.
    nonisolated private static func binaryURL(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return url.appendingPathComponent(frameworkBinaryName)
        }
        return url
    }

    /// Configures the API version (first CEF call in every process) and
    /// verifies the platform API hash against the vendored headers.
    nonisolated static func verifyAPIHash() throws(CefError) {
        guard let hash = cef_api_hash(CCEF_API_VERSION_VALUE, 0) else {
            throw CefError.loadFailed("cef_api_hash returned NULL for API version \(CCEF_API_VERSION_VALUE).")
        }
        let actual = String(cString: hash)
        let expected = CCEF_EXPECTED_API_HASH_PLATFORM
        guard actual == expected else {
            throw CefError.apiHashMismatch(expected: expected, actual: actual)
        }
    }

    // MARK: Browser registry / termination

    func registerBrowser(_ browser: CefBrowser) {
        guard browser.id >= 0 else { return }
        browsers[browser.id] = browser
    }

    func unregisterBrowser(id: Int32) {
        browsers[id] = nil
        if isTerminationRequested && browsers.isEmpty {
            // Re-enter terminate:; with no browsers left it now proceeds.
            NSApp.terminate(nil)
        }
    }

    /// Called from CEFApplication's terminate:. Returns true when the app
    /// may terminate immediately.
    func handleTerminationRequest() -> Bool {
        guard isInitialized else { return true }
        if browsers.isEmpty {
            shutdown()
            return true
        }
        isTerminationRequested = true
        for browser in browsers.values {
            browser.close(force: false)
        }
        return false
    }
}
