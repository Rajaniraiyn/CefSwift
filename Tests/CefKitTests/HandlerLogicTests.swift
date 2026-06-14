import CCef
import Foundation
import Testing

@testable import CefKit

/// Pure-logic tests for the handler value-type mappings added for the
/// Electron-class customization surface. None require `cef_initialize`.
struct HandlerLogicTests {

    // MARK: JS dialog mapping

    @Test func jsDialogValueType() {
        let dialog = CefJSDialog(kind: .prompt, message: "Name?", defaultPromptText: "Ada", origin: "https://x")
        #expect(dialog.kind == .prompt)
        #expect(dialog.message == "Name?")
        #expect(dialog.defaultPromptText == "Ada")
        #expect(dialog.origin == "https://x")
    }

    // MARK: Navigation decision mapping

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
        let kinds = CefPermissionKind.fromRequestTypes(cameraMic)
        #expect(kinds.contains(.camera))
        #expect(kinds.contains(.microphone))
        #expect(!kinds.contains(.geolocation))

        let geo = CefPermissionKind.fromRequestTypes(UInt32(CEF_PERMISSION_TYPE_GEOLOCATION.rawValue))
        #expect(geo.contains(.geolocation))

        // An unmapped type surfaces as .other rather than vanishing.
        let unmapped = CefPermissionKind.fromRequestTypes(UInt32(CEF_PERMISSION_TYPE_VR_SESSION.rawValue))
        #expect(unmapped.contains(.other))
    }

    @Test func mediaPermissionMapping() {
        let audioVideo = UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue)
            | UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue)
        let kinds = CefPermissionKind.fromMediaTypes(audioVideo)
        #expect(kinds.contains(.microphone))
        #expect(kinds.contains(.camera))

        // Re-encoding allowed kinds stays a subset of the requested mask.
        let mask = kinds.mediaMask(within: audioVideo)
        #expect(mask & ~audioVideo == 0)
        #expect(mask & UInt32(CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE.rawValue) != 0)
        #expect(mask & UInt32(CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE.rawValue) != 0)
    }

    @Test func menuModelUserCommandRange() {
        // Mirrors MENU_ID_USER_FIRST/LAST from cef_types.h.
        #expect(CefMenuModel.userCommandIDFirst == 26500)
        #expect(CefMenuModel.userCommandIDLast == 28500)
        #expect(CefMenuModel.userCommandIDFirst < CefMenuModel.userCommandIDLast)
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
        #expect(event.hasCommand)
        #expect(event.hasShift)
        #expect(!event.hasControl)
        #expect(event.windowsKeyCode == 65)
        #expect(event.character == "a")
        #expect(event.isEditableFieldFocused)
    }
}

/// Profile path-derivation tests (pure, no runtime).
@MainActor
struct ProfilePathTests {
    let root = URL(fileURLWithPath: "/tmp/cefroot")

    @Test func defaultProfileHasNoCachePath() {
        #expect(CefProfile.cachePath(for: .global, rootCachePath: root) == nil)
    }

    @Test func incognitoProfileHasNoCachePath() {
        // Empty cache_path is what puts a context in in-memory/incognito mode.
        #expect(CefProfile.cachePath(for: .incognito, rootCachePath: root) == nil)
    }

    @Test func persistentProfileDerivesUnderProfiles() {
        let path = CefProfile.cachePath(for: .persistent(name: "Work"), rootCachePath: root)
        #expect(path?.path == "/tmp/cefroot/Profiles/Work")
    }

    @Test func persistentProfileSanitizesName() {
        // Path separators and leading dots can't escape the Profiles dir.
        let path = CefProfile.cachePath(for: .persistent(name: "../../etc"), rootCachePath: root)
        #expect(path != nil)
        #expect(!(path!.path.contains("/etc")))
        #expect(path!.path.hasPrefix("/tmp/cefroot/Profiles/"))

        #expect(CefProfile.sanitize("a/b") == "a_b")
        #expect(CefProfile.sanitize("...") == "Profile")
        #expect(CefProfile.sanitize("") == "Profile")
    }

    @Test func persistentProfileWithNilRootYieldsNil() {
        #expect(CefProfile.cachePath(for: .persistent(name: "Work"), rootCachePath: nil) == nil)
    }
}
