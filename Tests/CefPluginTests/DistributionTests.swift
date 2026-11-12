import Foundation
import Testing

// The plugin's pure logic, compiled into this target through the
// `Distribution` directory symlink.

private let team = "A1B2C3D4E5"
private let developerID = SigningIdentity(
    name: "Developer ID Application: Example Corp (\(team))", kind: .developerID, teamIdentifier: team)
private let development = SigningIdentity(
    name: "Apple Development: Jane Doe (ZZZZZZZZZZ)", kind: .development, teamIdentifier: team)

private func profile(
    appID: String = "\(team).com.example.browser", allDevices: Bool = true,
    extra: PlistDictionary = [:], expires: Date = Date(timeIntervalSinceNow: 86_400)
) throws -> ProvisioningProfile {
    var entitlements: PlistDictionary = [
        "com.apple.application-identifier": .string(appID),
        "com.apple.developer.team-identifier": .string(team),
        "keychain-access-groups": .array([.string("\(team).*")]),
    ]
    entitlements = Plist.merge(entitlements, extra)
    var plist: PlistDictionary = [
        "Name": .string("Browser Developer ID"),
        "UUID": .string("0000"),
        "TeamIdentifier": .array([.string(team)]),
        "Platform": .array([.string("OSX")]),
        "ExpirationDate": .date(expires),
        "Entitlements": .dictionary(entitlements),
    ]
    if allDevices {
        plist["ProvisionsAllDevices"] = .bool(true)
    } else {
        plist["ProvisionedDevices"] = .array([.string("00008103-000000000000001E")])
    }
    return try ProvisioningProfile(plist: plist)
}

@Suite struct PlistTests {
    @Test func mergeIsDeepAndConcatenatesArrays() {
        let base: PlistDictionary = [
            "LSEnvironment": .dictionary(["MallocNanoZone": .string("0")]),
            "NSBonjourServices": .array([.string("_googlecast._tcp")]),
            "Name": .string("old"),
        ]
        let overlay: PlistDictionary = [
            "LSEnvironment": .dictionary(["FOO": .string("1")]),
            "NSBonjourServices": .array([.string("_googlecast._tcp"), .string("_ipp._tcp")]),
            "Name": .string("new"),
        ]
        let merged = Plist.merge(base, overlay)
        #expect(merged["LSEnvironment"] == .dictionary(["MallocNanoZone": .string("0"), "FOO": .string("1")]))
        #expect(merged["NSBonjourServices"] == .array([.string("_googlecast._tcp"), .string("_ipp._tcp")]))
        #expect(merged["Name"] == .string("new"))
    }

    @Test func roundTripsThroughPropertyListSerialization() throws {
        let plist: PlistDictionary = [
            "flag": .bool(true), "count": .integer(3), "ratio": .real(0.5),
            "list": .array([.string("a"), .bool(false)]),
        ]
        let decoded = try Plist.decode(try Plist.xmlData(plist), source: "test")
        #expect(decoded == plist)
    }

    @Test func jsonBooleansStayBooleans() throws {
        let config = try CefAppConfig.decode(
            Data(#"{ "infoPlist": { "A": true, "B": 1, "C": "x" }, }"#.utf8),
            source: URL(fileURLWithPath: "/tmp/cefapp.json"))
        #expect(config.infoPlist == ["A": .bool(true), "B": .integer(1), "C": .string("x")])
    }
}

@Suite struct AppConfigTests {
    @Test func allowsCommentsAndResolvesPathsBesideTheFile() throws {
        let json = """
        {
          // The browser's settings.
          "bundleIdentifier": "com.example.browser",
          "capabilities": ["camera"],
          "entitlements": "Browser.entitlements",
        }
        """
        let config = try CefAppConfig.decode(Data(json.utf8), source: URL(fileURLWithPath: "/src/App/cefapp.json"))
        #expect(config.bundleIdentifier == "com.example.browser")
        #expect(config.resolve(config.entitlements ?? "").path == "/src/App/Browser.entitlements")
    }

