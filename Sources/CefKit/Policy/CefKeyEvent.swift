import AppKit
import CCef
import Foundation

/// The modifier keys and mouse buttons held during an input event, mirroring
/// `cef_event_flags_t`.
public struct CefEventModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let capsLock = Self(rawValue: UInt32(EVENTFLAG_CAPS_LOCK_ON.rawValue))
    public static let shift = Self(rawValue: UInt32(EVENTFLAG_SHIFT_DOWN.rawValue))
    public static let control = Self(rawValue: UInt32(EVENTFLAG_CONTROL_DOWN.rawValue))
    public static let option = Self(rawValue: UInt32(EVENTFLAG_ALT_DOWN.rawValue))
    public static let command = Self(rawValue: UInt32(EVENTFLAG_COMMAND_DOWN.rawValue))
    public static let leftMouseButton = Self(rawValue: UInt32(EVENTFLAG_LEFT_MOUSE_BUTTON.rawValue))
    public static let middleMouseButton = Self(rawValue: UInt32(EVENTFLAG_MIDDLE_MOUSE_BUTTON.rawValue))
    public static let rightMouseButton = Self(rawValue: UInt32(EVENTFLAG_RIGHT_MOUSE_BUTTON.rawValue))
    public static let numLock = Self(rawValue: UInt32(EVENTFLAG_NUM_LOCK_ON.rawValue))
    /// The key is on the numeric keypad.
    public static let numericPad = Self(rawValue: UInt32(EVENTFLAG_IS_KEY_PAD.rawValue))

    /// The modifiers equivalent to AppKit's modifier flags.
    public init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.capsLock) { insert(.capsLock) }
    }

    /// The mouse-button modifiers for an `NSEvent.pressedMouseButtons` mask.
    public init(pressedMouseButtons: Int) {
        self = []
        if pressedMouseButtons & (1 << 0) != 0 { insert(.leftMouseButton) }
        if pressedMouseButtons & (1 << 1) != 0 { insert(.rightMouseButton) }
        if pressedMouseButtons & (1 << 2) != 0 { insert(.middleMouseButton) }
    }
}

/// A key event: delivered to
/// ``CefBrowserDelegate/browser(_:handleKeyEvent:isBeforePage:)``, or sent to
/// an offscreen browser with ``CefBrowser/sendKeyEvent(_:)``.
public struct CefKeyEvent: Sendable, Equatable {
    /// The kind of key event.
    public enum Phase: Sendable, Equatable {
        /// A key press, before any character it produces.
        case rawKeyDown
        /// A key press, followed by a ``character`` event when it produces one.
        case keyDown
        /// A key release.
        case keyUp
        /// The character a key press produces.
        case character

        init(cefValue: cef_key_event_type_t) {
            switch cefValue {
            case KEYEVENT_KEYDOWN: self = .keyDown
            case KEYEVENT_KEYUP: self = .keyUp
            case KEYEVENT_CHAR: self = .character
            default: self = .rawKeyDown
            }
        }

        var cefValue: cef_key_event_type_t {
            switch self {
            case .rawKeyDown: KEYEVENT_RAWKEYDOWN
            case .keyDown: KEYEVENT_KEYDOWN
            case .keyUp: KEYEVENT_KEYUP
            case .character: KEYEVENT_CHAR
            }
        }
    }

    /// The kind of key event.
    public var phase: Phase
    /// The modifier keys held.
    public var modifiers: CefEventModifiers
    /// The Windows virtual key code, which the DOM reports as `keyCode`.
    public var windowsKeyCode: Int
    /// The macOS key code.
    public var nativeKeyCode: Int
    /// The character the key produces, if any.
    public var character: Character?
    /// The character the key produces without modifiers, if any.
    public var unmodifiedCharacter: Character?
    /// Whether this is a system key event.
    public var isSystemKey: Bool
    /// Whether an editable field has focus. Reported by Chromium; ignored
    /// when sending.
    public var isEditableFieldFocused: Bool

    public init(
        phase: Phase,
        modifiers: CefEventModifiers = [],
        windowsKeyCode: Int = 0,
        nativeKeyCode: Int = 0,
        character: Character? = nil,
        unmodifiedCharacter: Character? = nil,
        isSystemKey: Bool = false,
        isEditableFieldFocused: Bool = false
    ) {
        self.phase = phase
        self.modifiers = modifiers
        self.windowsKeyCode = windowsKeyCode
        self.nativeKeyCode = nativeKeyCode
        self.character = character
        self.unmodifiedCharacter = unmodifiedCharacter
        self.isSystemKey = isSystemKey
        self.isEditableFieldFocused = isEditableFieldFocused
    }

    init(raw event: cef_key_event_t) {
        func character(_ unit: UInt16) -> Character? {
            unit != 0 ? Unicode.Scalar(UInt32(unit)).map(Character.init) : nil
        }
        self.init(
            phase: Phase(cefValue: event.type),
            modifiers: CefEventModifiers(rawValue: event.modifiers),
            windowsKeyCode: Int(event.windows_key_code),
            nativeKeyCode: Int(event.native_key_code),
            character: character(event.character),
            unmodifiedCharacter: character(event.unmodified_character),
            isSystemKey: event.is_system_key != 0,
            isEditableFieldFocused: event.focus_on_editable_field != 0
        )
    }

    /// The `cef_key_event_t` for sending this event. Characters are sent as
    /// their first UTF-16 code unit, as Chromium expects.
    var cefValue: cef_key_event_t {
        var event = cef_key_event_t()
        event.size = MemoryLayout<cef_key_event_t>.stride
        event.type = phase.cefValue
        event.modifiers = modifiers.rawValue
        event.windows_key_code = Int32(truncatingIfNeeded: windowsKeyCode)
        event.native_key_code = Int32(truncatingIfNeeded: nativeKeyCode)
        event.is_system_key = isSystemKey ? 1 : 0
        event.character = character?.utf16.first ?? 0
        event.unmodified_character = unmodifiedCharacter?.utf16.first ?? 0
        event.focus_on_editable_field = isEditableFieldFocused ? 1 : 0
        return event
    }
}
