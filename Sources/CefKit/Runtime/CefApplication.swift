import AppKit

// Chromium requires the application object to adopt these Objective-C
// protocols, which it looks up by name. They mirror CEF's
// include/cef_application_mac.h.

@MainActor
@objc(CrAppProtocol)
protocol CrAppProtocol {
    /// Whether the application is inside `-[NSApplication sendEvent:]`.
    func isHandlingSendEvent() -> Bool
}

@MainActor
@objc(CrAppControlProtocol)
protocol CrAppControlProtocol: CrAppProtocol {
    func setHandlingSendEvent(_ handlingSendEvent: Bool)
}

@MainActor
@objc(CefAppProtocol)
protocol CefAppProtocol: CrAppControlProtocol {}

/// The `NSApplication` subclass Chromium needs.
///
/// Chromium asks the application whether it is in the middle of dispatching
/// an event, and expects quitting to close browsers first. The application
/// object must be this class from the start, so it has to be created before
/// anything else touches `NSApp`. ``CefRuntime/initialize(configuration:)``
/// and `CefSwiftApp` do that for you.
@objc(CefApplication)
public final class CefApplication: NSApplication, CefAppProtocol {
    private var handlingSendEvent = false

    /// Creates the shared application as a `CefApplication`. Call before any
    /// other use of `NSApp`; calling it again is harmless.
    public static func install() {
        precondition(
            shared is CefApplication,
            "NSApp is \(type(of: shared)), not CefApplication. Initialize CefRuntime before anything touches NSApp.")
    }

    func isHandlingSendEvent() -> Bool {
        handlingSendEvent
    }

    func setHandlingSendEvent(_ handlingSendEvent: Bool) {
        self.handlingSendEvent = handlingSendEvent
    }

    public override func sendEvent(_ event: NSEvent) {
        let wasHandling = handlingSendEvent
        handlingSendEvent = true
        defer { handlingSendEvent = wasHandling }
        super.sendEvent(event)
    }

    /// Posted when an assistive app asks the application for its full
    /// accessibility tree by setting `AXEnhancedUserInterface` or
    /// `AXManualAccessibility`, as Voice Control, Switch Control and UI
    /// automation tools do. Offscreen browsers with
    /// ``CefBrowser/AccessibilityPolicy/automatic`` start building their tree.
    public nonisolated static let accessibilityRequestedNotification = Notification.Name("CefApplicationAccessibilityRequested")

    /// Whether an assistive app has asked for the full accessibility tree
    /// since launch. See ``accessibilityRequestedNotification``.
    public private(set) static var isAccessibilityRequested = false

    /// Catches `AXEnhancedUserInterface` and `AXManualAccessibility`, which
    /// arrive only through the informal accessibility protocol.
    public override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        let isRequest = attribute.rawValue == "AXEnhancedUserInterface" || attribute.rawValue == "AXManualAccessibility"
        if isRequest, (value as? NSNumber)?.boolValue == true {
            MainActor.assumeIsolated {
                guard !Self.isAccessibilityRequested else { return }
                Self.isAccessibilityRequested = true
                NotificationCenter.default.post(name: Self.accessibilityRequestedNotification, object: nil)
            }
        }
        // AppKit does not know AXManualAccessibility, which Chromium
        // introduced; accepting it here is enough.
        guard attribute.rawValue != "AXManualAccessibility" else { return }
        // The informal protocol is deprecated, so NSApplication's own
        // implementation is called through the runtime.
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?, NSString) -> Void
        guard let implementation = class_getMethodImplementation(NSApplication.self, selector) else { return }
        unsafeBitCast(implementation, to: Setter.self)(self, selector, value as AnyObject?, attribute.rawValue as NSString)
    }

    /// Quitting closes every browser first, so pages can run `beforeunload`
    /// and state is flushed; the runtime calls back here once they are gone.
    public override func terminate(_ sender: Any?) {
        if CefRuntime.shared.handleTerminationRequest() {
            super.terminate(sender)
        }
    }
}
