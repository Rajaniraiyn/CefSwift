import CCef
import CefBase
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
        #expect(CefProfile.storage(for: .global, rootCacheDirectory: root) == .init(chromiumDirectory: nil))
        // Empty cache_path is what puts a context in in-memory/incognito mode.
        #expect(CefProfile.storage(for: .incognito, rootCacheDirectory: root) == .init(chromiumDirectory: nil))
    }

    @Test func persistentProfileIsADirectChildOfTheRoot() {
        #expect(directory("work") == "/tmp/cefroot/Profile-work")
        #expect(directory("Work") == "/tmp/cefroot/Profile-%57ork")
        // Chromium makes profiles only directly inside root_cache_path, and
        // gives any other cache_path an in-memory profile.
        for id in ["work", "a/b", "../../etc", ".", "..", String(repeating: "x", count: 400)] {
            let path = URL(fileURLWithPath: directory(id) ?? "")
            #expect(path.deletingLastPathComponent().path == root.path, "\(id)")
        }
    }

    @Test func profileDirectoriesNeverTakeChromiumsNames() {
        // What Chromium keeps in root_cache_path itself, and its own
        // profile directory names.
        let chromiums = [
            "Default", "Local State", "Guest Profile", "System Profile", "Profile 1", "Profile 2",
            "Safe Browsing", "Dictionaries", "Variations", "component_crx_cache", "BrowserMetrics",
            "GrShaderCache", "GraphiteDawnCache", "SingletonLock", "WidevineCdm", "Crashpad",
        ]
        let ids = ["default ", "Default", "Local State", "Guest Profile", "System Profile", " 1", "1", "", "a"]
            .filter { !$0.isEmpty }
        for id in ids {
            let name = CefProfile.directoryName(for: id)
            #expect(!chromiums.contains { $0.lowercased() == name.lowercased() }, "\(id) → \(name)")
            #expect(name.hasPrefix("Profile-"))
        }
    }

    @Test func distinctIdentifiersNeverShareADirectory() {
        let ids = ["a/b", "a_b", "a%2Fb", "a%252Fb", "Work", "work", "WORK", "..", ".", "...", "a:b", "a\\b", "é", "e\u{301}"]
        let names = ids.map(CefProfile.directoryName(for:))
        // Injective, also when the volume ignores case.
        #expect(Set(names.map { $0.lowercased() }).count == ids.count)
        for name in names {
            #expect(!name.contains("/") && !name.contains(":") && name != "." && name != ".." && !name.hasPrefix("."))
        }
    }

    @Test func pathsCannotEscapeTheRoot() {
        let path = directory("../../etc")
        #expect(path == "/tmp/cefroot/Profile-%2E%2E%2F%2E%2E%2Fetc")
    }

    @Test func longIdentifiersStayWithinNameLimits() {
        let long = String(repeating: "Ä", count: 300)
        let other = String(repeating: "Ä", count: 299) + "Ö"
        #expect(CefProfile.directoryName(for: long).utf8.count <= 255)
        #expect(CefProfile.directoryName(for: long) != CefProfile.directoryName(for: other))
        #expect(CefProfile.directoryName(for: long) == CefProfile.directoryName(for: long))
    }

    @Test func profilesLiveInTheRootCacheDirectory() {
        var configuration = CefRuntime.Configuration()
        configuration.rootCacheDirectory = URL(fileURLWithPath: "/tmp/app/Data")
        let storage = CefProfile.storage(for: .persistent(id: "work"), rootCacheDirectory: configuration.resolvedRootCacheDirectory)
        #expect(storage.chromiumDirectory?.path == "/tmp/app/Data/Profile-work")
        // The default profile is Chromium's Default, with cache_path equal
        // to root_cache_path.
        let mapped = MappedCefSettings(configuration: configuration, frameworkDirectory: nil)
        #expect(CefStringUtil.string(from: &mapped.raw.cache_path) == "/tmp/app/Data")
        #expect(CefStringUtil.string(from: &mapped.raw.root_cache_path) == "/tmp/app/Data")
    }

    /// Chromium takes its user data directory with symbolic links
    /// resolved, and a profile path through a link is not inside it.
    @Test func profileDirectoriesResolveLinksInTheRoot() {
        let resolved = CefProfile.resolvingLinks(URL(fileURLWithPath: "/tmp", isDirectory: true))
        #expect(resolved.path == "/private/tmp")
        let missing = URL(fileURLWithPath: "/tmp/cefswift-no-such-directory-\(UUID().uuidString)")
        #expect(CefProfile.resolvingLinks(missing) == missing)
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
        #expect(CefProfile.incognito().isIncognito)
        #expect(!profile.isIncognito && !CefProfile.default.isIncognito)
    }
}
