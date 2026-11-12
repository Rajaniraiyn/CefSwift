import Foundation
import PackagePlugin

/// Finds a product in the invoking package or its dependencies, with the
/// package that declares it and the targets it is built from. A product's
/// name need not match its target's, nor its package the invoking one.
struct LocatedProduct {
    let product: Product
    /// The package whose manifest declares the product.
    let package: Package
    /// The executable target's source directory, where cefapp.json sits.
    let sourceDirectory: URL?
    /// `<Package>_<Target>.bundle` for each target of the product, its
    /// dependencies included, that has resources: what SwiftPM builds for
    /// `Bundle.module`.
    let resourceBundleNames: [String]

    static func locate(_ name: String, in root: Package) throws -> LocatedProduct {
        let packages = allPackages(from: root)
        guard let package = packages.first(where: { $0.products.contains { $0.name == name } }),
              let product = package.products.first(where: { $0.name == name }) else {
            let names = packages.flatMap { $0.products.compactMap { $0 as? ExecutableProduct }.map(\.name) }
            throw CefPluginError(
                "No product named '\(name)' in \(root.displayName) or its dependencies. Executable products: " +
                (names.isEmpty ? "none" : names.sorted().joined(separator: ", ")) + ".")
        }
        var owner: [Target.ID: Package] = [:]
        for package in packages {
            for target in package.targets { owner[target.id] = package }
        }
        var targets: [Target] = []
        for target in product.targets + product.targets.flatMap(\.recursiveTargetDependencies)
        where !targets.contains(where: { $0.id == target.id }) {
            targets.append(target)
        }
        let bundles = targets.compactMap { target -> String? in
            guard let source = target as? SourceModuleTarget,
                  source.sourceFiles.contains(where: { $0.type == .resource }),
                  let package = owner[target.id] else { return nil }
            return "\(package.displayName)_\(target.name).bundle"
        }
        let mainTarget = (product as? ExecutableProduct)?.mainTarget ?? product.targets.first
        return LocatedProduct(
            product: product, package: package,
            sourceDirectory: (mainTarget as? SourceModuleTarget).flatMap(sourceDirectory),
            resourceBundleNames: bundles.sorted())
    }

    /// The package and its dependencies, the invoking package first.
    static func allPackages(from root: Package) -> [Package] {
        var packages: [Package] = []
        var queue = [root]
        while !queue.isEmpty {
            let package = queue.removeFirst()
            guard !packages.contains(where: { $0.id == package.id }) else { continue }
            packages.append(package)
            queue.append(contentsOf: package.dependencies.map(\.package))
        }
        return packages
    }

    /// The closest directory that holds all of a target's sources.
    /// (`Target.directoryURL` needs tools version 6.1.)
    private static func sourceDirectory(of target: SourceModuleTarget) -> URL? {
        let directories = target.sourceFiles.map { $0.url.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var common = directories.first else { return nil }
        for components in directories.dropFirst() {
            common = Array(zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        return URL(fileURLWithPath: NSString.path(withComponents: common))
    }
}