    @Test func rejectsUnknownKeys() {
        #expect(throws: CefPluginError.self) {
            try CefAppConfig.decode(Data(#"{ "capabilites": [] }"#.utf8), source: URL(fileURLWithPath: "/x/cefapp.json"))
        }
    }

    @Test func rejectsUnknownHelpers() {
        #expect(throws: CefPluginError.self) {
            try CefAppConfig.decode(Data(#"{ "helperEntitlements": { "gpu2": "x" } }"#.utf8),
                                    source: URL(fileURLWithPath: "/x/cefapp.json"))
        }
    }
}

@Suite struct SigningIdentityTests {
    @Test func classifiesCertificateNames() {
        #expect(SignatureKind(certificateName: "-") == .adHoc)
        #expect(SignatureKind(certificateName: "Apple Development: Jane (X)") == .development)
        #expect(SignatureKind(certificateName: "Mac Developer: Jane (X)") == .development)
        #expect(SignatureKind(certificateName: "Developer ID Application: Corp (X)") == .developerID)
        #expect(SignatureKind(certificateName: "Apple Distribution: Corp (X)") == .appStore)
        #expect(SignatureKind(certificateName: "CefSwift Self-Signed") == .other)
    }

    @Test func parsesFindIdentity() {
        let output = """
          1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Jane Doe (ZZZZZZZZZZ)"
          2) 89ABCDEF0123456789ABCDEF0123456789ABCDEF "Developer ID Application: Corp (A1B2C3D4E5)"
             2 valid identities found
        """
        let identities = SigningIdentity.parseFindIdentity(output)
        #expect(identities.count == 2)
        #expect(identities[0].hash == "0123456789ABCDEF0123456789ABCDEF01234567")
        #expect(identities[1].name == "Developer ID Application: Corp (A1B2C3D4E5)")
    }

    @Test func readsTheTeamFromTheOrganizationalUnit() {
        let subject = #"subject=UID=QQQQQQQQQQ,CN=Apple Development: Doe\, Jane (ZZZZZZZZZZ),OU=A1B2C3D4E5,O=Jane Doe,C=US"#
        #expect(SigningIdentity.organizationalUnit(inSubject: subject) == "A1B2C3D4E5")
        #expect(SigningIdentity.organizationalUnit(inSubject: "subject=CN=Self Signed,O=Me") == nil)
    }
}

@Suite struct EntitlementTemplateTests {
    @Test func expandsXcodeVariables() throws {
        let expanded = try Entitlements.expand(
            ["keychain-access-groups": .array([.string("$(TeamIdentifierPrefix)$(CFBundleIdentifier).shared"),
                                               .string("${AppIdentifierPrefix}x")])],
            teamIdentifier: team, bundleIdentifier: "com.example.browser", source: "test")
        #expect(expanded["keychain-access-groups"] == .array([
            .string("\(team).com.example.browser.shared"), .string("\(team).x"),
        ]))
    }

    @Test func teamVariablesNeedATeam() {
        #expect(throws: CefPluginError.self) {
            try Entitlements.expand(["k": .string("$(TeamIdentifierPrefix)x")], teamIdentifier: nil,
                                    bundleIdentifier: "b", source: "test")
        }
        #expect(throws: CefPluginError.self) {
            try Entitlements.expand(["k": .string("$(UNKNOWN)")], teamIdentifier: team, bundleIdentifier: "b", source: "test")
        }
    }

    @Test func classifiesRestrictedEntitlements() {
        #expect(Entitlements.isRestricted("keychain-access-groups"))
        #expect(Entitlements.isRestricted("com.apple.developer.web-browser.public-key-credential"))
        #expect(Entitlements.isRestricted("com.apple.application-identifier"))
        #expect(!Entitlements.isRestricted("com.apple.security.cs.allow-jit"))
        #expect(!Entitlements.isRestricted("com.apple.security.device.camera"))
    }
}

@Suite struct DistributionPlanTests {
    @Test func adHocDefaultsMatchTheLocalBuild() throws {
        let plan = try DistributionSettings(bundleIdentifier: "com.example.browser", identity: .adHoc).plan()
        #expect(plan.hardenedRuntime == false)
        #expect(plan.secureTimestamp == false)
        #expect(plan.appEntitlements.isEmpty)
        #expect(plan.helperEntitlements[.renderer] == ["com.apple.security.cs.allow-jit": .bool(true)])
        #expect(plan.helperEntitlements[.gpu] == ["com.apple.security.cs.allow-jit": .bool(true)])
        #expect(plan.helperEntitlements[.plugin] == [:])
        #expect(plan.helperEntitlements[.base] == [:])
    }

