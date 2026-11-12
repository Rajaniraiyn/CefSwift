import AppKit
import CCef
import Foundation
import Observation

// MARK: - Settings mapping

/// Owns a fully-populated `cef_settings_t` whose string members are released
/// on deinit. Kept alive for the duration of `cef_initialize` (CEF copies
/// what it needs).
final class MappedCefSettings {
    var raw = cef_settings_t()

    /// - Parameters:
    ///   - configuration: the user configuration.
    ///   - frameworkDirectory: resolved `.framework` directory (maps to
    ///     `framework_dir_path`), or nil to let CEF use defaults.
    init(configuration: CefConfiguration, frameworkDirectory: URL?) {
        raw.size = MemoryLayout<cef_settings_t>.stride
        raw.no_sandbox = configuration.isSandboxEnabled ? 0 : 1
        // Chromium's message loop is driven from the app's run loop
        // (CefMessagePump), the only mode macOS apps support.
        raw.external_message_pump = 1
        raw.multi_threaded_message_loop = 0  // unsupported on macOS
        raw.log_severity = configuration.logSeverity.cefValue
        raw.persist_session_cookies = configuration.persistsSessionCookies ? 1 : 0
        raw.remote_debugging_port = Int32(configuration.remoteDebuggingPort ?? 0)
        raw.windowless_rendering_enabled = configuration.isOffscreenRenderingEnabled ? 1 : 0

        // CEF requires cache_path to equal or live under root_cache_path. When only
        // cacheDirectory is given, derive the root from it so the pair is always valid.
        let rootCache: URL
        if let explicitRoot = configuration.rootCacheDirectory {
            rootCache = explicitRoot
        } else if let cache = configuration.cacheDirectory {
            rootCache = cache.deletingLastPathComponent()
        } else {
            rootCache = Self.defaultRootCacheDirectory()
        }
        try? FileManager.default.createDirectory(at: rootCache, withIntermediateDirectories: true)
        CefStringUtil.set(rootCache.path, into: &raw.root_cache_path)
        CefStringUtil.set((configuration.cacheDirectory ?? rootCache).path, into: &raw.cache_path)

        CefStringUtil.set(configuration.locale, into: &raw.locale)
        CefStringUtil.set(configuration.userAgentProduct, into: &raw.user_agent_product)
        CefStringUtil.set(configuration.userAgent, into: &raw.user_agent)
        CefStringUtil.set(configuration.acceptLanguages.joined(separator: ","), into: &raw.accept_language_list)
        CefStringUtil.set(configuration.logFile?.path, into: &raw.log_file)
        CefStringUtil.set(frameworkDirectory?.path, into: &raw.framework_dir_path)
        CefStringUtil.set(configuration.helperExecutableURL?.path, into: &raw.browser_subprocess_path)
    }

    /// Default per-app CEF data directory:
    /// `~/Library/Application Support/<bundle id | "CefSwift">/CefSwift`.
    static func defaultRootCacheDirectory() -> URL {
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
        ccef_string_clear(&raw.user_agent)
        ccef_string_clear(&raw.accept_language_list)
        ccef_string_clear(&raw.log_file)
        ccef_string_clear(&raw.framework_dir_path)
        ccef_string_clear(&raw.browser_subprocess_path)
    }
}

// MARK: -

/// Process-wide CEF lifecycle: loading the framework, `cef_initialize`, the
/// message pump, the set of live browsers, and shutdown.
///
/// SwiftUI apps get all of this from `CefSwiftApp`. In an AppKit app, call
/// ``initialize(configuration:)`` first thing in `main`, before anything
/// touches `NSApp`.
@MainActor
@Observable
public final class CefRuntime {
    public static let shared = CefRuntime()

    /// Whether `cef_initialize` has completed successfully.
    public private(set) var isInitialized = false

    /// The configuration CEF was initialized with.
    public private(set) var configuration: CefConfiguration?

    /// Every live browser in the process, in creation order — including
    /// popups and tabs opened through Chrome's own UI.
    public private(set) var browsers: [CefBrowser] = []

    /// Called for each browser Chromium creates on its own initiative: a
    /// native popup, a DevTools window, a tab or window opened through
    /// Chrome's UI. Assign a delegate here to manage those browsers.
    @ObservationIgnored public var onBrowserCreated: ((CefBrowser) -> Void)?

