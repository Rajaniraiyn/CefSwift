import Foundation

/// The Xcode project `cefswift new --xcode` writes beside the package: one
/// app target whose sources are the package's `Sources/<Name>` (a folder
/// Xcode keeps in sync), CefSwift as a package dependency, and CefSwift's
/// build phase, set up as `Examples/Xcode` is (docs/bundling.md#xcode).
struct XcodeProject {
    let scaffold: Scaffold
    let manifest: Scaffold.Manifest

    private var name: String { scaffold.name }

    /// Files the synchronized folder holds that are not the app's
    /// resources: the package's settings and the entitlements.
    private var membershipExceptions: [String] {
        ["cefapp.json"] + [manifest.entitlements].compactMap { $0 }
    }

    /// A local CefSwift, relative to the project.
    private var localPath: String? {
        guard case .path(let path) = scaffold.dependency else { return nil }
        return Self.relative(path, from: scaffold.output.path)
    }

    /// Where the build phase finds CefSwift's scripts.
    private var packageDirectory: String {
        if let localPath { return "\"$(PROJECT_DIR)/\(localPath)\"" }
        return "\"$(BUILD_DIR)/../../SourcePackages/checkouts/CefSwift\""
    }

    /// `path` relative to the directory `base`.
    static func relative(_ path: String, from base: String) -> String {
        let target = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let origin = URL(fileURLWithPath: base).standardizedFileURL.pathComponents
        let common = zip(target, origin).prefix { $0 == $1 }.count
        let components = Array(repeating: "..", count: origin.count - common) + target[common...]
        return components.isEmpty ? "." : components.joined(separator: "/")
    }

