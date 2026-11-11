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

    /// Quitting closes every browser first, so pages can run `beforeunload`
    /// and state is flushed; the runtime calls back here once they are gone.
    public override func terminate(_ sender: Any?) {
        if CefRuntime.shared.handleTerminationRequest() {
            super.terminate(sender)
        }
    }
}