    @ObservationIgnored var messagePump: CefMessagePump?
    @ObservationIgnored private var appContext: CefAppContext?
    @ObservationIgnored private var settings: MappedCefSettings?
    @ObservationIgnored private var browsersByIdentifier: [Int32: CefBrowser] = [:]
    @ObservationIgnored private var isTerminationRequested = false

    private init() {}

    /// Initializes CEF in the browser (main) process. Call once, on the main
    /// thread, before creating browsers and before anything else creates
    /// `NSApp` — CEF needs the application object to be a `CefApplication`,
    /// which this installs.
    public func initialize(configuration: CefConfiguration = .default) throws(CefError) {
        guard !isInitialized else { throw CefError.alreadyInitialized }

        CefApplication.install()

        let frameworkBinary = try Self.resolveFrameworkBinary(override: configuration.frameworkDirectory)
        guard ccef_load_framework(frameworkBinary.path) != 0 else {
            throw CefError.loadFailed(String(cString: ccef_loader_error()))
        }
        try Self.verifyAPIHash()

        let pump = CefMessagePump()
        // Browsers created through Chrome's own UI have no CefBrowser asking
        // for them; this client adopts them as they appear.
        let defaultClient = CefBrowserClient(browser: nil, requestFilter: nil, chromeUI: configuration.chromeUI)
        let context = CefAppContext(
            configuration: configuration, pump: pump, defaultClient: defaultClient.makeClient())
        let mapped = MappedCefSettings(
            configuration: configuration,
            frameworkDirectory: frameworkBinary.deletingLastPathComponent()
        )

        // Kept for the life of the process, as the real argv is.
        let arguments = CefCommandLine.chromiumArguments(from: CommandLine.arguments)
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: arguments.count + 1)
        argv.initialize(from: arguments.map { strdup($0) } + [nil], count: arguments.count + 1)
        var mainArgs = cef_main_args_t(argc: Int32(arguments.count), argv: argv)
        guard cef_initialize(&mainArgs, &mapped.raw, context.makeApp(), nil) != 0 else {
            let exitCode = cef_get_exit_code()
            if exitCode == CEF_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED.rawValue {
                throw CefError.anotherInstanceRunning
            }
            throw CefError.initializationFailed(exitCode: exitCode)
        }

