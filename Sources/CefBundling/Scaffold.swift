import Foundation

/// `cefswift new`: a new app package from one of the templates in the
/// CefSwift checkout's `Templates/`, ready for `swift package cef bundle`.
///
/// A template is a directory of files whose contents and paths hold
/// placeholders (`__NAME__`, `__DISPLAY_NAME__`, `__BUNDLE_ID__`,
/// `__CEFSWIFT_PACKAGE__`), and a `template.json` that names the files it
/// copies from elsewhere in the checkout, such as the Browser example's
/// core and features, so the template cannot drift from the code it
/// shows. Each `replace` pair must match the copied file, so an edit that
/// breaks one stops `cefswift new` (and CI) instead of passing unnoticed.
struct Scaffold {
    /// Where the new package takes CefSwift from.
    enum Dependency: Equatable {
        case path(String)
        case version(String)
        case branch(String)
    }

    /// A template's `template.json`.
    struct Manifest: Decodable {
        struct Copy: Decodable {
            var from: String
            var to: String
            /// Exact replacements, by path inside `from` ("" for `from`
            /// itself when it is a file).
            var replace: [String: [[String]]]?
        }

        var summary: String
        /// CefSwift's products the app target depends on.
        var products: [String]
        /// The deployment target, as Xcode writes it.
        var macOS: String
        /// The app's entitlements file, beside its sources.
        var entitlements: String?
        var copy: [Copy]?
    }

    static let templates = ["browser", "app", "minimal"]
    static let repositoryURL = "https://github.com/Rajaniraiyn/CefSwift"

    var name: String
    var template: String
    /// The CefSwift checkout: `Templates/`, and what templates copy.
    var root: URL
    var output: URL
    var displayName: String
    var bundleIdentifier: String
    var dependency: Dependency
    var makesXcodeProject = false

    static let usage = """
    USAGE: cefswift new <Name> [--template browser|app|minimal] [--output <dir>]
                        [--display-name <name>] [--bundle-id <id>] [--xcode]
                        [--cefswift-path <dir> | --cefswift-version <1.2.3> | --cefswift-branch <name>]
                        [--cefswift-root <checkout>]
      Creates a package for the app <Name> (a Swift identifier) in --output
      (default ./<Name>): Package.swift, its sources, cefapp.json and a
      .gitignore with .cef/ and dist/; with --xcode, an Xcode project too.

      Templates:
        browser  A tabbed browser: tab rail, address bar with suggestions,
                 bookmarks, history, extensions, downloads, find bar and
                 tab discarding (a trimmed copy of the Browser example)
        app      An app shell: native sections that are web pages, its own
                 content at app://content/ and a JavaScript bridge to Swift
        minimal  One window with one web page

      The package depends on CefSwift by version when the checkout the
      templates come from is a release tag, else on that checkout's path;
      --cefswift-path, --cefswift-version and --cefswift-branch choose.
      --cefswift-root is the checkout (default: the one this tool was
      built in).
    """

    init(arguments: [String], workingDirectory: URL, toolLocation: URL?) throws {
        var args = Arguments(arguments)
        let template = args.option("template") ?? "browser"
        let outputOption = args.option("output")
        let displayName = args.option("display-name")
        let bundleIdentifier = args.option("bundle-id")
        let path = args.option("cefswift-path")
        let version = args.option("cefswift-version")
        let branch = args.option("cefswift-branch")
        let rootOption = args.option("cefswift-root")
        makesXcodeProject = args.flag("xcode")
        guard let name = args.positional() else {
            throw BundlingError("Missing the app's name.\n\(Self.usage)")
        }
        try args.rejectLeftovers(usage: Self.usage)

        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            throw BundlingError(
                "'\(name)' is not a Swift identifier, which the app's target and module need. " +
                "Use letters, digits and underscores, starting with a letter (MyBrowser); " +
                "--display-name sets the name people see.")
        }
        guard Self.templates.contains(template) else {
            throw BundlingError("Unknown template '\(template)'. Use one of: \(Self.templates.joined(separator: ", ")).")
        }
        guard [path, version, branch].compactMap({ $0 }).count <= 1 else {
            throw BundlingError("Pass one of --cefswift-path, --cefswift-version and --cefswift-branch.")
        }
        self.name = name
        self.template = template
        self.displayName = displayName ?? Self.words(name)
        self.bundleIdentifier = bundleIdentifier ?? "com.example.\(name.lowercased())"

