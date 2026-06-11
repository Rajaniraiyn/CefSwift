// CefSwift — CEFApplication, an NSApplication subclass conforming to CEF's
// CefAppProtocol (CrAppControlProtocol).
//
// CEF requires the NSApplication instance to (a) conform to
// CrAppControlProtocol so it can track when Cocoa is handling sendEvent:, and
// (b) exist BEFORE any other code touches NSApp. The protocols are
// re-declared here verbatim from CEF's include/cef_application_mac.h so this
// target never imports CEF's C++ headers.

#ifndef CCEF_APPKIT_H_
#define CCEF_APPKIT_H_

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Copy of CrAppProtocol from include/cef_application_mac.h.
@protocol CrAppProtocol
// Returns YES if the application is currently inside -[NSApplication sendEvent:].
- (BOOL)isHandlingSendEvent;
@end

// Copy of CrAppControlProtocol from include/cef_application_mac.h.
@protocol CrAppControlProtocol <CrAppProtocol>
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent;
@end

// Copy of CefAppProtocol from include/cef_application_mac.h.
@protocol CefAppProtocol <CrAppControlProtocol>
@end

/// Invoked when the user (or the system) asks the application to terminate.
/// Return YES to allow termination to proceed immediately; return NO to defer
/// (the callback is expected to close CEF browsers first and re-trigger
/// termination once they are gone).
typedef BOOL (*CEFApplicationTerminateHandler)(void);

/// NSApplication subclass required by CEF. Must be installed before any other
/// code touches NSApp (i.e. before NSApplicationMain/SwiftUI App.main()).
@interface CEFApplication : NSApplication <CefAppProtocol>

/// Creates the shared application instance ([CEFApplication sharedApplication])
/// and asserts that NSApp is a CEFApplication. Call as the first thing in
/// main(), before any NSApp access. Calling it after another NSApplication
/// has been created is a fatal programmer error.
+ (void)install;

/// Registers a C callback consulted by -terminate:. When NULL (default),
/// -terminate: falls through to NSApplication's standard behavior.
+ (void)setTerminateHandler:(nullable CEFApplicationTerminateHandler)handler;

@end

NS_ASSUME_NONNULL_END

#endif  // CCEF_APPKIT_H_
