import CCef
import CefBase
import MachO

/// The helper processes' entry point: Chromium's renderer, GPU and utility
/// processes all run the helper executable, which calls ``run()``.
///
/// The helper links the CEF framework when it launches (see
/// `docs/architecture.md`, "Loading the framework at launch"), so the
/// framework is in memory before this runs; the CCef trampolines bind to
/// that copy.
package enum CefHelper {
    /// Runs the subprocess Chromium asked for and returns its exit code.
    @MainActor
    package static func run() -> Int32 {
        guard let framework = loadedFrameworkPath(), ccef_load_framework(framework) != 0 else {
            print("CefSwift helper: the CEF framework is not loaded: \(String(cString: ccef_loader_error()))")
            return 125
        }
        // The first call into CEF in every process: it selects the API version.
        let expected = String(cString: ccef_pinned_api_hash())
        let hash = cef_api_hash(CEF_API_VERSION, 0).map { String(cString: $0) }
        guard hash == expected else {
            print("CefSwift helper: the CEF framework's API hash \(hash ?? "(none)") does not match the expected \(expected)")
            return 125
        }

        let arguments = CommandLine.arguments
        // Custom URL schemes must be registered in every process.
        let schemes = CefSchemeList.entries(inArguments: arguments)
        // Only renderers run page code; the other process types get an app
        // that registers the schemes and nothing else.
        let isRenderer = arguments.contains("--type=renderer")
        let process = CefRendererProcess(extensions: isRenderer ? [PageScripting()] : [], schemes: schemes)
        let app = process.makeApp()
        var mainArguments = cef_main_args_t(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        return cef_execute_process(&mainArguments, app, nil)
    }

    /// The path of the CEF framework binary that dyld loaded with the
    /// helper.
    private static func loadedFrameworkPath() -> String? {
        // dyld reports the resolved path, inside Versions/A.
        for index in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            if path.contains("/Chromium Embedded Framework.framework/"), path.hasSuffix("/Chromium Embedded Framework") {
                return path
            }
        }
        return nil
    }
}
