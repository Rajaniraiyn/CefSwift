// CefSwift — CEFApplication implementation.
//
// Mirrors the official cefsimple_capi sample (tests/cefsimple_capi/
// cefsimple_mac.m): sendEvent: wraps the handlingSendEvent flag, and
// terminate: routes through a registered handler so quitting closes CEF
// browsers cleanly before the application exits.

#import "CCefAppKit.h"

static CEFApplicationTerminateHandler g_terminate_handler = NULL;

@implementation CEFApplication {
  BOOL _handlingSendEvent;
}

+ (void)install {
  NSApplication* app = [CEFApplication sharedApplication];
  NSCAssert([app isKindOfClass:[CEFApplication class]],
            @"NSApp is %@, not CEFApplication. CEFApplication.install (or "
            @"CefRuntime.initialize) must run before anything else touches "
            @"NSApp — e.g. before NSApplicationMain or SwiftUI's App.main().",
            [app className]);
  (void)app;
}

+ (void)setTerminateHandler:(nullable CEFApplicationTerminateHandler)handler {
  g_terminate_handler = handler;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  BOOL previous = _handlingSendEvent;
  _handlingSendEvent = YES;
  [super sendEvent:event];
  _handlingSendEvent = previous;
}

- (void)terminate:(id)sender {
  if (g_terminate_handler != NULL && !g_terminate_handler()) {
    // The handler deferred termination (e.g. CEF browsers are still closing).
    // It is responsible for calling -terminate: again when ready.
    return;
  }
  [super terminate:sender];
}

@end