        // Relative to the directory itself, not to its parent.
        let base = URL(fileURLWithPath: workingDirectory.path, isDirectory: true)
        func absolute(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: base).standardizedFileURL
        }
        output = absolute(outputOption ?? name)
        if let rootOption {
            root = absolute(rootOption)
        } else if let found = toolLocation.flatMap(Self.checkout(containing:)) {
            root = found
        } else {
            throw BundlingError("Could not find the CefSwift checkout the templates come from. Pass --cefswift-root <dir>.")
        }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Templates/\(template)/template.json").path) else {
            throw BundlingError("\(root.path) has no Templates/\(template). Pass --cefswift-root with a CefSwift checkout.")
        }
        if let path {
            dependency = .path(absolute(path).path)
        } else if let version {
            dependency = .version(version.hasPrefix("v") ? String(version.dropFirst()) : version)
        } else if let branch {
            dependency = .branch(branch)
        } else {
            dependency = Self.releaseTag(of: root).map(Dependency.version) ?? .path(root.path)
        }
    }

    /// "MyBrowser" → "My Browser".
    static func words(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for character in name {
            if character == "_" {
                result.append(" ")
            } else {
                if character.isUppercase, let previous, previous.isLowercase || previous.isNumber {
                    result.append(" ")
                }
                result.append(character)
            }
            previous = character
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// The CefSwift checkout a built tool sits in (`<checkout>/.build/…/cefswift`).
    static func checkout(containing tool: URL) -> URL? {
        var directory = tool.resolvingSymlinksInPath().deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Templates").path),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent("CEF_VERSION.json").path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// The version a checkout is at when its commit carries a release tag
    /// (`v1.2.3`), as SwiftPM's checkouts of a dependency do.
    static func releaseTag(of root: URL) -> String? {
        guard let result = try? Shell.run("/usr/bin/git", ["-C", root.path, "tag", "--points-at", "HEAD"]),
              result.exitCode == 0 else { return nil }
        return result.stdout.split(separator: "\n")
            .map(String.init)
            .first { $0.range(of: #"^v?\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
            .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
    }

    /// The `.package(…)` line of the new Package.swift.
    var packageDependency: String {
        switch dependency {
        case .path(let path): ".package(name: \"CefSwift\", path: \(Self.quoted(path)))"
        case .version(let version): ".package(url: \(Self.quoted(Self.repositoryURL)), .upToNextMinor(from: \(Self.quoted(version))))"
        case .branch(let branch): ".package(url: \(Self.quoted(Self.repositoryURL)), branch: \(Self.quoted(branch)))"
        }
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    var placeholders: [(String, String)] {
        [("__CEFSWIFT_PACKAGE__", packageDependency), ("__DISPLAY_NAME__", displayName),
         ("__BUNDLE_ID__", bundleIdentifier), ("__NAME__", name)]
    }

    func substitute(_ text: String) -> String {
        placeholders.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    // MARK: - Writing

    /// Writes the package and returns the paths written, relative to it.
    @discardableResult
    func run() throws -> [String] {
        let fm = FileManager.default
        if fm.fileExists(atPath: output.path),
           let contents = try? fm.contentsOfDirectory(atPath: output.path), !contents.isEmpty {
            throw BundlingError("\(output.path) already exists and is not empty. Choose another --output.")
        }
        let templateDirectory = root.appendingPathComponent("Templates/\(template)")
        let manifest = try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: templateDirectory.appendingPathComponent("template.json")))

        var files: [String: Data] = [:]
        // The template's own files.
        for relative in try Self.files(in: templateDirectory) where relative != "template.json" {
            files[substitute(relative)] = try contents(of: templateDirectory.appendingPathComponent(relative), replacing: [])
        }
        files[".gitignore"] = try Data(contentsOf: root.appendingPathComponent("Templates/common/gitignore"))
        // What it copies from the rest of the checkout.
        for copy in manifest.copy ?? [] {
            let source = root.appendingPathComponent(copy.from)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                throw BundlingError("Templates/\(template)/template.json copies \(copy.from), which does not exist.")
            }
            let entries = isDirectory.boolValue ? try Self.files(in: source) : [""]
            for entry in entries {
                let file = entry.isEmpty ? source : source.appendingPathComponent(entry)
                let destination = entry.isEmpty ? copy.to : copy.to + "/" + entry
                let pairs = copy.replace?[entry] ?? []
                files[substitute(destination)] = try contents(of: file, replacing: pairs, named: copy.from + (entry.isEmpty ? "" : "/" + entry))
            }
            for key in (copy.replace ?? [:]).keys where !entries.contains(key) {
                throw BundlingError("Templates/\(template)/template.json replaces text in \(copy.from)/\(key), which it does not copy.")
            }
        }
        if makesXcodeProject {
            let project = XcodeProject(scaffold: self, manifest: manifest)
            files["\(name).xcodeproj/project.pbxproj"] = Data(project.text.utf8)
            files["CefSwift.xcconfig"] = Data(try project.configuration(root: root).utf8)
        }
        files["README.md"] = Data(readme(manifest).utf8)

        for (relative, data) in files {
            let url = output.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return files.keys.sorted()
    }

    /// A file with the placeholders filled in and `pairs` replaced, each of
    /// which must match.
    private func contents(of file: URL, replacing pairs: [[String]], named: String = "") throws -> Data {
        let data = try Data(contentsOf: file)
        guard var text = String(data: data, encoding: .utf8) else { return data }
        for pair in pairs {
            guard pair.count == 2, text.contains(pair[0]) else {
                throw BundlingError(
                    "Templates/\(template)/template.json replaces \(Self.quoted(pair.first ?? "")) in \(named), " +
                    "which it no longer contains. Update the template to match.")
            }
            text = text.replacingOccurrences(of: pair[0], with: pair[1])
        }
        return Data(substitute(text).utf8)
    }

    /// Every regular file under `directory`, as sorted relative paths.
    static func files(in directory: URL) throws -> [String] {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
        var result: [String] = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  url.lastPathComponent != ".DS_Store" else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            result.append(String(path.dropFirst(base.count + 1)))
        }
        return result.sorted()
    }

    private func readme(_ manifest: Manifest) -> String {
        let bundle = "swift package --allow-writing-to-package-directory --allow-network-connections all \\\n    cef bundle --product \(name)"
        var text = """
        # \(displayName)

        \(manifest.summary), built on [CefSwift](\(Self.repositoryURL)) (Chromium for Swift on macOS).

        ## Build and run

        ```sh
        \(bundle)
        open dist/\(name).app
        ```

        The first run downloads Chromium (the pinned CEF build, about 135 MB)
        into `.cef/`. Chromium runs only from the app bundle, so `swift run`
        cannot start it. The bundle's settings (identifier, name, version,
        capabilities, signing) are in `Sources/\(name)/cefapp.json`.

        `swift package cef doctor --product \(name)` checks the bundle;
        `cef package` and `cef notarize` wrap and notarize it for others
        ([Bundling](\(Self.repositoryURL)/blob/main/docs/bundling.md)).

        """
        if makesXcodeProject {
            text += """

            ## Xcode

            `\(name).xcodeproj` builds the same sources into the same bundle with
            CefSwift's build phase. Open it and Run; settings are its build
            settings and `CefSwift.xcconfig`
            ([Xcode](\(Self.repositoryURL)/blob/main/docs/bundling.md#xcode)).

            """
        }
        if template == "browser" {
            text += """

            ## Layout

            `Sources/\(name)/Core` is what every feature relies on: the windows
            and tabs, the tab rail and toolbar, the menus and settings.
            `Sources/\(name)/Features` holds one folder per feature, each listed
            in `BrowserApp.features`; delete the line and the folder to drop
            one. The [Browser example](\(Self.repositoryURL)/tree/main/Examples/Sources/Browser)
            has more features to copy in.

            """
        }
        return text
    }
}
