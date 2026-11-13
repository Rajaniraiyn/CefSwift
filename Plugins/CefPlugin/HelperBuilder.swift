import Foundation
import PackagePlugin

/// Builds the helper executable and its startup library, CefSwift's
/// `cefswift-helper` and `cefswift_helper_startup` products, against the
/// framework being bundled.
///
/// The helper links the framework when it launches rather than loading it
/// with `dlopen`: the kernel then fixes up the framework's pointers as
/// pages are read in, and those pages stay clean, shared memory instead of
/// about 12 MB of private memory in every helper process. The startup
/// library comes first in the helper's link order, so it seals the sandbox
/// before any of the framework's code runs. See docs/architecture.md.
struct HelperBuilder {
    /// The startup library's file name in the app's `Contents/Frameworks/`.
    static let startupLibraryName = "libcefswift_helper_startup.dylib"
    static let helperProduct = "cefswift-helper"
    static let startupProduct = "cefswift_helper_startup"

    /// The framework's path from a helper executable,
    /// `<App>.app/Contents/Frameworks/<Helper>.app/Contents/MacOS/<Helper>`.
    static let frameworkPathFromHelper =
        "@executable_path/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework"
    static let startupLibraryPathFromHelper = "@executable_path/../../../\(startupLibraryName)"

    /// The converted `Chromium Embedded Framework.framework` in `.cef/dist`.
    let framework: URL
    let workDirectory: URL

    struct Products {
        let executable: URL
        let startupLibrary: URL
    }

    /// Builds both products with `buildProduct` (a product name, its kind
    /// and extra linker flags; the built file), then points the helper at
    /// the libraries' places in the bundle.
    func build(
        _ buildProduct: (String, PackageManager.BuildResult.BuiltArtifact.Kind, [String]) throws -> URL
    ) throws -> Products {
        let fm = FileManager.default
        try? fm.removeItem(at: workDirectory)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        // Room for the longer library paths install_name_tool writes.
        let builtStartup = try buildProduct(Self.startupProduct, .dynamicLibrary, ["-headerpad_max_install_names"])
        let builtHelper = try buildProduct(Self.helperProduct, .executable, [
            // Drop libraries the helper does not use, such as Foundation,
            // which the build system links by default; keep the two below,
            // in this order: the startup library, then the framework.
            "-dead_strip_dylibs",
            "-needed_library", builtStartup.path,
            "-F", framework.deletingLastPathComponent().path,
            "-needed_framework", "Chromium Embedded Framework",
            "-headerpad_max_install_names",
        ])

        let startupLibrary = workDirectory.appendingPathComponent(Self.startupLibraryName)
        let executable = workDirectory.appendingPathComponent(Self.helperProduct)
        try fm.copyItem(at: builtStartup, to: startupLibrary)
        try fm.copyItem(at: builtHelper, to: executable)
        try setInstallName(of: startupLibrary, to: Self.startupLibraryPathFromHelper)
        try Shell.runChecked(
            "/usr/bin/xcrun", ["install_name_tool",
                               "-change", installName(of: builtStartup), Self.startupLibraryPathFromHelper,
                               "-change", installName(of: framework.appendingPathComponent("Chromium Embedded Framework")),
                               Self.frameworkPathFromHelper,
                               executable.path],
            hint: "Could not set the library paths of \(executable.lastPathComponent).")
        return Products(executable: executable, startupLibrary: startupLibrary)
    }

    /// A library's install name (`LC_ID_DYLIB`).
    private func installName(of library: URL) throws -> String {
        guard let name = MachOFile(contentsOf: library)?.slices.first?.installName else {
            throw CefPluginError("\(library.path) has no install name. Run 'swift package cef clean' and bundle again.")
        }
        return name
    }

    private func setInstallName(of library: URL, to name: String) throws {
        try Shell.runChecked(
            "/usr/bin/xcrun", ["install_name_tool", "-id", name, library.path],
            hint: "Could not set the install name of \(library.lastPathComponent).")
    }
}
