// CefSwift helper-process executable.
//
// This binary is copied five times into the app bundle by `swift package cef
// bundle` (Helper, Alerts, GPU, Plugin, Renderer variants). It loads the CEF
// framework from the bundle-relative location, runs cef_execute_process for
// whatever subprocess type CEF requested, and exits. It never returns.

import CefKit

CefRuntime.helperMain()
