import CCef
import Foundation
import Testing

@testable import CefKit

/// Mappings from CEF values to the types delegates receive.
struct HandlerLogicTests {

    // MARK: JS dialog mapping

    @Test func jsDialogValueType() {
        let dialog = CefJavaScriptDialog(kind: .prompt, message: "Name?", defaultPromptText: "Ada", origin: "https://x")
        #expect(dialog.kind == .prompt)
        #expect(dialog.message == "Name?")
        #expect(dialog.defaultPromptText == "Ada")
        #expect(dialog.origin == "https://x")
    }

    // MARK: Termination reason mapping

    @Test func terminationReasonMapping() {
        #expect(CefTerminationReason(cefValue: TS_PROCESS_WAS_KILLED) == .killed)
        #expect(CefTerminationReason(cefValue: TS_PROCESS_CRASHED) == .crashed)
        #expect(CefTerminationReason(cefValue: TS_PROCESS_OOM) == .outOfMemory)
        #expect(CefTerminationReason(cefValue: TS_LAUNCH_FAILED) == .launchFailed)
        #expect(CefTerminationReason(cefValue: TS_ABNORMAL_TERMINATION) == .abnormal)
    }

    // MARK: Permission mapping

    @Test func permissionRequestTypeMapping() {
        let cameraMic = UInt32(CEF_PERMISSION_TYPE_CAMERA_STREAM.rawValue)
            | UInt32(CEF_PERMISSION_TYPE_MIC_STREAM.rawValue)
        let kinds = CefPermissionRequest.Kinds.fromRequestTypes(cameraMic)
        #expect(kinds.contains(.camera))
        #expect(kinds.contains(.microphone))
        #expect(!kinds.contains(.geolocation))

        let geo = CefPermissionRequest.Kinds.fromRequestTypes(UInt32(CEF_PERMISSION_TYPE_GEOLOCATION.rawValue))
        #expect(geo.contains(.geolocation))

        // An unmapped type surfaces as .other rather than vanishing.
        let unmapped = CefPermissionRequest.Kinds.fromRequestTypes(UInt32(CEF_PERMISSION_TYPE_VR_SESSION.rawValue))
        #expect(unmapped.contains(.other))
    }

    @Test func mediaPermissionMapping() {
        let audioVideo = UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue)
            | UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue)
        let kinds = CefPermissionRequest.Kinds.fromMediaTypes(audioVideo)
        #expect(kinds.contains(.microphone))
        #expect(kinds.contains(.camera))

        // Re-encoding allowed kinds stays a subset of the requested mask.
        let mask = kinds.mediaMask(within: audioVideo)
        #expect(mask & ~audioVideo == 0)
        #expect(mask & UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue) != 0)
        #expect(mask & UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue) != 0)
    }

    @Test func menuModelUserCommandRange() {
        #expect(CefMenuModel.userCommandIDs == 26500...28500)
    }

    // MARK: Key event mapping

    @Test func keyEventMapping() {
        var raw = cef_key_event_t()
        raw.type = KEYEVENT_KEYDOWN
        raw.modifiers = UInt32(EVENTFLAG_COMMAND_DOWN.rawValue) | UInt32(EVENTFLAG_SHIFT_DOWN.rawValue)
        raw.windows_key_code = 65  // 'A'
        raw.character = UInt16("a".utf16.first!)
        raw.focus_on_editable_field = 1
        let event = CefKeyEvent(raw: raw)
        #expect(event.phase == .keyDown)
        #expect(event.modifiers.contains(.command))
        #expect(event.modifiers.contains(.shift))
        #expect(!event.modifiers.contains(.control))
        #expect(event.windowsKeyCode == 65)
        #expect(event.character == "a")
        #expect(event.isEditableFieldFocused)
    }
}

/// Profile identity and storage layout (pure, no runtime).
@MainActor
struct ProfilePathTests {
    let root = URL(fileURLWithPath: "/tmp/cefroot")

    private func directory(_ id: String) -> String? {
        CefProfile.storage(for: .persistent(id: id), rootCacheDirectory: root).chromiumDirectory?.path
    }

