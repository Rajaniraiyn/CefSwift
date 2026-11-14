import Foundation
import Testing

@testable import CefChromium
@testable import CefKit

/// `chrome.developerPrivate.ExtensionInfo` and the manifest, decoded into
/// `CefExtension`.
struct ExtensionTests {
    /// What `getExtensionsInfo` returned for SelfTest's fixture in CEF 156,
    /// trimmed.
    static let info = """
        {"id": "hijdjdmlodkldbmopflekahgjddfeagl", "name": "CefSwift Test Extension", "version": "1.0",
         "description": "A test fixture.", "state": "ENABLED", "location": "UNPACKED",
         "iconUrl": "data:image/png;base64,iVBORw0KGgo=",
         "path": "/tmp/TestExtension",
         "optionsPage": {"openInTab": true, "url": "chrome-extension://hijdjdmlodkldbmopflekahgjddfeagl/options.html"},
         "homePage": {"specified": false, "url": ""}, "webStoreUrl": "",
         "permissions": {"simplePermissions": [{"message": "Read and change your bookmarks", "submessages": []}],
                         "runtimeHostPermissions": {"hasAllHosts": false, "hostAccess": "ON_ALL_SITES",
                                                    "hosts": [{"granted": true, "host": "http://127.0.0.1/*"}]}},
         "incognitoAccess": {"isActive": false, "isEnabled": true}, "userMayModify": true, "mustRemainInstalled": false,
         "commands": [{"description": "Activate the extension", "isActive": true, "isExtensionAction": true,
                       "keybinding": "⌃⇧Y", "name": "_execute_action", "scope": "CHROME"}],
         "futureField": {"ignored": true}}
        """

    static let manifest = """
        {"manifest_version": 3, "name": "x", "version": "1.0",
         "action": {"default_title": "CefSwift Test", "default_popup": "popup.html", "default_icon": {"16": "a.png", "32": "b.png"}},
         "chrome_url_overrides": {"newtab": "newtab.html", "unknown": "x.html"}}
        """

    @Test func decodesDeveloperInfo() throws {
        let info = try JSONDecoder().decode(DeveloperExtensionInfo.self, from: Data(Self.info.utf8))
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(Self.manifest.utf8))
        let item = CefExtension(info, manifest: manifest)
        #expect(item.id == "hijdjdmlodkldbmopflekahgjddfeagl")
        #expect(item.name == "CefSwift Test Extension")
        #expect(item.state == .enabled && item.isEnabled)
        #expect(item.installSource == .unpacked)
        #expect(item.iconData == Data(base64Encoded: "iVBORw0KGgo="))
        #expect(item.directory?.path == "/tmp/TestExtension")
        #expect(item.optionsURL?.lastPathComponent == "options.html")
        #expect(item.homepageURL == nil && item.webStoreURL == nil)
        #expect(item.permissionWarnings == ["Read and change your bookmarks"])
        #expect(item.hosts == [CefExtension.Host(pattern: "http://127.0.0.1/*", isGranted: true)])
        #expect(item.siteAccess == .onAllSites)
        #expect(!item.isAllowedInIncognito)
        #expect(item.commands == [CefExtension.Command(name: "_execute_action", description: "Activate the extension", shortcut: "⌃⇧Y", isAction: true)])
        #expect(item.action?.title == "CefSwift Test")
        #expect(item.action?.popupURL?.absoluteString == "chrome-extension://hijdjdmlodkldbmopflekahgjddfeagl/popup.html")
        #expect(item.replacedPages == [.newTab: URL(string: "chrome-extension://hijdjdmlodkldbmopflekahgjddfeagl/newtab.html")!])
    }

    @Test func decodesStatesAndSources() {
        #expect(CefExtension.state("DISABLED") == .disabled)
        #expect(CefExtension.state("TERMINATED") == .terminated)
        #expect(CefExtension.state("BLOCKLISTED") == .blocklisted)
        #expect(CefExtension.state("SOMETHING_NEW") == .disabled)
        #expect(CefExtension.installSource("FROM_STORE") == .webStore)
        #expect(CefExtension.installSource("THIRD_PARTY") == .external)
        #expect(CefExtension.installSource("INSTALLED_BY_DEFAULT") == .installedByDefault)
        #expect(CefExtension.installSource(nil) == .other)
        #expect(CefExtension.siteAccess("ON_CLICK") == .onClick)
        #expect(CefExtension.siteAccess(nil) == nil)
        for access in [CefExtension.SiteAccess.onClick, .onSpecificSites, .onAllSites] {
            #expect(CefExtension.siteAccess(access.developerValue) == access)
        }
    }

    @Test func policyExtensionsAreManaged() throws {
        var json = try JSONSerialization.jsonObject(with: Data(Self.info.utf8)) as! [String: Any]
        json["controlledInfo"] = ["text": "Installed by your administrator"]
        json["location"] = "THIRD_PARTY"
        json["userMayModify"] = false
        let info = try JSONDecoder().decode(DeveloperExtensionInfo.self, from: JSONSerialization.data(withJSONObject: json))
        let item = CefExtension(info, manifest: nil)
        #expect(item.installSource == .policy)
        #expect(!item.isUserModifiable)
        // Without a manifest the action is known from its command only.
        #expect(item.action?.title == "CefSwift Test Extension" && item.action?.popupURL == nil)
    }

    @Test func minimalInfoDecodes() throws {
        let info = try JSONDecoder().decode(DeveloperExtensionInfo.self, from: Data(#"{"id": "a", "name": "b"}"#.utf8))
        let item = CefExtension(info, manifest: nil)
        #expect(item.state == .disabled && item.action == nil && item.iconData == nil && item.directory == nil)
    }

    @Test func dataURLs() {
        #expect(CefExtension.dataURLContents("data:image/png;base64,AAEC") == Data([0, 1, 2]))
        #expect(CefExtension.dataURLContents("data:image/png,AAEC") == nil)
        #expect(CefExtension.dataURLContents("chrome://extension-icon/x/128/0") == nil)
    }

    @Test func manifestIconSets() throws {
        let single = try JSONDecoder().decode(ExtensionManifest.IconSet.self, from: Data(#""icon.png""#.utf8))
        #expect(single.largest == "icon.png")
        let sizes = try JSONDecoder().decode(ExtensionManifest.IconSet.self, from: Data(#"{"16": "s.png", "128": "l.png", "48": "m.png"}"#.utf8))
        #expect(sizes.largest == "l.png")
    }

    @Test func actionIconComesFromTheDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cefswift-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("b.png"))
        try Data(Self.manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        var json = try JSONSerialization.jsonObject(with: Data(Self.info.utf8)) as! [String: Any]
        json["path"] = directory.path
        let info = try JSONDecoder().decode(DeveloperExtensionInfo.self, from: JSONSerialization.data(withJSONObject: json))
        let item = CefExtension(info, manifest: ExtensionManifest.read(in: directory))
        #expect(item.action?.iconData == Data([1, 2, 3]))
    }

    @Test func extensionSurfaceKinds() {
        #expect(CefChromiumSurface.Kind.extensionPopup.hangsFromToolbar)
        #expect(CefChromiumSurface.Kind.extensionsMenu.capabilities.contains(.dismiss))
        #expect(!CefChromiumSurface.Kind.extensionInstallPrompt.capabilities.contains(.hide))
    }
}