    @Test func teamlessHardenedRuntimeTurnsLibraryValidationOff() throws {
        var settings = DistributionSettings(bundleIdentifier: "b", identity: .adHoc)
        settings.hardenedRuntime = true
        let plan = try settings.plan()
        let key = "com.apple.security.cs.disable-library-validation"
        #expect(plan.appEntitlements[key] == .bool(true))
        for helper in HelperKind.allCases { #expect(plan.helperEntitlements[helper]?[key] == .bool(true)) }
        // A team signature keeps library validation.
        let team = try DistributionSettings(bundleIdentifier: "b", identity: developerID).plan()
        #expect(team.appEntitlements[key] == nil)
        #expect(team.helperEntitlements[.renderer]?[key] == nil)
    }

    @Test func protectedMediaLetsTheBaseHelperLoadGooglesCDM() throws {
        var settings = DistributionSettings(bundleIdentifier: "b", identity: developerID)
        settings.capabilities = ["protectedMedia"]
        let plan = try settings.plan()
        let key = Capability.disableLibraryValidation
        #expect(plan.helperEntitlements[.base]?[key] == .bool(true))
        #expect(plan.helperEntitlements[.renderer]?[key] == nil)
        #expect(plan.appEntitlements[key] == nil)
    }

    @Test func capabilitiesExpandToKeysAndEntitlements() throws {
        var settings = DistributionSettings(bundleIdentifier: "com.example.browser", identity: .adHoc)
        settings.capabilities = ["camera", "microphone", "localNetwork", "defaultBrowser"]
        settings.usageDescriptions = ["camera": "Cam", "microphone": "Mic", "localNetwork": "LAN"]
        let plan = try settings.plan()
        #expect(plan.appInfoPlist["NSCameraUsageDescription"] == .string("Cam"))
        #expect(plan.appInfoPlist["NSBonjourServices"] == .array([.string("_googlecast._tcp")]))
        #expect(plan.appInfoPlist["CFBundleURLTypes"] != nil)
        #expect(plan.appEntitlements["com.apple.security.device.camera"] == .bool(true))
        #expect(plan.helperEntitlements[.base]?["com.apple.security.device.audio-input"] == .bool(true))
        // Helpers get the usage descriptions, nothing else of the app's keys.
        #expect(plan.helperInfoPlist["NSMicrophoneUsageDescription"] == .string("Mic"))
        #expect(plan.helperInfoPlist["CFBundleURLTypes"] == nil)
    }

    @Test func missingUsageDescriptionIsAnError() {
        var settings = DistributionSettings(bundleIdentifier: "b", identity: .adHoc)
        settings.capabilities = ["passkeys"]  // implies bluetooth
        #expect {
            try settings.plan()
        } throws: { error in
            "\(error)".contains("'bluetooth'") && "\(error)".contains("usageDescriptions")
        }
        settings.infoPlistOverlays = [("infoPlist", ["NSBluetoothAlwaysUsageDescription": .string("BT")])]
        #expect(throws: Never.self) { try settings.plan() }
    }

    @Test func unknownCapabilityIsAnError() {
        var settings = DistributionSettings(bundleIdentifier: "b", identity: .adHoc)
        settings.capabilities = ["teleport"]
        #expect(throws: CefPluginError.self) { try settings.plan() }
    }

    @Test func adHocLeavesRestrictedCapabilityEntitlementsOut() throws {
        var settings = DistributionSettings(bundleIdentifier: "b", identity: .adHoc)
        settings.capabilities = ["passkeys"]
        settings.usageDescriptions = ["bluetooth": "BT"]
        let plan = try settings.plan()
        #expect(plan.appEntitlements[Capability.publicKeyCredentialEntitlement] == nil)
        #expect(plan.appEntitlements["com.apple.security.device.bluetooth"] == .bool(true))
        #expect(plan.warnings.contains { $0.contains("iCloud Keychain") })
    }

