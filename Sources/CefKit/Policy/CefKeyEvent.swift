import CCef
import Foundation

/// A key event delivered to
/// ``CefBrowserDelegate/browser(_:handleKeyEvent:isBeforePage:)``.
public struct CefKeyEvent: Sendable, Equatable {
    /// The kind of key event.
    public enum Phase: Sendable, Equatable {
        case rawKeyDown, keyDown, keyUp, character

        init(cefValue: cef_key_event_type_t) {
            switch cefValue {
            case KEYEVENT_KEYDOWN: self = .keyDown
            case KEYEVENT_KEYUP: self = .keyUp
            case KEYEVENT_CHAR: self = .character
            default: self = .rawKeyDown
            }
        }
    }

    /// The kind of key event.
    public var phase: Phase
    /// The `cef_event_flags_t` modifier mask.
    public var modifiers: UInt32
    /// The Windows virtual key code, which the DOM reports as `keyCode`.
    public var windowsKeyCode: Int
    /// The macOS key code.
    public var nativeKeyCode: Int
    /// The character the key produces, if any.
    public var character: Character?
    /// Whether an editable field has focus.
    public var isEditableFieldFocused: Bool

    public init(
        phase: Phase,
        modifiers: UInt32,
        windowsKeyCode: Int,
        nativeKeyCode: Int,
        character: Character?,
        isEditableFieldFocused: Bool
    ) {
        self.phase = phase
        self.modifiers = modifiers
        self.windowsKeyCode = windowsKeyCode
        self.nativeKeyCode = nativeKeyCode
        self.character = character
        self.isEditableFieldFocused = isEditableFieldFocused
    }

    /// Whether the Command (⌘) modifier is held.
    public var hasCommand: Bool { modifiers & UInt32(EVENTFLAG_COMMAND_DOWN.rawValue) != 0 }
    /// Whether the Shift modifier is held.
    public var hasShift: Bool { modifiers & UInt32(EVENTFLAG_SHIFT_DOWN.rawValue) != 0 }
    /// Whether the Control modifier is held.
    public var hasControl: Bool { modifiers & UInt32(EVENTFLAG_CONTROL_DOWN.rawValue) != 0 }
    /// Whether the Option/Alt modifier is held.
    public var hasOption: Bool { modifiers & UInt32(EVENTFLAG_ALT_DOWN.rawValue) != 0 }

    init(raw event: cef_key_event_t) {
        let scalarValue = UInt32(event.character)
        let char = scalarValue != 0 ? Unicode.Scalar(scalarValue).map(Character.init) : nil
        self.init(
            phase: Phase(cefValue: event.type),
            modifiers: event.modifiers,
            windowsKeyCode: Int(event.windows_key_code),
            nativeKeyCode: Int(event.native_key_code),
            character: char,
            isEditableFieldFocused: event.focus_on_editable_field != 0
        )
    }
}