    /// `CefSwift.xcconfig`, as `Examples/Xcode` has it.
    func configuration(root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent("Examples/Xcode/CefSwift.xcconfig"), encoding: .utf8)
    }

    private var packageReference: String {
        switch scaffold.dependency {
        case .path:
            return """
            \t\tCE0000000000000000000003 /* XCLocalSwiftPackageReference "CefSwift" */ = {
            \t\t\tisa = XCLocalSwiftPackageReference;
            \t\t\trelativePath = \(Self.quoted(localPath ?? "."));
            \t\t};
            """
        case .version(let version):
            return remoteReference("kind = upToNextMinorVersion;\n\t\t\t\tminimumVersion = \(version);")
        case .branch(let branch):
            return remoteReference("branch = \(Self.quoted(branch));\n\t\t\t\tkind = branch;")
        }
    }

    private func remoteReference(_ requirement: String) -> String {
        """
        \t\tCE0000000000000000000003 /* XCRemoteSwiftPackageReference "CefSwift" */ = {
        \t\t\tisa = XCRemoteSwiftPackageReference;
        \t\t\trepositoryURL = "\(Scaffold.repositoryURL)";
        \t\t\trequirement = {
        \t\t\t\t\(requirement)
        \t\t\t};
        \t\t};
        """
    }

    private var referenceKind: String {
        if case .path = scaffold.dependency { return "XCLocalSwiftPackageReference" }
        return "XCRemoteSwiftPackageReference"
    }

    static func quoted(_ text: String) -> String {
        text.range(of: #"^[A-Za-z0-9_./]+$"#, options: .regularExpression) != nil ? text : Scaffold.quoted(text)
    }

    /// Product `index`'s two identifiers: its build file and its dependency.
    private func identifiers(_ index: Int) -> (file: String, product: String) {
        (String(format: "CE00000000000000000001%02X", index), String(format: "CE00000000000000000002%02X", index))
    }

    private var targetSettings: String {
        var settings: [(String, String)] = [
            ("CEFSWIFT_PACKAGE_DIR", packageDirectory),
            ("CEF_APP_CONFIG", "\"$(PROJECT_DIR)/Sources/\(name)/cefapp.json\""),
            ("CODE_SIGN_STYLE", "Automatic"),
            ("COMBINE_HIDPI_IMAGES", "YES"),
            ("CURRENT_PROJECT_VERSION", "1"),
            ("ENABLE_HARDENED_RUNTIME", "YES"),
            ("ENABLE_PREVIEWS", "YES"),
            ("GENERATE_INFOPLIST_FILE", "YES"),
            ("INFOPLIST_KEY_CFBundleDisplayName", Scaffold.quoted(scaffold.displayName)),
            ("LD_RUNPATH_SEARCH_PATHS", "(\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t\t\"@executable_path/../Frameworks\",\n\t\t\t\t)"),
            ("MACOSX_DEPLOYMENT_TARGET", manifest.macOS),
            ("MARKETING_VERSION", "1.0"),
            ("PRODUCT_BUNDLE_IDENTIFIER", Self.quoted(scaffold.bundleIdentifier)),
            ("PRODUCT_NAME", "\"$(TARGET_NAME)\""),
            ("SWIFT_VERSION", "6.0"),
        ]
        if let entitlements = manifest.entitlements {
            settings.append(("CODE_SIGN_ENTITLEMENTS", "\"Sources/\(name)/\(entitlements)\""))
        }
        // The browser's capabilities (cefapp.json) give its helpers camera,
        // microphone and location access, which the app needs too.
        if scaffold.template == "browser" {
            settings += [("ENABLE_RESOURCE_ACCESS_AUDIO_INPUT", "YES"), ("ENABLE_RESOURCE_ACCESS_CAMERA", "YES"),
                         ("ENABLE_RESOURCE_ACCESS_LOCATION", "YES")]
        }
        return settings.sorted { $0.0 < $1.0 }.map { "\t\t\t\t\($0.0) = \($0.1);" }.joined(separator: "\n")
    }

    var text: String {
        let products = manifest.products.enumerated().map { (index: $0.offset, name: $0.element) }
        let buildFiles = products.map { product in
            "\t\t\(identifiers(product.index).file) /* \(product.name) in Frameworks */ = {isa = PBXBuildFile; " +
                "productRef = \(identifiers(product.index).product) /* \(product.name) */; };"
        }.joined(separator: "\n")
        let frameworkFiles = products.map { "\t\t\t\t\(identifiers($0.index).file) /* \($0.name) in Frameworks */," }
            .joined(separator: "\n")
        let productReferences = products.map { "\t\t\t\t\(identifiers($0.index).product) /* \($0.name) */," }
            .joined(separator: "\n")
        let packageLine: String
        if case .path = scaffold.dependency { packageLine = "" } else {
            packageLine = "\t\t\tpackage = CE0000000000000000000003 /* XCRemoteSwiftPackageReference \"CefSwift\" */;\n"
        }
        let productDependencies = products.map { product in
            """
            \t\t\(identifiers(product.index).product) /* \(product.name) */ = {
            \t\t\tisa = XCSwiftPackageProductDependency;
            \(packageLine)\t\t\tproductName = \(product.name);
            \t\t};
            """
        }.joined(separator: "\n")
        let exceptions = membershipExceptions.sorted().map { "\t\t\t\t\(Self.quoted($0))," }.joined(separator: "\n")
        let project = Self.quoted(name)

        return """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 77;
        \tobjects = {

        /* Begin PBXBuildFile section */
        \(buildFiles)
        /* End PBXBuildFile section */

        /* Begin PBXFileReference section */
        \t\tCE0000000000000000000010 /* \(name).app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \(Self.quoted(name + ".app")); sourceTree = BUILT_PRODUCTS_DIR; };
        \t\tCE0000000000000000000011 /* CefSwift.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = CefSwift.xcconfig; sourceTree = "<group>"; };
        /* End PBXFileReference section */

        /* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
        \t\tCE0000000000000000000021 /* Exceptions for "Sources/\(name)" folder in "\(name)" target */ = {
        \t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;
        \t\t\tmembershipExceptions = (
        \(exceptions)
        \t\t\t);
        \t\t\ttarget = CE0000000000000000000050 /* \(name) */;
        \t\t};
        /* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

        /* Begin PBXFileSystemSynchronizedRootGroup section */
        \t\tCE0000000000000000000020 /* Sources/\(name) */ = {
        \t\t\tisa = PBXFileSystemSynchronizedRootGroup;
        \t\t\texceptions = (
        \t\t\t\tCE0000000000000000000021 /* Exceptions for "Sources/\(name)" folder in "\(name)" target */,
        \t\t\t);
        \t\t\tpath = \(Self.quoted("Sources/" + name));
        \t\t\tsourceTree = "<group>";
        \t\t};
        /* End PBXFileSystemSynchronizedRootGroup section */

        /* Begin PBXFrameworksBuildPhase section */
        \t\tCE0000000000000000000030 /* Frameworks */ = {
        \t\t\tisa = PBXFrameworksBuildPhase;
        \t\t\tbuildActionMask = 2147483647;
        \t\t\tfiles = (
        \(frameworkFiles)
        \t\t\t);
        \t\t\trunOnlyForDeploymentPostprocessing = 0;
        \t\t};
        /* End PBXFrameworksBuildPhase section */

        /* Begin PBXGroup section */
        \t\tCE0000000000000000000040 = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tCE0000000000000000000011 /* CefSwift.xcconfig */,
        \t\t\t\tCE0000000000000000000020 /* Sources/\(name) */,
        \t\t\t\tCE0000000000000000000041 /* Products */,
        \t\t\t);
        \t\t\tsourceTree = "<group>";
        \t\t};
        \t\tCE0000000000000000000041 /* Products */ = {
        \t\t\tisa = PBXGroup;
        \t\t\tchildren = (
        \t\t\t\tCE0000000000000000000010 /* \(name).app */,
        \t\t\t);
        \t\t\tname = Products;
        \t\t\tsourceTree = "<group>";
        \t\t};
        /* End PBXGroup section */

        /* Begin PBXNativeTarget section */
        \t\tCE0000000000000000000050 /* \(name) */ = {
        \t\t\tisa = PBXNativeTarget;
        \t\t\tbuildConfigurationList = CE0000000000000000000060 /* Build configuration list for PBXNativeTarget "\(name)" */;
        \t\t\tbuildPhases = (
        \t\t\t\tCE0000000000000000000051 /* Sources */,
        \t\t\t\tCE0000000000000000000030 /* Frameworks */,
        \t\t\t\tCE0000000000000000000052 /* Resources */,
        \t\t\t\tCE0000000000000000000053 /* CefSwift */,
        \t\t\t);
        \t\t\tbuildRules = (
        \t\t\t);
        \t\t\tdependencies = (
        \t\t\t);
        \t\t\tfileSystemSynchronizedGroups = (
        \t\t\t\tCE0000000000000000000020 /* Sources/\(name) */,
        \t\t\t);
        \t\t\tname = \(project);
        \t\t\tpackageProductDependencies = (
        \(productReferences)
        \t\t\t);
        \t\t\tproductName = \(project);
        \t\t\tproductReference = CE0000000000000000000010 /* \(name).app */;
        \t\t\tproductType = "com.apple.product-type.application";
        \t\t};
        /* End PBXNativeTarget section */

        /* Begin PBXProject section */
        \t\tCE0000000000000000000070 /* Project object */ = {
        \t\t\tisa = PBXProject;
        \t\t\tattributes = {
        \t\t\t\tBuildIndependentTargetsInParallel = 1;
        \t\t\t\tLastSwiftUpdateCheck = 2720;
        \t\t\t\tLastUpgradeCheck = 2720;
        \t\t\t};
        \t\t\tbuildConfigurationList = CE0000000000000000000071 /* Build configuration list for PBXProject "\(name)" */;
        \t\t\tdevelopmentRegion = en;
        \t\t\thasScannedForEncodings = 0;
        \t\t\tknownRegions = (
        \t\t\t\ten,
        \t\t\t\tBase,
        \t\t\t);
        \t\t\tmainGroup = CE0000000000000000000040;
        \t\t\tminimizedProjectReferenceProxies = 1;
        \t\t\tpackageReferences = (
        \t\t\t\tCE0000000000000000000003 /* \(referenceKind) "CefSwift" */,
        \t\t\t);
        \t\t\tpreferredProjectObjectVersion = 77;
        \t\t\tproductRefGroup = CE0000000000000000000041 /* Products */;
        \t\t\tprojectDirPath = "";
        \t\t\tprojectRoot = "";
        \t\t\ttargets = (
        \t\t\t\tCE0000000000000000000050 /* \(name) */,
        \t\t\t);
        \t\t};
        /* End PBXProject section */

        /* Begin PBXResourcesBuildPhase section */
        \t\tCE0000000000000000000052 /* Resources */ = {
        \t\t\tisa = PBXResourcesBuildPhase;
        \t\t\tbuildActionMask = 2147483647;
        \t\t\tfiles = (
        \t\t\t);
        \t\t\trunOnlyForDeploymentPostprocessing = 0;
        \t\t};
        /* End PBXResourcesBuildPhase section */

        /* Begin PBXShellScriptBuildPhase section */
        \t\tCE0000000000000000000053 /* CefSwift */ = {
        \t\t\tisa = PBXShellScriptBuildPhase;
        \t\t\talwaysOutOfDate = 1;
        \t\t\tbuildActionMask = 2147483647;
        \t\t\tfiles = (
        \t\t\t);
        \t\t\tinputFileListPaths = (
        \t\t\t);
        \t\t\tinputPaths = (
        \t\t\t);
        \t\t\tname = CefSwift;
        \t\t\toutputFileListPaths = (
        \t\t\t);
        \t\t\toutputPaths = (
        \t\t\t);
        \t\t\trunOnlyForDeploymentPostprocessing = 0;
        \t\t\tshellPath = /bin/sh;
        \t\t\tshellScript = "\\"$CEFSWIFT_PACKAGE_DIR/Scripts/xcode-embed.sh\\"\\n";
        \t\t};
        /* End PBXShellScriptBuildPhase section */

        /* Begin PBXSourcesBuildPhase section */
        \t\tCE0000000000000000000051 /* Sources */ = {
        \t\t\tisa = PBXSourcesBuildPhase;
        \t\t\tbuildActionMask = 2147483647;
        \t\t\tfiles = (
        \t\t\t);
        \t\t\trunOnlyForDeploymentPostprocessing = 0;
        \t\t};
        /* End PBXSourcesBuildPhase section */

        /* Begin XCBuildConfiguration section */
        \(projectConfiguration(id: "CE0000000000000000000080", debug: true))
        \(projectConfiguration(id: "CE0000000000000000000081", debug: false))
        \t\tCE0000000000000000000082 /* Debug */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbaseConfigurationReference = CE0000000000000000000011 /* CefSwift.xcconfig */;
        \t\t\tbuildSettings = {
        \(targetSettings)
        \t\t\t};
        \t\t\tname = Debug;
        \t\t};
        \t\tCE0000000000000000000083 /* Release */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbaseConfigurationReference = CE0000000000000000000011 /* CefSwift.xcconfig */;
        \t\t\tbuildSettings = {
        \(targetSettings)
        \t\t\t};
        \t\t\tname = Release;
        \t\t};
        /* End XCBuildConfiguration section */

        /* Begin XCConfigurationList section */
        \t\tCE0000000000000000000060 /* Build configuration list for PBXNativeTarget "\(name)" */ = {
        \t\t\tisa = XCConfigurationList;
        \t\t\tbuildConfigurations = (
        \t\t\t\tCE0000000000000000000082 /* Debug */,
        \t\t\t\tCE0000000000000000000083 /* Release */,
        \t\t\t);
        \t\t\tdefaultConfigurationIsVisible = 0;
        \t\t\tdefaultConfigurationName = Release;
        \t\t};
        \t\tCE0000000000000000000071 /* Build configuration list for PBXProject "\(name)" */ = {
        \t\t\tisa = XCConfigurationList;
        \t\t\tbuildConfigurations = (
        \t\t\t\tCE0000000000000000000080 /* Debug */,
        \t\t\t\tCE0000000000000000000081 /* Release */,
        \t\t\t);
        \t\t\tdefaultConfigurationIsVisible = 0;
        \t\t\tdefaultConfigurationName = Release;
        \t\t};
        /* End XCConfigurationList section */

        /* Begin \(referenceKind) section */
        \(packageReference)
        /* End \(referenceKind) section */

        /* Begin XCSwiftPackageProductDependency section */
        \(productDependencies)
        /* End XCSwiftPackageProductDependency section */
        \t};
        \trootObject = CE0000000000000000000070 /* Project object */;
        }

        """
    }

    /// The project-level configuration, as Xcode's app template has it.
    private func projectConfiguration(id: String, debug: Bool) -> String {
        var settings = [
            "ALWAYS_SEARCH_USER_PATHS = NO;", "CLANG_ENABLE_MODULES = YES;", "CLANG_ENABLE_OBJC_ARC = YES;",
            "COPY_PHASE_STRIP = NO;", "ENABLE_STRICT_OBJC_MSGSEND = YES;", "ENABLE_USER_SCRIPT_SANDBOXING = YES;",
            "GCC_C_LANGUAGE_STANDARD = gnu17;", "LOCALIZATION_PREFERS_STRING_CATALOGS = YES;",
            "MACOSX_DEPLOYMENT_TARGET = \(manifest.macOS);", "SDKROOT = macosx;",
        ]
        if debug {
            settings += [
                "DEBUG_INFORMATION_FORMAT = dwarf;", "ENABLE_TESTABILITY = YES;", "GCC_DYNAMIC_NO_PIC = NO;",
                "GCC_OPTIMIZATION_LEVEL = 0;",
                "GCC_PREPROCESSOR_DEFINITIONS = (\n\t\t\t\t\t\"DEBUG=1\",\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t);",
                "ONLY_ACTIVE_ARCH = YES;", "SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";",
                "SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";",
            ]
        } else {
            settings += ["DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";", "ENABLE_NS_ASSERTIONS = NO;",
                         "SWIFT_COMPILATION_MODE = wholemodule;"]
        }
        let configuration = debug ? "Debug" : "Release"
        return """
        \t\t\(id) /* \(configuration) */ = {
        \t\t\tisa = XCBuildConfiguration;
        \t\t\tbuildSettings = {
        \(settings.sorted().map { "\t\t\t\t\($0)" }.joined(separator: "\n"))
        \t\t\t};
        \t\t\tname = \(configuration);
        \t\t};
        """
    }
}
