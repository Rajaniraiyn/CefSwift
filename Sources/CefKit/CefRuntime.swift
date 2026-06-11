import AppKit
import CCef
import CCefAppKit
import Foundation

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

        let pump = CefMessagePump()
        let context = CefAppContext(
            extraSwitches: configuration.extraCommandLineSwitches,
            useMockKeychain: configuration.safeStorage.resolved() == .mockKeychain,
            userCommandLineHook: configuration.onBeforeCommandLineProcessing,
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
    /// only this). Loads the framework from the helper-relative bundle
    /// location (or `CEF_FRAMEWORK_PATH`), runs `cef_execute_process`, and
    /// exits with its return code. Never returns.
    public static func helperMain() -> Never {
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
        var mainArgs = cef_main_args_t(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        let code = cef_execute_process(&mainArgs, nil, nil)
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
