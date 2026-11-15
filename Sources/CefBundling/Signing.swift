import Foundation

/// Finds signing identities and decodes provisioning profiles with the
/// `security` tool. None of this reads a private key, so none of it asks
/// for a keychain password.
enum Signing {
    /// Resolves the identity for `cef bundle`. Precedence: `--sign` >
    /// cefapp.json `signingIdentity` > the first "Apple Development"
    /// identity, else the first "Developer ID Application" one, else ad hoc.
    static func resolveIdentity(
        flag: String?, configValue: String?, teamIdentifier: String?, keychain: String?,
        workDirectory: URL
    ) throws -> (identity: SigningIdentity, certificateSHA1: String?) {
        let requested = flag ?? configValue
        let source = flag != nil ? "--sign" : "cefapp.json signingIdentity"
        if requested == "-" {
            Log.info("Signing: ad hoc (\(source) -)")
            return (.adHoc, nil)
        }

        let valid = identities(keychain: keychain, validOnly: true)
        let all = identities(keychain: keychain, validOnly: false)
        let chosen: (hash: String, name: String)
        if let requested, all.isEmpty {
            // `security` lists nothing, as happens inside SwiftPM's plugin
            // sandbox for a keychain outside the search list. Let codesign
            // find the identity.
            Log.warning("could not list code-signing identities" + (keychain.map { " in \($0)" } ?? "") +
                  "; signing with '\(requested)' as given.")
            let kind = SignatureKind(certificateName: requested)
            return (SigningIdentity(name: requested, kind: kind,
                                    teamIdentifier: kind.hasAppleTeam ? teamIdentifier : nil), nil)
        } else if let requested {
            if let match = find(requested, in: valid) {
                chosen = match
            } else if let match = find(requested, in: all) {
                // A certificate macOS does not trust, such as a self-signed
                // one; codesign can still sign with it.
                Log.warning("'\(match.name)' is not a trusted code-signing identity; signing with it anyway.")
                chosen = match
            } else {
                throw BundlingError(
                    "No code-signing identity matches '\(requested)' (\(source))" +
                    (keychain.map { " in \($0)" } ?? "") + ". Identities found:\n" +
                    (valid.isEmpty ? "  none\n" : valid.map { "  \($0.hash) \"\($0.name)\"\n" }.joined()) +
                    "Create one in Xcode (Settings > Accounts > Manage Certificates), or pass '--sign -' for ad hoc.")
            }
            Log.info("Signing with identity from \(source): \(chosen.name)")
        } else if let match = valid.first(where: { $0.name.hasPrefix("Apple Development") })
                    ?? valid.first(where: { $0.name.hasPrefix("Developer ID Application") }) {
            chosen = match
            Log.info("Signing with auto-detected identity: \(chosen.name)")
        } else {
            Log.info("Signing: ad hoc (no code-signing identity found)")
            return (.adHoc, nil)
        }

        let team = teamIdentifier ?? certificateTeam(name: chosen.name, hash: chosen.hash, keychain: keychain,
                                                      workDirectory: workDirectory)
        if team == nil, SignatureKind(certificateName: chosen.name).hasAppleTeam {
            Log.warning("could not read the team identifier of '\(chosen.name)'; set teamIdentifier in cefapp.json.")
        }
        return (SigningIdentity(name: chosen.name, kind: SignatureKind(certificateName: chosen.name),
                                teamIdentifier: team), chosen.hash)
    }

    /// `security find-identity -p codesigning`, valid identities only or all.
    static func identities(keychain: String?, validOnly: Bool) -> [(hash: String, name: String)] {
        var arguments = ["find-identity", "-p", "codesigning"]
        if validOnly { arguments.append("-v") }
        if let keychain { arguments.append(keychain) }
        guard let result = try? Shell.run("/usr/bin/security", arguments), result.exitCode == 0 else { return [] }
        // Without -v the output lists "Matching identities" and then the
        // valid ones again; keep each hash once.
        var seen = Set<String>()
        return SigningIdentity.parseFindIdentity(result.stdout).filter { seen.insert($0.hash).inserted }
    }

    /// Matches like codesign: the SHA-1 hash, the whole name, or a part of
    /// the name.
    private static func find(_ requested: String, in identities: [(hash: String, name: String)]) -> (hash: String, name: String)? {
        identities.first { $0.hash.caseInsensitiveCompare(requested) == .orderedSame || $0.name == requested }
            ?? identities.first { $0.name.contains(requested) }
    }

    /// The certificate's organizational unit, which Apple sets to the team
    /// identifier.
    static func certificateTeam(name: String, hash: String, keychain: String?, workDirectory: URL) -> String? {
        var arguments = ["find-certificate", "-a", "-Z", "-p", "-c", name]
        if let keychain { arguments.append(keychain) }
        guard let result = try? Shell.run("/usr/bin/security", arguments), result.exitCode == 0 else { return nil }
        // Several certificates can share a name; take the one whose SHA-1
        // matches. Each starts with a "SHA-1 hash:" line.
        var pem: String?
        for block in result.stdout.components(separatedBy: "SHA-1 hash: ").dropFirst() {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.first?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(hash) == .orderedSame {
                pem = lines.dropFirst().joined(separator: "\n")
            }
        }
        guard let pem else { return nil }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let file = workDirectory.appendingPathComponent("certificate.pem")
        guard (try? Data(pem.utf8).write(to: file)) != nil,
              let subject = try? Shell.run("/usr/bin/openssl",
                                           ["x509", "-noout", "-subject", "-nameopt", "RFC2253", "-in", file.path]),
              subject.exitCode == 0
        else { return nil }
        return SigningIdentity.organizationalUnit(inSubject: subject.stdout)
    }

    /// Decodes a provisioning profile's CMS envelope.
    static func decodeProfile(at url: URL) throws -> ProvisioningProfile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BundlingError("No provisioning profile at \(url.path).")
        }
        let result = try Shell.runChecked(
            "/usr/bin/security", ["cms", "-D", "-i", url.path],
            hint: "\(url.lastPathComponent) is not a provisioning profile. Download it again from the Apple " +
                "Developer website (Certificates, Identifiers & Profiles > Profiles).")
        return try ProvisioningProfile(decodedData: Data(result.stdout.utf8), source: url.path)
    }
}
