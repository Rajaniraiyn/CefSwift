import CCef
import Foundation
import Testing

@testable import CefKit

/// Site permissions, stored answers and typed preference keys, without
/// Chromium.
struct SiteSettingsTests {
    @Test func everyPermissionHasItsOwnContentType() {
        let types = CefSitePermission.allCases.map(\.contentType.rawValue)
        #expect(Set(types).count == types.count)
        for permission in CefSitePermission.allCases {
            #expect(CefSitePermission(contentType: permission.contentType) == permission)
            #expect(!permission.supportedSettings.contains(.default))
        }
        #expect(CefSitePermission(contentType: CEF_CONTENT_SETTING_TYPE_SITE_ENGAGEMENT) == nil)
    }

    @Test func settingsMapToChromiumValues() {
        for setting in CefSitePermission.Setting.allCases {
            #expect(CefSitePermission.Setting(cefValue: setting.cefValue) == setting)
        }
        #expect(CefSitePermission.Setting(storedValue: 1) == .allow)
        #expect(CefSitePermission.Setting(storedValue: 2) == .block)
        #expect(CefSitePermission.Setting(storedValue: 3) == .ask)
        #expect(CefSitePermission.Setting(storedValue: -1) == nil)
    }

    @Test func storedExceptionsParse() {
        let stored: CefJSON = .object([
            "https://meet.example:443,*": .object(["setting": .number(1), "last_modified": .string("1")]),
            "http://intranet.local:8080,*": .object(["setting": .number(2)]),
            "[*.]ads.example,*": .object(["setting": .number(2)]),
            "https://broken.example:443,*": .object(["no_setting": .number(1)]),
        ])
        let exceptions = CefSiteSettings.exceptions(of: .camera, stored: stored)
        #expect(exceptions.count == 3)
        let meet = exceptions.first { $0.pattern == "https://meet.example:443" }
        #expect(meet?.origin == URL(string: "https://meet.example"))
        #expect(meet?.setting == .allow)
        #expect(exceptions.first { $0.pattern.contains("intranet") }?.origin == URL(string: "http://intranet.local:8080"))
        #expect(exceptions.first { $0.pattern.contains("ads") }?.origin == nil)
        #expect(CefSiteSettings.exceptions(of: .camera, stored: .null).isEmpty)
    }

    @Test func patternsMatchOrigins() {
        let site = URL(string: "https://www.shop.example/cart")!
        #expect(CefSiteSettings.pattern("https://www.shop.example:443", matches: site))
        #expect(CefSiteSettings.pattern("https://[*.]shop.example:443", matches: site))
        #expect(CefSiteSettings.pattern("[*.]shop.example", matches: site))
        #expect(CefSiteSettings.pattern("*", matches: site))
        #expect(!CefSiteSettings.pattern("http://www.shop.example:80", matches: site))
        #expect(!CefSiteSettings.pattern("https://www.shop.example:8443", matches: site))
        #expect(!CefSiteSettings.pattern("https://[*.]other.example:443", matches: site))
        #expect(CefSiteSettings.pattern("http://localhost:8000", matches: URL(string: "http://localhost:8000/")!))
    }

    @Test func originsDropPathsAndKeepPorts() {
        #expect(CefSiteSettings.origin(of: URL(string: "https://a.example/path?q")!) == "https://a.example")
        #expect(CefSiteSettings.origin(of: URL(string: "http://localhost:8000/x")!) == "http://localhost:8000")
    }

    @Test func storedAnswersSortKindsBySetting() {
        let settings: [CefSitePermission: CefSitePermission.Setting] = [.camera: .allow, .microphone: .block]
        let answer = CefStoredPermissionAnswer(kinds: [.camera, .microphone, .geolocation, .other]) {
            settings[$0] ?? .ask
        }
        #expect(answer.allowed == .camera)
        #expect(answer.blocked == .microphone)
        #expect(answer.undecided == [.geolocation, .other])
        #expect(answer.granted(after: nil) == .camera)
        #expect(answer.granted(after: .deny) == .camera)
        #expect(answer.granted(after: .alwaysAllow) == [.camera, .geolocation, .other])
    }

    @Test func aStoredBlockAnswersWithoutAsking() {
        let answer = CefStoredPermissionAnswer(kinds: [.camera, .microphone]) { _ in .block }
        #expect(answer.undecided.isEmpty)
        #expect(answer.granted(after: nil).isEmpty)
        #expect(CefPermissionRequest.Kinds.camera.mediaMask(within: UInt32.max) != 0)
    }

    // MARK: Desktop capture is its own permission