    @Test func defaultAndIncognitoProfilesHaveNoDirectoryOfTheirOwn() {
        #expect(CefProfile.storage(for: .global, rootCacheDirectory: root) == .init(chromiumDirectory: nil, webKitStore: .default))
        // Empty cache_path is what puts a context in in-memory/incognito mode.
        #expect(CefProfile.storage(for: .incognito, rootCacheDirectory: root)
            == .init(chromiumDirectory: nil, webKitStore: .nonPersistent))
    }

    @Test func persistentProfileDerivesUnderProfiles() {
        #expect(directory("work") == "/tmp/cefroot/Profiles/work")
        #expect(directory("Work") == "/tmp/cefroot/Profiles/%57ork")
    }

    @Test func distinctIdentifiersNeverShareADirectory() {
        let ids = ["a/b", "a_b", "a%2Fb", "a%252Fb", "Work", "work", "WORK", "..", ".", "...", "a:b", "a\\b", "é", "e\u{301}"]
        let names = ids.map(CefProfile.directoryName(for:))
        // Injective, also when the volume ignores case.
        #expect(Set(names.map { $0.lowercased() }).count == ids.count)
        for name in names {
            #expect(!name.contains("/") && !name.contains(":") && name != "." && name != ".." && !name.hasPrefix("."))
        }
        // Each maps to its own WebKit store too.
        #expect(Set(ids.map(CefProfile.dataStoreIdentifier)).count == ids.count)
    }

    @Test func pathsCannotEscapeTheProfilesDirectory() {
        let path = directory("../../etc")
        #expect(path?.hasPrefix("/tmp/cefroot/Profiles/") == true)
        #expect(path.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } == "/tmp/cefroot/Profiles")
    }

    @Test func longIdentifiersStayWithinNameLimits() {
        let long = String(repeating: "Ä", count: 300)
        let other = String(repeating: "Ä", count: 299) + "Ö"
        #expect(CefProfile.directoryName(for: long).utf8.count <= 255)
        #expect(CefProfile.directoryName(for: long) != CefProfile.directoryName(for: other))
        #expect(CefProfile.directoryName(for: long) == CefProfile.directoryName(for: long))
    }

    @Test func bothEnginesUseTheRootDerivedFromAnExplicitCacheDirectory() {
        var configuration = CefRuntime.Configuration()
        configuration.cacheDirectory = URL(fileURLWithPath: "/tmp/app/Data/Default")
        #expect(configuration.resolvedRootCacheDirectory.path == "/tmp/app/Data")
        let storage = CefProfile.storage(for: .persistent(id: "work"), rootCacheDirectory: configuration.resolvedRootCacheDirectory)
        #expect(storage.chromiumDirectory?.path == "/tmp/app/Data/Profiles/work")
        #expect(storage.webKitStore == .persistent(CefProfile.dataStoreIdentifier("work")))
        configuration.rootCacheDirectory = URL(fileURLWithPath: "/tmp/root")
        #expect(configuration.resolvedRootCacheDirectory.path == "/tmp/root")
    }

    @Test func identifiersAndDisplayNamesAreSeparate() {
        let profile = CefProfile.persistent(id: "ProfilePathTests-identity", displayName: "Work")
        #expect(profile.id == "ProfilePathTests-identity" && profile.displayName == "Work")
        #expect(CefProfile.persistent(id: "ProfilePathTests-identity") === profile)
        #expect(profile.displayName == "Work")
        profile.displayName = "Office"
        #expect(CefProfile.persistent(id: "ProfilePathTests-identity").displayName == "Office")
        #expect(CefProfile.persistent(id: "ProfilePathTests-identity/") !== profile)
        #expect(CefProfile.persistent(id: "default") === CefProfile.default)
        #expect(CefProfile.incognito().id != CefProfile.incognito().id)
    }

    @Test func aServiceKeepsItsProfileAliveWithoutACycle() {
        weak var weakProfile: CefProfile?
        var autocomplete: CefAutocomplete?
        var history: CefHistory?
        do {
            let profile = CefProfile.incognito()
            weakProfile = profile
            autocomplete = profile.autocomplete
            history = profile.history
            #expect(profile.autocomplete === autocomplete)
        }
        #expect(weakProfile != nil)
        autocomplete = nil
        #expect(weakProfile != nil)
        history = nil
        #expect(weakProfile == nil)
        _ = (autocomplete, history)
    }
}
