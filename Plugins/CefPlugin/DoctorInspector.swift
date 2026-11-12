import Foundation

/// Reads the facts `cef doctor` evaluates from a built bundle.
enum DoctorInspector {
    static func inspect(_ app: URL) throws -> BundleFacts {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue,
              app.pathExtension == "app" else {
            throw CefPluginError("\(app.path) is not an app bundle. Pass the path of a .app, such as dist/MyApp.app.")
        }
        let contents = app.appendingPathComponent("Contents")
        let info = (try? Plist.read(contents.appendingPathComponent("Info.plist"))) ?? [:]
        guard let executable = info["CFBundleExecutable"]?.stringValue else {
            throw CefPluginError("\(app.path) has no CFBundleExecutable in Contents/Info.plist.")
        }

        var facts = BundleFacts(app: part(named: app.lastPathComponent, at: app, info: info))
        let frameworks = contents.appendingPathComponent("Frameworks")
        for helper in HelperKind.allCases {
            let url = frameworks.appendingPathComponent("\(helper.appName(for: executable)).app")
            guard fm.fileExists(atPath: url.path) else { continue }
            let helperInfo = (try? Plist.read(url.appendingPathComponent("Contents/Info.plist"))) ?? [:]
            facts.helpers[helper] = part(named: url.lastPathComponent, at: url, info: helperInfo)
        }
        let framework = frameworks.appendingPathComponent("Chromium Embedded Framework.framework")
        var libraries = [framework, frameworks.appendingPathComponent(HelperBuilder.startupLibraryName)]
        libraries += (try? AppBundler.machOFiles(in: framework.appendingPathComponent("Versions/A/Libraries"))) ?? []
        facts.libraries = libraries.filter { fm.fileExists(atPath: $0.path) }
            .map { part(named: $0.lastPathComponent, at: $0, info: [:]) }

        if let verify = try? Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]),
           verify.exitCode != 0 {
            facts.verifyError = verify.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let profile = contents.appendingPathComponent("embedded.provisionprofile")
        if fm.fileExists(atPath: profile.path) {
            do {
                facts.profile = try Signing.decodeProfile(at: profile)
            } catch {
                facts.profileError = "\(error)"
            }
        }

        if let spctl = try? Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path]) {
            let output = (spctl.stderr + spctl.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            // spctl prints "accepted" or "rejected" after the path; any
            // other failure means it could not assess here.
            if output.contains(": accepted") || output.contains(": rejected") {
                facts.gatekeeperAccepted = spctl.exitCode == 0
                facts.gatekeeperOutput = output.split(separator: "\n").dropFirst().joined(separator: "\n")
            } else {
                facts.gatekeeperOutput = output
            }
        }
        if let stapler = try? Shell.run("/usr/bin/xcrun", ["stapler", "validate", "-q", app.path]) {
            facts.isStapled = stapler.exitCode == 0
        }
        if let xattr = try? Shell.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", app.path]) {
            facts.isQuarantined = xattr.exitCode == 0
        }
        return facts
    }

    private static func part(named name: String, at url: URL, info: PlistDictionary) -> BundleFacts.Part {
        var part = BundleFacts.Part(name: name, path: url.path, infoPlist: info)
        if let display = try? Shell.run("/usr/bin/codesign", ["-d", "--verbose=4", url.path]) {
            Doctor.parseCodesignDisplay(display.stderr + display.stdout, into: &part)
        }
        if part.isSigned,
           let result = try? Shell.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", url.path]),
           result.exitCode == 0, let start = result.stdout.range(of: "<?xml") {
            part.entitlements = (try? Plist.decode(Data(result.stdout[start.lowerBound...].utf8), source: name)) ?? [:]
        }
        return part
    }
}