    private static let deviceAudio = UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue)
    private static let deviceVideo = UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue)
    private static let desktopAudio = UInt32(CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE.rawValue)
    private static let desktopVideo = UInt32(CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE.rawValue)

    @Test func desktopCaptureMapsToItsOwnKinds() {
        typealias Kinds = CefPermissionRequest.Kinds
        #expect(Kinds.fromMediaTypes(Self.desktopVideo) == .screenCapture)
        #expect(Kinds.fromMediaTypes(Self.desktopAudio) == .systemAudioCapture)
        #expect(Kinds.fromMediaTypes(Self.desktopVideo | Self.desktopAudio) == [.screenCapture, .systemAudioCapture])
        #expect(Kinds.fromMediaTypes(Self.deviceVideo | Self.deviceAudio) == [.camera, .microphone])
        #expect(Kinds.fromRequestTypes(UInt32(CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM.rawValue)) == .cameraPanTiltZoom)
    }

    @Test func aDeviceGrantNeverGrantsDesktopCapture() {
        let everything = Self.deviceAudio | Self.deviceVideo | Self.desktopAudio | Self.desktopVideo
        #expect(CefPermissionRequest.Kinds([.camera, .microphone]).mediaMask(within: everything)
            == Self.deviceAudio | Self.deviceVideo)
        #expect(CefPermissionRequest.Kinds.camera.mediaMask(within: Self.desktopVideo) == 0)
        #expect(CefPermissionRequest.Kinds.microphone.mediaMask(within: Self.desktopAudio) == 0)
        #expect(CefPermissionRequest.Kinds.screenCapture.mediaMask(within: everything) == Self.desktopVideo)
        #expect(CefPermissionRequest.Kinds.systemAudioCapture.mediaMask(within: everything) == Self.desktopAudio)
        // Limited to what was asked for.
        #expect(CefPermissionRequest.Kinds.screenCapture.mediaMask(within: Self.deviceVideo) == 0)
    }

    @Test func storedCameraAndMicrophoneDoNotAnswerDesktopCapture() {
        let request = CefPermissionRequest.Kinds.fromMediaTypes(Self.desktopVideo | Self.desktopAudio)
        let answer = CefStoredPermissionAnswer(kinds: request) { _ in .allow }
        #expect(answer.allowed.isEmpty)
        #expect(answer.undecided == [.screenCapture, .systemAudioCapture])
        #expect(answer.granted(after: nil).mediaMask(within: Self.desktopVideo | Self.desktopAudio) == 0)
        // A stored block on the camera does not refuse it either: the
        // delegate decides.
        #expect(CefStoredPermissionAnswer(kinds: request) { _ in .block }.blocked.isEmpty)
    }

    @Test func desktopCaptureIsNeverStored() {
        #expect(CefPermissionRequest.Kinds([.screenCapture, .systemAudioCapture]).sitePermissions.isEmpty)
        #expect(CefPermissionRequest.Kinds([.camera, .screenCapture]).sitePermissions == [.camera])
        #expect(CefPermissionRequest.Kinds.cameraPanTiltZoom.sitePermissions == [.cameraPanTiltZoom])
        #expect(CefPermissionRequest.Kinds.camera.sitePermissions == [.camera])
    }

    @Test func decisionsThatGrant() {
        #expect(CefPermissionDecision.allow.grants && CefPermissionDecision.alwaysAllow.grants)
        #expect(!CefPermissionDecision.deny.grants && !CefPermissionDecision.alwaysDeny.grants)
        #expect(CefPermissionDecision.alwaysDeny.cefResult == CEF_PERMISSION_RESULT_DENY)
        #expect(CefPermissionDecision.alwaysAllow.cefResult == CEF_PERMISSION_RESULT_ACCEPT)
    }

    @Test func permissionKindsMapToSitePermissions() {
        #expect(CefPermissionRequest.Kinds([.camera, .notifications]).sitePermissions == [.camera, .notifications])
        #expect(CefPermissionRequest.Kinds.other.sitePermissions.isEmpty)
    }

    @Test func preferenceKeysConvert() {
        let languages = CefPreferences.Key<[String]>.acceptLanguages
        #expect(languages.decode(.string("en-US, de,fr")) == ["en-US", "de", "fr"])
        #expect(languages.encode(["en", "de"]) == .string("en,de"))
        #expect(CefPreferences.Key<Int>.defaultFontSize.decode(.number(16)) == 16)
        #expect(CefPreferences.Key<Bool>.savesPasswords.decode(.number(1)) == nil)
        #expect(CefPreferences.Key<URL>.downloadDirectory.decode(.string("")) == nil)
        #expect(CefPreferences.Key<URL>.downloadDirectory.decode(.string("/tmp/x"))?.path == "/tmp/x")
        #expect(CefPreferences.Key<CefPreferences.ThirdPartyCookies>.thirdPartyCookies.decode(.number(2)) == .block)
    }

    @Test func dottedNamesLookUpNestedMembers() {
        let all: CefJSON = .object(["browser": .object(["show_home_button": .bool(true)])])
        #expect(CefPreferences.lookUp("browser.show_home_button", in: all) == .bool(true))
        #expect(CefPreferences.lookUp("browser.missing", in: all) == nil)
    }
}
