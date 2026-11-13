import Foundation

/// Everything a SwiftPM build of an executable product produces that its
/// app bundle needs: the executable, the resource bundles of the targets it
/// is built from (what `Bundle.module` loads), and the dynamic libraries
/// and frameworks it loads through `@rpath` from the build directory.
///
/// `AppBundler` puts the resource bundles in `Contents/Resources`
/// (`Bundle.main.resourceURL`), where CefSwift's targets find theirs, and
/// the libraries in `Contents/Frameworks`.
struct BuiltProduct: Equatable, Sendable {
    var executable: URL
    /// `<Package>_<Target>.bundle` directories.
    var resourceBundles: [URL] = []
    /// `.dylib` files and `.framework` directories.
    var libraries: [URL] = []
    var architectures: [String]
    var deploymentTarget: String?

    static let cefFrameworkName = "Chromium Embedded Framework.framework"

    /// Collects the product built at `executable`. `resourceBundleNames`
    /// are the bundles its targets have resources for; each must exist
    /// beside the executable.
    static func collect(
        executable: URL,
        resourceBundleNames: [String],
        readMachO: (URL) -> MachOFile? = { MachOFile(contentsOf: $0) },
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) throws -> BuiltProduct {
        guard let main = readMachO(executable) else {
            throw CefPluginError("\(executable.path) is not a Mach-O executable.")
        }
        let products = executable.deletingLastPathComponent()
        var built = BuiltProduct(
            executable: executable, architectures: main.architectures,
            deploymentTarget: main.slices.first?.minimumSystemVersion)

        var missingBundles: [String] = []
        for name in resourceBundleNames {
            let url = products.appendingPathComponent(name)
            if fileExists(url) { built.resourceBundles.append(url) } else { missingBundles.append(name) }
        }
        if !missingBundles.isEmpty {
            throw CefPluginError(
                "The build of \(executable.lastPathComponent) produced no \(missingBundles.joined(separator: ", ")) " +
                "in \(products.path), though those targets declare resources. Bundle.module would not find them " +
                "in the app. Build the product again; if the resources are .embedInCode, report this as a bug.")
        }

        // Libraries from the build directory, breadth first: the
        // executable's, then theirs.
        var queue: [(binary: URL, file: MachOFile)] = [(executable, main)]
        var index = 0
        while index < queue.count {
            let (binary, file) = queue[index]
            index += 1
            for slice in file.slices.prefix(1) {
                for name in slice.loadedLibraries where name.hasPrefix("@rpath/") {
                    let relative = String(name.dropFirst("@rpath/".count))
                    if relative.hasPrefix(cefFrameworkName) { continue }
                    let directories = searchDirectories(
                        runPaths: slice.runPaths, loader: binary, executable: executable)
                        + [products, products.appendingPathComponent("PackageFrameworks")]
                    guard let found = directories.map({ $0.appendingPathComponent(relative) }).first(where: fileExists)
                    else {
                        // The Swift runtime is part of macOS.
                        if relative.hasPrefix("libswift") { continue }
                        throw CefPluginError(
                            "\(binary.lastPathComponent) loads \(name), which is in none of: " +
                            directories.map(\.path).joined(separator: ", ") + ". Build the product that provides it.")
                    }
                    let unit = frameworkDirectory(containing: found) ?? found
                    guard !built.libraries.contains(unit) else { continue }
                    built.libraries.append(unit)
                    if let library = readMachO(found) { queue.append((found, library)) }
                }
            }
        }
        return built
    }

    /// The directories a binary's run-path search list names, outside
    /// macOS, with `@loader_path` and `@executable_path` expanded.
    static func searchDirectories(runPaths: [String], loader: URL, executable: URL) -> [URL] {
        runPaths.compactMap { path -> URL? in
            let expanded = expand(path, loader: loader, executable: executable)
            return MachOFile.isSystemPath(expanded.path + "/") ? nil : expanded
        }
    }

    static func expand(_ path: String, loader: URL, executable: URL) -> URL {
        for (token, base) in [("@loader_path", loader), ("@executable_path", executable)] where path.hasPrefix(token) {
            return URL(fileURLWithPath: base.deletingLastPathComponent().path + path.dropFirst(token.count))
                .standardizedFileURL
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// `…/Name.framework` for a file inside a framework.
    static func frameworkDirectory(containing file: URL) -> URL? {
        var url = file
        while url.pathComponents.count > 1 {
            if url.pathExtension == "framework" { return url }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    /// The run paths `AppBundler` removes from a binary it copies into the
    /// bundle: absolute ones outside macOS, which point into the build
    /// machine's build directory or toolchain. Left in, the bundled app
    /// loads libraries from there on the build machine, and fails
    /// everywhere else.
    static func buildMachineRunPaths(of file: MachOFile) -> [String] {
        let paths = file.slices.first?.runPaths ?? []
        return paths.filter { $0.hasPrefix("/") && !MachOFile.isSystemPath($0 + "/") }
    }
}

/// Problems with how the code in a built app finds its libraries, for
/// `cef doctor`.
enum Linkage {
    /// Checks each binary: every architecture of the main executable is in
    /// it, its run paths stay inside the bundle, and each library it loads
    /// relative to itself or through `@rpath` is in the bundle.
    static func problems(
        binaries: [URL], executable: URL, app: URL,
        readMachO: (URL) -> MachOFile? = { MachOFile(contentsOf: $0) },
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [String] {
        let required = readMachO(executable)?.architectures ?? []
        var problems: [String] = []
        let prefix = app.standardizedFileURL.path + "/"
        func name(_ url: URL) -> String {
            url.standardizedFileURL.path.hasPrefix(prefix)
                ? String(url.standardizedFileURL.path.dropFirst(prefix.count)) : url.path
        }
        for binary in binaries {
            guard let file = readMachO(binary) else { continue }
            // A helper app's executable is the main executable of its process.
            let executable = binary.deletingLastPathComponent().lastPathComponent == "MacOS" ? binary : executable
            let missing = required.filter { !file.architectures.contains($0) }
            if !missing.isEmpty {
                problems.append("\(name(binary)) has \(file.architectures.joined(separator: ", ")), not " +
                                missing.joined(separator: ", ") + " like the app")
            }
            guard let slice = file.slices.first else { continue }
            for path in BuiltProduct.buildMachineRunPaths(of: file) {
                problems.append("\(name(binary)) searches \(path) for libraries, outside the bundle")
            }
            let directories = slice.runPaths.filter { $0.hasPrefix("@") }
                .map { BuiltProduct.expand($0, loader: binary, executable: executable) }
            for library in slice.loadedLibraries {
                if library.hasPrefix("@rpath/") {
                    let relative = String(library.dropFirst("@rpath/".count))
                    if directories.contains(where: { fileExists($0.appendingPathComponent(relative)) }) { continue }
                    if relative.hasPrefix("libswift") { continue }
                    problems.append("\(name(binary)) loads \(library), which is not in the bundle")
                } else if library.hasPrefix("@") {
                    let url = BuiltProduct.expand(library, loader: binary, executable: executable)
                    if !fileExists(url) { problems.append("\(name(binary)) loads \(library), which is not in the bundle") }
                } else if !MachOFile.isSystemPath(library) {
                    problems.append("\(name(binary)) loads \(library), outside the bundle")
                }
            }
        }
        return problems
    }
}
