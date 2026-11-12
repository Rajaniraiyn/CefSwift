import Foundation

/// What `cef bundle` leaves out of the CEF framework it copies into an app:
/// the `cef` object of `cefapp.json`, with the command line's
/// `--localizations` and `--software-gpu-fallback` applied.
///
/// Everything else in the framework stays: the shared `.pak` files, ICU
/// data, V8 snapshots and DevTools resources are all loaded by the
/// runtime (docs/bundling.md).
struct FrameworkTrimPolicy: Sendable, Equatable {
    /// Which of Chromium's locale packs (`<pack>.lproj/locale.pak`) the
    /// app keeps.
    enum Localizations: Sendable, Equatable {
        /// The packs for the app's own localizations
        /// (`CFBundleLocalizations`), its development language and English.
        case application
        /// Every pack the framework has.
        case all
        /// The packs for these localizations, the development language and
        /// English.
        case list([String])
    }

    var localizations: Localizations = .application
    /// Whether SwiftShader, Chromium's software Vulkan implementation, stays
    /// in the framework: `libvk_swiftshader.dylib`, `libvulkan.dylib` and
    /// `vk_swiftshader_icd.json`. Without it Chromium has no software
    /// fallback for WebGL and GPU compositing when the GPU is unavailable
    /// or blocklisted.
    var includesSoftwareGPU = true

    /// Parses `--localizations`: `application`, `all`, or a comma-separated
    /// list.
    static func localizations(fromOption value: String) throws -> Localizations {
        switch value {
        case "application": return .application
        case "all": return .all
        default:
            let list = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !list.isEmpty else {
                throw CefPluginError("--localizations takes application, all, or a list such as en,fr,de.")
            }
            return .list(list)
        }
    }

    /// Parses `include` or `exclude`, from `--software-gpu-fallback` or
    /// `cefapp.json`.
    static func includesSoftwareGPU(from value: String, source: String) throws -> Bool {
        switch value {
        case "include": return true
        case "exclude": return false
        default: throw CefPluginError("\(source): softwareGPUFallback is \"include\" or \"exclude\", not \"\(value)\".")
        }
    }
}

/// The `cef` object of `cefapp.json`.
struct CefFrameworkOptions: Decodable, Sendable, Equatable {
    var localizations: FrameworkTrimPolicy.Localizations?
    /// `"include"` or `"exclude"`.
    var softwareGPUFallback: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case localizations, softwareGPUFallback
    }
}

extension FrameworkTrimPolicy.Localizations: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            self = .list(list)
            return
        }
        let value = try container.decode(String.self)
        switch value {
        case "application": self = .application
        case "all": self = .all
        default:
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "localizations is \"application\", \"all\" or a list of localizations, not \"\(value)\".")
        }
    }
}

/// Applies a ``FrameworkTrimPolicy`` to a copied framework, and describes
/// what a framework holds for `cef doctor`.
enum FrameworkTrim {
    static let softwareGPUFiles = ["libvk_swiftshader.dylib", "libvulkan.dylib", "vk_swiftshader_icd.json"]

    /// What the policy keeps and removes of the locale packs.
    struct LocaleDecision: Equatable, Sendable {
        var kept: Set<String>
        var removed: Set<String>
        /// Each localization the app has, and the pack it gets (nil: none
        /// fits, Chromium shows the development language).
        var mapping: [Mapping]

        struct Mapping: Equatable, Sendable {
            var localization: String
            var pack: String?
        }
    }

    /// The localizations an app declares: `CFBundleLocalizations` from its
    /// Info.plist.
    static func appLocalizations(infoPlist: PlistDictionary) -> [String] {
        infoPlist["CFBundleLocalizations"]?.strings ?? []
    }

    /// The development language from an Info.plist.
    static func developmentLanguage(infoPlist: PlistDictionary) -> String {
        infoPlist["CFBundleDevelopmentRegion"]?.stringValue ?? "en"
    }

    /// The localizations of SwiftPM resource bundles: the names of their
    /// `.lproj` directories, without `Base`.
    static func resourceLocalizations(in bundles: [URL]) -> [String] {
        let fm = FileManager.default
        var found = Set<String>()
        for bundle in bundles {
            for directory in [bundle, bundle.appendingPathComponent("Contents/Resources")] {
                for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".lproj") {
                    let localization = String(name.dropLast(".lproj".count))
                    if localization != "Base" { found.insert(localization) }
                }
            }
        }
        return found.sorted()
    }

    static func locales(
        _ policy: FrameworkTrimPolicy.Localizations, appLocalizations: [String], developmentLanguage: String,
        packs: Set<String>
    ) -> LocaleDecision {
        let wanted: [String]
        switch policy {
        case .all:
            let mapping = appLocalizations.map { LocaleDecision.Mapping(localization: $0, pack: ChromiumLocales.pack(for: $0, in: packs)) }
            return LocaleDecision(kept: packs, removed: [], mapping: mapping)
        case .application: wanted = appLocalizations
        case .list(let list): wanted = list
        }
        let kept = ChromiumLocales.packsToKeep(for: wanted, developmentLanguage: developmentLanguage, packs: packs)
        let mapping = wanted.map { LocaleDecision.Mapping(localization: $0, pack: ChromiumLocales.pack(for: $0, in: packs)) }
        return LocaleDecision(kept: kept, removed: packs.subtracting(kept), mapping: mapping)
    }

    /// What ``apply(_:to:appLocalizations:developmentLanguage:)`` removed.
    struct Result: Sendable {
        var locales: LocaleDecision
        var removedLocaleBytes: Int64 = 0
        var removedSoftwareGPUBytes: Int64 = 0
    }

    /// Removes what `policy` leaves out from `framework`, a copy about to
    /// be signed.
    @discardableResult
    static func apply(
        _ policy: FrameworkTrimPolicy, to framework: URL, appLocalizations: [String], developmentLanguage: String
    ) throws -> Result {
        let fm = FileManager.default
        let resources = framework.appendingPathComponent("Versions/A/Resources")
        let packs = ChromiumLocales.packs(inResources: resources)
        var result = Result(locales: locales(
            policy.localizations, appLocalizations: appLocalizations, developmentLanguage: developmentLanguage,
            packs: packs))
        for pack in result.locales.removed.sorted() {
            for suffix in [""] + ChromiumLocales.genderSuffixes {
                let directory = resources.appendingPathComponent("\(pack)\(suffix).lproj")
                guard fm.fileExists(atPath: directory.path) else { continue }
                result.removedLocaleBytes += size(of: directory)
                try fm.removeItem(at: directory)
            }
        }
        if !policy.includesSoftwareGPU {
            let libraries = framework.appendingPathComponent("Versions/A/Libraries")
            for name in softwareGPUFiles {
                let file = libraries.appendingPathComponent(name)
                guard fm.fileExists(atPath: file.path) else { continue }
                result.removedSoftwareGPUBytes += size(of: file)
                try fm.removeItem(at: file)
            }
        }
        return result
    }

    /// The logical size of a file, or of everything in a directory;
    /// symbolic links count as nothing.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return 0 }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = enumerator?.nextObject() as? URL {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// `12.3 MiB`.
    static func formatted(_ bytes: Int64) -> String {
        String(format: "%.1f MiB", Double(bytes) / 1_048_576)
    }
}