    @Test func adHocRefusesRestrictedEntitlementsFromAFile() {
        var settings = DistributionSettings(bundleIdentifier: "b", identity: .adHoc)
        settings.appEntitlementsFile = ("App.entitlements", ["keychain-access-groups": .array([.string("x.y")])])
        #expect {
            try settings.plan()
        } throws: { "\($0)".contains("AMFI") }
    }

    @Test func teamWithoutProfileRefusesRestrictedEntitlementsFromAFile() {
        var settings = DistributionSettings(bundleIdentifier: "b", identity: developerID)
        settings.appEntitlementsFile = ("App.entitlements", ["com.apple.developer.web-browser.public-key-credential": .bool(true)])
        #expect {
            try settings.plan()
        } throws: { "\($0)".contains("provisioningProfile") }
    }

    @Test func developerIDWithProfileGetsRestrictedEntitlements() throws {
        var settings = DistributionSettings(bundleIdentifier: "com.example.browser", identity: developerID)
        settings.capabilities = ["passkeys"]
        settings.usageDescriptions = ["bluetooth": "BT", "passkeys": "Sign in"]
        settings.profile = try profile(extra: [Capability.publicKeyCredentialEntitlement: .bool(true)])
        let plan = try settings.plan()
        #expect(plan.hardenedRuntime && plan.secureTimestamp)
        #expect(plan.appEntitlements[Capability.publicKeyCredentialEntitlement] == .bool(true))
        #expect(plan.appEntitlements["com.apple.application-identifier"] == .string("\(team).com.example.browser"))
        #expect(plan.appEntitlements["com.apple.developer.team-identifier"] == .string(team))
        #expect(plan.appEntitlements["com.apple.security.get-task-allow"] == nil)
        #expect(plan.appInfoPlist["NSWebBrowserPublicKeyCredentialUsageDescription"] == .string("Sign in"))
        #expect(plan.warnings.isEmpty)
        // Helpers never carry restricted entitlements.
        for helper in HelperKind.allCases {
            #expect(plan.helperEntitlements[helper]?.keys.contains(where: Entitlements.isRestricted) == false)
        }
    }

    @Test func profileWithoutTheEntitlementLeavesItOutWithAWarning() throws {
        var settings = DistributionSettings(bundleIdentifier: "com.example.browser", identity: developerID)
        settings.capabilities = ["passkeys"]
        settings.usageDescriptions = ["bluetooth": "BT"]
        settings.profile = try profile()
        let plan = try settings.plan()
        #expect(plan.appEntitlements[Capability.publicKeyCredentialEntitlement] == nil)
        #expect(plan.warnings.contains { $0.contains("does not authorize") })
    }

    @Test func developmentSigningAllowsDebugging() throws {
        let plan = try DistributionSettings(bundleIdentifier: "b", identity: development).plan()
        #expect(plan.appEntitlements["com.apple.security.get-task-allow"] == .bool(true))
        #expect(plan.helperEntitlements[.renderer]?["com.apple.security.get-task-allow"] == .bool(true))
        #expect(plan.hardenedRuntime && !plan.secureTimestamp)
    }

    @Test func developerIDRejectsGetTaskAllow() {
        var settings = DistributionSettings(bundleIdentifier: "b", identity: developerID)
        settings.appEntitlementsFile = ("App.entitlements", ["com.apple.security.get-task-allow": .bool(true)])
        #expect(throws: CefPluginError.self) { try settings.plan() }
    }

    @Test func helperOverridesMergeAndCannotBeRestricted() throws {
        var settings = DistributionSettings(bundleIdentifier: "b", identity: .adHoc)
        settings.helperEntitlementFiles[.plugin] = ("plugin.entitlements",
                                                    ["com.apple.security.cs.disable-library-validation": .bool(true)])
        settings.helperEntitlementFiles[.renderer] = ("renderer.entitlements",
                                                      ["com.apple.security.cs.allow-jit": .bool(false)])
        let plan = try settings.plan()
        #expect(plan.helperEntitlements[.plugin]?["com.apple.security.cs.disable-library-validation"] == .bool(true))
        #expect(plan.helperEntitlements[.renderer]?["com.apple.security.cs.allow-jit"] == nil)

        settings.helperEntitlementFiles[.gpu] = ("gpu.entitlements", ["keychain-access-groups": .array([.string("x")])])
        #expect(throws: CefPluginError.self) { try settings.plan() }
    }

    @Test func reservedInfoPlistKeysAreRejected() {
        var settings = DistributionSettings(bundleIdentifier: "b", identity: .adHoc)
        settings.infoPlistOverlays = [("infoPlist", ["CFBundleIdentifier": .string("other")])]
        #expect(throws: CefPluginError.self) { try settings.plan() }
    }
}