        appContext = context
        settings = mapped
        self.configuration = configuration
        messagePump = pump
        pump.start()
        isInitialized = true
        applyApplicationWidePreferences(configuration.preferences)
    }

    /// Opens a window drawn entirely by Chrome — tab strip, omnibox, menus,
    /// extension toolbar — showing `url`. The fastest route to a complete
    /// browser; trim or rebrand it with ``CefConfiguration/chromeUI`` and
    /// ``CefConfiguration/productName``.
    ///
    /// Tabs and windows the user opens from there are reported through
    /// ``onBrowserCreated`` and listed in ``browsers``.
    @discardableResult
    public func openChromeWindow(
        url: URL, frame: CGRect? = nil, options: CefBrowserOptions = .init(), delegate: CefBrowserDelegate? = nil
    ) -> CefBrowser {
        let browser = CefBrowser(url: url, options: options, delegate: delegate)
        browser.createInChromeUIWindow(frame: frame)
        return browser
    }

    // MARK: Custom scheme handlers

    /// Registers `handler` as the content source for `scheme` (optionally
    /// restricted to `domain` for standard schemes). Call after
    /// ``initialize(configuration:)``; for custom (non-built-in) schemes the
    /// scheme must also be declared in ``CefConfiguration/customSchemes``.
    /// Registering again for the same scheme/domain replaces the handler.
    ///
    /// The handler serves every profile: the default one, and the
    /// ``CefProfile/incognito()`` and ``CefProfile/persistent(name:)``
    /// profiles, whose request contexts Chromium keeps separately.
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
            CefLog.error("cef_register_scheme_handler_factory failed for scheme '\(scheme)'")
        }
        schemeHandlers.removeAll { $0.scheme == scheme && $0.domain == domain }
        schemeHandlers.append(RegisteredSchemeHandler(scheme: scheme, domain: domain, factory: factory))
        CefProfile.registerSchemeHandler(schemeHandlers[schemeHandlers.count - 1])
    }

    /// A scheme handler registered with ``registerSchemeHandler(scheme:domain:handler:)``.
    struct RegisteredSchemeHandler {
        var scheme: String
        var domain: String?
        var factory: SchemeHandlerFactory
    }

    /// Every registered scheme handler, for profiles that create their
    /// request context later.
    @ObservationIgnored private(set) var schemeHandlers: [RegisteredSchemeHandler] = []

    /// Shuts CEF down and unloads the framework. All browsers must already
    /// be closed. Call once, at process exit.
    public func shutdown() {
        guard isInitialized else { return }
        messagePump?.stop()
        messagePump = nil
        cef_shutdown()
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
        let version = ccef_pinned_api_version()
        guard let hash = cef_api_hash(version, 0) else {
            throw CefError.loadFailed("cef_api_hash returned NULL for API version \(version).")
        }
        let actual = String(cString: hash)
        let expected = String(cString: ccef_pinned_api_hash())
        guard actual == expected else {
            throw CefError.apiHashMismatch(expected: expected, actual: actual)
        }
    }

    // MARK: Browser registry / termination

    func register(_ browser: CefBrowser) {
        browsersByIdentifier[browser.identifier] = browser
        // Internal-page service browsers stay out of the public list.
        if serviceBrowserIDs.contains(browser.id) {
            serviceBrowsers.append(browser)
        } else {
            browsers.append(browser)
        }
    }

    func unregister(_ browser: CefBrowser) {
        browsersByIdentifier[browser.identifier] = nil
        browsers.removeAll { $0 === browser }
        serviceBrowsers.removeAll { $0 === browser }
        serviceBrowserIDs.remove(browser.id)
        continueTerminationIfReady()
    }

    /// Resumes a quit that was waiting for browsers and their windows to
    /// close. Chromium finishes destroying a window after its browser has
    /// gone, and shutting down before that, or from inside one of its
    /// callbacks, crashes in `cef_shutdown()`; so `terminate:` is retried
    /// from the run loop once nothing is left.
    func continueTerminationIfReady() {
        guard isTerminationRequested, hasNoBrowsers, CefBrowserWindow.liveCount == 0 else { return }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private var hasNoBrowsers: Bool { browsers.isEmpty && serviceBrowsers.isEmpty }

    /// A page asked to stay open while quitting: the quit is abandoned, so
    /// closing the last window later does not end the app.
    func cancelTermination() {
        isTerminationRequested = false
    }

    func browser(withIdentifier identifier: Int32) -> CefBrowser? {
        browsersByIdentifier[identifier]
    }

    /// Called from `CefApplication.terminate(_:)`. Quitting closes every
    /// browser first (so pages can run `beforeunload` and state is flushed),
    /// then terminates once the last one is gone.
    func handleTerminationRequest() -> Bool {
        guard isInitialized else { return true }
        isTerminationRequested = true
        if hasNoBrowsers {
            // Not from inside Chromium's message loop work, where a Chrome
            // command or a page may have asked to quit.
            guard CefBrowserWindow.liveCount == 0, messagePump?.isPerformingWork != true else {
                CefBrowserWindow.all.forEach { $0.close() }
                continueTerminationIfReady()
                return false
            }
            shutdown()
            return true
        }
        for browser in browsers {
            browser.close()
        }
        for browser in serviceBrowsers {
            browser.close(force: true)
        }
        return false
    }

    // MARK: Service browsers (internal-page data APIs)

    /// Live service browsers: hidden, created by CefKit itself, and left out
    /// of ``browsers``.
    @ObservationIgnored private var serviceBrowsers: [CefBrowser] = []
    @ObservationIgnored private var serviceBrowserIDs: Set<CefBrowser.ID> = []

    /// Marks `browser` as a service browser. Call before it is created.
    func registerServiceBrowser(_ browser: CefBrowser) {
        serviceBrowserIDs.insert(browser.id)
    }

    /// Whether the app is quitting, so no new service browsers should start.
    var isTerminating: Bool { isTerminationRequested }
}
