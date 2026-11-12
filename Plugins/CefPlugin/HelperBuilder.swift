import Foundation
import PackagePlugin

/// Compiles the helper executable and its startup library from the C
/// sources in `Plugins/CefPlugin/Helper/`, against the framework being
/// bundled.
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

    /// The framework's path from a helper executable,
    /// `<App>.app/Contents/Frameworks/<Helper>.app/Contents/MacOS/<Helper>`.
    static let frameworkPathFromHelper =
        "@executable_path/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework"
    static let sandboxLibraryPathFromHelper =
        "@executable_path/../../../Chromium Embedded Framework.framework/Libraries/libcef_sandbox.dylib"
    static let startupLibraryPathFromHelper = "@executable_path/../../../\(startupLibraryName)"

    /// CefSwift's package directory, which holds the sources and headers.
    let packageDirectory: URL
    /// The converted `Chromium Embedded Framework.framework` in `.cef/dist`.
    let framework: URL
    /// `macosarm64` or `macosx64`.
    let platform: String
    let minimumSystemVersion: String
    let workDirectory: URL

    struct Products {
        let executable: URL
        let startupLibrary: URL
    }

    func build() throws -> Products {
        let fm = FileManager.default
        try? fm.removeItem(at: workDirectory)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let sources = packageDirectory.appendingPathComponent("Plugins/CefPlugin/Helper")
        let headers = packageDirectory.appendingPathComponent("Sources/CCef/include")
        let startupLibrary = workDirectory.appendingPathComponent(Self.startupLibraryName)
        let executable = workDirectory.appendingPathComponent("cefswift-helper")
        let common = [
            "-O2", "-Wall", "-Wextra",
            "-arch", platform == "macosx64" ? "x86_64" : "arm64",
            "-mmacosx-version-min=\(minimumSystemVersion)",
            // Room for the longer library paths install_name_tool writes.
            "-headerpad_max_install_names",
        ]

        print("[cef] Compiling the helper…")
        try compile(common + [
            "-dynamiclib", "-install_name", Self.startupLibraryPathFromHelper,
            sources.appendingPathComponent("helper_startup.c").path,
            framework.appendingPathComponent("Libraries/libcef_sandbox.dylib").path,
            "-o", startupLibrary.path,
        ])
        try changeLibraryPath(
            of: startupLibrary,
            from: installName(of: framework.appendingPathComponent("Libraries/libcef_sandbox.dylib")),
            to: Self.sandboxLibraryPathFromHelper)

        try compile(common + [
            "-I", headers.path,
            sources.appendingPathComponent("helper_main.c").path,
            // The startup library must precede the framework.
            startupLibrary.path,
            "-F", framework.deletingLastPathComponent().path,
            "-framework", "Chromium Embedded Framework",
            "-o", executable.path,
        ])
        try changeLibraryPath(
            of: executable,
            from: installName(of: framework.appendingPathComponent("Chromium Embedded Framework")),
            to: Self.frameworkPathFromHelper)

        return Products(executable: executable, startupLibrary: startupLibrary)
    }

    private func compile(_ arguments: [String]) throws {
        let result = try Shell.run("/usr/bin/xcrun", ["clang"] + arguments)
        guard result.exitCode == 0 else {
            throw CefPluginError(
                "Could not compile the CefSwift helper:\n\(result.stderr)\n" +
                "The helper is compiled with the Xcode toolchain's clang (xcrun clang). Check that " +
                "'xcrun clang --version' works.")
        }
    }

    /// A library's install name, as `otool -D` prints it.
    private func installName(of library: URL) throws -> String {
        let result = try Shell.runChecked(
            "/usr/bin/xcrun", ["otool", "-D", library.path],
            hint: "Could not read the install name of \(library.path).")
        guard let name = result.stdout.split(separator: "\n").dropFirst().first else {
            throw CefPluginError("\(library.path) has no install name. Run 'swift package cef clean' and bundle again.")
        }
        return String(name)
    }

    private func changeLibraryPath(of binary: URL, from old: String, to new: String) throws {
        try Shell.runChecked(
            "/usr/bin/xcrun", ["install_name_tool", "-change", old, new, binary.path],
            hint: "Could not set the library paths of \(binary.lastPathComponent).")
    }

    /// The package that provides CefSwift's `CCef` target: the invoking
    /// package itself or one of its dependencies.
    static func cefSwiftPackageDirectory(in package: Package) -> URL? {
        if package.targets.contains(where: { $0.name == "CCef" }) {
            return package.directoryURL
        }
        for dependency in package.dependencies {
            if let directory = cefSwiftPackageDirectory(in: dependency.package) {
                return directory
            }
        }
        return nil
    }
}