@Suite struct ProvisioningProfileTests {
    @Test func matchesWildcards() throws {
        let profile = try profile(appID: "\(team).*")
        #expect(profile.authorizes("keychain-access-groups", .array([.string("\(team).com.example.webauthn")])))
        #expect(!profile.authorizes("keychain-access-groups", .array([.string(".org.chromium.Chromium.webauthn")])))
        #expect(!profile.authorizes(Capability.publicKeyCredentialEntitlement, .bool(true)))
        #expect(profile.problems(bundleIdentifier: "com.example.browser", identity: developerID,
                                 certificateSHA1: nil, entitlements: [:]).isEmpty)
    }

    @Test func reportsMismatches() throws {
        let other = SigningIdentity(name: "Developer ID Application: Other (Q1Q1Q1Q1Q1)", kind: .developerID,
                                    teamIdentifier: "Q1Q1Q1Q1Q1")
        let expired = try profile(allDevices: false, expires: Date(timeIntervalSinceNow: -86_400))
        let messages = expired.problems(bundleIdentifier: "com.example.other", identity: other,
                                        certificateSHA1: nil,
                                        entitlements: [Capability.publicKeyCredentialEntitlement: .bool(true)])
            .map(\.message)
        #expect(messages.contains { $0.contains("expired") })
        #expect(messages.contains { $0.contains("belongs to team") })
        #expect(messages.contains { $0.contains("App ID") })
        #expect(messages.contains { $0.contains("development profile") })
        #expect(messages.contains { $0.contains("does not authorize") })
    }

    @Test func checksTheCertificate() throws {
        var plist: PlistDictionary = [
            "Name": .string("p"), "ProvisionsAllDevices": .bool(true),
            "TeamIdentifier": .array([.string(team)]),
            "Entitlements": .dictionary(["com.apple.application-identifier": .string("\(team).*")]),
            "DeveloperCertificates": .array([.data(Data([1, 2, 3]))]),
        ]
        let profile = try ProvisioningProfile(plist: plist)
        let matching = SHA1.hex(Data([1, 2, 3]))
        #expect(profile.problems(bundleIdentifier: "b", identity: developerID, certificateSHA1: matching,
                                 entitlements: [:]).isEmpty)
        #expect(!profile.problems(bundleIdentifier: "b", identity: developerID, certificateSHA1: "00",
                                  entitlements: [:]).isEmpty)
        plist["Entitlements"] = nil
        #expect(throws: CefPluginError.self) { try ProvisioningProfile(plist: plist) }
    }
}

@Suite struct DoctorTests {
    private func facts(kind: SignatureKind, team: String?, runtime: Bool,
                       entitlements: PlistDictionary = [:], info: PlistDictionary = [:]) -> BundleFacts {
        // cef bundle turns library validation off for team-less hardened builds.
        let extra: PlistDictionary = runtime && team == nil
            ? ["com.apple.security.cs.disable-library-validation": .bool(true)] : [:]
        func part(_ name: String, _ entitlements: PlistDictionary = [:]) -> BundleFacts.Part {
            .init(name: name, path: "/x/\(name)", kind: kind, teamIdentifier: team, isHardenedRuntime: runtime,
                  hasSecureTimestamp: kind == .developerID, entitlements: Plist.merge(entitlements, extra))
        }
        var app = part("Browser.app", entitlements)
        app.infoPlist = Plist.merge(["CFBundleIdentifier": .string("com.example.browser")], info)
        var facts = BundleFacts(app: app)
        for helper in HelperKind.allCases {
            facts.helpers[helper] = part(helper.appName(for: "Browser") + ".app", helper.baseEntitlements)
        }
        facts.libraries = [part("Chromium Embedded Framework.framework")]
        return facts
    }

    @Test func adHocBuildOffersOnlySecurityKeys() {
        let report = Doctor.evaluate(facts(kind: .adHoc, team: nil, runtime: false))
        #expect(report.errorCount == 0)
        #expect(report.passkeyAuthenticators == ["security keys (USB/NFC)"])
        #expect(report.keychainPolicy == "mock keychain")
    }

    @Test func bluetoothUsageEnablesHybrid() {
        let report = Doctor.evaluate(facts(
            kind: .adHoc, team: nil, runtime: true,
            entitlements: ["com.apple.security.device.bluetooth": .bool(true)],
            info: ["NSBluetoothAlwaysUsageDescription": .string("BT")]))
        #expect(report.passkeyAuthenticators.contains("phones (hybrid)"))
    }

    @Test func restrictedEntitlementsWithoutProfileAreErrors() {
        let report = Doctor.evaluate(facts(
            kind: .adHoc, team: nil, runtime: true,
            entitlements: ["keychain-access-groups": .array([.string("x")])]))
        #expect(report.errorCount >= 1)
    }

    @Test func missingJITUnderHardenedRuntimeIsAnError() {
        var facts = facts(kind: .adHoc, team: nil, runtime: true)
        facts.helpers[.renderer]?.entitlements = [:]
        #expect(Doctor.evaluate(facts).errorCount == 1)
    }

