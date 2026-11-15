import Foundation

/// How the helper executable and its startup library, CefSwift's
/// `cefswift-helper` and `cefswift_helper_startup` products, are linked
/// against the framework being bundled, and how the built files are pointed
/// at their places in the app bundle. Whoever builds them (SwiftPM's
/// `PackageManager` for `swift package cef bundle`, `swift build` for the
/// Xcode build phase) passes these linker flags and hands the built files
/// to ``prepare(startup:helper:framework:in:)``.
///
/// The helper links the framework when it launches rather than loading it
/// with `dlopen`: the kernel then fixes up the framework's pointers as
/// pages are read in, and those pages stay clean, shared memory instead of
/// about 12 MB of private memory in every helper process. The startup
/// library comes first in the helper's link order, so it seals the sandbox
/// before any of the framework's code runs. See docs/architecture.md.
enum HelperLink {
    /// The startup library's file name in the app's `Contents/Frameworks/`.
    static let startupLibraryName = "libcefswift_helper_startup.dylib"
    static let helperProduct = "cefswift-helper"
    static let startupProduct = "cefswift_helper_startup"
    /// The targets the two products are built from, in the package.
    static let sourceDirectories = [
        "Sources/CefHelper", "Sources/CefHelperStartup", "Sources/CefRenderer", "Sources/CefBase", "Sources/CCef",
    ]

    /// The framework's path from a helper executable,
    /// `<App>.app/Contents/Frameworks/<Helper>.app/Contents/MacOS/<Helper>`.
    static let frameworkPathFromHelper =
        "@executable_path/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework"
    static let startupLibraryPathFromHelper = "@executable_path/../../../\(startupLibraryName)"

    /// The startup library's linker flags: room for the longer install name
    /// written later.
    static let startupLinkerFlags = ["-headerpad_max_install_names"]

    /// The helper's linker flags. Drop libraries the helper does not use,
    /// such as Foundation, which the build system links by default; keep the
    /// two below, in this order: the startup library, then the framework.
    static func helperLinkerFlags(startupLibrary: URL, framework: URL) -> [String] {
        [
            "-dead_strip_dylibs",
            "-needed_library", startupLibrary.path,
            "-F", framework.deletingLastPathComponent().path,
            "-needed_framework", FrameworkLayout.frameworkName,
            "-headerpad_max_install_names",
        ]
    }

    /// Links the app's executable to the framework, weakly, so that dyld
    /// loads it at launch. A library loaded at launch has its pointers fixed
    /// up by the kernel as pages are read in, which keeps about 12 MB of the
    /// framework's data clean, shared memory; one loaded later with `dlopen`
    /// holds it as private memory. CefKit's own `dlopen` of the framework
    /// then returns the library already loaded. The link is weak, so an
    /// executable run outside the bundle still starts and finds the
    /// framework the usual way. With room for the run path `AppBundler`
    /// adds.
    static func appLinkerFlags(framework: URL) -> [String] {
        ["-F", framework.deletingLastPathComponent().path, "-weak_framework", FrameworkLayout.frameworkName,
         "-headerpad_max_install_names"]
    }

    struct Products: Sendable {
        let executable: URL
        let startupLibrary: URL
    }

    /// Copies the built files into `workDirectory` and points the helper at
    /// the libraries' places in the bundle.
    static func prepare(startup builtStartup: URL, helper builtHelper: URL, framework: URL,
                        in workDirectory: URL) throws -> Products {
        let fm = FileManager.default
        try? fm.removeItem(at: workDirectory)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let startupLibrary = workDirectory.appendingPathComponent(startupLibraryName)
        let executable = workDirectory.appendingPathComponent(helperProduct)
        try fm.copyItem(at: builtStartup, to: startupLibrary)
        try fm.copyItem(at: builtHelper, to: executable)
        try Shell.runChecked(
            "/usr/bin/xcrun", ["install_name_tool", "-id", startupLibraryPathFromHelper, startupLibrary.path],
            hint: "Could not set the install name of \(startupLibrary.lastPathComponent).")
        try Shell.runChecked(
            "/usr/bin/xcrun", ["install_name_tool",
                               "-change", installName(of: builtStartup), startupLibraryPathFromHelper,
                               "-change", installName(of: framework.appendingPathComponent(FrameworkLayout.frameworkName)),
                               frameworkPathFromHelper,
                               executable.path],
            hint: "Could not set the library paths of \(executable.lastPathComponent).")
        return Products(executable: executable, startupLibrary: startupLibrary)
    }

    /// A library's install name (`LC_ID_DYLIB`).
    private static func installName(of library: URL) throws -> String {
        guard let name = MachOFile(contentsOf: library)?.slices.first?.installName else {
            throw BundlingError("\(library.path) has no install name. Delete the CEF cache (.cef) and build again.")
        }
        return name
    }
}