    @Test func teamlessHardenedRuntimeNeedsLibraryValidationOff() {
        var facts = facts(kind: .adHoc, team: nil, runtime: true)
        facts.app.entitlements = [:]
        facts.helpers[.gpu]?.entitlements["com.apple.security.cs.disable-library-validation"] = nil
        #expect(Doctor.evaluate(facts).errorCount == 2)
    }

    @Test func protectedMediaNeedsLibraryValidationOffInTeamSignedHelper() {
        func status(_ facts: BundleFacts) -> DoctorReport.Status? {
            Doctor.evaluate(facts).sections.flatMap(\.checks).first { $0.title == "protectedMedia" }?.status
        }
        var facts = facts(kind: .developerID, team: team, runtime: true)
        #expect(status(facts) == .info)
        facts.helpers[.base]?.entitlements[Capability.disableLibraryValidation] = .bool(true)
        #expect(status(facts) == .ok)
        #expect(status(self.facts(kind: .adHoc, team: nil, runtime: false)) == .ok)
    }

    @Test func mismatchedLibrarySignatureIsAnError() {
        var facts = facts(kind: .developerID, team: team, runtime: true)
        facts.libraries.append(.init(name: "libvulkan.dylib", path: "/x", kind: .adHoc))
        let report = Doctor.evaluate(facts)
        #expect(report.sections.flatMap(\.checks).contains {
            $0.status == .error && $0.detail.contains("libvulkan.dylib")
        })
    }

    @Test func linkageProblemsAreErrors() {
        func linking(_ facts: BundleFacts) -> DoctorReport.Check? {
            Doctor.evaluate(facts).sections.flatMap(\.checks).first { $0.title == "linking" }
        }
        var facts = facts(kind: .adHoc, team: nil, runtime: false)
        facts.architectures = ["arm64"]
        facts.appLibraries = ["libGreeter.dylib"]
        facts.resourceBundles = ["App_Hello.bundle"]
        #expect(linking(facts)?.status == .ok)
        #expect(linking(facts)?.detail.contains("libGreeter.dylib") == true)
        #expect(linking(facts)?.detail.contains("App_Hello.bundle") == true)

        facts.linkageProblems = ["Contents/MacOS/Browser searches /build/out for libraries, outside the bundle"]
        #expect(linking(facts)?.status == .error)
        #expect(Doctor.evaluate(facts).errorCount == 1)
    }

    @Test func developerIDWithEntitlementAndProfileOffersICloudKeychain() throws {
        var facts = facts(kind: .developerID, team: team, runtime: true, entitlements: [
            Capability.publicKeyCredentialEntitlement: .bool(true),
            "com.apple.application-identifier": .string("\(team).com.example.browser"),
        ])
        facts.profile = try profile(extra: [Capability.publicKeyCredentialEntitlement: .bool(true)])
        facts.gatekeeperAccepted = true
        facts.isStapled = true
        let report = Doctor.evaluate(facts)
        #expect(report.errorCount == 0)
        #expect(report.passkeyAuthenticators.contains("iCloud Keychain"))
        #expect(report.keychainPolicy == "keychain")
        #expect(try report.json().contains("\"errors\" : 0"))
    }

    @Test func parsesCodesignDisplay() {
        var part = BundleFacts.Part(name: "a", path: "/a")
        Doctor.parseCodesignDisplay("""
            Executable=/a
            CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+7 location=embedded
            Authority=Developer ID Application: Corp (A1B2C3D4E5)
            Authority=Developer ID Certification Authority
            Authority=Apple Root CA
            Timestamp=Nov 12, 2026 at 10:00:00
            TeamIdentifier=A1B2C3D4E5
            """, into: &part)
        #expect(part.kind == .developerID && part.isHardenedRuntime && part.hasSecureTimestamp)
        #expect(part.teamIdentifier == "A1B2C3D4E5")

        var adHoc = BundleFacts.Part(name: "b", path: "/b")
        Doctor.parseCodesignDisplay("""
            CodeDirectory v=20400 size=1 flags=0x20002(adhoc,linker-signed) hashes=1+0 location=embedded
            Signature=adhoc
            TeamIdentifier=not set
            """, into: &adHoc)
        #expect(adHoc.kind == .adHoc && !adHoc.isHardenedRuntime && adHoc.teamIdentifier == nil)
    }
}
